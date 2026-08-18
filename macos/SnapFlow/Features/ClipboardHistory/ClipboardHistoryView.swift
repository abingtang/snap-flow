import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// local key monitor 用的引用语义桥：避免闭包捕获过期 `View` 值后吞键却不更新选中。
@MainActor
private final class ClipboardKeyEventBridge {
    var handler: ((NSEvent) -> Bool)?
}

/// 剪切板历史 UI 呈现方式。
enum ClipboardHistoryPresentation: Sendable {
    /// 菜单栏浮层（固定宽高 + 局部快捷键）
    case floating
    /// 偏好设置内嵌（占满可用区域，不抢全局快捷键）
    case embedded
}

struct ClipboardHistoryView: View {
    let container: AppContainer
    let onPaste: (HistoryItem, Bool) -> Void
    let onClose: () -> Void
    let onPreviewChanged: (Bool) -> Void
    /// 文本 → 划词翻译；图片 → 截图翻译（OCR + 多服务）
    var onTranslate: ((HistoryItem) -> Void)? = nil
    var presentation: ClipboardHistoryPresentation = .floating
    /// 设置页内嵌时固定范围；浮层由内部 Tab 切换。
    var listScope: HistoryListScope = .clipboard
    /// 设置页 deep link：出现时自动打开「添加自定义收藏」
    var autoPresentAddFavorite: Bool = false

    @Environment(\.snapFlowAccent) private var accent
    @State private var query = ""
    @State private var timeFilter = HistoryTimeFilter()
    @State private var selectedID: UUID?
    @State private var isPreviewOpen = false
    @State private var eventMonitor: Any?
    /// 把 key 处理闭包挂在 class 上，避免 local monitor 捕获过期 View 值
    @State private var eventBridge = ClipboardKeyEventBridge()
    /// 浮层：剪切板 / 收藏 Tab
    @State private var floatingScope: HistoryListScope = .clipboard
    /// 手动添加自定义收藏（仅设置内嵌弹窗）
    @State private var showAddCustomFavorite = false
    @State private var didAutoPresentAddFavorite = false
    /// 设置页分页；浮层使用连续滚动的批次窗口。
    @State private var page = 1
    @State private var floatingVisibleCount = HistoryListWindowing.initialVisibleCount
    @State private var floatingScrollResetToken = 0
    @State private var floatingNewItemsCount = 0
    @State private var floatingObservedItemIDs: [UUID] = []
    /// 筛选后的全量快照（避免 body 每次 search + filter）。
    @State private var cachedAllItems: [HistoryItem] = []

    private var currentScope: HistoryListScope {
        isEmbedded ? listScope : floatingScope
    }

    /// 筛选后的全量（分页前）— 读缓存。
    private var allItems: [HistoryItem] { cachedAllItems }

    /// 当前呈现条目：设置页按页切片，浮层按已展开批次截取。
    private var items: [HistoryItem] {
        if isEmbedded {
            return HistoryListPagination.slice(allItems, page: page).items
        }
        return Array(allItems.prefix(floatingVisibleCount))
    }

    private var selectedItem: HistoryItem? {
        selectedID.flatMap { id in items.first { $0.id == id } }
            // 选中可能跨页：在全量中回退查找，便于预览仍可用
            ?? selectedID.flatMap { id in allItems.first { $0.id == id } }
    }

    private var isEmbedded: Bool { presentation == .embedded }

    var body: some View {
        // 订阅强调色与列表世代，便于缓存失效
        let _ = container.settings.useSystemAccentColor
        let _ = container.historyStore.listEpoch
        Group {
            if isEmbedded {
                embeddedBody
            } else {
                floatingBody
            }
        }
        .foregroundStyle(AppTheme.textPrimary)
        .tint(accent)
        .onAppear {
            rebuildCachedAllItems()
            if presentation == .floating {
                floatingScope = listScope
                floatingObservedItemIDs = allItems.map(\.id)
                floatingNewItemsCount = 0
                // 延后一帧安装：避免 SwiftUI 重复 onAppear 叠多个 monitor，
                // 旧闭包吞键且改不到当前 @State（表现为方向键要按好几下才动）。
                DispatchQueue.main.async {
                    installEventMonitor()
                }
            }
            if selectedID == nil || selectedItem == nil {
                selectedID = items.first?.id
            }
            if autoPresentAddFavorite, isEmbedded, !didAutoPresentAddFavorite {
                didAutoPresentAddFavorite = true
                // 等设置窗成为 key 后再弹 sheet，避免首帧被挡
                DispatchQueue.main.async {
                    showAddCustomFavorite = true
                }
            }
        }
        .onDisappear {
            removeEventMonitor()
        }
        .onChange(of: query) {
            page = 1
            rebuildCachedAllItems()
            if !isEmbedded { resetFloatingWindow() }
            selectedID = allItems.first?.id
            rebindKeyHandler()
        }
        .onChange(of: timeFilter) {
            page = 1
            rebuildCachedAllItems()
            if !isEmbedded { resetFloatingWindow() }
            selectedID = allItems.first?.id
            rebindKeyHandler()
        }
        .onChange(of: floatingScope) {
            page = 1
            rebuildCachedAllItems()
            resetFloatingWindow()
            selectedID = allItems.first?.id
            rebindKeyHandler()
        }
        .onChange(of: listScope) {
            guard isEmbedded else { return }
            page = 1
            rebuildCachedAllItems()
            selectedID = allItems.first?.id
            rebindKeyHandler()
        }
        .onChange(of: page) {
            guard isEmbedded else { return }
            // 换页后选中落在本页第一条（若原选中仍在本页则保留）
            if selectedID == nil || !items.contains(where: { $0.id == selectedID }) {
                selectedID = items.first?.id
            }
            rebindKeyHandler()
        }
        .onChange(of: container.historyStore.listEpoch) {
            handleStoreListEpochChange()
        }
        .sheet(isPresented: $showAddCustomFavorite) {
            AddCustomFavoriteSheet { text, image in
                if let item = commitCustomFavorite(text: text, image: image) {
                    selectedID = item.id
                    if !isEmbedded {
                        floatingScope = .favorites
                    }
                }
            }
        }
    }

