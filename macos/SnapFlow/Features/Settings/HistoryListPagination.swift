import SwiftUI

// MARK: - 分页模型

/// 历史列表分页（剪切板 / 截图 / OCR / 翻译共用）。
enum HistoryListPagination {
    /// 默认每页条数
    static let defaultPageSize = 20

    struct PageInfo: Equatable, Sendable {
        /// 1-based，已夹紧到有效范围
        var page: Int
        var pageSize: Int
        var totalCount: Int
        var pageCount: Int

        var hasPrevious: Bool { page > 1 }
        var hasNext: Bool { page < pageCount }
        /// 如「第 1–20 条，共 55 条」
        var summary: String {
            guard totalCount > 0 else { return L10n.string("共 0 条") }
            let start = (page - 1) * pageSize + 1
            let end = min(page * pageSize, totalCount)
            if pageCount <= 1 {
                return String(format: L10n.string("共 %lld 条"), totalCount)
            }
            return String(format: L10n.string("第 %lld–%lld 条 · 共 %lld 条"), start, end, totalCount)
        }
    }

    /// 计算页信息（空列表时 pageCount=1、page=1）。
    static func pageInfo(
        totalCount: Int,
        page: Int,
        pageSize: Int = defaultPageSize
    ) -> PageInfo {
        let size = max(1, pageSize)
        let total = max(0, totalCount)
        let count = max(1, Int(ceil(Double(total) / Double(size))))
        let safe = min(max(1, page), count)
        return PageInfo(page: safe, pageSize: size, totalCount: total, pageCount: count)
    }

    /// 切片；返回当前页元素与夹紧后的页信息。
    static func slice<T>(
        _ items: [T],
        page: Int,
        pageSize: Int = defaultPageSize
    ) -> (items: [T], info: PageInfo) {
        let info = pageInfo(totalCount: items.count, page: page, pageSize: pageSize)
        guard !items.isEmpty else { return ([], info) }
        let start = (info.page - 1) * info.pageSize
        let end = min(start + info.pageSize, items.count)
        guard start < items.count else { return ([], info) }
        return (Array(items[start..<end]), info)
    }
}

// MARK: - 浮层批次窗口

/// 浮层连续滚动使用的界面批次；数据仍由 HistoryStore 全量提供。
enum HistoryListWindowing {
    /// 首次打开浮层时准备的条目数。
    static let initialVisibleCount = 40
    /// 接近底部后追加的条目数。
    static let batchSize = HistoryListPagination.defaultPageSize
    /// 距离当前批次底部的预加载条数。
    static let loadMoreThreshold = 3

    static func initialCount(totalCount: Int) -> Int {
        min(max(0, totalCount), initialVisibleCount)
    }

    static func nextCount(current: Int, totalCount: Int) -> Int {
        let total = max(0, totalCount)
        let visible = min(max(0, current), total)
        return min(total, visible + batchSize)
    }

    static func countRequired(toShow index: Int, totalCount: Int) -> Int {
        let total = max(0, totalCount)
        guard index >= 0, total > 0 else { return 0 }
        let batchBoundary = ((index / batchSize) + 1) * batchSize
        return min(total, max(initialVisibleCount, batchBoundary))
    }

    static func shouldLoadMore(
        itemIndex: Int,
        visibleCount: Int,
        totalCount: Int,
        threshold: Int = loadMoreThreshold
    ) -> Bool {
        let total = max(0, totalCount)
        let visible = min(max(0, visibleCount), total)
        guard total > visible, itemIndex >= 0 else { return false }
        return itemIndex >= max(0, visible - max(1, threshold))
    }

    static func insertedCount<ID: Hashable>(
        currentIDs: [ID],
        previousIDs: [ID]
    ) -> Int {
        let previous = Set(previousIDs)
        return currentIDs.reduce(into: 0) { count, id in
            if !previous.contains(id) { count += 1 }
        }
    }
}

// MARK: - 分页条 UI

