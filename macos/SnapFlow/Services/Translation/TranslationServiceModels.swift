import AppKit
import Foundation

// MARK: - Kind / Entry

enum TranslationServiceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case baidu
    case youdao
    case google
    case deepl
    case microsoft
    case volcengine
    case tencent
    case aliyun
    case caiyun
    case niutrans
    case amazon
    case openai
    case openrouter
    case deepseek
    case qwen
    case zhipu
    case siliconflow
    case groq
    case grok
    case kimi
    case ollama
    case lmStudio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: L10n.string("系统翻译")
        case .baidu: L10n.string("百度翻译")
        case .youdao: L10n.string("有道翻译")
        case .google: L10n.string("Google 翻译")
        case .deepl: "DeepL"
        case .microsoft: L10n.string("Microsoft 翻译")
        case .volcengine: L10n.string("火山翻译")
        case .tencent: L10n.string("腾讯翻译")
        case .aliyun: L10n.string("阿里翻译")
        case .caiyun: L10n.string("彩云小译")
        case .niutrans: L10n.string("小牛翻译")
        case .amazon: L10n.string("Amazon 翻译")
        case .openai: "OpenAI"
        case .openrouter: "OpenRouter"
        case .deepseek: "DeepSeek"
        case .qwen: L10n.string("通义千问")
        case .zhipu: L10n.string("智谱 GLM")
        case .siliconflow: L10n.string("硅基流动")
        case .groq: "Groq"
        case .grok: "Grok"
        case .kimi: "Kimi"
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        }
    }

    var symbolName: String {
        switch self {
        case .system: "globe"
        case .baidu: "b.circle"
        case .youdao: "y.circle"
        case .google: "g.circle"
        case .deepl: "character.bubble"
        case .microsoft: "window.vertical.open"
        case .volcengine: "v.circle"
        case .tencent: "t.circle"
        case .aliyun: "a.circle"
        case .caiyun: "cloud.sun"
        case .niutrans: "n.circle"
        case .amazon: "a.circle"
        case .openai: "sparkles"
        case .openrouter: "arrow.triangle.branch"
        case .deepseek: "d.circle"
        case .qwen: "q.circle"
        case .zhipu: "z.circle"
        case .siliconflow: "waveform.path"
        case .groq: "bolt.circle"
        case .grok: "x.circle"
        case .kimi: "moon.stars"
        case .ollama: "cube"
        case .lmStudio: "rectangle.3.group"
        }
    }

    /// 服务有明确的翻译专用模型时，展示在配置页的建议值。
    var recommendedTranslationModel: String? {
        switch self {
        case .siliconflow: "tencent/Hunyuan-MT-7B"
        case .ollama: "translategemma:4b"
        case .lmStudio: "TranslateGemma 4B（搜索 translategemma-4b-it，选择可用的 GGUF/MLX 量化版本）"
        default: nil
        }
    }

    var isBuiltIn: Bool { self == .system }
    var requiresCredentials: Bool { self != .system }

    static let catalogAddable: [TranslationServiceKind] = [
        .baidu, .youdao, .google, .deepl, .microsoft,
        .volcengine, .tencent, .aliyun, .caiyun, .niutrans,
        .amazon,
        .openai, .openrouter, .deepseek, .qwen, .zhipu,
        .siliconflow, .groq, .grok, .kimi,
        .ollama, .lmStudio,
    ]
}

struct OpenAICompatibleTranslationConfig: Codable, Equatable, Sendable {
    var apiKey: String = ""
    var model: String = ""
    /// 支持流式协议的模型是否按增量响应请求；旧配置缺失时默认关闭。
    var streamingEnabled: Bool = false

    private enum CodingKeys: String, CodingKey {
        case apiKey
        case model
        case streamingEnabled
    }

    init(
        apiKey: String = "",
        model: String = "",
        streamingEnabled: Bool = false
    ) {
        self.apiKey = apiKey
        self.model = model
        self.streamingEnabled = streamingEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiKey = try container.decode(String.self, forKey: .apiKey)
        model = try container.decode(String.self, forKey: .model)
        streamingEnabled = try container.decodeIfPresent(Bool.self, forKey: .streamingEnabled) ?? false
    }

    var hasCredentials: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct LocalModelTranslationConfig: Codable, Equatable, Sendable {
    var baseURL: String = ""
    var model: String = ""
    var apiKey: String = ""
    /// 支持流式协议的本地服务是否按增量响应请求；旧配置缺失时默认关闭。
    var streamingEnabled: Bool = false

    private enum CodingKeys: String, CodingKey {
        case baseURL
        case model
        case apiKey
        case streamingEnabled
    }

    init(
        baseURL: String = "",
        model: String = "",
        apiKey: String = "",
        streamingEnabled: Bool = false
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.streamingEnabled = streamingEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        model = try container.decode(String.self, forKey: .model)
        apiKey = try container.decode(String.self, forKey: .apiKey)
        streamingEnabled = try container.decodeIfPresent(Bool.self, forKey: .streamingEnabled) ?? false
    }

    var hasCredentials: Bool {
        guard !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil
        else {
            return false
        }
        return true
    }
}

struct BaiduTranslationConfig: Codable, Equatable, Sendable {
    var appID: String = ""
    var secretKey: String = ""

