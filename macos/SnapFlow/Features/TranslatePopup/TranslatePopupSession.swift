import Foundation
import Observation

// MARK: - Language options (精简常用表)

enum TranslatePopupLanguageOption: String, CaseIterable, Identifiable, Hashable, Sendable {
    case autoDetect = "auto"
    case autoSelect = "system"
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"

    var id: String { rawValue }

    /// 源语言下拉（含自动检测）
    static var sourceOptions: [TranslatePopupLanguageOption] {
        [.autoDetect, .english, .simplifiedChinese, .traditionalChinese, .japanese, .korean, .french, .german, .spanish]
    }

    /// 目标语言下拉（含自动选择=系统）
    static var targetOptions: [TranslatePopupLanguageOption] {
        [.autoSelect, .simplifiedChinese, .english, .traditionalChinese, .japanese, .korean, .french, .german, .spanish]
    }

    var menuTitle: String {
        switch self {
        case .autoDetect: L10n.string("自动检测")
        case .autoSelect: L10n.string("自动选择")
        case .english: L10n.string("英语")
        case .simplifiedChinese: L10n.string("简体中文")
        case .traditionalChinese: L10n.string("繁体中文")
        case .japanese: L10n.string("日语")
        case .korean: L10n.string("韩语")
        case .french: L10n.string("法语")
        case .german: L10n.string("德语")
        case .spanish: L10n.string("西班牙语")
        }
    }

    static func from(code: String) -> TranslatePopupLanguageOption {
        let raw = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty || raw == TranslationLanguage.autoSourceToken { return .autoDetect }
        if raw == TranslationLanguage.systemTargetToken { return .autoSelect }
        let n = TranslationLanguage.normalize(raw)
        if let exact = TranslatePopupLanguageOption(rawValue: n) { return exact }
        // en-GB 等变体归到常用项
        switch TranslationLanguage.identityKey(n) {
        case "en": return .english
        case "zh-hans": return .simplifiedChinese
        case "zh-hant": return .traditionalChinese
        case "ja": return .japanese
        case "ko": return .korean
        case "fr": return .french
        case "de": return .german
        case "es": return .spanish
        default: return .autoDetect
        }
    }
}

// MARK: - Per-service result

@MainActor
@Observable
final class TranslateServiceResultItem: Identifiable {
    let id: String
    let displayName: String
    let symbolName: String
    /// 当前服务类型；历史记录中可能没有该信息，因此保留旧图标回退。
    var kind: TranslationServiceKind?
    var text: String
    var statusMessage: String?
    var isExpanded: Bool
    var isLoading: Bool
    var isRetryable: Bool
    var canOpenSettings: Bool

    init(
        id: String,
        displayName: String,
        symbolName: String = "globe",
        kind: TranslationServiceKind? = nil,
        text: String = "",
        statusMessage: String? = nil,
        isExpanded: Bool = true,
        isLoading: Bool = false,
        isRetryable: Bool = false,
        canOpenSettings: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.symbolName = symbolName
        self.kind = kind
        self.text = text
        self.statusMessage = statusMessage
        self.isExpanded = isExpanded
        self.isLoading = isLoading
        self.isRetryable = isRetryable
        self.canOpenSettings = canOpenSettings
    }

    var summaryLine: String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return statusMessage ?? L10n.string("暂无译文") }
        if t.count <= 48 { return t }
        return String(t.prefix(48)) + "…"
    }
}

// MARK: - Session

/// 划词翻译浮层会话：原文 + 方向条 + 多服务译文列表。
@MainActor
@Observable
final class TranslatePopupSession {
    var sourceText: String
    /// 源语言选择（会话内；默认 auto；不写设置）
    var sourceSelection: String
    /// 目标语言选择（与设置同步；`system` 或 BCP-47）
    var targetSelection: String
    /// 最近一次检测到的源语言码
    var detectedLanguageCode: String?
    /// 多服务结果；顺序由默认服务优先规则决定。
    var serviceResults: [TranslateServiceResultItem]
    var isTranslating: Bool = false
    var flashMessage: String?
    var sourceStatusMessage: String?
    /// >0 时禁止因失焦关闭（仅系统「下载语言以翻译」等抢 key 场景）。
    /// loading 时**允许**点外部关闭并取消翻译。
    var suppressFocusDismissCount: Int = 0

