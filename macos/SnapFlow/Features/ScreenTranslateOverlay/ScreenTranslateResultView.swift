import AppKit
import Observation
import SwiftUI

// MARK: - Session

enum ScreenTranslateResultErrorAction: Equatable {
    case retryOCR
    case retranslate
    case openOCRSettings
    case openTranslationSettings
}

/// 截图翻译结果窗会话：左图+OCR 原文，右多服务译文。
@MainActor
@Observable
final class ScreenTranslateResultSession {
    var image: NSImage
    var cgImage: CGImage
    var lines: [OCRLine]
    /// 左侧 OCR 原文（可编辑；编辑后需手动再译）
    var ocrText: String
    var selectedOCRServiceID: String
    var showLeftPanel = true
    var showOCRBoxes = true
    var isPinned = false
    var isRecognizing = false
    var isTranslating = false
    /// 当前收藏内容是否已收藏（顶栏实心星）
    var isContentFavorited = false
    var statusHint: String?
    var emptyMessage: String?
    var errorMessage: String?
    var errorAction: ScreenTranslateResultErrorAction?
    var sourceSelection: String = TranslationLanguage.autoSourceToken
    var targetSelection: String
    var detectedLanguageCode: String?
    var serviceResults: [TranslateServiceResultItem] = []
    /// >0 时忽略失焦关闭
    var suppressFocusDismissCount = 0
    private(set) var operationID = UUID()

    init(
        image: NSImage,
        cgImage: CGImage,
        lines: [OCRLine],
        ocrText: String,
        selectedOCRServiceID: String,
        targetSelection: String,
        services: [TranslationServiceEntry]
    ) {
        self.image = image
        self.cgImage = cgImage
        self.lines = lines
        self.ocrText = ocrText.isEmpty ? OCRTextLayout.makeText(from: lines) : ocrText
        self.selectedOCRServiceID = selectedOCRServiceID
        self.targetSelection = targetSelection
        self.detectedLanguageCode = TranslationLanguage.detectLanguageCode(in: self.ocrText)
        configureServices(services)
    }

    var shouldSuppressFocusDismiss: Bool { suppressFocusDismissCount > 0 }

    func beginFocusSuppress() { suppressFocusDismissCount += 1 }
    func endFocusSuppress() {
        suppressFocusDismissCount = max(0, suppressFocusDismissCount - 1)
    }

    @discardableResult
    func beginOperation() -> UUID {
        operationID = UUID()
        emptyMessage = nil
        errorMessage = nil
        errorAction = nil
        statusHint = nil
        return operationID
    }

    func isCurrent(_ id: UUID) -> Bool { operationID == id }

    var canRetranslate: Bool {
        !ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isTranslating && !isRecognizing
    }

    var detectedLanguageLabel: String {
        guard let code = detectedLanguageCode,
              !code.isEmpty,
              code != TranslationLanguage.autoSourceToken
        else {
            return L10n.string("未识别")
        }
        return TranslationLanguage.displayName(for: code)
    }

    var hasDetectedLanguage: Bool {
        guard let code = detectedLanguageCode?.trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty,
              code != TranslationLanguage.autoSourceToken
        else {
            return false
        }
        return true
    }

    var sourceMenuTitle: String {
        sourceSelection == TranslationLanguage.autoSourceToken
            ? L10n.string("自动检测")
            : TranslatePopupLanguageOption.from(code: sourceSelection).menuTitle
    }

    var targetMenuTitle: String {
        targetSelection == TranslationLanguage.systemTargetToken
            ? L10n.string("自动选择")
            : TranslatePopupLanguageOption.from(code: targetSelection).menuTitle
    }

    func refreshDetectedLanguage() {
        detectedLanguageCode = TranslationLanguage.detectLanguageCode(in: ocrText)
    }

    func swapDirection() {
        let left = sourceSelection
        let right = targetSelection
        sourceSelection = (right == TranslationLanguage.systemTargetToken)
            ? TranslationLanguage.autoSourceToken
            : right
        targetSelection = (left == TranslationLanguage.autoSourceToken)
            ? TranslationLanguage.systemTargetToken
            : left
    }

    func configureServices(_ services: [TranslationServiceEntry]) {
        let old = Dictionary(uniqueKeysWithValues: serviceResults.map { ($0.id, $0) })
        serviceResults = services.map { entry in
            if let keep = old[entry.id] {
                keep.kind = entry.kind
                return keep
            }
            return TranslateServiceResultItem(
                id: entry.id,
                displayName: entry.displayName,
                symbolName: entry.kind.symbolName,
                kind: entry.kind
            )
        }
    }