    /// 按当前 query / 时间 / scope 重建列表缓存。
    private func rebuildCachedAllItems() {
        let next = container.historyStore.search(query, scope: currentScope)
            .filter { timeFilter.contains($0.createdAt) }
        // 结构未变时仍替换引用（SwiftData 对象可能已 reload），但避免无意义的空→空抖动。
        if next.isEmpty, cachedAllItems.isEmpty { return }
        cachedAllItems = next
    }

    /// Store 数据变更：重建缓存并维护浮层插入提示 / 选中。
    private func handleStoreListEpochChange() {
        let previousIDs = cachedAllItems.map(\.id)
        // 首帧 / 空缓存时用浮层已观察 id，避免把全量当成「新记录」
        let baselineIDs = previousIDs.isEmpty ? floatingObservedItemIDs : previousIDs
        let shouldCountInserts = !isEmbedded && !baselineIDs.isEmpty
        rebuildCachedAllItems()
        let newIDs = cachedAllItems.map(\.id)

        if isEmbedded {
            let info = HistoryListPagination.pageInfo(totalCount: allItems.count, page: page)
            if info.page != page { page = info.page }
            if selectedItem == nil { selectedID = items.first?.id }
        } else {
            if shouldCountInserts {
                floatingNewItemsCount += HistoryListWindowing.insertedCount(
                    currentIDs: newIDs,
                    previousIDs: baselineIDs
                )
            }
            floatingObservedItemIDs = newIDs

            if let selectedID,
               let index = allItems.firstIndex(where: { $0.id == selectedID })
            {
                let required = HistoryListWindowing.countRequired(
                    toShow: index,
                    totalCount: allItems.count
                )
                if required > floatingVisibleCount {
                    floatingVisibleCount = required
                }
            } else {
                selectedID = allItems.first?.id
            }
        }
        rebindKeyHandler()
    }

    // MARK: - 设置页内嵌：外框对齐 OCR 历史页

    private var embeddedBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            historySearchField(
                query: $query,
                timeFilter: $timeFilter,
                placeholder: currentScope == .favorites ? L10n.string("搜索收藏") : L10n.string("搜索剪切板历史")
            )