    var shouldSuppressFocusDismiss: Bool {
        suppressFocusDismissCount > 0
    }

    func beginFocusSuppress() {
        suppressFocusDismissCount += 1
    }

    func endFocusSuppress() {
        suppressFocusDismissCount = max(0, suppressFocusDismissCount - 1)
    }

    init(
        sourceText: String,
        translatedText: String = "",
        statusMessage: String? = nil,
        targetSelection: String = TranslationLanguage.systemTargetToken,
        detectedLanguageCode: String? = nil,
        services: [TranslationServiceEntry] = [.system()]
    ) {
        self.sourceText = sourceText
        self.sourceSelection = TranslationLanguage.autoSourceToken
        self.targetSelection = targetSelection
        self.detectedLanguageCode = detectedLanguageCode
            ?? TranslationLanguage.detectLanguageCode(in: sourceText)
        self.sourceStatusMessage = sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? statusMessage
            : nil
        self.serviceResults = services.map { entry in
            TranslateServiceResultItem(
                id: entry.id,
                displayName: entry.displayName,
                symbolName: entry.kind.symbolName,
                kind: entry.kind,
                text: entry.kind == .system ? translatedText : "",
                statusMessage: entry.kind == .system ? statusMessage : nil,
                isExpanded: true,
                isLoading: false
            )
        }
    }

    var canRetranslate: Bool {
        !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isTranslating
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

    /// 是否已本地检出源语（标识符未识别时为 false）。
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
        if sourceSelection == TranslationLanguage.autoSourceToken {
            return L10n.string("自动检测")
        }
        return TranslatePopupLanguageOption.from(code: sourceSelection).menuTitle
    }

    var targetMenuTitle: String {
        if targetSelection == TranslationLanguage.systemTargetToken {
            return L10n.string("自动选择")
        }
        return TranslatePopupLanguageOption.from(code: targetSelection).menuTitle
    }

    /// 交换方向：auto↔system；固定语言对调。目标变更由调用方写入设置。
    func swapDirection() {
        let left = sourceSelection
        let right = targetSelection
        let newLeft = (right == TranslationLanguage.systemTargetToken)
            ? TranslationLanguage.autoSourceToken
            : right
        let newRight = (left == TranslationLanguage.autoSourceToken)
            ? TranslationLanguage.systemTargetToken
            : left
        sourceSelection = newLeft
        targetSelection = newRight
    }

    func refreshDetectedLanguage() {
        detectedLanguageCode = TranslationLanguage.detectLanguageCode(in: sourceText)
    }

    func configureServices(_ services: [TranslationServiceEntry]) {
        let oldItems = Dictionary(uniqueKeysWithValues: serviceResults.map { ($0.id, $0) })
        serviceResults = services.map { entry in
            if let old = oldItems[entry.id] {
                old.kind = entry.kind
                return old
            }
            return TranslateServiceResultItem(
                id: entry.id,
                displayName: entry.displayName,
                symbolName: entry.kind.symbolName,
                kind: entry.kind
            )
        }
    }

    func applyResult(_ result: TranslationResult, serviceID: String) {
        // 译成功后用实际执行源语回写标签（标识符静默 en →「识别为 英语」）。
        // 译前 detect==nil 仍显示「未识别」。
        if result.sourceLanguageCode == TranslationLanguage.autoSourceToken
            || result.sourceLanguageCode.isEmpty
        {
            detectedLanguageCode = TranslationLanguage.detectLanguageCode(in: sourceText)
        } else {
            detectedLanguageCode = result.sourceLanguageCode
        }
        if let item = serviceResults.first(where: { $0.id == serviceID }) {
            item.text = result.texts.first ?? ""
            item.statusMessage = result.userFacingNote
            item.isLoading = false
            item.isRetryable = false
            item.canOpenSettings = false
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
        flashMessage = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if flashMessage == message {
                flashMessage = nil
            }
        }
    }
}