    var hasCredentials: Bool {
        !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct YoudaoTranslationConfig: Codable, Equatable, Sendable {
    var appKey: String = ""
    var appSecret: String = ""

    var hasCredentials: Bool {
        !appKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !appSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct GoogleTranslationConfig: Codable, Equatable, Sendable {
    var apiKey: String = ""

    var hasCredentials: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct DeepLTranslationConfig: Codable, Equatable, Sendable {
    var authKey: String = ""

    var hasCredentials: Bool {
        !authKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct MicrosoftTranslationConfig: Codable, Equatable, Sendable {
    var subscriptionKey: String = ""
    var region: String = ""

    var hasCredentials: Bool {
        !subscriptionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct VolcengineTranslationConfig: Codable, Equatable, Sendable {
    var accessKey: String = ""
    var secretKey: String = ""
    var region: String = "cn-north-1"

    var hasCredentials: Bool {
        !accessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct TencentTranslationConfig: Codable, Equatable, Sendable {
    var secretID: String = ""
    var secretKey: String = ""
    var region: String = "ap-beijing"

    var hasCredentials: Bool {
        !secretID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct AliyunTranslationConfig: Codable, Equatable, Sendable {
    var accessKeyID: String = ""
    var accessKeySecret: String = ""

    var hasCredentials: Bool {
        !accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !accessKeySecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct CaiyunTranslationConfig: Codable, Equatable, Sendable {
    var token: String = ""

    var hasCredentials: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct NiuTransTranslationConfig: Codable, Equatable, Sendable {
    var apiKey: String = ""

    var hasCredentials: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct AmazonTranslationConfig: Codable, Equatable, Sendable {
    var accessKeyID: String = ""
    var secretAccessKey: String = ""
    var region: String = "us-east-1"
    var sessionToken: String = ""

    var hasCredentials: Bool {
        !accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct TranslationServiceEntry: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var kind: TranslationServiceKind
    var displayName: String
    var isEnabled: Bool
    var privacyAccepted: Bool
    var baidu: BaiduTranslationConfig?
    var youdao: YoudaoTranslationConfig?
    var google: GoogleTranslationConfig?
    var deepl: DeepLTranslationConfig?
    var microsoft: MicrosoftTranslationConfig?
    var volcengine: VolcengineTranslationConfig?
    var tencent: TencentTranslationConfig?
    var aliyun: AliyunTranslationConfig?
    var caiyun: CaiyunTranslationConfig?
    var niutrans: NiuTransTranslationConfig?
    var amazon: AmazonTranslationConfig?
    var openAICompatible: OpenAICompatibleTranslationConfig?
    var localModel: LocalModelTranslationConfig?

    static let systemID = "system"

    static func system() -> TranslationServiceEntry {
        TranslationServiceEntry(
            id: systemID,
            kind: .system,
            displayName: TranslationServiceKind.system.displayName,
            isEnabled: true,
            privacyAccepted: true
        )
    }

    static func make(kind: TranslationServiceKind) -> TranslationServiceEntry {
        var entry = TranslationServiceEntry(
            id: kind == .system ? systemID : UUID().uuidString,
            kind: kind,
            displayName: kind.displayName,
            isEnabled: kind == .system,
            privacyAccepted: kind == .system
        )
        switch kind {
        case .system: break
        case .baidu: entry.baidu = BaiduTranslationConfig()
        case .youdao: entry.youdao = YoudaoTranslationConfig()
        case .google: entry.google = GoogleTranslationConfig()
        case .deepl: entry.deepl = DeepLTranslationConfig()
        case .microsoft: entry.microsoft = MicrosoftTranslationConfig()
        case .volcengine: entry.volcengine = VolcengineTranslationConfig()
        case .tencent: entry.tencent = TencentTranslationConfig()
        case .aliyun: entry.aliyun = AliyunTranslationConfig()
        case .caiyun: entry.caiyun = CaiyunTranslationConfig()
        case .niutrans: entry.niutrans = NiuTransTranslationConfig()
        case .amazon: entry.amazon = AmazonTranslationConfig()
        case .openai, .openrouter, .deepseek, .qwen, .zhipu,
             .siliconflow, .groq, .grok, .kimi:
            entry.openAICompatible = OpenAICompatibleTranslationConfig()
        case .ollama:
            entry.localModel = LocalModelTranslationConfig(baseURL: "http://127.0.0.1:11434")
        case .lmStudio:
            entry.localModel = LocalModelTranslationConfig(baseURL: "http://127.0.0.1:1234/v1")
        }
        return entry
    }

    var badgeTitle: String? {
        kind.isBuiltIn ? L10n.string("内置") : L10n.string("密钥")
    }

    var isReadyToTranslate: Bool {
        switch kind {
        case .system: true
        case .baidu: baidu?.hasCredentials == true
        case .youdao: youdao?.hasCredentials == true
        case .google: google?.hasCredentials == true
        case .deepl: deepl?.hasCredentials == true
        case .microsoft: microsoft?.hasCredentials == true
        case .volcengine: volcengine?.hasCredentials == true
        case .tencent: tencent?.hasCredentials == true
        case .aliyun: aliyun?.hasCredentials == true
        case .caiyun: caiyun?.hasCredentials == true
        case .niutrans: niutrans?.hasCredentials == true
        case .amazon: amazon?.hasCredentials == true
        case .openai, .openrouter, .deepseek, .qwen, .zhipu,
             .siliconflow, .groq, .grok, .kimi:
            openAICompatible?.hasCredentials == true
        case .ollama, .lmStudio:
            localModel?.hasCredentials == true
        }
    }

    /// 当前配置是否要求 Provider 使用流式协议。
    /// 仅 OpenAI 兼容和本地模型服务支持该开关，传统翻译 API 始终走完整响应。
    var isStreamingEnabled: Bool {
        switch kind {
        case .openai, .openrouter, .deepseek, .qwen, .zhipu,
             .siliconflow, .groq, .grok, .kimi:
            openAICompatible?.streamingEnabled == true
        case .ollama, .lmStudio:
            localModel?.streamingEnabled == true
        default:
            false
        }
    }
}

// MARK: - Result

struct TranslationResult: Sendable, Equatable {
    /// 与入参等长的译文（同语言短路时为原文）。
    let texts: [String]
    let sourceLanguageCode: String
    let targetLanguageCode: String
    /// 源≈目标，未调用系统翻译。
    let isSameLanguage: Bool

    /// 给 UI 的轻提示（可空）。
    var userFacingNote: String? {
        if isSameLanguage {
            return L10n.string("已是目标语言，无需翻译")
        }
        return nil
    }
}

// MARK: - Errors

enum TranslationServiceError: LocalizedError {
    case emptyInput
    case serviceNotFound
    case serviceDisabled
    case missingCredentials(String)
    case cannotDetectLanguage
    case modelNotInstalled(source: String, target: String)
    case unsupportedPair(source: String, target: String)
    case network(String)
    case authenticationFailed
    case quotaExceeded
    case rateLimited
    case serverUnavailable
    case api(String)
    case invalidResponse(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return L10n.string("没有可翻译的文本")
        case .serviceNotFound:
            return L10n.string("未找到翻译服务，请到设置中配置")
        case .serviceDisabled:
            return L10n.string("该翻译服务未启用，请到设置中开启")
        case .missingCredentials(let name):
            return String(format: L10n.string("「%@」配置未完成，请到设置中补充密钥"), name)
        case .cannotDetectLanguage:
            return L10n.string("无法识别原文语言，请在设置中指定源语言后重试")
        case .modelNotInstalled(let source, let target):
            return String(format: L10n.string("系统需要「%@ → %@」语言包才能翻译。请打开「系统设置 → 通用 → 语言与地区 → 翻译语言」确认双方语言已下载；若刚装完请稍候再试，或在设置中固定源语言后重试"), TranslationLanguage.displayName(for: source), TranslationLanguage.displayName(for: target))
        case .unsupportedPair(let source, let target):
            return String(format: L10n.string("当前服务不支持「%@ → %@」语言对"), TranslationLanguage.displayName(for: source), TranslationLanguage.displayName(for: target))
        case .network(let msg):
            return String(format: L10n.string("翻译网络错误：%@"), msg)
        case .authenticationFailed:
            return L10n.string("翻译服务认证失败，请检查密钥和权限")
        case .quotaExceeded:
            return L10n.string("翻译服务额度不足或计费未启用")
        case .rateLimited:
            return L10n.string("翻译请求过于频繁，请稍后重试")
        case .serverUnavailable:
            return L10n.string("翻译服务暂时不可用，请稍后重试")
        case .api(let msg):
            return String(format: L10n.string("翻译服务返回错误：%@"), msg)
        case .invalidResponse(let msg):
            return String(format: L10n.string("翻译响应无法解析：%@"), msg)
        case .failed(let msg):
            return String(format: L10n.string("翻译失败：%@"), msg)
        }
    }
}

// MARK: - System settings opener

enum TranslationSystemSettingsOpener {
    /// 尽量打开「语言与地区 / 翻译语言」相关面板。
    @MainActor
    static func openTranslationLanguages() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Localization-Settings.extension",
            "x-apple.systempreferences:com.apple.Localization-Settings",
            "x-apple.systempreferences:com.apple.preference.language",
        ]
        for s in candidates {
            if let url = URL(string: s), NSWorkspace.shared.open(url) {
                return
            }
        }
        if let url = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(url)
        }
    }
}
