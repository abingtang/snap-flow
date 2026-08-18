import AppKit
import SwiftUI

// MARK: - 截图历史

struct SnipHistorySettingsView: View {
    @Environment(AppContainer.self) private var container
    @Bindable private var store = SnipHistoryStore.shared
    @State private var confirmClear = false
    @State private var query = ""
    @State private var timeFilter = HistoryTimeFilter()
    @State private var page = 1

    private var filteredRecords: [SnipHistoryStore.Record] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.records.filter { rec in
            guard timeFilter.contains(rec.createdAt) else { return false }
            guard !q.isEmpty else { return true }
            return FeatureHistoryIO.formatTimestamp(rec.createdAt).localizedCaseInsensitiveContains(q)
                || "\(rec.pixelWidth)×\(rec.pixelHeight)".localizedCaseInsensitiveContains(q)
                || "\(rec.pixelWidth)x\(rec.pixelHeight)".localizedCaseInsensitiveContains(q)
        }
    }

    private var paged: (items: [SnipHistoryStore.Record], info: HistoryListPagination.PageInfo) {
        HistoryListPagination.slice(filteredRecords, page: page)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            historySearchField(query: $query, timeFilter: $timeFilter, placeholder: L10n.string("搜索截图历史"))

            if store.records.isEmpty {
                historyEmptyState(
                    symbol: "camera.viewfinder",
                    title: L10n.string("暂无截图记录"),
                    message: container.settings.snipHistoryEnabled
                        ? L10n.string("成功完成区域截图后会出现在这里。点击卡片可复制图片；也可用下方入口在访达中查看文件夹。")
                        : L10n.string("当前未开启保存截图记录，可在「截图」设置中开启。已有记录仍可浏览。")
                )
                .frame(maxHeight: .infinity)
            } else if filteredRecords.isEmpty {
                historyEmptyState(
                    symbol: "magnifyingglass",
                    title: L10n.string("没有匹配内容"),
                    message: historyNoMatchMessage(query: query, timeFilter: timeFilter)
                )
                .frame(maxHeight: .infinity)
            } else {
                let pageItems = paged.items
                historyListCard(fillsAvailableHeight: true) {
                    ForEach(Array(pageItems.enumerated()), id: \.element.id) { index, record in
                        HStack(spacing: 8) {
                            Button {
                                container.workflows.copySnipHistoryToPasteboard(record)
                            } label: {
                                HStack(spacing: 12) {
                                    historyAsyncThumbnail(url: store.thumbnailFileURL(for: record))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(FeatureHistoryIO.formatTimestamp(record.createdAt))
                                            .settingsRowTitleText()
                                            .foregroundStyle(AppTheme.textPrimary)
                                        Text("\(record.pixelWidth)×\(record.pixelHeight)")
                                            .settingsBodyText()
                                            .foregroundStyle(AppTheme.textSecondary)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "doc.on.doc")
                                        .settingsCompactText()
                                        .foregroundStyle(AppTheme.textSecondary)
                                        .help(L10n.string("复制到剪切板"))
                                }
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                updateHandCursor(hovering)
                            }

                            historyListIconButton(
                                systemName: "eye",
                                help: L10n.string("快速预览")
                            ) {
                                previewSnipHistory(pageItems: pageItems, current: record)
                            }

                            historyListIconButton(
                                systemName: "pin",
                                help: L10n.string("贴到屏幕")
                            ) {
                                container.workflows.pinSnipHistoryToScreen(record)
                            }

                            historyListIconButton(
                                systemName: "folder",
                                help: L10n.string("在访达中显示此文件")
                            ) {
                                _ = store.revealInFinder(record)
                            }
                        }
                        .contextMenu {
                            Button(L10n.string("复制到剪切板")) {
                                container.workflows.copySnipHistoryToPasteboard(record)
                            }
                            Button(L10n.string("快速预览")) {
                                previewSnipHistory(pageItems: pageItems, current: record)
                            }
                            Button(L10n.string("贴到屏幕")) {
                                container.workflows.pinSnipHistoryToScreen(record)
                            }
                            Button(L10n.string("在访达中显示")) {
                                _ = store.revealInFinder(record)
                            }
                        }

                        if index < pageItems.count - 1 {
                            Divider().opacity(0.35)
                        }
                    }
                }

                HistoryPaginationBar(totalCount: filteredRecords.count, page: $page)
            }

            historyFooterActions {
                revealInFinderHistoryButton {
                    _ = store.revealDirectoryInFinder()
                }
                destructiveHistoryButton(L10n.string("清除截图历史")) {
                    confirmClear = true
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: query) { _, _ in page = 1 }
        .onChange(of: timeFilter) { _, _ in page = 1 }
        .confirmationDialog(L10n.string("清除全部截图历史？"), isPresented: $confirmClear) {
            Button(L10n.string("清除"), role: .destructive) {
                store.clearAll()
                page = 1
            }
            Button(L10n.string("取消"), role: .cancel) {}
        } message: {
            Text(L10n.string("将删除本地保存的截图文件，此操作不可撤销。"))
        }
    }

    private func previewSnipHistory(
        pageItems: [SnipHistoryStore.Record],
        current: SnipHistoryStore.Record
    ) {
        let urls = pageItems.map { store.imageFileURL(for: $0) }
        let index = pageItems.firstIndex(where: { $0.id == current.id }) ?? 0
        QuickLookPreviewController.shared.preview(urls: urls, startingAt: index)
    }
}