    func applyRecognition(image: NSImage, cgImage: CGImage, lines: [OCRLine]) {
        self.image = image
        self.cgImage = cgImage
        self.lines = lines
        self.ocrText = OCRTextLayout.makeText(from: lines)
        refreshDetectedLanguage()
        isRecognizing = false
        emptyMessage = lines.isEmpty ? L10n.string("未识别到文字") : nil
        errorMessage = nil
        errorAction = nil
        statusHint = nil
    }

    func applyResult(_ result: TranslationResult, serviceID: String) {
        // 译成功后回写实际源语；标识符译前「未识别」，译后为执行用 en 等
        if result.sourceLanguageCode == TranslationLanguage.autoSourceToken
            || result.sourceLanguageCode.isEmpty
        {
            refreshDetectedLanguage()
        } else {
            detectedLanguageCode = result.sourceLanguageCode
        }
        if let item = serviceResults.first(where: { $0.id == serviceID }) {
            item.text = result.texts.joined(separator: "\n")
            item.statusMessage = result.userFacingNote
            item.isLoading = false
            item.isRetryable = false
            item.canOpenSettings = false
        }
        if serviceResults.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            emptyMessage = nil
            errorMessage = nil
            errorAction = nil
        }
    }

    /// 写入流式响应的当前累计文本；在最终响应到达前保持加载状态。
    func applyPartialText(_ text: String, serviceID: String) {
        guard let item = serviceResults.first(where: { $0.id == serviceID }) else { return }
        item.text = text
        item.statusMessage = nil
        item.isLoading = true
        item.isRetryable = false
        item.canOpenSettings = false
    }

    func applyError(
        _ message: String,
        serviceID: String,
        retryable: Bool = true,
        openSettings: Bool = false
    ) {
        if let item = serviceResults.first(where: { $0.id == serviceID }) {
            item.statusMessage = message
            item.isLoading = false
            item.isRetryable = retryable
            item.canOpenSettings = openSettings
        }
    }

    func applyError(_ message: String, action: ScreenTranslateResultErrorAction) {
        isRecognizing = false
        isTranslating = false
        errorMessage = message
        errorAction = action
        emptyMessage = nil
        statusHint = nil
    }

    func setServiceLoading(_ loading: Bool, serviceID: String) {
        guard let item = serviceResults.first(where: { $0.id == serviceID }) else { return }
        item.isLoading = loading
        if loading {
            item.statusMessage = nil
            item.isRetryable = false
            item.canOpenSettings = false
        }
    }

    func setServicesLoading(_ loading: Bool) {
        for item in serviceResults {
            item.isLoading = loading
            if loading {
                item.statusMessage = nil
                item.isRetryable = false
                item.canOpenSettings = false
            }
        }
    }

    func flash(_ message: String) {
        statusHint = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            if statusHint == message { statusHint = nil }
        }
    }
}

// MARK: - Actions

struct ScreenTranslateResultActions {
    var enabledOCRServices: () -> [OCRServiceEntry] = { [.vision()] }
    var onClose: () -> Void = {}
    var onTogglePin: () -> Void = {}
    var onRetryOCR: () -> Void = {}
    var onRescreen: () -> Void = {}
    var onOpenFile: () -> Void = {}
    var onSelectOCRService: (String) -> Void = { _ in }
    var onRetryService: (String) -> Void = { _ in }
    var onSourceLanguageChanged: (String) -> Void = { _ in }
    var onTargetLanguageChanged: (String) -> Void = { _ in }
    var onRetranslate: () -> Void = {}
    var onOpenOCRSettings: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onFavorite: () -> Void = {}
    var isFavorited: () -> Bool = { false }
}

// MARK: - View

/// 截图翻译结果窗：左图（顶对齐）+ OCR 原文；右方向条 + 多服务译文。
/// 大量复用 OCR 顶栏控件 / 图布 / 多服务卡片组件。
struct ScreenTranslateResultView: View {
    @Bindable var session: ScreenTranslateResultSession
    let actions: ScreenTranslateResultActions
    var settings: SettingsStore? = nil
    @FocusState private var isOCRFocused: Bool
    @State private var hoverCopyOCR = false