            if allItems.isEmpty {
                // 收藏空态：标题 +「添加自定义」仍在上方，与有数据时一致
                if currentScope == .favorites {
                    HStack(alignment: .center, spacing: 10) {
                        Text(L10n.string("收藏列表"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                        addCustomFavoriteButton
                        Spacer(minLength: 0)
                    }
                }
                historyEmptyState(
                    symbol: emptySymbol,
                    title: emptyTitle,
                    message: emptyDescription
                )
                .frame(maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    // 列表在卡片内滚动，高度随设置窗可用空间伸缩
                    historyListCard(
                        title: currentScope == .favorites ? L10n.string("收藏列表") : L10n.string("最近记录"),
                        fillsAvailableHeight: true,
                        trailing: {
                            if currentScope == .favorites {
                                addCustomFavoriteButton
                            }
                        }
                    ) {
                        ScrollViewReader { proxy in
                            LazyVStack(spacing: 0) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                    row(item, quickIndex: nil)
                                        .id(item.id)
                                    if index < items.count - 1 {
                                        Divider()
                                            .opacity(0.28)
                                            .padding(.leading, 36)
                                    }
                                }
                            }
                            .onChange(of: selectedID) {
                                if let selectedID {
                                    // 与浮层一致：最小滚动进可见区，避免居中猛滑
                                    proxy.scrollTo(selectedID)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // 预览侧栏与列表同高，保证整卡落在窗口内
                    if isPreviewOpen {
                        embeddedPreviewPane
                            .frame(width: 280)
                            .frame(maxHeight: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)

                HistoryPaginationBar(totalCount: allItems.count, page: $page)
            }

            HStack(spacing: 12) {
                revealInFinderHistoryButton {
                    _ = container.historyStore.revealDirectoryInFinder()
                }

                // 设置页保留批量清理；预览改由列表条目点击展开
                if currentScope == .favorites {
                    destructiveHistoryButton(L10n.string("取消全部收藏")) {
                        container.historyStore.clearFavorites()
                        page = 1
                        selectedID = items.first?.id
                    }
                    .disabled(container.historyStore.favoriteItems.isEmpty)
                } else {
                    destructiveHistoryButton(L10n.string("清空未固定内容")) {
                        container.historyStore.clearUnpinned()
                        page = 1
                        selectedID = items.first?.id
                    }
                    .disabled(
                        container.historyStore.unpinnedItems.filter { !$0.isFavorite }.isEmpty
                    )
                }

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var addCustomFavoriteButton: some View {
        Button {
            showAddCustomFavorite = true
        } label: {
            Label(L10n.string("添加自定义"), systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        // 标题行内用小号，避免压过「收藏列表」
        .controlSize(.small)
        .help(L10n.string("手动添加文本或图片到收藏"))
        .onHover { inside in
            updateHandCursor(inside)
        }
    }

    @discardableResult
    private func commitCustomFavorite(text: String?, image: NSImage?) -> HistoryItem? {
        let item = container.historyStore.addFavorite(
            text: text,
            image: image,
            application: HistoryStore.manualFavoriteApplicationID
        )
        return item
    }

    private var embeddedPreviewPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L10n.string("预览"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer(minLength: 0)
                if let item = selectedItem {
                    previewDetailActions(for: item)
                }
            }
            Group {
                if let item = selectedItem {
                    previewContent(item)
                } else {
                    Text(L10n.string("选择一条记录"))
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(AppTheme.border, lineWidth: 1)
            )
        }
    }

    // MARK: - 菜单栏浮层

    private var floatingBody: some View {
        HStack(spacing: 0) {
            floatingMainPanel
                .frame(width: 360)
                .frame(maxHeight: .infinity)

            if isPreviewOpen {
                Divider()
                preview
                    .frame(width: 320)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(height: 560)
        .background(AppTheme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppTheme.border)
        }
    }

    private var floatingMainPanel: some View {
        let visibleItems = items
        let totalCount = allItems.count

        return VStack(spacing: 0) {
            floatingSearchField
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 6)

            floatingScopeBar
            Divider()

            if floatingNewItemsCount > 0 {
                floatingNewItemsBanner
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
            }

            if allItems.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: emptySymbol,
                    description: Text(emptyDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                                    row(item, quickIndex: index < 9 ? index + 1 : nil)
                                        .id(item.id)
                                        .onAppear {
                                            if HistoryListWindowing.shouldLoadMore(
                                                itemIndex: index,
                                                visibleCount: visibleItems.count,
                                                totalCount: totalCount
                                            ) {
                                                loadMoreFloatingItems()
                                            }
                                        }
                                }
                            }
                            .padding(8)
                            // 底部留白：收藏 FAB
                            .padding(.bottom, floatingScope == .favorites ? 56 : 8)
                        }
                        .scrollIndicators(.automatic)
                        .overlayScrollersPreferred()
                        .onChange(of: selectedID) {
                            if let selectedID {
                                // 仅滚到可见，勿 anchor:.center：居中滚动会把列表在光标下猛滑，
                                // 像「鼠标位置变了」，并触发 hover 光标抖动。
                                proxy.scrollTo(selectedID)
                            }
                        }
                        .onChange(of: floatingScrollResetToken) {
                            guard let firstID = visibleItems.first?.id else { return }
                            DispatchQueue.main.async {
                                proxy.scrollTo(firstID, anchor: .top)
                            }
                        }
                    }

                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if floatingScope == .favorites {
                floatingAddFavoriteFAB
                    .padding(.trailing, 14)
                    .padding(.bottom, 14)
            }
        }
    }

    private var floatingNewItemsBanner: some View {
        Button {
            floatingNewItemsCount = 0
            selectedID = allItems.first?.id
            floatingScrollResetToken &+= 1
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.circle.fill")
                    .accessibilityHidden(true)
                Text(String(format: L10n.string("有 %lld 条新记录"), floatingNewItemsCount))
                Spacer(minLength: 0)
                Text(L10n.string("查看"))
                    .fontWeight(.medium)
            }
            .font(.system(size: 11))
            .foregroundStyle(accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
        .help(L10n.string("回到最新剪切板记录"))
        .accessibilityLabel(String(format: L10n.string("有 %lld 条新剪切板记录，查看最新记录"), floatingNewItemsCount))
    }

    /// 浮层收藏 Tab：右下角悬浮「+」，跳转设置 → 收藏 → 添加自定义。
    private var floatingAddFavoriteFAB: some View {
        Button {
            openSettingsAddCustomFavorite()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppTheme.onAccent)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(accent)
                        .shadow(color: .black.opacity(0.28), radius: 10, y: 3)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(L10n.string("在偏好设置中添加自定义收藏"))
        .clipboardPointer()
    }

    private func openSettingsAddCustomFavorite() {
        onClose()
        container.panelPresenter.showSettings(pane: .favorites, openAddCustomFavorite: true)
    }

    /// 搜索框下方：剪切板 / 收藏 Tab（预览改由卡片右侧入口打开）。
    private var floatingScopeBar: some View {
        HStack(spacing: 4) {
            floatingScopeTab(L10n.string("剪切板"), scope: .clipboard)
            floatingScopeTab(L10n.string("收藏"), scope: .favorites)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private func floatingScopeTab(_ title: String, scope: HistoryListScope) -> some View {
        let isSelected = floatingScope == scope
        return Button {
            floatingScope = scope
        } label: {
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? AppTheme.textPrimary : AppTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                Rectangle()
                    .fill(isSelected ? accent : Color.clear)
                    .frame(height: 2)
                    .clipShape(Capsule())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clipboardPointer()
        .help(scope == .favorites ? L10n.string("查看收藏") : L10n.string("查看剪切板历史"))
    }

    private var floatingSearchField: some View {
        historySearchField(
            query: $query,
            timeFilter: $timeFilter,
            placeholder: L10n.string("搜索"),
            searchFieldMaxWidth: 160,
            compact: true,
            onSubmit: { pasteSelected(plainText: false) }
        )
    }

    private func row(_ item: HistoryItem, quickIndex: Int?) -> some View {
        // 设置内嵌：单击展开右侧详情；浮层：单击粘贴（预览打开时双击才粘贴）
        let action = {
            if isEmbedded {
                expandDetail(for: item)
                return
            }
            selectedID = item.id
            let plainText = NSEvent.modifierFlags.contains(.shift)
            if isPreviewOpen {
                // Button 对双击会再触发一次 action，此时 clickCount == 2
                if NSApp.currentEvent?.clickCount == 2 {
                    onPaste(item, plainText)
                } else {
                    // 仅选中：视为最新复制，排到置顶项之后
                    container.historyStore.markAsLatestCopy(id: item.id)
                }
                return
            }
            onPaste(item, plainText)
        }

        // 设置内嵌：OCR 历史式扁平行；浮层：仅固定项带卡片底/边框
        // 内嵌：单击展开详情；浮层：单击粘贴（预览打开时双击才粘贴）
        let rowA11yLabel = rowAccessibilityLabel(for: item)
        let rowA11yHint = isEmbedded ? L10n.string("轻点展开详情") : L10n.string("轻点粘贴")
        let rowA11yActionName = isEmbedded ? L10n.string("展开详情") : L10n.string("粘贴")

        return Group {
            if isEmbedded {
                EmbeddedHistoryListRow(
                    isSelected: selectedID == item.id,
                    isPinned: item.isPinned,
                    accessibilityLabel: rowA11yLabel,
                    accessibilityHint: rowA11yHint,
                    accessibilityActionName: rowA11yActionName,
                    action: action
                ) { isRowHovered in
                    rowContent(item, quickIndex: quickIndex, isRowHovered: isRowHovered)
                }
            } else {
                ClipboardHistoryCard(
                    isSelected: selectedID == item.id,
                    isPinned: item.isPinned,
                    accessibilityLabel: rowA11yLabel,
                    accessibilityHint: rowA11yHint,
                    accessibilityActionName: rowA11yActionName,
                    action: action
                ) { isRowHovered in
                    rowContent(item, quickIndex: quickIndex, isRowHovered: isRowHovered)
                }
            }
        }
        .contextMenu {
            Button(currentScope == .favorites || isEmbedded ? L10n.string("复制到剪切板") : L10n.string("粘贴")) {
                onPaste(item, false)
            }
            if item.string != nil {
                Button(currentScope == .favorites || isEmbedded ? L10n.string("复制为纯文本") : L10n.string("粘贴为纯文本")) {
                    onPaste(item, true)
                }
            }
            Button(item.isFavorite ? L10n.string("取消收藏") : L10n.string("添加到收藏")) {
                container.historyStore.toggleFavorite(id: item.id)
            }
            if canTranslate(item), let onTranslate {
                Button(
                    canTranslateImage(item) && !canTranslateText(item) ? L10n.string("图片翻译") : L10n.string("翻译")
                ) {
                    selectedID = item.id
                    onTranslate(item)
                }
            }
            Button(isPreviewOpen && selectedID == item.id ? L10n.string("关闭详情") : L10n.string("展开详情")) {
                expandDetail(for: item)
            }
            if currentScope != .favorites {
                Button(item.isPinned ? L10n.string("取消固定") : L10n.string("固定")) {
                    container.historyStore.togglePin(id: item.id)
                }
            }
            Divider()
            if currentScope == .favorites {
                Button(L10n.string("取消收藏"), role: .destructive) {
                    container.historyStore.removeFavorite(id: item.id)
                }
            }
            Button(L10n.string("删除"), role: .destructive) {
                container.historyStore.delete(id: item.id)
            }
        }
    }

    /// 行内内容：浮层右侧默认快捷键，hover / 已展开时切预览；设置内嵌右侧固定为复制。
    @ViewBuilder
    private func rowContent(
        _ item: HistoryItem,
        quickIndex: Int?,
        isRowHovered: Bool
    ) -> some View {
        let isExpanded = isPreviewOpen && selectedID == item.id
        // 设置内嵌始终露出复制；浮层仍 hover / 已展开时显示预览入口
        let showTrailingAction = isEmbedded || isRowHovered || isExpanded

        HStack(spacing: 10) {
            sourceIcon(item)
                .frame(width: 24, height: 24)

            itemThumbnail(item)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .lineLimit(item.kind == .text ? 2 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // 第二行：日期 + 仅 icon 元信息（无文字说明，避免换行挤乱布局）
                HStack(spacing: 5) {
                    Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .lineLimit(1)
                    if item.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(AppTheme.warning)
                            .help(L10n.string("已收藏"))
                            .accessibilityLabel(L10n.string("已收藏"))
                    }
                    if item.isPinned, let chord = item.pinShortcut {
                        Text(HotKeyChord.displayString(from: chord))
                            .font(.caption2.monospacedDigit())
                            .lineLimit(1)
                    }
                    if item.copyCount > 1 {
                        // 重复复制次数：紧凑数字角标，无「复制 N 次」类长文案
                        Text("×\(item.copyCount)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(AppTheme.textTertiary)
                            .lineLimit(1)
                            .help(String(format: L10n.string("相同内容已复制 %lld 次"), item.copyCount))
                            .accessibilityLabel(String(format: L10n.string("复制 %lld 次"), item.copyCount))
                    }
                    if item.isUniversalClipboard {
                        Image(systemName: "icloud")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(AppTheme.textTertiary)
                            .help(L10n.string("来自通用剪切板（其他设备）"))
                            .accessibilityLabel(L10n.string("通用剪切板"))
                    }
                }
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            // 最右侧同一槽位：
            // - 设置内嵌：复制
            // - 浮层：快捷粘贴 chord；hover / 已展开 → 预览
            ZStack {
                if !isEmbedded, let quickIndex, let quickLabel = quickPasteDisplay(for: quickIndex) {
                    Text(quickLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(AppTheme.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .opacity(showTrailingAction ? 0 : 1)
                        .help(L10n.string("按此快捷键粘贴本条"))
                }

                // borderless Button 独立命中，不触发行 onTapGesture
                if isEmbedded {
                    Button {
                        selectedID = item.id
                        let plainText = NSEvent.modifierFlags.contains(.shift)
                        onPaste(item, plainText)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppTheme.textSecondary)
                            .frame(width: 26, height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(AppTheme.textPrimary.opacity(0.08))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.string("复制到剪切板（按住 Shift 复制为纯文本）"))
                    .accessibilityLabel(L10n.string("复制到剪切板"))
                    .opacity(showTrailingAction ? 1 : 0)
                    .allowsHitTesting(showTrailingAction)
                } else {
                    Button {
                        expandDetail(for: item)
                    } label: {
                        Image(systemName: "sidebar.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(isExpanded ? accent : AppTheme.textSecondary)
                            .frame(width: 26, height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(
                                        isExpanded
                                            ? accent.opacity(0.16)
                                            : AppTheme.textPrimary.opacity(0.08)
                                    )
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help(
                        isExpanded
                            ? container.settings.tooltip(L10n.string("关闭预览"), action: .clipboardTogglePreview)
                            : container.settings.tooltip(L10n.string("预览"), action: .clipboardTogglePreview)
                    )
                    .accessibilityLabel(isExpanded ? L10n.string("关闭预览") : L10n.string("预览"))
                    .opacity(showTrailingAction ? 1 : 0)
                    .allowsHitTesting(showTrailingAction)
                }
            }
            .frame(width: 26, height: 26)
            .animation(.easeOut(duration: 0.12), value: showTrailingAction)
        }
    }

    /// 收藏 / 翻译：详情侧栏操作区。
    @ViewBuilder
    private func previewDetailActions(for item: HistoryItem) -> some View {
        HStack(spacing: 6) {
            Button {
                container.historyStore.toggleFavorite(id: item.id)
            } label: {
                Image(systemName: item.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(item.isFavorite ? AppTheme.warning : AppTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(AppTheme.textPrimary.opacity(0.08))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(item.isFavorite ? L10n.string("取消收藏") : L10n.string("添加到收藏"))
            .onHover { inside in
                updateHandCursor(inside)
            }

            if canTranslate(item), let onTranslate {
                let imageOnly = canTranslateImage(item) && !canTranslateText(item)
                Button {
                    onTranslate(item)
                } label: {
                    Image(systemName: "globe")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(AppTheme.textPrimary.opacity(0.08))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(imageOnly ? L10n.string("图片翻译（OCR + 翻译）") : L10n.string("翻译此条内容"))
                .onHover { inside in
                    updateHandCursor(inside)
                }
            }
        }
    }

    private func canTranslateText(_ item: HistoryItem) -> Bool {
        item.string.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true
    }

    private func canTranslateImage(_ item: HistoryItem) -> Bool {
        // 只检查类型，避免列表渲染时全分辨率解码。
        item.hasImageRepresentation
    }

    private func canTranslate(_ item: HistoryItem) -> Bool {
        onTranslate != nil && (canTranslateText(item) || canTranslateImage(item))
    }

    /// 展开详情侧栏；再次点同一项的展开则关闭。
    private func expandDetail(for item: HistoryItem) {
        if isPreviewOpen, selectedID == item.id {
            withAnimation(.easeOut(duration: 0.15)) {
                isPreviewOpen = false
            }
            onPreviewChanged(false)
            return
        }
        selectedID = item.id
        if !isPreviewOpen {
            withAnimation(.easeOut(duration: 0.15)) {
                isPreviewOpen = true
            }
            onPreviewChanged(true)
        }
    }

    private var hasActiveFilter: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || timeFilter.isFiltering
    }

    private var emptyTitle: String {
        if hasActiveFilter { return L10n.string("没有匹配内容") }
        return currentScope == .favorites ? L10n.string("暂无收藏") : L10n.string("剪切板为空")
    }

    private var emptySymbol: String {
        if hasActiveFilter { return "magnifyingglass" }
        return currentScope == .favorites ? "star" : "clipboard"
    }

    private var emptyDescription: String {
        if hasActiveFilter {
            return historyNoMatchMessage(query: query, timeFilter: timeFilter)
        }
        if currentScope == .favorites {
            if isEmbedded {
                return L10n.string("可添加自定义文本或图片，也可在 OCR / 截图 / 翻译 / 剪切板条目上点星收藏")
            }
            return L10n.string("点右下角 + 在偏好设置中添加自定义收藏，或在其它结果里点星收藏")
        }
        return L10n.string("复制的文本、图片和文件会保存在本机")
    }

    @ViewBuilder
    private func sourceIcon(_ item: HistoryItem) -> some View {
        if item.application == HistoryStore.manualFavoriteApplicationID {
            Image(systemName: "star.fill")
                .foregroundStyle(AppTheme.warning)
        } else if item.isUniversalClipboard {
            Image(systemName: "icloud")
                .foregroundStyle(AppTheme.textSecondary)
        } else if let bundle = item.application,
                  let icon = ApplicationIconCache.icon(bundleIdentifier: bundle)
        {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "clipboard")
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    @ViewBuilder
    private func itemThumbnail(_ item: HistoryItem) -> some View {
        ClipboardListThumbnail(item: item)
    }

    @ViewBuilder
    private var preview: some View {
        if let item = selectedItem {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(L10n.string("预览"))
                        .font(.headline)
                    Spacer(minLength: 8)
                    previewDetailActions(for: item)
                    Button {
                        togglePreview()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppTheme.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(AppTheme.textPrimary.opacity(0.08))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.string("关闭预览"))
                    .clipboardPointer()
                }

                previewContent(item)

                Text(item.createdAt.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(16)
        } else {
            ContentUnavailableView(L10n.string("选择一条记录"), systemImage: "sidebar.right")
        }
    }

    @ViewBuilder
    private func previewContent(_ item: HistoryItem) -> some View {
        let hasText = hasPreviewText(item)
        // 预览也走降采样，避免侧栏为 260pt 高度却解码 4K 全图。
        let previewImage = ClipboardImageThumbnailCache.thumbnail(
            for: item,
            maxPixel: ClipboardImageThumbnailCache.previewMaxPixel
        )
        if let image = previewImage, hasText {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 260)

                    Divider()

                    Text(previewText(item))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else if let image = previewImage {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if item.kind == .file {
            filePreview(item)
        } else {
            ScrollView {
                Text(previewText(item))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func hasPreviewText(_ item: HistoryItem) -> Bool {
        if let string = item.string,
           !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return true
        }
        return item.content(for: .rtf) != nil || item.content(for: .html) != nil
    }

    private func filePreview(_ item: HistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(item.fileURLs, id: \.absoluteString) { url in
                HStack {
                    Image(nsImage: ApplicationIconCache.icon(filePath: url.path))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading) {
                        Text(url.lastPathComponent)
                        if !FileManager.default.fileExists(atPath: url.path) {
                            Text(L10n.string("源文件已不可用"))
                                .font(.caption)
                                .foregroundStyle(AppTheme.danger)
                        }
                    }
                }
            }
            Spacer()
        }
    }

    private func previewText(_ item: HistoryItem) -> AttributedString {
        if let rtf = item.content(for: .rtf),
           let attributed = try? NSAttributedString(
               data: rtf,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil
           )
        {
            return AttributedString(attributed)
        }
        if let html = item.content(for: .html),
           var source = String(data: html, encoding: .utf8)
        {
            source = source.replacingOccurrences(
                of: "(?is)<(script|iframe|object|embed).*?</\\1>|https?://[^\"' >]+",
                with: "",
                options: .regularExpression
            )
            if let data = source.data(using: .utf8),
               let attributed = try? NSAttributedString(
                   data: data,
                   options: [.documentType: NSAttributedString.DocumentType.html],
                   documentAttributes: nil
               )
            {
                return AttributedString(attributed)
            }
        }
        return AttributedString(item.string ?? item.title)
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private func rebindKeyHandler() {
        guard presentation == .floating else { return }
        eventBridge.handler = { [self] event in
            handle(event)
        }
    }

    private func installEventMonitor() {
        // 必须先卸掉旧 monitor，否则会叠多个闭包；旧闭包仍 return nil 吞键，
        // 却改不到当前 View 的 selectedID。
        removeEventMonitor()
        rebindKeyHandler()
        let bridge = eventBridge
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // AppKit local monitor 在主线程派发
            guard Thread.isMainThread else { return event }
            return bridge.handler?(event) == true ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let settings = container.settings

        // 方向键优先：无修饰时直接按 keyCode 导航。
        // 注意：不要 makeFirstResponder 抢焦点——系统「键盘焦点跟随指针/指针移到焦点」
        // 会把鼠标拽到 contentView 中心（看起来像跑到屏幕中间）。
        // local monitor 已吞掉 ↑↓，搜索框即使有焦点也不会吃掉方向键。
        if let nav = navigationOffset(for: event, settings: settings) {
            moveSelection(nav)
            return true
        }

        if let pinned = container.historyStore.pinnedItems.first(where: {
            guard let chord = $0.pinShortcut else { return false }
            return LocalShortcutMatcher.matches(event, chord: chord)
        }) {
            onPaste(pinned, false)
            return true
        }
        let actions: [LocalShortcutAction] = [
            .clipboardPaste, .clipboardPastePlain, .clipboardClose, .clipboardTogglePreview,
            .clipboardTogglePin, .clipboardDelete, .clipboardClearUnpinned,
            .clipboardQuick1, .clipboardQuick2, .clipboardQuick3, .clipboardQuick4,
            .clipboardQuick5, .clipboardQuick6, .clipboardQuick7, .clipboardQuick8,
            .clipboardQuick9,
        ]
        guard let action = actions.first(where: { settings.matches($0, event: event) }) else {
            return false
        }
        if action == .clipboardTogglePreview,
           event.window?.firstResponder is NSTextView,
           !query.isEmpty
        {
            return false
        }
        switch action {
        case .clipboardPaste: pasteSelected(plainText: false)
        case .clipboardPastePlain: pasteSelected(plainText: true)
        case .clipboardClose: onClose()
        case .clipboardTogglePreview: togglePreview()
        case .clipboardTogglePin:
            if let selectedID { container.historyStore.togglePin(id: selectedID) }
        case .clipboardDelete:
            if let selectedID { container.historyStore.delete(id: selectedID) }
        case .clipboardClearUnpinned:
            container.historyStore.clearUnpinned()
        default:
            if let index = quickIndex(for: action), items.indices.contains(index) {
                onPaste(items[index], false)
            }
        }
        return true
    }

    /// 解析「上一项 / 下一项」：优先用户配置的 chord；无修饰时也认 ↑↓ keyCode。
    private func navigationOffset(for event: NSEvent, settings: SettingsStore) -> Int? {
        if settings.matches(.clipboardPrevious, event: event) { return -1 }
        if settings.matches(.clipboardNext, event: event) { return 1 }

        // 默认 chord 为 up/down 时，无修饰方向键兜底（防止 TextField / 修饰位脏标志漏匹配）
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard mods.isEmpty else { return nil }
        let prevIsArrow = settings.shortcut(for: .clipboardPrevious)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "up"
        let nextIsArrow = settings.shortcut(for: .clipboardNext)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "down"
        // keyCode: 126 = ↑, 125 = ↓
        if prevIsArrow, event.keyCode == 126 { return -1 }
        if nextIsArrow, event.keyCode == 125 { return 1 }
        return nil
    }

    private func quickIndex(for action: LocalShortcutAction) -> Int? {
        let quick: [LocalShortcutAction] = [
            .clipboardQuick1, .clipboardQuick2, .clipboardQuick3, .clipboardQuick4,
            .clipboardQuick5, .clipboardQuick6, .clipboardQuick7, .clipboardQuick8,
            .clipboardQuick9,
        ]
        return quick.firstIndex(of: action)
    }

    /// 列表 1…9 对应 `clipboardQuick1…9` 的**用户配置**展示文案（空 chord 则不显示）。
    private func quickPasteDisplay(for oneBasedIndex: Int) -> String? {
        let quick: [LocalShortcutAction] = [
            .clipboardQuick1, .clipboardQuick2, .clipboardQuick3, .clipboardQuick4,
            .clipboardQuick5, .clipboardQuick6, .clipboardQuick7, .clipboardQuick8,
            .clipboardQuick9,
        ]
        guard oneBasedIndex >= 1, oneBasedIndex <= quick.count else { return nil }
        let chord = container.settings.shortcut(for: quick[oneBasedIndex - 1])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chord.isEmpty else { return nil }
        let display = HotKeyChord.displayString(from: chord)
        return display.isEmpty ? nil : display
    }

    private func resetFloatingWindow() {
        guard !isEmbedded else { return }
        floatingVisibleCount = HistoryListWindowing.initialCount(totalCount: allItems.count)
        floatingScrollResetToken &+= 1
        floatingNewItemsCount = 0
        floatingObservedItemIDs = allItems.map(\.id)
    }

    private func loadMoreFloatingItems() {
        guard !isEmbedded else { return }
        let next = HistoryListWindowing.nextCount(
            current: floatingVisibleCount,
            totalCount: allItems.count
        )
        guard next != floatingVisibleCount else { return }
        floatingVisibleCount = next
    }

    private func moveSelection(_ offset: Int) {
        // 设置页在页内移动并跨页；浮层在连续批次中移动并按需追加。
        let list = items
        guard !list.isEmpty || allItems.count > 0 else { return }

        if list.isEmpty {
            if isEmbedded {
                // 页已空（数据收缩）：夹紧页码后再试
                page = HistoryListPagination.pageInfo(totalCount: allItems.count, page: page).page
                selectedID = items.first?.id
            } else {
                resetFloatingWindow()
                selectedID = allItems.first?.id
            }
            return
        }

        let currentIndex = selectedID.flatMap { id in list.firstIndex { $0.id == id } }
        let base: Int
        if let currentIndex {
            base = currentIndex
        } else {
            base = offset > 0 ? -1 : list.count
        }
        let candidate = base + offset

        if candidate < 0 {
            if isEmbedded {
                let info = HistoryListPagination.pageInfo(totalCount: allItems.count, page: page)
                if info.hasPrevious {
                    page = info.page - 1
                    // 下一帧 items 已是新页；选中末条
                    DispatchQueue.main.async {
                        selectedID = items.last?.id
                    }
                }
            }
            return
        }
        if candidate >= list.count {
            if isEmbedded {
                let info = HistoryListPagination.pageInfo(totalCount: allItems.count, page: page)
                if info.hasNext {
                    page = info.page + 1
                    DispatchQueue.main.async {
                        selectedID = items.first?.id
                    }
                }
            } else if floatingVisibleCount < allItems.count {
                let previousCount = list.count
                loadMoreFloatingItems()
                if previousCount < allItems.count {
                    selectedID = allItems[previousCount].id
                }
            }
            return
        }

        let newID = list[candidate].id
        if selectedID != newID {
            selectedID = newID
        }
    }

    private func pasteSelected(plainText: Bool) {
        guard let selectedItem else { return }
        onPaste(selectedItem, plainText)
    }

    private func togglePreview() {
        if !isPreviewOpen, selectedItem == nil { return }
        withAnimation(.easeOut(duration: 0.15)) {
            isPreviewOpen.toggle()
        }
        onPreviewChanged(isPreviewOpen)
    }

    /// VoiceOver 行标签：优先 title，空则截取文本预览。
    private func rowAccessibilityLabel(for item: HistoryItem) -> String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        if let text = item.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return String(text.prefix(80))
        }
        return L10n.string("剪切板条目")
    }
}

/// 列表缩略图：内存 → 后台读盘 →（串行）短暂 fault 原图 Data 后后台解码。
/// 禁止多行同时在主线程解码全图，否则历史页首屏易 CPU 打满卡死。
private struct ClipboardListThumbnail: View {
    let item: HistoryItem
    @State private var image: NSImage?
    @State private var fileMissing = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else if item.hasImageRepresentation {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(AppTheme.surfaceMuted)
                    .frame(width: 48, height: 38)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppTheme.textTertiary)
                    }
            } else if item.kind == .file {
                let url = item.fileURLs.first
                Image(
                    nsImage: url.map { ApplicationIconCache.icon(filePath: $0.path) } ?? NSImage()
                )
                .resizable()
                .scaledToFit()
                .frame(width: 38, height: 38)
                .opacity(fileMissing ? 0.35 : 1)
            }
        }
        .task(id: item.id) {
            await load()
        }
    }

    @MainActor
    private func load() async {
        if item.kind == .file, let url = item.fileURLs.first {
            fileMissing = !FileManager.default.fileExists(atPath: url.path)
            return
        }
        guard item.hasImageRepresentation else { return }

        let maxPx = ClipboardImageThumbnailCache.listMaxPixel
        if let hit = ClipboardImageThumbnailCache.memoryCached(id: item.id, maxPixel: maxPx) {
            image = hit
            return
        }

        let id = item.id
        if let disk = await Task.detached(priority: .userInitiated, operation: {
            ClipboardImageThumbnailCache.loadThumbnailFromDisk(id: id, maxPixel: maxPx)
        }).value {
            ClipboardImageThumbnailCache.storeMemory(disk, id: id, maxPixel: maxPx)
            image = disk
            return
        }

        // 冷路径：门闸串行 + 主线程只取 Data，解码/落盘放后台。
        let materialized = await ClipboardListThumbnailFaultGate.withPermit {
            await Task.yield()
            guard !Task.isCancelled else { return nil as NSImage? }
            guard let data = item.primaryImageData else { return nil }
            return await Task.detached(priority: .utility, operation: {
                ClipboardImageThumbnailCache.materializeFromImageData(
                    data,
                    id: id,
                    listMaxPixel: maxPx
                )
            }).value
        }
        if let materialized {
            ClipboardImageThumbnailCache.storeMemory(materialized, id: id, maxPixel: maxPx)
            image = materialized
        }
    }
}

/// 设置页列表行：轻量选中/悬停，避免整行厚重色块。
/// 行点击用 `onTapGesture`（不用外层 Button），保证右侧复制 icon 的子 Button 可独立命中。
private struct EmbeddedHistoryListRow<Content: View>: View {
    let isSelected: Bool
    let isPinned: Bool
    let accessibilityLabel: String
    let accessibilityHint: String
    let accessibilityActionName: String
    let action: () -> Void
    let content: (Bool) -> Content
    @Environment(\.snapFlowAccent) private var accent
    @State private var isHovered = false

    init(
        isSelected: Bool,
        isPinned: Bool,
        accessibilityLabel: String,
        accessibilityHint: String,
        accessibilityActionName: String,
        action: @escaping () -> Void,
        @ViewBuilder content: @escaping (Bool) -> Content
    ) {
        self.isSelected = isSelected
        self.isPinned = isPinned
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.accessibilityActionName = accessibilityActionName
        self.action = action
        self.content = content
    }

    var body: some View {
        content(isHovered)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(rowBackground)
            .padding(.vertical, 1)
            // 整行点击展开详情；右侧复制 Button 自行处理，不会被外层吞掉
            .onTapGesture { action() }
            .onHover { inside in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovered = inside
                }
                updateHandCursor(inside)
            }
            .animation(.easeOut(duration: 0.14), value: isSelected)
            .animation(.easeOut(duration: 0.14), value: isPinned)
            // children: .contain 保留右侧复制等子 Button 的独立 accessibilityLabel
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(accessibilityHint)
            .accessibilityAction(named: Text(accessibilityActionName)) {
                action()
            }
    }

    @ViewBuilder
    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(fillColor)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(accent.opacity(0.28), lineWidth: 1)
                } else if isPinned {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(AppTheme.border.opacity(0.85), lineWidth: 1)
                }
            }
    }

    private var fillColor: Color {
        if isSelected {
            return accent.opacity(0.12)
        }
        if isPinned {
            return isHovered ? AppTheme.surfaceHover : AppTheme.surface
        }
        if isHovered {
            return AppTheme.textPrimary.opacity(0.06)
        }
        return .clear
    }
}

private struct ClipboardHistoryCard<Content: View>: View {
    let isSelected: Bool
    /// 仅固定项使用如图「整卡底色 + 边框」样式
    let isPinned: Bool
    let accessibilityLabel: String
    let accessibilityHint: String
    let accessibilityActionName: String
    let action: () -> Void
    /// 参数为整卡 hover，用于右侧「快捷键 ↔ 展开」切换
    let content: (Bool) -> Content

    @Environment(\.snapFlowAccent) private var accent
    @State private var isHovered = false

    init(
        isSelected: Bool,
        isPinned: Bool,
        accessibilityLabel: String,
        accessibilityHint: String,
        accessibilityActionName: String,
        action: @escaping () -> Void,
        @ViewBuilder content: @escaping (Bool) -> Content
    ) {
        self.isSelected = isSelected
        self.isPinned = isPinned
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.accessibilityActionName = accessibilityActionName
        self.action = action
        self.content = content
    }

    var body: some View {
        // 行用 onTapGesture，右侧预览用子 Button，避免嵌套 Button 吞点击
        content(isHovered)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .background(fillColor, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            }
            .onTapGesture { action() }
            .onHover { inside in
                isHovered = inside
                updateHandCursor(inside)
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.14), value: isSelected)
            .animation(.easeOut(duration: 0.14), value: isPinned)
            // children: .contain 保留右侧预览等子 Button 的独立 accessibilityLabel
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(accessibilityHint)
            .accessibilityAction(named: Text(accessibilityActionName)) {
                action()
            }
    }

    private var fillColor: Color {
        if isSelected {
            return accent.opacity(0.14)
        }
        if isPinned {
            // 如图：固定项整卡 surface 底
            return isHovered ? AppTheme.surfaceHover : AppTheme.surface
        }
        // 未固定：无卡片底，仅 hover 轻提示
        return isHovered ? AppTheme.textPrimary.opacity(0.06) : .clear
    }

    private var borderColor: Color {
        if isSelected {
            return accent.opacity(0.32)
        }
        if isPinned {
            return AppTheme.border.opacity(0.85)
        }
        return .clear
    }

    private var borderWidth: CGFloat {
        (isSelected || isPinned) ? 1 : 0
    }
}

/// 优先叠加式细滚动条，悬停才显眼。
private struct OverlayScrollersModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(OverlayScrollerConfigurator())
    }
}

private extension View {
    func overlayScrollersPreferred() -> some View {
        modifier(OverlayScrollersModifier())
    }
}

private struct OverlayScrollerConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.isHidden = true
        DispatchQueue.main.async { configure(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(from: nsView) }
    }

    private func configure(from view: NSView) {
        guard let scroll = view.enclosingScrollView else { return }
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.scrollerKnobStyle = .default
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        // 内边距避免滚动条压住列表圆角
        scroll.scrollerInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 2)
    }
}

private extension View {
    func clipboardPointer() -> some View {
        buttonStyle(.plain)
            .onHover { inside in
                updateHandCursor(inside)
            }
    }

    func clipboardFooterButton() -> some View {
        buttonStyle(.borderless)
            .onHover { inside in
                updateHandCursor(inside)
            }
    }
}

// MARK: - 添加自定义收藏

/// 手动写入收藏：文本（可编辑），图片通过输入框复制粘贴加入。
private struct AddCustomFavoriteSheet: View {
    /// 提交：text 与 image 至少一个非空。
    let onSave: (String?, NSImage?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var image: NSImage?
    @State private var errorMessage: String?

    private var canSave: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || image != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.string("添加自定义收藏"))
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(AppTheme.textPrimary.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .help(L10n.string("关闭"))
            }

            Text(
                String(
                    format: L10n.string("可只填文本或保存图文混合内容。复制图片后，在输入框按 %@ 插入。"),
                    ShortcutDisplay.label(chord: "cmd+v")
                )
            )
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string("文本"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                VStack(alignment: .leading, spacing: 0) {
                    TextEditor(text: $text)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(minHeight: 120, maxHeight: image == nil ? 180 : 220)
                        .onPasteCommand(of: [.image]) { _ in
                            pasteFromClipboard()
                        }

                    if let image {
                        Divider()
                            .padding(.horizontal, 10)
                        HStack(spacing: 10) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 160, maxHeight: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Text(L10n.string("已插入图片"))
                                .font(.system(size: 12))
                                .foregroundStyle(AppTheme.textSecondary)
                            Spacer(minLength: 0)
                            Button(L10n.string("移除"), role: .destructive) {
                                self.image = nil
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(10)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppTheme.surfaceMuted)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(AppTheme.border, lineWidth: 1)
                )
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.danger)
            }

            HStack {
                Spacer()
                Button(L10n.string("取消")) {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button(L10n.string("保存到收藏")) {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(AppTheme.panelBackground)
    }

    private func pasteFromClipboard() {
        errorMessage = nil
        let pb = NSPasteboard.general
        if let str = pb.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !str.isEmpty
        {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = str
            } else if text != str {
                text += (text.hasSuffix("\n") ? "" : "\n") + str
            }
        }
        if let img = NSImage(pasteboard: pb) {
            image = img
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, image == nil {
            errorMessage = L10n.string("剪切板中没有可用的文本或图片")
        }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let textOut: String? = trimmed.isEmpty ? nil : trimmed
        guard textOut != nil || image != nil else {
            errorMessage = L10n.string("请输入文本或添加图片")
            return
        }
        onSave(textOut, image)
        dismiss()
    }
}
