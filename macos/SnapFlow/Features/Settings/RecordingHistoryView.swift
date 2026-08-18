import SwiftUI

/// 设置中的录制历史页：搜索 + 类型/时间筛选、列表卡、分页、底栏（写入开关在「录制」设置）。
struct RecordingHistoryView: View {
    @Environment(AppContainer.self) private var container
    @State private var filter: RecordingHistoryFilter = .all
    @State private var query = ""
    @State private var timeFilter = HistoryTimeFilter()
    @State private var page = 1
    @State private var pendingDeleteID: String?
    @State private var confirmClear = false
    @State private var isExportingGIFID: String?

    private var store: RecordingHistoryStore { container.recordingHistory }
    private var isRecordingActive: Bool { container.workflows.isRecordingActive }

    private var filteredRows: [RecordingHistoryItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.filtered(filter).filter { item in
            guard timeFilter.contains(item.createdAt) else { return false }
            guard !q.isEmpty else { return true }
            return item.displayTitle.localizedCaseInsensitiveContains(q)
                || item.format.displayName.localizedCaseInsensitiveContains(q)
                || metaLine(item).localizedCaseInsensitiveContains(q)
                || FeatureHistoryIO.formatTimestamp(item.createdAt).localizedCaseInsensitiveContains(q)
        }
    }