    /// 上图 / 下 OCR 比例（约 58 / 42）
    private let imageFlex: CGFloat = 0.58

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().opacity(0.35)
            mainSplit
        }
        .resultPanelChrome()
        .frame(minWidth: session.showLeftPanel ? 860 : 420, minHeight: 480)
    }

    // MARK: Header（对齐 OCR 结果窗）

    private var headerBar: some View {
        HStack(spacing: 8) {
            OCRChromeIconButton(
                symbol: session.isPinned ? "pin.fill" : "pin",
                tooltip: strTooltip(
                    session.isPinned ? L10n.string("取消钉住窗口") : L10n.string("钉住窗口"),
                    .ocrTogglePin
                ),
                isAccent: session.isPinned
            ) {
                actions.onTogglePin()
            }

            if session.isRecognizing || session.isTranslating {
                ProgressView()
                    .controlSize(.small)
            }

            if let hint = session.statusHint {
                ResultChromeStatusHint(text: hint)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                OCRServiceMenu(
                    selectedID: session.selectedOCRServiceID,
                    services: actions.enabledOCRServices(),
                    onSelect: { id in
                        guard id != session.selectedOCRServiceID else { return }
                        actions.onSelectOCRService(id)
                    },
                    onMenuOpenChange: { open in
                        if open {
                            session.beginFocusSuppress()
                        } else {
                            session.endFocusSuppress()
                        }
                    }
                )

                // 顶栏不再放「重试识别」：下方「再译」/卡片刷新已覆盖；快捷键 ocrRetry 仍可用
                OCRChromeIconButton(symbol: "camera.viewfinder", tooltip: L10n.string("重新截图")) {
                    actions.onRescreen()
                }
                OCRChromeIconButton(symbol: "folder", tooltip: L10n.string("从本地文件识别并翻译")) {
                    actions.onOpenFile()
                }
                OCRChromeIconButton(
                    symbol: session.isContentFavorited ? "star.fill" : "star",
                    tooltip: session.isContentFavorited ? L10n.string("取消收藏") : L10n.string("添加到收藏（图 + 译文）"),
                    isAccent: session.isContentFavorited
                ) {
                    actions.onFavorite()
                }
                OCRChromeIconButton(
                    symbol: session.showLeftPanel
                        ? "rectangle.lefthalf.filled"
                        : "rectangle.leadinghalf.inset.filled",
                    tooltip: session.showLeftPanel ? L10n.string("隐藏左侧") : L10n.string("显示左侧"),
                    isAccent: !session.showLeftPanel
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        session.showLeftPanel.toggle()
                    }
                }
                OCRChromeIconButton(symbol: "gearshape", tooltip: L10n.string("偏好设置")) {
                    actions.onOpenSettings()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Split

    private var mainSplit: some View {
        HStack(spacing: 0) {
            if session.showLeftPanel {
                leftPane
                    .frame(minWidth: 300)
                    .layoutPriority(1)
                Divider().opacity(0.35)
            }
            rightPane
                .frame(minWidth: 320)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Left — 上图顶对齐 + 下 OCR

    private var leftPane: some View {
        GeometryReader { geo in
            let imageH = max(120, geo.size.height * imageFlex)
            VStack(spacing: 0) {
                OCRImageCanvas(
                    image: session.image,
                    pixelSize: CGSize(width: session.cgImage.width, height: session.cgImage.height),
                    lines: session.lines,
                    showBoxes: session.showOCRBoxes,
                    contentAlignment: .top
                )
                .frame(height: imageH)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.25))

                HStack(spacing: 8) {
                    OCRChromeTextButton(
                        title: session.showOCRBoxes ? L10n.string("隐藏识别框") : L10n.string("显示识别框"),
                        symbol: session.showOCRBoxes ? "eye.slash" : "eye",
                        tooltip: session.showOCRBoxes ? L10n.string("隐藏 OCR 识别框") : L10n.string("显示 OCR 识别框")
                    ) {
                        session.showOCRBoxes.toggle()
                    }
                    Spacer()
                    Text(String(format: L10n.string("%lld 块"), session.lines.count))
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.textTertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AppTheme.textPrimary.opacity(0.04))

                ocrTextCard
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var ocrTextCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $session.ocrText)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .focused($isOCRFocused)
                    .disabled(session.isRecognizing)

                if session.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(session.isRecognizing ? L10n.string("正在识别…") : L10n.string("未识别到文字"))
                        .font(.system(size: 13))
                        .foregroundStyle(AppTheme.textTertiary)
                        .padding(18)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.surface.opacity(0.55))

            HStack(spacing: 8) {
                Button {
                    copyText(session.ocrText, hint: L10n.string("已复制 OCR 原文"))
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(AppTheme.textPrimary.opacity(hoverCopyOCR ? 0.14 : 0.08))
                        )
                        .foregroundStyle(AppTheme.textPrimary.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help(L10n.string("复制 OCR 原文"))
                .onHover { hoverCopyOCR = $0 }
                .onContinuousHover { phase in
                    switch phase {
                    case .active: updateHandCursor(true)
                    case .ended: updateHandCursor(false)
                    }
                }

                if session.sourceSelection == TranslationLanguage.autoSourceToken,
                   !session.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(AppTheme.textPrimary.opacity(0.04))
        }
    }

    // MARK: Right — 方向条 + 多服务

    private var rightPane: some View {
        VStack(spacing: 0) {
            TranslationDirectionBar(
                sourceTitle: session.sourceMenuTitle,
                targetTitle: session.targetMenuTitle,
                sourceSelection: session.sourceSelection,
                targetSelection: session.targetSelection,
                showRetranslate: true,
                canRetranslate: session.canRetranslate,
                onSelectSource: { code in
                    session.sourceSelection = code
                    actions.onSourceLanguageChanged(code)
                },
                onSelectTarget: { code in
                    session.targetSelection = code
                    actions.onTargetLanguageChanged(code)
                },
                onSwap: {
                    session.swapDirection()
                    actions.onTargetLanguageChanged(session.targetSelection)
                    // 交换后立即再译（目标已变）
                    actions.onRetranslate()
                },
                onRetranslate: {
                    session.refreshDetectedLanguage()
                    actions.onRetranslate()
                }
            )
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if let errorMessage = session.errorMessage {
                stateBanner(
                    message: errorMessage,
                    isError: true,
                    action: session.errorAction ?? .retranslate
                )
            } else if let emptyMessage = session.emptyMessage {
                stateBanner(
                    message: emptyMessage,
                    isError: false,
                    action: session.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? .retryOCR
                        : .retranslate
                )
            }

            if session.isRecognizing {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(L10n.string("正在识别…"))
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.emptyMessage != nil {
                Spacer(minLength: 0)
            } else if session.serviceResults.isEmpty {
                ContentUnavailableView(
                    L10n.string("无可用翻译服务"),
                    systemImage: "globe",
                    description: Text(L10n.string("请到设置中启用并配置翻译服务"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TranslationServiceCardsView(
                    items: session.serviceResults,
                    canRetranslate: session.canRetranslate,
                    onCopy: { text in
                        copyText(text, hint: L10n.string("已复制译文"))
                    },
                    onRetranslate: {
                        session.refreshDetectedLanguage()
                        actions.onRetranslate()
                    },
                    onRetryService: actions.onRetryService,
                    onOpenSettings: actions.onOpenSettings
                )
            }
        }
        .background(AppTheme.surface.opacity(0.35))
    }

    private func stateBanner(
        message: String,
        isError: Bool,
        action: ScreenTranslateResultErrorAction
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle" : "text.viewfinder")
                .foregroundStyle(isError ? AppTheme.warning : AppTheme.textSecondary)

            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button(stateActionTitle(action)) {
                performStateAction(action)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background((isError ? AppTheme.warning : AppTheme.textSecondary).opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 10)
    }

    private func stateActionTitle(_ action: ScreenTranslateResultErrorAction) -> String {
        switch action {
        case .retryOCR:
            return L10n.string("重试识别")
        case .retranslate:
            return L10n.string("重新翻译")
        case .openOCRSettings:
            return L10n.string("打开 OCR 设置")
        case .openTranslationSettings:
            return L10n.string("打开翻译设置")
        }
    }

    private func performStateAction(_ action: ScreenTranslateResultErrorAction) {
        switch action {
        case .retryOCR:
            actions.onRetryOCR()
        case .retranslate:
            actions.onRetranslate()
        case .openOCRSettings:
            actions.onOpenOCRSettings()
        case .openTranslationSettings:
            actions.onOpenSettings()
        }
    }

    private func copyText(_ text: String, hint: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            session.flash(L10n.string("没有可复制的内容"))
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        session.flash(hint)
    }

    private func strTooltip(_ title: String, _ action: LocalShortcutAction) -> String {
        if let settings {
            return settings.tooltip(title, action: action)
        }
        return ShortcutDisplay.tooltip(title, chord: action.defaultChord)
    }
}