/// 历史列表底部分页控件：摘要 + 上一页 / 页码跳转 / 下一页。
/// 偏好设置（截图 / OCR / 翻译历史）与剪切板历史浮层共用。
///
/// 跳转交互（避免「失焦就跳」的误触感）：
/// - 默认展示静态「当前页 / 总页」
/// - 点击后进入编辑，输入页码
/// - **回车** 或点 **前往** 才跳转；**Esc** / 点空白失焦 = 取消并还原
struct HistoryPaginationBar: View {
    let totalCount: Int
    @Binding var page: Int
    var pageSize: Int = HistoryListPagination.defaultPageSize
    /// 紧凑样式（浮层列表底）
    var compact: Bool = false

    @State private var isEditingPage = false
    @State private var pageInput: String = ""
    @FocusState private var isPageFieldFocused: Bool
    /// 失焦取消稍作延迟，避免点「前往」时先 cancel 掉待跳转状态
    @State private var blurCancelTask: Task<Void, Never>?

    private var info: HistoryListPagination.PageInfo {
        HistoryListPagination.pageInfo(totalCount: totalCount, page: page, pageSize: pageSize)
    }

    private var pageLabelFont: Font {
        compact
            ? .system(size: 11, weight: .medium).monospacedDigit()
            : .system(size: 12, weight: .medium).monospacedDigit()
    }

