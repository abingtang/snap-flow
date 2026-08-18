import AppKit
import SwiftUI

/// 划词翻译浮窗内容。
///
/// 高度规则：
/// - 整窗 **max-height** = 当前屏可用高度；内容少则变矮；底部不够时 Presenter **向上撑开**到屏高
/// - 原文 **max-height 固定 200**，超出框内滚动
/// - 折叠译文卡只占标题行；**展开卡均分剩余高度** 作为各自 max-height
/// - 内容超过 max → 框内滚动；折叠/展开后重新均分
/// - 整窗高度由 Presenter 按 LayoutBudget 离散 setFrame（禁止 preference 连续改尺寸）
struct TranslatePopupView: View {
    @Bindable var session: TranslatePopupSession
    var onTargetSelectionChanged: (String) -> Void
    var onRetranslate: () -> Void
    var onRetryService: ((String) -> Void)? = nil
    var onClose: () -> Void
    /// 可选：关闭键展示（划词窗本身固定 Esc，无独立 LocalShortcut 时用此 chord）
    var closeChord: String = "escape"
    /// 打开偏好设置（翻译服务页）
    var onOpenSettings: (() -> Void)? = nil
    /// 查询某段文本是否已收藏
    var isTextFavorited: ((String) -> Bool)? = nil
    /// 切换收藏，返回切换后是否已收藏
    var onToggleFavoriteText: ((String) -> Bool)? = nil
    /// 折叠/展开或源文变化导致预算变化时通知 Presenter
    var onLayoutNeeded: (() -> Void)? = nil
    /// 整窗最大高度（屏 visible − 边距）
    var panelMaxHeight: CGFloat = 560
    /// 当前 NSPanel 实际高度（与 setFrame 一致）
    var panelHeight: CGFloat = 400

    @State private var hoverCopySource = false
    @State private var hoverFavoriteSource = false
    @State private var hoverRetranslateSource = false
    @State private var hoverSwap = false
    /// 收藏状态变更后递增，强制刷新实心/空心星
    @State private var favoriteEpoch = 0
    @State private var keyMonitor: Any?
    @State private var sourceEditTask: Task<Void, Never>?

    static let panelWidth: CGFloat = 420
    static let sourceEditorMaxHeight: CGFloat = 200
    static let sourceEditorMinHeight: CGFloat = 72
    static let headerHeight: CGFloat = 40
    static let bodyPadding: CGFloat = 12
    static let sectionSpacing: CGFloat = 10
    static let serviceSpacing: CGFloat = 8
    static let directionBarHeight: CGFloat = 40
    static let serviceTitleRow: CGFloat = 42
    static let serviceFooterRow: CGFloat = 36
    static let sourceFooterHeight: CGFloat = 40
    /// 正文可用宽度（panel − 外边距 − 卡片水平内边距）
    static let textContentWidth: CGFloat = panelWidth - bodyPadding * 2 - 24