    private var paged: (items: [RecordingHistoryItem], info: HistoryListPagination.PageInfo) {
        HistoryListPagination.slice(filteredRows, page: page)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if store.indexLoadFailed || container.settings.recordingIndexCorruptedNotice {
                Label(
                    L10n.string("索引曾损坏并已重建为空列表；媒体文件仍在 ~/Movies/SnapFlow/。"),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(AppTheme.warning)
            }

            if store.isOverLimitWithOnlyFavorites {
                Label(
                    L10n.string("历史已超限且仅剩收藏项，收藏项不会被自动清理。"),
                    systemImage: "star.circle"
                )
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
            }

            historySearchField(
                query: $query,
                timeFilter: $timeFilter,
                placeholder: L10n.string("搜索录制历史"),
                leadingFilters: {
                    Picker(L10n.string("类型"), selection: $filter) {
                        ForEach(RecordingHistoryFilter.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.regular)
                    .frame(minWidth: 88, alignment: .trailing)
                    .help(L10n.string("按类型筛选录制历史"))
                }
            )

            if store.items.isEmpty {
                historyEmptyState(
                    symbol: "film",
                    title: L10n.string("暂无录制历史"),
                    message: container.settings.recordingHistoryEnabled
                        ? L10n.string("完成录制并保存后会出现在这里。")
                        : L10n.string("当前未开启记录到历史，可在「录制」设置中开启。媒体仍会保存到 ~/Movies/SnapFlow/。")
                )
                .frame(maxHeight: .infinity)
            } else if filteredRows.isEmpty {
                historyEmptyState(
                    symbol: "magnifyingglass",
                    title: L10n.string("没有匹配内容"),
                    message: historyNoMatchMessage(query: query, timeFilter: timeFilter)
                )
                .frame(maxHeight: .infinity)
            } else {
                let pageItems = paged.items
                historyListCard(fillsAvailableHeight: true) {
                    ForEach(Array(pageItems.enumerated()), id: \.element.id) { index, item in
                        historyRow(item)
                        if index < pageItems.count - 1 {
                            Divider().opacity(0.35)
                        }
                    }
                }

                HistoryPaginationBar(totalCount: filteredRows.count, page: $page)
            }

            historyFooterActions {
                revealInFinderHistoryButton {
                    _ = store.revealDirectoryInFinder()
                }
                destructiveHistoryButton(L10n.string("清除录制历史")) {
                    confirmClear = true
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: query) { _, _ in page = 1 }
        .onChange(of: filter) { _, _ in page = 1 }
        .onChange(of: timeFilter) { _, _ in page = 1 }
        .confirmationDialog(
            L10n.string("删除这条录制历史？"),
            isPresented: Binding(
                get: { pendingDeleteID != nil },
                set: { if !$0 { pendingDeleteID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.string("删除"), role: .destructive) {
                if let id = pendingDeleteID {
                    store.delete(id: id)
                }
                pendingDeleteID = nil
            }
            Button(L10n.string("取消"), role: .cancel) {
                pendingDeleteID = nil
            }
        } message: {
            Text(L10n.string("SnapFlow 自有文件会一并删除；若文件已被移动，则只删除历史记录。"))
        }
        .confirmationDialog(L10n.string("清除全部录制历史？"), isPresented: $confirmClear) {
            Button(L10n.string("清除"), role: .destructive) {
                store.clearAll()
                page = 1
            }
            Button(L10n.string("取消"), role: .cancel) {}
        } message: {
            Text(L10n.string("将删除历史记录与 SnapFlow 自有媒体文件，此操作不可撤销。"))
        }
    }

    @ViewBuilder
    private func historyRow(_ item: RecordingHistoryItem) -> some View {
        HStack(spacing: 12) {
            thumbnail(for: item)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.displayTitle)
                        .settingsRowTitleText()
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    formatBadge(item.format)
                    if item.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                    if item.endedAbnormally {
                        Text(L10n.string("异常结束"))
                            .settingsBadgeText(weight: .semibold)
                            .foregroundStyle(AppTheme.warning)
                    }
                }
                Text(metaLine(item))
                    .settingsBodyText()
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(2)
                if !item.fileExists {
                    Text(L10n.string("文件已缺失或被移动"))
                        .settingsBodyText()
                        .foregroundStyle(AppTheme.warning)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                iconActionButton(
                    systemImage: item.isFavorite ? "star.fill" : "star",
                    help: item.isFavorite ? L10n.string("取消收藏") : L10n.string("收藏")
                ) {
                    store.toggleFavorite(id: item.id)
                }

                iconActionButton(
                    systemImage: "play.circle",
                    help: L10n.string("用默认应用打开"),
                    disabled: !item.fileExists
                ) {
                    store.openInDefaultApp(id: item.id)
                }

                iconActionButton(
                    systemImage: "folder",
                    help: L10n.string("在访达中显示")
                ) {
                    store.revealInFinder(id: item.id)
                }

                if item.format == .mp4 {
                    Button {
                        exportGIF(from: item)
                    } label: {
                        Group {
                            if isExportingGIFID == item.id {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "square.and.arrow.up.on.square")
                                    .settingsCompactText(weight: .semibold)
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                        }
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(AppTheme.textPrimary.opacity(0.06))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!item.fileExists || isRecordingActive || isExportingGIFID != nil)
                    .help(
                        isRecordingActive
                            ? L10n.string("录制进行中，暂不可导出 GIF")
                            : L10n.string("从 MP4 导出 GIF（保留原 MP4）")
                    )
                    .onHover { hovering in
                        updateHandCursor(hovering)
                    }
                }

                iconActionButton(
                    systemImage: "trash",
                    help: L10n.string("删除"),
                    tint: AppTheme.danger
                ) {
                    pendingDeleteID = item.id
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Button(item.isFavorite ? L10n.string("取消收藏") : L10n.string("收藏")) {
                store.toggleFavorite(id: item.id)
            }
            Button(L10n.string("打开")) {
                store.openInDefaultApp(id: item.id)
            }
            .disabled(!item.fileExists)
            Button(L10n.string("在访达中显示")) {
                store.revealInFinder(id: item.id)
            }
            if item.format == .mp4 {
                Button(L10n.string("导出 GIF")) {
                    exportGIF(from: item)
                }
                .disabled(!item.fileExists || isRecordingActive || isExportingGIFID != nil)
            }
            Divider()
            Button(L10n.string("删除"), role: .destructive) {
                pendingDeleteID = item.id
            }
        }
    }

    private func iconActionButton(
        systemImage: String,
        help: String,
        disabled: Bool = false,
        tint: Color = AppTheme.textSecondary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .settingsCompactText(weight: .semibold)
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(AppTheme.textPrimary.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .onHover { hovering in
            updateHandCursor(hovering)
        }
    }

    private func thumbnail(for item: RecordingHistoryItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.surfaceMuted)
            if let image = store.thumbnailImage(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: item.format == .gif ? "gift" : "film")
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

    private func formatBadge(_ format: ScreenRecordingFormat) -> some View {
        Text(format.displayName)
            .settingsBadgeText(weight: .semibold)
            .foregroundStyle(AppTheme.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(AppTheme.accent.opacity(0.12))
            )
    }

    private func metaLine(_ item: RecordingHistoryItem) -> String {
        var parts: [String] = [
            FeatureHistoryIO.formatTimestamp(item.createdAt),
            String(format: "%.1fs", item.durationSeconds),
            "\(item.pixelWidth)×\(item.pixelHeight)",
        ]
        if item.containsSystemAudio { parts.append(L10n.string("系统声")) }
        if item.containsMicrophone { parts.append(L10n.string("麦克风")) }
        if item.fileByteSize > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: item.fileByteSize, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    private func exportGIF(from item: RecordingHistoryItem) {
        guard item.format == .mp4, item.fileExists, !isRecordingActive else { return }
        isExportingGIFID = item.id
        Task { @MainActor in
            defer { isExportingGIFID = nil }
            do {
                let counter = container.settings.nextRecordingFilenameCounter()
                let destination = try ScreenRecordingFileStore.uniqueDestination(
                    format: .gif,
                    template: container.settings.recordingFilenameTemplate,
                    counter: counter
                )
                try await RecordingExporter.exportGIF(from: item.fileURL, to: destination)
                let duration = item.durationSeconds
                _ = store.register(
                    fileURL: destination,
                    format: .gif,
                    createdAt: Date(),
                    durationSeconds: duration,
                    pixelWidth: item.pixelWidth,
                    pixelHeight: item.pixelHeight,
                    displayID: CGDirectDisplayID(item.displayID),
                    containsSystemAudio: false,
                    containsMicrophone: false,
                    endedAbnormally: false,
                    isOwnedBySnapFlow: true
                )
                FeedbackCenter.shared.post(String(format: L10n.string("已导出 GIF：%@"), destination.lastPathComponent))
                if container.settings.recordingRevealInFinder {
                    _ = FeatureHistoryIO.revealFileInFinder(destination)
                }
            } catch {
                FeedbackCenter.shared.post(
                    String(format: L10n.string("GIF 导出失败：%@"), error.localizedDescription),
                    level: .error
                )
            }
        }
    }
}