    /// 输入框解析并夹紧后的目标页；与当前页不同时才算「待跳转」
    private var pendingJumpPage: Int? {
        let trimmed = pageInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed) else { return nil }
        let next = HistoryListPagination.pageInfo(
            totalCount: totalCount,
            page: value,
            pageSize: pageSize
        ).page
        return next == info.page ? nil : next
    }

    var body: some View {
        // 不足一页不显示，避免空列表/少量记录时占位
        if info.totalCount > info.pageSize {
            HStack(spacing: compact ? 8 : 10) {
                Text(info.summary)
                    .font(compact ? .system(size: 11) : .system(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                paginationButton(
                    symbol: "chevron.left",
                    help: L10n.string("上一页"),
                    disabled: !info.hasPrevious
                ) {
                    cancelPageEdit()
                    jump(to: info.page - 1)
                }

                pageJumpControl

                paginationButton(
                    symbol: "chevron.right",
                    help: L10n.string("下一页"),
                    disabled: !info.hasNext
                ) {
                    cancelPageEdit()
                    jump(to: info.page + 1)
                }
            }
            .padding(.horizontal, compact ? 4 : 0)
            .padding(.vertical, compact ? 4 : 2)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(format: L10n.string("分页，%@，第 %lld 页，共 %lld 页"), info.summary, info.page, info.pageCount))
            .onChange(of: totalCount) { _, _ in
                let next = HistoryListPagination.pageInfo(
                    totalCount: totalCount,
                    page: page,
                    pageSize: pageSize
                ).page
                if next != page { page = next }
                if !isEditingPage {
                    syncPageInput(from: next)
                }
            }
            .onChange(of: page) { _, newValue in
                let clamped = HistoryListPagination.pageInfo(
                    totalCount: totalCount,
                    page: newValue,
                    pageSize: pageSize
                ).page
                if clamped != newValue {
                    page = clamped
                }
                if !isEditingPage {
                    syncPageInput(from: clamped)
                }
            }
        }
    }

    /// 静态标签 ⇄ 编辑框 + 可选「前往」
    private var pageJumpControl: some View {
        HStack(spacing: 4) {
            if isEditingPage {
                pageInputField

                Text("/")
                    .font(pageLabelFont)
                    .foregroundStyle(AppTheme.textTertiary)

                Text("\(info.pageCount)")
                    .font(pageLabelFont)
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(minWidth: compact ? 16 : 18, alignment: .leading)

                if pendingJumpPage != nil {
                    paginationButton(
                        symbol: "arrow.right.circle.fill",
                        help: L10n.string("跳转到该页"),
                        disabled: false
                    ) {
                        commitPageJump()
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            } else {
                Button {
                    beginPageEdit()
                } label: {
                    Text("\(info.page) / \(info.pageCount)")
                        .font(pageLabelFont)
                        .foregroundStyle(AppTheme.textPrimary)
                        .padding(.horizontal, compact ? 8 : 10)
                        .padding(.vertical, compact ? 4 : 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(AppTheme.textPrimary.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(AppTheme.border.opacity(0.75), lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(L10n.string("点击输入页码跳转"))
                .onHover { inside in updateHandCursor(inside) }
                .accessibilityLabel(String(format: L10n.string("页码 %lld / %lld"), info.page, info.pageCount))
                .accessibilityHint(L10n.string("点击后输入页码，回车或点前往跳转"))
            }
        }
        .animation(.easeOut(duration: 0.12), value: isEditingPage)
        .animation(.easeOut(duration: 0.12), value: pendingJumpPage != nil)
        .frame(minWidth: compact ? 56 : 64)
    }

    private var pageInputField: some View {
        TextField("", text: $pageInput)
            .textFieldStyle(.plain)
            .font(pageLabelFont)
            .foregroundStyle(AppTheme.textPrimary)
            .multilineTextAlignment(.center)
            .frame(width: pageFieldWidth, height: compact ? 22 : 24)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(AppTheme.textPrimary.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(AppTheme.border, lineWidth: 1)
            )
            .focused($isPageFieldFocused)
            .onSubmit { commitPageJump() }
            .onChange(of: pageInput) { _, newValue in
                let filtered = newValue.filter(\.isNumber)
                if filtered != newValue {
                    pageInput = filtered
                }
            }
            .onChange(of: isPageFieldFocused) { _, focused in
                blurCancelTask?.cancel()
                guard !focused, isEditingPage else { return }
                // 延迟取消：给「前往」按钮 action 留出触发窗口
                blurCancelTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, !isPageFieldFocused, isEditingPage else { return }
                    cancelPageEdit()
                }
            }
            .onKeyPress(.escape) {
                blurCancelTask?.cancel()
                cancelPageEdit()
                return .handled
            }
            .help(String(format: L10n.string("回车跳转 · Esc 取消（1–%lld）"), info.pageCount))
            .accessibilityLabel(L10n.string("页码输入"))
            .accessibilityHint(L10n.string("输入页码后按回车跳转，Esc 取消"))
    }

    private var pageFieldWidth: CGFloat {
        let digits = max(2, String(info.pageCount).count)
        let unit: CGFloat = compact ? 8 : 9
        return CGFloat(digits) * unit + 16
    }

    private func beginPageEdit() {
        blurCancelTask?.cancel()
        syncPageInput(from: info.page)
        isEditingPage = true
        DispatchQueue.main.async {
            isPageFieldFocused = true
        }
    }

    private func cancelPageEdit() {
        blurCancelTask?.cancel()
        isEditingPage = false
        isPageFieldFocused = false
        syncPageInput(from: info.page)
    }

    private func syncPageInput(from pageValue: Int) {
        pageInput = "\(pageValue)"
    }

    private func jump(to rawPage: Int) {
        blurCancelTask?.cancel()
        let next = HistoryListPagination.pageInfo(
            totalCount: totalCount,
            page: rawPage,
            pageSize: pageSize
        ).page
        page = next
        syncPageInput(from: next)
        isEditingPage = false
        isPageFieldFocused = false
    }

    private func commitPageJump() {
        blurCancelTask?.cancel()
        let trimmed = pageInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed) else {
            cancelPageEdit()
            return
        }
        jump(to: value)
    }

    private func paginationButton(
        symbol: String,
        help: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
                .foregroundStyle(disabled ? AppTheme.textTertiary : AppTheme.textPrimary)
                .frame(width: compact ? 26 : 28, height: compact ? 26 : 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(AppTheme.textPrimary.opacity(disabled ? 0.04 : 0.08))
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .onHover { inside in
            if !disabled { updateHandCursor(inside) }
        }
        .accessibilityLabel(help)
    }
}
