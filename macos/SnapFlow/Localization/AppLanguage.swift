import Foundation

extension Notification.Name {
    /// 界面语言偏好变更（菜单栏、窗标题等 AppKit 路径可订阅刷新）。
    static let snapFlowLanguageDidChange = Notification.Name("SnapFlow.languageDidChange")
}

/// 应用界面语言偏好。翻译目标语言仍由 `SettingsStore.targetLanguage` 单独管理。
enum AppLanguagePreference: String, CaseIterable, Identifiable, Codable, Sendable {
    /// 跟随系统首选语言（在 `zh-Hans` / `en` 中择优，其它语言回退到简体中文）。
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    static let defaultsKey = "app.languagePreference"

    var id: String { rawValue }

    /// 语言名称：跟随系统用本地化文案；固定语言用该语言自称。
    var displayName: String {
        switch self {
        case .system:
            return L10n.string("language.system")
        case .simplifiedChinese:
            return "简体中文"
        case .english:
            return "English"
        }
    }

    /// 解析为实际用于 `String(localized:)` / SwiftUI `locale` 的 `Locale`。
    var resolvedLocale: Locale {
        switch self {
        case .system:
            return Self.bestSupportedLocale(from: Locale.preferredLanguages)
        case .simplifiedChinese:
            return Locale(identifier: "zh-Hans")
        case .english:
            return Locale(identifier: "en")
        }
    }

    /// BCP-47 语言码（固定偏好）或系统解析结果。
    var resolvedLanguageCode: String {
        switch self {
        case .system:
            return Self.bestSupportedLanguageCode(from: Locale.preferredLanguages)
        case .simplifiedChinese:
            return "zh-Hans"
        case .english:
            return "en"
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> AppLanguagePreference {
        guard let raw = defaults.string(forKey: defaultsKey),
              let value = AppLanguagePreference(rawValue: raw)
        else {
            return .system
        }
        return value
    }

    static func save(_ value: AppLanguagePreference, to defaults: UserDefaults = .standard) {
        defaults.set(value.rawValue, forKey: defaultsKey)
    }

    /// 当前已支持的界面语言集合；扩展新语言时在此追加。
    static let supportedLanguageCodes: [String] = ["zh-Hans", "en"]

    static func bestSupportedLocale(from preferredLanguages: [String]) -> Locale {
        Locale(identifier: bestSupportedLanguageCode(from: preferredLanguages))
    }

    static func bestSupportedLanguageCode(from preferredLanguages: [String]) -> String {
        for tag in preferredLanguages {
            let normalized = tag.replacingOccurrences(of: "_", with: "-")
            let lower = normalized.lowercased()
            if lower == "zh-hans" || lower.hasPrefix("zh-hans-") || lower == "zh-cn" || lower.hasPrefix("zh-cn-") {
                return "zh-Hans"
            }
            if lower == "zh" || lower.hasPrefix("zh-") {
                // 未标明繁简时，当前产品默认简体
                if lower.contains("hant") || lower.contains("tw") || lower.contains("hk") || lower.contains("mo") {
                    // 暂无繁体包：回退简体，便于后续扩展
                    return "zh-Hans"
                }
                return "zh-Hans"
            }
            if lower == "en" || lower.hasPrefix("en-") {
                return "en"
            }
        }
        return "zh-Hans"
    }
}

/// 从 UserDefaults 解析当前界面 Locale（供 AppKit / 非 Observation 路径使用）。
enum AppLanguage {
    static func currentPreference(defaults: UserDefaults = .standard) -> AppLanguagePreference {
        AppLanguagePreference.load(from: defaults)
    }

    static func resolvedLocale(defaults: UserDefaults = .standard) -> Locale {
        currentPreference(defaults: defaults).resolvedLocale
    }

    static func resolvedLanguageCode(defaults: UserDefaults = .standard) -> String {
        currentPreference(defaults: defaults).resolvedLanguageCode
    }
}