    private var budget: LayoutBudget {
        LayoutBudget.compute(
            sourceText: session.sourceText,
            serviceResults: session.serviceResults,
            panelMaxHeight: panelMaxHeight,
            sourceStatusMessage: session.sourceStatusMessage
        )
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(height: Self.headerHeight)
            Rectangle()
                .fill(AppTheme.separator)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                sourceBlock
                directionBar
                serviceList
                Spacer(minLength: 0)
            }
            .padding(Self.bodyPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: Self.panelWidth, height: panelHeight, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.panelBackground)
        }
        .foregroundStyle(AppTheme.textPrimary)
        .tint(AppTheme.accent)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppTheme.border, lineWidth: 1)
        }
        .onAppear { installKeyMonitor() }
        .onDisappear {
            sourceEditTask?.cancel()
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        .onChange(of: session.sourceText) { _, _ in
            // 输入中不立刻 relayout（避免重建 HostingView 丢焦点）；防抖翻译完成后 Presenter 会 relayout
            if !session.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                session.sourceStatusMessage = nil
            }
            scheduleSourceDebouncedTranslate()
        }
    }

    // MARK: - LayoutBudget

    /// 一次性算清窗高 / 源高 / 展开卡 max（折叠不参与均分）
    @MainActor
    struct LayoutBudget {
        var panelHeight: CGFloat
        var sourceEditorHeight: CGFloat
        /// 每张**展开**卡的 max-height
        var expandedCardMaxHeight: CGFloat

        func cardMaxHeight(expanded: Bool) -> CGFloat {
            expanded ? expandedCardMaxHeight : TranslatePopupView.serviceTitleRow
        }

        func bodyMaxHeight(expanded: Bool) -> CGFloat {
            guard expanded else { return 0 }
            return max(
                48,
                expandedCardMaxHeight
                    - TranslatePopupView.serviceTitleRow
                    - TranslatePopupView.serviceFooterRow
            )
        }

        static func preferredPanelHeight(
            sourceText: String,
            serviceResults: [TranslateServiceResultItem],
            panelMaxHeight: CGFloat,
            sourceStatusMessage: String? = nil
        ) -> CGFloat {
            compute(
                sourceText: sourceText,
                serviceResults: serviceResults,
                panelMaxHeight: panelMaxHeight,
                sourceStatusMessage: sourceStatusMessage
            ).panelHeight
        }

        static func compute(
            sourceText: String,
            serviceResults: [TranslateServiceResultItem],
            panelMaxHeight: CGFloat,
            sourceStatusMessage: String? = nil
        ) -> LayoutBudget {
            let sourceEditor = TranslatePopupView.estimateSourceEditorHeight(sourceText: sourceText)
            let sourceNotice: CGFloat = sourceStatusMessage == nil ? 0 : 48
            let sourceBlock = sourceEditor + sourceNotice + TranslatePopupView.sourceFooterHeight

            let chrome =
                TranslatePopupView.headerHeight + 1
                + TranslatePopupView.bodyPadding * 2
                + sourceBlock
                + TranslatePopupView.directionBarHeight
                + TranslatePopupView.sectionSpacing * 2

            let serviceAreaMax = max(96, panelMaxHeight - chrome)
            let items = serviceResults
            let n = items.count
            let gaps = TranslatePopupView.serviceSpacing * CGFloat(max(0, n - 1))

            let expandedItems = items.filter(\.isExpanded)
            let collapsedCount = max(0, n - expandedItems.count)
            let collapsedReserved =
                CGFloat(collapsedCount) * TranslatePopupView.serviceTitleRow

            // 展开卡均分：译文区 max − 折叠标题 − 间距
            let forExpanded = max(0, serviceAreaMax - collapsedReserved - gaps)
            let expandedMax: CGFloat
            if expandedItems.isEmpty {
                expandedMax = TranslatePopupView.serviceTitleRow
            } else {
                expandedMax = max(72, floor(forExpanded / CGFloat(expandedItems.count)))
            }

            var cardsH: CGFloat = 0
            for (i, item) in items.enumerated() {
                if i > 0 { cardsH += TranslatePopupView.serviceSpacing }
                let maxH = item.isExpanded ? expandedMax : TranslatePopupView.serviceTitleRow
                cardsH += TranslatePopupView.estimateServiceCardHeight(item: item, cardMaxHeight: maxH)
            }

            let total = chrome + cardsH
            let panelH = min(panelMaxHeight, max(220, ceil(total)))

            return LayoutBudget(
                panelHeight: panelH,
                sourceEditorHeight: sourceEditor,
                expandedCardMaxHeight: expandedMax
            )
        }
    }

    @MainActor
    static func preferredPanelHeight(
        sourceText: String,
        serviceResults: [TranslateServiceResultItem],
        panelMaxHeight: CGFloat,
        sourceStatusMessage: String? = nil
    ) -> CGFloat {
        LayoutBudget.preferredPanelHeight(
            sourceText: sourceText,
            serviceResults: serviceResults,
            panelMaxHeight: panelMaxHeight,
            sourceStatusMessage: sourceStatusMessage
        )
    }

    // MARK: - Measurement

    static func measureTextHeight(_ text: String, width: CGFloat, fontSize: CGFloat = 13) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let font = NSFont.systemFont(ofSize: fontSize)
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return ceil(rect.height)
    }

    static func estimateSourceEditorHeight(sourceText: String) -> CGFloat {
        if sourceText.isEmpty { return sourceEditorMinHeight }
        let measured = measureTextHeight(sourceText, width: textContentWidth) + 24
        return min(sourceEditorMaxHeight, max(sourceEditorMinHeight, measured))
    }

    static func estimateServiceBodyContentHeight(
        text: String,
        statusMessage: String?,
        bodyMaxHeight: CGFloat
    ) -> CGFloat {
        if text.isEmpty { return min(bodyMaxHeight, 48) }
        var body = measureTextHeight(text, width: textContentWidth) + 16
        // lineSpacing(3) 粗补偿
        let approxLines = max(1, Int(ceil(body / 18)))
        body += CGFloat(max(0, approxLines - 1)) * 3
        if let note = statusMessage, !note.isEmpty {
            body += measureTextHeight(note, width: textContentWidth, fontSize: 11) + 8
        }
        return min(bodyMaxHeight, max(40, body))
    }

    @MainActor
    static func estimateServiceCardHeight(
        item: TranslateServiceResultItem,
        cardMaxHeight: CGFloat
    ) -> CGFloat {
        if !item.isExpanded { return serviceTitleRow }
        let bodyMax = max(48, cardMaxHeight - serviceTitleRow - serviceFooterRow)
        if item.isLoading && item.text.isEmpty {
            return min(cardMaxHeight, serviceTitleRow + 56 + serviceFooterRow)
        }
        if item.text.isEmpty {
            return min(cardMaxHeight, serviceTitleRow + 48 + serviceFooterRow)
        }
        let body = estimateServiceBodyContentHeight(
            text: item.text,
            statusMessage: item.statusMessage,
            bodyMaxHeight: bodyMax
        )
        return min(cardMaxHeight, serviceTitleRow + body + serviceFooterRow)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "character.cursor.ibeam")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
            Text(L10n.string("划词翻译"))
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            if session.isTranslating {
                ProgressView()
                    .controlSize(.small)
            } else if let flash = session.flashMessage {
                Text(flash)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            } else {
                Text(String(format: L10n.string("%@ 关闭"), ShortcutDisplay.label(chord: closeChord)))
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.textTertiary)
            }
            if let onOpenSettings {
                OCRChromeIconButton(symbol: "gearshape", tooltip: L10n.string("偏好设置"), action: onOpenSettings)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Source

    private var sourceBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if session.sourceText.isEmpty {
                    Text(L10n.string("划词、剪切板或在此输入原文"))
                        .font(.system(size: 13))
                        .foregroundStyle(AppTheme.textTertiary)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                }
                // NSScrollView 无固有高度：必须写死 height；超 200 时内部滚动
                SourceNativeTextEditor(
                    text: $session.sourceText,
                    isEditable: !session.isTranslating,
                    minHeight: Self.sourceEditorMinHeight,
                    maxHeight: Self.sourceEditorMaxHeight
                )
                .frame(height: budget.sourceEditorHeight)
            }
            .frame(height: budget.sourceEditorHeight, alignment: .top)

            if let sourceStatusMessage = session.sourceStatusMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(AppTheme.warning)
                    Text(sourceStatusMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AppTheme.warning.opacity(0.10))
            }

            HStack(spacing: 6) {
                iconButton(
                    systemImage: "doc.on.doc",
                    help: L10n.string("复制原文"),
                    hovering: $hoverCopySource,
                    style: .plain,
                    disabled: session.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    copy(session.sourceText, hint: L10n.string("已复制原文"))
                }

                if session.sourceSelection == TranslationLanguage.autoSourceToken,
                   !session.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    Text(
                        session.hasDetectedLanguage
                            ? String(format: L10n.string("识别为 %@"), session.detectedLanguageLabel)
                            : L10n.string("未识别")
                    )
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(
                        session.hasDetectedLanguage ? AppTheme.accent : AppTheme.textSecondary
                    )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(
                                (session.hasDetectedLanguage ? AppTheme.accent : AppTheme.textSecondary)
                                    .opacity(0.14)
                            )
                    )
                }

                Spacer(minLength: 0)

                if onToggleFavoriteText != nil {
                    let sourceFavorited = textIsFavorited(session.sourceText)
                    favoriteStarButton(
                        favorited: sourceFavorited,
                        help: sourceFavorited ? L10n.string("取消收藏") : L10n.string("收藏原文"),
                        hovering: $hoverFavoriteSource,
                        disabled: session.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ) {
                        _ = onToggleFavoriteText?(session.sourceText)
                        favoriteEpoch &+= 1
                    }
                }

                iconButton(
                    systemImage: "arrow.clockwise",
                    help: L10n.string("全量重新翻译（所有服务）"),
                    hovering: $hoverRetranslateSource,
                    style: .plain,
                    disabled: !session.canRetranslate || session.isTranslating
                ) {
                    onRetranslate()
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .padding(.top, 2)
            .frame(height: Self.sourceFooterHeight, alignment: .center)
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .background(blockBackground)
    }

    // MARK: - Direction

    private var directionBar: some View {
        HStack(spacing: 0) {
            languageMenu(
                title: session.sourceMenuTitle,
                selection: session.sourceSelection,
                options: TranslatePopupLanguageOption.sourceOptions
            ) { code in
                session.sourceSelection = code
                onRetranslate()
            }

            Button {
                session.swapDirection()
                onTargetSelectionChanged(session.targetSelection)
                onRetranslate()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 36, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(
                OCRPressableChromeStyle(
                    isHovered: hoverSwap,
                    idleFill: .clear,
                    hoverFill: AppTheme.textPrimary.opacity(0.10),
                    pressedFill: AppTheme.textPrimary.opacity(0.16),
                    idleForeground: AppTheme.textPrimary.opacity(0.75),
                    hoverForeground: AppTheme.textPrimary
                )
            )
            .help(L10n.string("交换翻译方向"))
            .accessibilityLabel(L10n.string("交换翻译方向"))
            .onHover { hovering in
                hoverSwap = hovering
                updateHandCursor(hovering)
            }

            languageMenu(
                title: session.targetMenuTitle,
                selection: session.targetSelection,
                options: TranslatePopupLanguageOption.targetOptions
            ) { code in
                session.targetSelection = code
                onTargetSelectionChanged(code)
                onRetranslate()
            }
        }
        .frame(height: Self.directionBarHeight)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.textPrimary.opacity(0.08))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(AppTheme.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func languageMenu(
        title: String,
        selection: String,
        options: [TranslatePopupLanguageOption],
        onSelect: @escaping (String) -> Void
    ) -> some View {
        Menu {
            ForEach(options) { opt in
                Button {
                    onSelect(opt.rawValue)
                } label: {
                    if selection == opt.rawValue
                        || TranslationLanguage.normalize(selection)
                        == TranslationLanguage.normalize(opt.rawValue)
                    {
                        Label(opt.menuTitle, systemImage: "checkmark")
                    } else {
                        Text(opt.menuTitle)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .foregroundStyle(AppTheme.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Services

    private var serviceList: some View {
        Group {
            if session.serviceResults.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 22))
                        .foregroundStyle(AppTheme.textTertiary)
                    Text(L10n.string("无可用翻译服务"))
                        .font(.system(size: 13, weight: .medium))
                    Text(L10n.string("请到设置中启用并配置翻译服务"))
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textSecondary)
                    if let onOpenSettings {
                        Button(L10n.string("打开翻译服务设置"), action: onOpenSettings)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                VStack(alignment: .leading, spacing: Self.serviceSpacing) {
                    ForEach(session.serviceResults) { item in
                        serviceCard(item)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func serviceCard(_ item: TranslateServiceResultItem) -> some View {
        let cardMax = budget.cardMaxHeight(expanded: item.isExpanded)
        let bodyMax = budget.bodyMaxHeight(expanded: item.isExpanded)
        let cardH = Self.estimateServiceCardHeight(item: item, cardMaxHeight: cardMax)

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    item.isExpanded.toggle()
                }
                // 折叠/展开后立刻重算均分 max 与窗高
                onLayoutNeeded?()
            } label: {
                HStack(spacing: 8) {
                    if let kind = item.kind {
                        TranslationServiceIconView(kind: kind, size: 22)
                    } else {
                        Image(systemName: item.symbolName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppTheme.accent)
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(AppTheme.accent.opacity(0.15))
                            )
                    }

                    Text(item.displayName)
                        .font(.system(size: 13, weight: .semibold))

                    if item.isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    }

                    Spacer(minLength: 4)

                    if !item.isExpanded {
                        Text(item.summaryLine)
                            .font(.system(size: 11))
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1)
                    }

                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.textTertiary)
                        .rotationEffect(.degrees(item.isExpanded ? 0 : -90))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onContinuousHover { phase in
                switch phase {
                case .active: updateHandCursor(true)
                case .ended: updateHandCursor(false)
                }
            }

            if item.isExpanded {
                serviceBodyContent(item, bodyMaxHeight: bodyMax)

                HStack(spacing: 4) {
                    ServiceFooterIconButton(
                        systemImage: "doc.on.doc",
                        help: L10n.string("复制译文"),
                        disabled: item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ) {
                        copy(item.text, hint: L10n.string("已复制译文"))
                    }
                    ServiceFooterIconButton(
                        systemImage: "arrow.clockwise",
                        help: item.isRetryable ? L10n.string("重试此服务") : L10n.string("重新翻译"),
                        disabled: !session.canRetranslate || item.isLoading
                    ) {
                        if item.isRetryable, let onRetryService {
                            onRetryService(item.id)
                        } else {
                            onRetranslate()
                        }
                    }
                    if item.canOpenSettings, let onOpenSettings {
                        ServiceFooterIconButton(
                            systemImage: "gearshape",
                            help: L10n.string("打开翻译服务设置"),
                            disabled: false,
                            action: onOpenSettings
                        )
                    }
                    if onToggleFavoriteText != nil {
                        let translationFavorited = textIsFavorited(item.text)
                        ServiceFooterIconButton(
                            systemImage: translationFavorited ? "star.fill" : "star",
                            help: translationFavorited ? L10n.string("取消收藏") : L10n.string("收藏译文"),
                            disabled: item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            isAccent: translationFavorited
                        ) {
                            _ = onToggleFavoriteText?(item.text)
                            favoriteEpoch &+= 1
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(height: Self.serviceFooterRow, alignment: .center)
            }
        }
        // 关键高度写死 = min(内容, max)，杜绝撑满/溢出裁切无滚动
        .frame(maxWidth: .infinity, minHeight: cardH, maxHeight: cardH, alignment: .top)
        .clipped()
        .background(blockBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func serviceBodyContent(
        _ item: TranslateServiceResultItem,
        bodyMaxHeight: CGFloat
    ) -> some View {
        if item.isLoading && item.text.isEmpty {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.string("正在翻译…"))
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: min(56, bodyMaxHeight), alignment: .top)
        } else if item.text.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(item.statusMessage ?? L10n.string("暂无译文"))
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let msg = item.statusMessage,
                   msg.contains(L10n.string("模型")) || msg.contains(L10n.string("系统设置")) || msg.contains(L10n.string("翻译语言"))
                {
                    Button(L10n.string("打开系统翻译语言设置")) {
                        TranslationSystemSettingsOpener.openTranslationLanguages()
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.link)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: min(48, bodyMaxHeight), alignment: .top)
        } else {
            let ideal = Self.estimateServiceBodyContentHeight(
                text: item.text,
                statusMessage: item.statusMessage,
                bodyMaxHeight: .greatestFiniteMagnitude
            )
            let displayH = min(ideal, bodyMaxHeight)

            // 始终用固定 height；超 max 时 ScrollView 内滚
            ScrollView {
                serviceTranslationText(item)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: displayH)
        }
    }

    private func serviceTranslationText(_ item: TranslateServiceResultItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.text)
                .font(.system(size: 13))
                .multilineTextAlignment(.leading)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let note = item.statusMessage, !note.isEmpty {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    // MARK: - Chrome

    private var blockBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(AppTheme.surface)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AppTheme.border, lineWidth: 1)
            }
    }

    private enum IconStyle { case plain, accent }

    private func iconButton(
        systemImage: String,
        help: String,
        hovering: Binding<Bool>,
        style: IconStyle,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let hovered = hovering.wrappedValue && !disabled
        return Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(
            OCRPressableChromeStyle(
                isHovered: hovered,
                idleFill: iconFill(style: style, hovering: false, disabled: disabled),
                hoverFill: iconFill(style: style, hovering: true, disabled: disabled),
                pressedFill: iconPressedFill(style: style, disabled: disabled),
                idleForeground: iconForeground(style: style, disabled: disabled),
                hoverForeground: iconForeground(style: style, disabled: disabled, emphasized: true)
            )
        )
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
        .onHover { inside in
            hovering.wrappedValue = inside && !disabled
            if !disabled { updateHandCursor(inside) }
        }
    }

    private func iconFill(style: IconStyle, hovering: Bool, disabled: Bool) -> Color {
        if disabled { return AppTheme.textPrimary.opacity(0.04) }
        switch style {
        case .accent: return AppTheme.accent.opacity(hovering ? 1 : 0.9)
        case .plain: return AppTheme.textPrimary.opacity(hovering ? 0.14 : 0.08)
        }
    }

    private func iconPressedFill(style: IconStyle, disabled: Bool) -> Color {
        if disabled { return AppTheme.textPrimary.opacity(0.04) }
        switch style {
        case .accent: return AppTheme.accent
        case .plain: return AppTheme.textPrimary.opacity(0.18)
        }
    }

    private func iconForeground(style: IconStyle, disabled: Bool, emphasized: Bool = false) -> Color {
        if disabled { return AppTheme.textSecondary.opacity(0.5) }
        switch style {
        case .accent: return .white
        case .plain: return AppTheme.textPrimary.opacity(emphasized ? 1 : 0.85)
        }
    }

    private func scheduleSourceDebouncedTranslate() {
        sourceEditTask?.cancel()
        sourceEditTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled else { return }
            session.refreshDetectedLanguage()
            guard session.canRetranslate else { return }
            onRetranslate()
        }
    }

    private func copy(_ text: String, hint: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        session.flash(hint)
    }

    private func textIsFavorited(_ text: String) -> Bool {
        _ = favoriteEpoch
        return isTextFavorited?(text) ?? false
    }

    /// 收藏星：未收藏空心，已收藏实心琥珀色，无 Toast。
    private func favoriteStarButton(
        favorited: Bool,
        help: String,
        hovering: Binding<Bool>,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let hovered = hovering.wrappedValue && !disabled
        let idleFill: Color = {
            if disabled { return AppTheme.textPrimary.opacity(0.04) }
            return favorited ? AppTheme.warning.opacity(0.18) : AppTheme.textPrimary.opacity(0.08)
        }()
        let hoverFill: Color = {
            if disabled { return AppTheme.textPrimary.opacity(0.04) }
            return favorited ? AppTheme.warning.opacity(0.28) : AppTheme.textPrimary.opacity(0.14)
        }()
        let pressedFill: Color = {
            if disabled { return AppTheme.textPrimary.opacity(0.04) }
            return favorited ? AppTheme.warning.opacity(0.34) : AppTheme.textPrimary.opacity(0.18)
        }()
        let fg: Color = {
            if disabled { return AppTheme.textSecondary.opacity(0.5) }
            return favorited ? AppTheme.warning : AppTheme.textPrimary.opacity(0.85)
        }()
        let hoverFg: Color = {
            if disabled { return AppTheme.textSecondary.opacity(0.5) }
            return favorited ? AppTheme.warning : AppTheme.textPrimary
        }()

        return Button(action: action) {
            Image(systemName: favorited ? "star.fill" : "star")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(
            OCRPressableChromeStyle(
                isHovered: hovered,
                idleFill: idleFill,
                hoverFill: hoverFill,
                pressedFill: pressedFill,
                idleForeground: fg,
                hoverForeground: hoverFg
            )
        )
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
        .onHover { inside in
            hovering.wrappedValue = inside && !disabled
            if !disabled { updateHandCursor(inside) }
        }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Self.isEditingText(in: event.window) {
                if event.keyCode == 53 {
                    onClose()
                    return nil
                }
                if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
                   event.charactersIgnoringModifiers?.lowercased() == "w"
                {
                    onClose()
                    return nil
                }
                if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
                   event.keyCode == 36,
                   session.canRetranslate
                {
                    onRetranslate()
                    return nil
                }
                return event
            }
            if event.keyCode == 53 {
                onClose()
                return nil
            }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "w"
            {
                onClose()
                return nil
            }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
               event.keyCode == 36,
               session.canRetranslate
            {
                onRetranslate()
                return nil
            }
            return event
        }
    }

    private static func isEditingText(in window: NSWindow?) -> Bool {
        guard let fr = window?.firstResponder else { return false }
        if fr is NSTextView { return true }
        if fr is NSText { return true }
        if let tv = fr as? NSView, tv.enclosingScrollView?.documentView is NSTextView {
            return true
        }
        return false
    }
}

// MARK: - Service footer icon

private struct ServiceFooterIconButton: View {
    var systemImage: String
    var help: String
    var disabled: Bool
    var isAccent: Bool = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(
            OCRPressableChromeStyle(
                isHovered: hovering && !disabled,
                idleFill: idleFill,
                hoverFill: hoverFill,
                pressedFill: pressedFill,
                idleForeground: idleForeground,
                hoverForeground: hoverForeground
            )
        )
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
        .onHover { inside in
            hovering = inside && !disabled
            if !disabled { updateHandCursor(inside) }
        }
    }

    private var idleFill: Color {
        if disabled { return AppTheme.textPrimary.opacity(0.04) }
        if isAccent { return AppTheme.warning.opacity(0.18) }
        return AppTheme.textPrimary.opacity(0.08)
    }

    private var hoverFill: Color {
        if disabled { return AppTheme.textPrimary.opacity(0.04) }
        if isAccent { return AppTheme.warning.opacity(0.28) }
        return AppTheme.textPrimary.opacity(0.14)
    }

    private var pressedFill: Color {
        if disabled { return AppTheme.textPrimary.opacity(0.04) }
        if isAccent { return AppTheme.warning.opacity(0.34) }
        return AppTheme.textPrimary.opacity(0.18)
    }

    private var idleForeground: Color {
        if disabled { return AppTheme.textPrimary.opacity(0.4) }
        if isAccent { return AppTheme.warning }
        return AppTheme.textPrimary.opacity(0.85)
    }

    private var hoverForeground: Color {
        if disabled { return AppTheme.textPrimary.opacity(0.4) }
        if isAccent { return AppTheme.warning }
        return AppTheme.textPrimary
    }
}

// MARK: - 原文原生编辑器

private struct SourceNativeTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var minHeight: CGFloat
    var maxHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.verticalScroller?.controlSize = .mini
        scroll.verticalScroller?.alphaValue = 0.55

        let tv = NSTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isEditable = isEditable
        tv.isSelectable = true
        tv.font = NSFont.systemFont(ofSize: 13)
        tv.textColor = AppTheme.nsTextPrimary
        tv.insertionPointColor = AppTheme.nsTextPrimary
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        tv.string = text
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false

        scroll.documentView = tv
        context.coordinator.textView = tv

        DispatchQueue.main.async {
            tv.window?.makeFirstResponder(tv)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        tv.isEditable = isEditable
        if tv.string != text, !context.coordinator.isUserEditing {
            let selected = tv.selectedRange()
            tv.string = text
            let maxLoc = (tv.string as NSString).length
            let loc = min(selected.location, maxLoc)
            let len = min(selected.length, max(0, maxLoc - loc))
            tv.setSelectedRange(NSRange(location: loc, length: len))
        }
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var parent: SourceNativeTextEditor?
        weak var textView: NSTextView?
        var isUserEditing = false

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidBeginEditing(_ notification: Notification) {
            isUserEditing = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isUserEditing = false
            syncBinding(from: notification)
        }

        func textDidChange(_ notification: Notification) {
            isUserEditing = true
            syncBinding(from: notification)
        }

        private func syncBinding(from notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            if text.wrappedValue != tv.string {
                text.wrappedValue = tv.string
            }
        }
    }
}