// MARK: - OCR 历史

struct OCRHistorySettingsView: View {
    @Environment(AppContainer.self) private var container
    @Bindable private var store = OCRHistoryStore.shared
    @State private var confirmClear = false
    @State private var query = ""
    @State private var timeFilter = HistoryTimeFilter()
    @State private var page = 1
    @State private var selectedID: UUID?
    @State private var isPreviewOpen = false

    private var filteredRecords: [OCRHistoryStore.Record] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.records.filter { rec in
            guard timeFilter.contains(rec.createdAt) else { return false }
            guard !q.isEmpty else { return true }
            return rec.text.localizedCaseInsensitiveContains(q)
                || rec.serviceDisplayName.localizedCaseInsensitiveContains(q)
                || FeatureHistoryIO.formatTimestamp(rec.createdAt).localizedCaseInsensitiveContains(q)
        }
    }

    private var paged: (items: [OCRHistoryStore.Record], info: HistoryListPagination.PageInfo) {
        HistoryListPagination.slice(filteredRecords, page: page)
    }

    private var selectedRecord: OCRHistoryStore.Record? {
        selectedID.flatMap { id in filteredRecords.first { $0.id == id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            historySearchField(query: $query, timeFilter: $timeFilter, placeholder: L10n.string("搜索 OCR 历史"))

            if store.records.isEmpty {
                historyEmptyState(
                    symbol: "text.viewfinder",
                    title: L10n.string("暂无识别记录"),
                    message: container.settings.ocrHistoryEnabled
                        ? L10n.string("完成文字识别后会出现在这里。点击条目在右侧查看详情。")
                        : L10n.string("当前未开启保存 OCR 识别记录，可在「OCR 设置」中开启。已有记录仍可查看详情。")
                )
                .frame(maxHeight: .infinity)
            } else if filteredRecords.isEmpty {
                historyEmptyState(
                    symbol: "magnifyingglass",
                    title: L10n.string("没有匹配内容"),
                    message: historyNoMatchMessage(query: query, timeFilter: timeFilter)
                )
                .frame(maxHeight: .infinity)
            } else {
                let pageItems = paged.items
                HStack(alignment: .top, spacing: 12) {
                    historyListCard(fillsAvailableHeight: true) {
                        ForEach(Array(pageItems.enumerated()), id: \.element.id) { index, record in
                            HistoryArchiveListRow(
                                isSelected: selectedID == record.id && isPreviewOpen,
                                accessibilityLabel: FeatureHistoryIO.previewText(record.text),
                                accessibilityHint: L10n.string("轻点展开详情"),
                                accessibilityActionName: L10n.string("展开详情"),
                                onSelect: { expandDetail(for: record) },
                                onCopy: {
                                    container.workflows.copyHistoryTextToPasteboard(record.text)
                                }
                            ) {
                                HStack(spacing: 12) {
                                    historyAsyncThumbnail(url: store.thumbnailFileURL(for: record))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(FeatureHistoryIO.formatTimestamp(record.createdAt))
                                            .settingsRowTitleText()
                                            .foregroundStyle(AppTheme.textPrimary)
                                        Text(FeatureHistoryIO.previewText(record.text))
                                            .settingsCompactText()
                                            .foregroundStyle(AppTheme.textSecondary)
                                            .lineLimit(2)
                                        Text(record.serviceDisplayName)
                                            .settingsBodyText()
                                            .foregroundStyle(AppTheme.textSecondary.opacity(0.9))
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                            .contextMenu {
                                Button(L10n.string("复制全文")) {
                                    container.workflows.copyHistoryTextToPasteboard(record.text)
                                }
                                Button(L10n.string("快速预览")) {
                                    previewOCRHistory(pageItems: pageItems, current: record)
                                }
                                Button(L10n.string("在访达中显示")) {
                                    _ = store.revealInFinder(record)
                                }
                                Divider()
                                Button(L10n.string("删除"), role: .destructive) {
                                    deleteRecord(record)
                                }
                            }

                            if index < pageItems.count - 1 {
                                Divider().opacity(0.35)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if isPreviewOpen {
                        HistoryArchiveDetailPane(title: L10n.string("预览")) {
                            if let record = selectedRecord {
                                OCRHistoryDetailContent(record: record, container: container)
                            } else {
                                Text(L10n.string("选择一条记录"))
                                    .font(.system(size: 12))
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        .frame(width: 280)
                        .frame(maxHeight: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)

                HistoryPaginationBar(totalCount: filteredRecords.count, page: $page)
            }

            historyFooterActions {
                revealInFinderHistoryButton {
                    _ = store.revealDirectoryInFinder()
                }
                destructiveHistoryButton(L10n.string("清除 OCR 历史")) {
                    confirmClear = true
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: query) { _, _ in
            page = 1
            collapsePreview()
        }
        .onChange(of: timeFilter) { _, _ in
            page = 1
            collapsePreview()
        }
        .onChange(of: page) { _, _ in
            // 换页后若当前选中不在本页，仍可从全量筛选结果保留详情
            if let selectedID, !filteredRecords.contains(where: { $0.id == selectedID }) {
                collapsePreview()
            }
        }
        .onDisappear {
            collapsePreview()
        }
        .confirmationDialog(L10n.string("清除全部 OCR 历史？"), isPresented: $confirmClear) {
            Button(L10n.string("清除"), role: .destructive) {
                store.clearAll()
                page = 1
                collapsePreview()
            }
            Button(L10n.string("取消"), role: .cancel) {}
        } message: {
            Text(L10n.string("将删除本地识别图与文本快照，此操作不可撤销。"))
        }
    }

    private func expandDetail(for record: OCRHistoryStore.Record) {
        if isPreviewOpen, selectedID == record.id {
            withAnimation(.easeOut(duration: 0.15)) {
                isPreviewOpen = false
            }
            return
        }
        selectedID = record.id
        if !isPreviewOpen {
            withAnimation(.easeOut(duration: 0.15)) {
                isPreviewOpen = true
            }
        }
    }

    private func collapsePreview() {
        isPreviewOpen = false
        selectedID = nil
    }

    private func deleteRecord(_ record: OCRHistoryStore.Record) {
        if selectedID == record.id {
            collapsePreview()
        }
        store.delete(id: record.id)
        page = HistoryListPagination.pageInfo(totalCount: filteredRecords.count, page: page).page
    }

    private func previewOCRHistory(
        pageItems: [OCRHistoryStore.Record],
        current: OCRHistoryStore.Record
    ) {
        let urls = pageItems.map { store.imageFileURL(for: $0) }
        let index = pageItems.firstIndex(where: { $0.id == current.id }) ?? 0
        QuickLookPreviewController.shared.preview(urls: urls, startingAt: index)
    }
}

// MARK: - 翻译历史

struct TranslationHistorySettingsView: View {
    @Environment(AppContainer.self) private var container
    @Bindable private var store = TranslationHistoryStore.shared
    @State private var confirmClear = false
    @State private var query = ""
    @State private var timeFilter = HistoryTimeFilter()
    @State private var page = 1
    @State private var selectedID: UUID?
    @State private var isPreviewOpen = false

    private var filteredRecords: [TranslationHistoryStore.Record] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.records.filter { rec in
            guard timeFilter.contains(rec.createdAt) else { return false }
            guard !q.isEmpty else { return true }
            return rec.sourceText.localizedCaseInsensitiveContains(q)
                || rec.primaryTranslation.localizedCaseInsensitiveContains(q)
                || rec.kind.badgeTitle.localizedCaseInsensitiveContains(q)
                || FeatureHistoryIO.formatTimestamp(rec.createdAt).localizedCaseInsensitiveContains(q)
        }
    }

    private var paged: (items: [TranslationHistoryStore.Record], info: HistoryListPagination.PageInfo) {
        HistoryListPagination.slice(filteredRecords, page: page)
    }

    private var selectedRecord: TranslationHistoryStore.Record? {
        selectedID.flatMap { id in filteredRecords.first { $0.id == id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            historySearchField(query: $query, timeFilter: $timeFilter, placeholder: L10n.string("搜索翻译历史"))

            if store.records.isEmpty {
                historyEmptyState(
                    symbol: "globe",
                    title: L10n.string("暂无翻译记录"),
                    message: container.settings.translationHistoryEnabled
                        ? L10n.string("划词或截图翻译成功后会出现在这里。点击条目在右侧查看详情。")
                        : L10n.string("当前未开启保存翻译记录，可在「翻译设置」中开启。已有记录仍可查看详情。")
                )
                .frame(maxHeight: .infinity)
            } else if filteredRecords.isEmpty {
                historyEmptyState(
                    symbol: "magnifyingglass",
                    title: L10n.string("没有匹配内容"),
                    message: historyNoMatchMessage(query: query, timeFilter: timeFilter)
                )
                .frame(maxHeight: .infinity)
            } else {
                let pageItems = paged.items
                HStack(alignment: .top, spacing: 12) {
                    historyListCard(fillsAvailableHeight: true) {
                        ForEach(Array(pageItems.enumerated()), id: \.element.id) { index, record in
                            HistoryArchiveListRow(
                                isSelected: selectedID == record.id && isPreviewOpen,
                                accessibilityLabel: FeatureHistoryIO.previewText(record.primaryTranslation),
                                accessibilityHint: L10n.string("轻点展开详情"),
                                accessibilityActionName: L10n.string("展开详情"),
                                onSelect: { expandDetail(for: record) },
                                onCopy: {
                                    container.workflows.copyHistoryTextToPasteboard(record.primaryTranslation)
                                }
                            ) {
                                HStack(spacing: 12) {
                                    if let thumbURL = store.thumbnailFileURL(for: record) {
                                        historyAsyncThumbnail(url: thumbURL)
                                    } else {
                                        historyTextBadge(record.kind.badgeTitle)
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 6) {
                                            Text(record.kind.badgeTitle)
                                                .settingsBadgeText(weight: .semibold)
                                                .foregroundStyle(AppTheme.accent)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(
                                                    Capsule(style: .continuous)
                                                        .fill(AppTheme.accent.opacity(0.12))
                                                )
                                            Text(FeatureHistoryIO.formatTimestamp(record.createdAt))
                                                .settingsCompactText(weight: .medium)
                                                .foregroundStyle(AppTheme.textPrimary)
                                        }
                                        Text(FeatureHistoryIO.previewText(record.sourceText))
                                            .settingsCompactText()
                                            .foregroundStyle(AppTheme.textSecondary)
                                            .lineLimit(1)
                                        Text(FeatureHistoryIO.previewText(record.primaryTranslation))
                                            .settingsCompactText()
                                            .foregroundStyle(AppTheme.textPrimary.opacity(0.85))
                                            .lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                            .contextMenu {
                                Button(L10n.string("复制主译文")) {
                                    container.workflows.copyHistoryTextToPasteboard(record.primaryTranslation)
                                }
                                Button(L10n.string("复制源文")) {
                                    container.workflows.copyHistoryTextToPasteboard(record.sourceText)
                                }
                                if store.imageFileURL(for: record) != nil {
                                    Button(L10n.string("快速预览")) {
                                        previewTranslationHistory(pageItems: pageItems, current: record)
                                    }
                                    Button(L10n.string("在访达中显示")) {
                                        _ = store.revealInFinder(record)
                                    }
                                }
                                Divider()
                                Button(L10n.string("删除"), role: .destructive) {
                                    deleteRecord(record)
                                }
                            }

                            if index < pageItems.count - 1 {
                                Divider().opacity(0.35)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if isPreviewOpen {
                        HistoryArchiveDetailPane(title: L10n.string("预览")) {
                            if let record = selectedRecord {
                                TranslationHistoryDetailContent(record: record, container: container)
                            } else {
                                Text(L10n.string("选择一条记录"))
                                    .font(.system(size: 12))
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        .frame(width: 280)
                        .frame(maxHeight: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)

                HistoryPaginationBar(totalCount: filteredRecords.count, page: $page)
            }

            historyFooterActions {
                revealInFinderHistoryButton {
                    _ = store.revealDirectoryInFinder()
                }
                destructiveHistoryButton(L10n.string("清除翻译历史")) {
                    confirmClear = true
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: query) { _, _ in
            page = 1
            collapsePreview()
        }
        .onChange(of: timeFilter) { _, _ in
            page = 1
            collapsePreview()
        }
        .onChange(of: page) { _, _ in
            if let selectedID, !filteredRecords.contains(where: { $0.id == selectedID }) {
                collapsePreview()
            }
        }
        .onDisappear {
            collapsePreview()
        }
        .confirmationDialog(L10n.string("清除全部翻译历史？"), isPresented: $confirmClear) {
            Button(L10n.string("清除"), role: .destructive) {
                store.clearAll()
                page = 1
                collapsePreview()
            }
            Button(L10n.string("取消"), role: .cancel) {}
        } message: {
            Text(L10n.string("将删除本地翻译快照与相关图片，此操作不可撤销。"))
        }
    }

    private func expandDetail(for record: TranslationHistoryStore.Record) {
        if isPreviewOpen, selectedID == record.id {
            withAnimation(.easeOut(duration: 0.15)) {
                isPreviewOpen = false
            }
            return
        }
        selectedID = record.id
        if !isPreviewOpen {
            withAnimation(.easeOut(duration: 0.15)) {
                isPreviewOpen = true
            }
        }
    }

    private func collapsePreview() {
        isPreviewOpen = false
        selectedID = nil
    }

    private func previewTranslationHistory(
        pageItems: [TranslationHistoryStore.Record],
        current: TranslationHistoryStore.Record
    ) {
        let urls = pageItems.compactMap { store.imageFileURL(for: $0) }
        guard !urls.isEmpty else {
            FeedbackCenter.shared.post(L10n.string("该记录没有可预览的图片"), level: .warning)
            return
        }
        let currentURL = store.imageFileURL(for: current)
        let index = currentURL.flatMap { url in urls.firstIndex(of: url) } ?? 0
        QuickLookPreviewController.shared.preview(urls: urls, startingAt: index)
    }

    private func deleteRecord(_ record: TranslationHistoryStore.Record) {
        if selectedID == record.id {
            collapsePreview()
        }
        store.delete(id: record.id)
        page = HistoryListPagination.pageInfo(totalCount: filteredRecords.count, page: page).page
    }
}

// MARK: - 历史档案侧栏（OCR / 翻译共用骨架）

/// 列表行：点行展开详情；右侧复制按钮独立命中（对齐剪切板设置页）。
private struct HistoryArchiveListRow<Content: View>: View {
    let isSelected: Bool
    let accessibilityLabel: String
    let accessibilityHint: String
    let accessibilityActionName: String
    let onSelect: () -> Void
    let onCopy: () -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.snapFlowAccent) private var accent
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onCopy) {
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
            .help(L10n.string("复制"))
            .accessibilityLabel(L10n.string("复制"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowFill)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(accent.opacity(0.28), lineWidth: 1)
                    }
                }
        }
        .padding(.vertical, 1)
        .onTapGesture { onSelect() }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = inside
            }
            updateHandCursor(inside)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .accessibilityAction(named: Text(accessibilityActionName)) {
            onSelect()
        }
    }

    private var rowFill: Color {
        if isSelected { return accent.opacity(0.12) }
        if isHovered { return AppTheme.textPrimary.opacity(0.06) }
        return .clear
    }
}

/// 右侧档案详情外壳：标题 + 独立滚动内容区。
private struct HistoryArchiveDetailPane<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
            content()
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
}

private struct HistoryArchiveIconButton: View {
    let systemName: String
    let help: String
    var isAccent: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isAccent ? AppTheme.warning : AppTheme.textSecondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(AppTheme.textPrimary.opacity(0.08))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
        .onHover { inside in
            updateHandCursor(inside)
        }
    }
}

private struct OCRHistoryDetailContent: View {
    let record: OCRHistoryStore.Record
    let container: AppContainer
    @State private var favoriteEpoch = 0

    private var isFavorited: Bool {
        _ = favoriteEpoch
        return container.historyStore.isTextFavorited(record.text)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    HistoryArchiveIconButton(
                        systemName: "doc.on.doc",
                        help: L10n.string("复制全文")
                    ) {
                        container.workflows.copyHistoryTextToPasteboard(record.text)
                    }
                    HistoryArchiveIconButton(
                        systemName: isFavorited ? "star.fill" : "star",
                        help: isFavorited ? L10n.string("取消收藏") : L10n.string("收藏文本"),
                        isAccent: isFavorited
                    ) {
                        _ = container.historyStore.toggleFavorite(
                            text: record.text,
                            application: "com.snapflow.ocr"
                        )
                        favoriteEpoch &+= 1
                    }
                    HistoryArchiveIconButton(systemName: "eye", help: L10n.string("快速预览")) {
                        QuickLookPreviewController.shared.preview(
                            url: OCRHistoryStore.shared.imageFileURL(for: record)
                        )
                    }
                    HistoryArchiveIconButton(systemName: "folder", help: L10n.string("在访达中显示")) {
                        _ = OCRHistoryStore.shared.revealInFinder(record)
                    }
                }

                historyArchiveImageBlock(
                    image: OCRHistoryStore.shared.loadImage(for: record),
                    missingTitle: L10n.string("原图已丢失")
                ) {
                    QuickLookPreviewController.shared.preview(
                        url: OCRHistoryStore.shared.imageFileURL(for: record)
                    )
                }

                historyArchiveMetaLine(
                    FeatureHistoryIO.formatTimestamp(record.createdAt)
                )
                historyArchiveMetaLine(
                    "\(record.serviceDisplayName) · \(record.pixelWidth)×\(record.pixelHeight)"
                )

                historyArchiveTextSection(title: L10n.string("识别全文"), text: record.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }
}

private struct TranslationHistoryDetailContent: View {
    let record: TranslationHistoryStore.Record
    let container: AppContainer
    @State private var favoriteEpoch = 0

    private var isFavorited: Bool {
        _ = favoriteEpoch
        return container.historyStore.isTextFavorited(record.primaryTranslation)
    }

    private var languageDirection: String {
        let source: String = {
            if record.sourceSelection == TranslationLanguage.autoSourceToken {
                return L10n.string("自动检测")
            }
            return TranslatePopupLanguageOption.from(code: record.sourceSelection).menuTitle
        }()
        let target: String = {
            if record.targetSelection == TranslationLanguage.systemTargetToken {
                return L10n.string("系统语言")
            }
            return TranslatePopupLanguageOption.from(code: record.targetSelection).menuTitle
        }()
        return "\(source) → \(target)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text(record.kind.badgeTitle)
                        .settingsBadgeText(weight: .semibold)
                        .foregroundStyle(AppTheme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule(style: .continuous)
                                .fill(AppTheme.accent.opacity(0.12))
                        )
                    Spacer(minLength: 0)
                    HistoryArchiveIconButton(
                        systemName: "doc.on.doc",
                        help: L10n.string("复制主译文")
                    ) {
                        container.workflows.copyHistoryTextToPasteboard(record.primaryTranslation)
                    }
                    HistoryArchiveIconButton(
                        systemName: isFavorited ? "star.fill" : "star",
                        help: isFavorited ? L10n.string("取消收藏") : L10n.string("收藏主译文"),
                        isAccent: isFavorited
                    ) {
                        _ = container.historyStore.toggleFavorite(
                            text: record.primaryTranslation,
                            application: "com.snapflow.translate"
                        )
                        favoriteEpoch &+= 1
                    }
                    if let imageURL = TranslationHistoryStore.shared.imageFileURL(for: record) {
                        HistoryArchiveIconButton(systemName: "eye", help: L10n.string("快速预览")) {
                            QuickLookPreviewController.shared.preview(url: imageURL)
                        }
                        HistoryArchiveIconButton(systemName: "folder", help: L10n.string("在访达中显示")) {
                            _ = TranslationHistoryStore.shared.revealInFinder(record)
                        }
                    }
                }

                historyArchiveMetaLine(FeatureHistoryIO.formatTimestamp(record.createdAt))
                historyArchiveMetaLine(languageDirection)

                if record.kind == .screenTranslate {
                    historyArchiveImageBlock(
                        image: TranslationHistoryStore.shared.loadImage(for: record),
                        missingTitle: L10n.string("原图已丢失")
                    ) {
                        if let imageURL = TranslationHistoryStore.shared.imageFileURL(for: record) {
                            QuickLookPreviewController.shared.preview(url: imageURL)
                        }
                    }
                }

                historyArchiveTextSection(
                    title: L10n.string("源文"),
                    text: record.sourceText,
                    copyHelp: L10n.string("复制源文")
                ) {
                    container.workflows.copyHistoryTextToPasteboard(record.sourceText)
                }

                ForEach(record.services) { service in
                    let body = serviceBody(service)
                    historyArchiveTextSection(
                        title: service.displayName,
                        text: body,
                        copyHelp: L10n.string("复制此服务译文")
                    ) {
                        container.workflows.copyHistoryTextToPasteboard(body)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }

    private func serviceBody(_ service: TranslationServiceSnapshot) -> String {
        let text = service.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return service.text }
        if let status = service.statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !status.isEmpty
        {
            return status
        }
        return L10n.string("（无译文）")
    }
}

/// 列表行右侧小图标按钮（截图历史：预览 / 贴屏 / 访达）。
private func historyListIconButton(
    systemName: String,
    help: String,
    action: @escaping () -> Void
) -> some View {
    Button(action: action) {
        Image(systemName: systemName)
            .settingsCompactText(weight: .semibold)
            .foregroundStyle(AppTheme.textSecondary)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AppTheme.textPrimary.opacity(0.06))
            )
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityLabel(help)
    .onHover { hovering in
        updateHandCursor(hovering)
    }
}

@ViewBuilder
private func historyArchiveImageBlock(
    image: NSImage?,
    missingTitle: String,
    onQuickLook: (() -> Void)? = nil
) -> some View {
    if let image {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(AppTheme.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture {
                onQuickLook?()
            }
            .help(onQuickLook == nil ? "" : L10n.string("点击快速预览"))
            .onHover { hovering in
                if onQuickLook != nil {
                    updateHandCursor(hovering)
                }
            }
    } else {
        VStack(spacing: 6) {
            Image(systemName: "photo")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(AppTheme.textTertiary)
            Text(missingTitle)
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 100)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.surfaceMuted)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(AppTheme.border, lineWidth: 1)
        )
    }
}

private func historyArchiveMetaLine(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 11))
        .foregroundStyle(AppTheme.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
}

@ViewBuilder
private func historyArchiveTextSection(
    title: String,
    text: String,
    copyHelp: String? = nil,
    onCopy: (() -> Void)? = nil
) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
            Spacer(minLength: 0)
            if let onCopy, let copyHelp {
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(AppTheme.textPrimary.opacity(0.08))
                        )
                }
                .buttonStyle(.borderless)
                .help(copyHelp)
                .accessibilityLabel(copyHelp)
            }
        }
        Text(text.isEmpty ? L10n.string("（无文字）") : text)
            .font(.system(size: 12))
            .foregroundStyle(AppTheme.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(AppTheme.textPrimary.opacity(0.04))
    )
}

// MARK: - Shared chrome

/// 历史列表时间预设。
enum HistoryTimeRange: String, CaseIterable, Identifiable, Sendable {
    case all
    case today
    case last7Days
    case last30Days
    case last90Days
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: L10n.string("全部时间")
        case .today: L10n.string("今天")
        case .last7Days: L10n.string("近 7 天")
        case .last30Days: L10n.string("近 30 天")
        case .last90Days: L10n.string("近 90 天")
        case .custom: L10n.string("自定义")
        }
    }
}

/// 历史时间筛选状态：预设 + 自定义起止日期（含两端整日）。
struct HistoryTimeFilter: Equatable, Sendable {
    var range: HistoryTimeRange = .all
    /// 自定义起始日（按本地日界）
    var customStart: Date
    /// 自定义结束日（按本地日界，含当日）
    var customEnd: Date

    init(
        range: HistoryTimeRange = .all,
        customStart: Date? = nil,
        customEnd: Date? = nil,
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        self.range = range
        let todayStart = calendar.startOfDay(for: now)
        self.customEnd = calendar.startOfDay(for: customEnd ?? now)
        self.customStart = calendar.startOfDay(
            for: customStart
                ?? calendar.date(byAdding: .day, value: -30, to: todayStart)
                ?? todayStart
        )
    }

    var isFiltering: Bool { range != .all }

    /// 是否包含给定时间点（`createdAt` 等）。
    func contains(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> Bool {
        switch range {
        case .all:
            return true
        case .today:
            return calendar.isDate(date, inSameDayAs: now)
        case .last7Days:
            guard let start = calendar.date(byAdding: .day, value: -7, to: now) else { return true }
            return date >= start
        case .last30Days:
            guard let start = calendar.date(byAdding: .day, value: -30, to: now) else { return true }
            return date >= start
        case .last90Days:
            guard let start = calendar.date(byAdding: .day, value: -90, to: now) else { return true }
            return date >= start
        case .custom:
            let bounds = normalizedCustomBounds(calendar: calendar)
            return date >= bounds.start && date < bounds.endExclusive
        }
    }

    /// 规范化起止：按日对齐；若开始晚于结束则对调。
    func normalizedCustomBounds(calendar: Calendar = .current) -> (start: Date, endExclusive: Date) {
        let a = calendar.startOfDay(for: customStart)
        let b = calendar.startOfDay(for: customEnd)
        let start = min(a, b)
        let endDay = max(a, b)
        let endExclusive = calendar.date(byAdding: .day, value: 1, to: endDay) ?? endDay.addingTimeInterval(86_400)
        return (start, endExclusive)
    }

    /// 纠正自定义起止顺序（写入 state 时用）。
    mutating func normalizeCustomDates(calendar: Calendar = .current) {
        let bounds = normalizedCustomBounds(calendar: calendar)
        customStart = bounds.start
        // endExclusive 的前一天
        customEnd = calendar.date(byAdding: .day, value: -1, to: bounds.endExclusive) ?? bounds.start
    }
}

/// 历史页统一搜索栏：左侧短搜索框，右侧可选类型筛选 + 时间筛选。
func historySearchField(
    query: Binding<String>,
    timeFilter: Binding<HistoryTimeFilter>,
    placeholder: String = L10n.string("搜索"),
    searchFieldMaxWidth: CGFloat = 260,
    compact: Bool = false,
    onSubmit: (() -> Void)? = nil
) -> some View {
    historySearchField(
        query: query,
        timeFilter: timeFilter,
        placeholder: placeholder,
        searchFieldMaxWidth: searchFieldMaxWidth,
        compact: compact,
        onSubmit: onSubmit,
        leadingFilters: { EmptyView() }
    )
}

/// 历史页统一搜索栏（带额外筛选插槽，如录制类型下拉）。
func historySearchField<LeadingFilters: View>(
    query: Binding<String>,
    timeFilter: Binding<HistoryTimeFilter>,
    placeholder: String = L10n.string("搜索"),
    searchFieldMaxWidth: CGFloat = 260,
    compact: Bool = false,
    onSubmit: (() -> Void)? = nil,
    @ViewBuilder leadingFilters: () -> LeadingFilters
) -> some View {
    let showCustomDates = timeFilter.wrappedValue.range == .custom
    // 浮层较窄：自定义日期单独一行；设置页宽：与时间菜单同一行。
    let datesOnSecondRow = compact && showCustomDates

    return VStack(alignment: .leading, spacing: compact ? 6 : 8) {
        HStack(spacing: compact ? 8 : 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppTheme.textSecondary)
                TextField(placeholder, text: query)
                    .textFieldStyle(.plain)
                    .onSubmit { onSubmit?() }
                if !query.wrappedValue.isEmpty {
                    Button {
                        query.wrappedValue = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.textSecondary)
                    .onHover { hovering in
                        updateHandCursor(hovering)
                    }
                }
            }
            .padding(.horizontal, compact ? 10 : 12)
            .frame(maxWidth: searchFieldMaxWidth, alignment: .leading)
            .frame(height: compact ? 34 : 36)
            .background(
                RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                    .fill(compact ? AppTheme.surfaceMuted : AppTheme.surface)
            )
            .overlay {
                if !compact {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(AppTheme.border, lineWidth: 1)
                }
            }

            Spacer(minLength: 4)

            HStack(spacing: compact ? 6 : 8) {
                leadingFilters()

                Picker(L10n.string("时间"), selection: Binding(
                    get: { timeFilter.wrappedValue.range },
                    set: { newRange in
                        var next = timeFilter.wrappedValue
                        next.range = newRange
                        if newRange == .custom {
                            next.normalizeCustomDates()
                        }
                        timeFilter.wrappedValue = next
                    }
                )) {
                    ForEach(HistoryTimeRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(compact ? .small : .regular)
                .frame(minWidth: compact ? 88 : 108, alignment: .trailing)
                .help(L10n.string("按创建时间筛选历史"))

                if showCustomDates, !datesOnSecondRow {
                    historyCustomDatePickers(timeFilter: timeFilter, compact: compact)
                }
            }
        }

        if datesOnSecondRow {
            HStack {
                Spacer(minLength: 0)
                historyCustomDatePickers(timeFilter: timeFilter, compact: true)
            }
        }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}

@ViewBuilder
private func historyCustomDatePickers(
    timeFilter: Binding<HistoryTimeFilter>,
    compact: Bool
) -> some View {
    HStack(spacing: compact ? 4 : 6) {
        DatePicker(
            L10n.string("开始"),
            selection: Binding(
                get: { timeFilter.wrappedValue.customStart },
                set: { newStart in
                    var next = timeFilter.wrappedValue
                    next.customStart = newStart
                    next.normalizeCustomDates()
                    timeFilter.wrappedValue = next
                }
            ),
            in: ...timeFilter.wrappedValue.customEnd,
            displayedComponents: .date
        )
        .labelsHidden()
        .datePickerStyle(.compact)
        .controlSize(compact ? .small : .regular)
        .help(L10n.string("起始日期"))

        Text("–")
            .foregroundStyle(AppTheme.textSecondary)
            .settingsBodyText()

        DatePicker(
            L10n.string("结束"),
            selection: Binding(
                get: { timeFilter.wrappedValue.customEnd },
                set: { newEnd in
                    var next = timeFilter.wrappedValue
                    next.customEnd = newEnd
                    next.normalizeCustomDates()
                    timeFilter.wrappedValue = next
                }
            ),
            in: timeFilter.wrappedValue.customStart...,
            displayedComponents: .date
        )
        .labelsHidden()
        .datePickerStyle(.compact)
        .controlSize(compact ? .small : .regular)
        .help(L10n.string("结束日期"))
    }
    .fixedSize(horizontal: true, vertical: false)
}

/// 无匹配结果时的提示文案（区分关键词 / 时间筛选）。
func historyNoMatchMessage(query: String, timeFilter: HistoryTimeFilter) -> String {
    let hasQuery = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if hasQuery, timeFilter.isFiltering {
        return L10n.string("试试更短的关键词，或放宽时间范围。")
    }
    if hasQuery {
        return L10n.string("试试更短的关键词，或清空搜索。")
    }
    if timeFilter.range == .custom {
        return L10n.string("该起止日期内没有记录，可调整日期或切换为「全部时间」。")
    }
    if timeFilter.isFiltering {
        return L10n.string("当前时间范围内没有记录，可切换为「全部时间」。")
    }
    return L10n.string("试试更短的关键词，或清空搜索。")
}

@ViewBuilder
func historyListCard<Content: View>(
    title: String = L10n.string("最近记录"),
    /// 列表区最大高度；`nil` 时随内容撑开（空态等）
    maxListHeight: CGFloat? = nil,
    /// 在可用高度内伸展列表卡片（设置页 / 剪切板内嵌）
    fillsAvailableHeight: Bool = false,
    @ViewBuilder content: () -> Content
) -> some View {
    historyListCard(
        title: title,
        maxListHeight: maxListHeight,
        fillsAvailableHeight: fillsAvailableHeight,
        trailing: { EmptyView() },
        content: content
    )
}

/// 标题行可带 trailing（如收藏页「添加自定义」）。
/// 列表放在圆角卡片内；超高时内部滚动，保证分页条与底栏仍在窗口内完整可见。
@ViewBuilder
func historyListCard<Content: View, Trailing: View>(
    title: String = L10n.string("最近记录"),
    maxListHeight: CGFloat? = nil,
    fillsAvailableHeight: Bool = false,
    @ViewBuilder trailing: () -> Trailing,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .settingsCardTitleText()
                .foregroundStyle(AppTheme.textSecondary)
            trailing()
            Spacer(minLength: 0)
        }

        Group {
            if fillsAvailableHeight || maxListHeight != nil {
                ScrollView {
                    VStack(spacing: 0) {
                        content()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: fillsAvailableHeight ? .infinity : maxListHeight,
                    alignment: .top
                )
            } else {
                VStack(spacing: 0) {
                    content()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(
            maxWidth: .infinity,
            maxHeight: fillsAvailableHeight ? .infinity : nil,
            alignment: .top
        )
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .frame(
        maxWidth: .infinity,
        maxHeight: fillsAvailableHeight ? .infinity : nil,
        alignment: .topLeading
    )
}

@ViewBuilder
func historyEmptyState(symbol: String, title: String, message: String) -> some View {
    VStack(spacing: 12) {
        Image(systemName: symbol)
            .font(.system(size: 36, weight: .light, design: .default))
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .foregroundStyle(AppTheme.textSecondary.opacity(0.55))
        Text(title)
            .font(.headline)
            .dynamicTypeSize(SettingsTypography.contentTypeRange)
            .foregroundStyle(AppTheme.textPrimary)
        Text(message)
            .settingsCompactText()
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 48)
    .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(AppTheme.surface)
    )
    .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(AppTheme.border, lineWidth: 1)
    )
}

/// 底部操作区：左对齐。
@ViewBuilder
func historyFooterActions<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    HStack(spacing: 12) {
        content()
        Spacer(minLength: 0)
    }
}

/// 危险操作：红色实心按钮。
func destructiveHistoryButton(
    _ title: String,
    controlSize: ControlSize = .regular,
    action: @escaping () -> Void
) -> some View {
    Button(title, role: .destructive, action: action)
        .buttonStyle(.borderedProminent)
        .tint(AppTheme.danger)
        .controlSize(controlSize)
}

/// 底栏「在访达里打开」：进入对应历史缓存目录。
func revealInFinderHistoryButton(
    controlSize: ControlSize = .regular,
    action: @escaping () -> Void
) -> some View {
    Button(action: action) {
        Label(L10n.string("在访达里打开"), systemImage: "folder")
    }
    .buttonStyle(.bordered)
    .controlSize(controlSize)
    .help(L10n.string("在访达中打开本类历史的本地缓存目录"))
    .onHover { hovering in
        updateHandCursor(hovering)
    }
}

@ViewBuilder
func historyThumbnail(_ image: NSImage?) -> some View {
    ZStack {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(AppTheme.surfaceMuted)
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: "photo")
                .foregroundStyle(AppTheme.textSecondary)
        }
    }
    .frame(width: 56, height: 40)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(AppTheme.border, lineWidth: 1)
    )
}

/// 列表缩略图：内存命中即时显示，否则占位后后台读盘。
@ViewBuilder
func historyAsyncThumbnail(url: URL?) -> some View {
    HistoryAsyncThumbnailView(url: url)
}

private struct HistoryAsyncThumbnailView: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        historyThumbnail(image)
            .task(id: url?.path) {
                guard let url else {
                    image = nil
                    return
                }
                if let hit = FeatureHistoryThumbnailCache.memoryCached(url: url) {
                    image = hit
                    return
                }
                let loaded = await Task.detached(priority: .userInitiated) {
                    FeatureHistoryThumbnailCache.loadFromDisk(url: url)
                }.value
                if let loaded {
                    FeatureHistoryThumbnailCache.store(loaded, for: url)
                    image = loaded
                }
            }
    }
}

@ViewBuilder
func historyTextBadge(_ title: String) -> some View {
    ZStack {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(AppTheme.accent.opacity(0.12))
        Text(title)
            .settingsBadgeText(weight: .semibold)
            .foregroundStyle(AppTheme.accent)
    }
    .frame(width: 56, height: 40)
}
