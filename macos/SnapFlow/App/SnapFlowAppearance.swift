import SwiftUI

extension Notification.Name {
    /// 强调色 / 外观偏好变更（可选旁路；主路径靠 SettingsStore Observation）
    static let snapFlowAppearanceDidChange = Notification.Name("SnapFlow.appearanceDidChange")
    // 语言变更见 `AppLanguage.swift` 中的 `snapFlowLanguageDidChange`
}

/// 解析品牌色 vs 系统强调色。
enum SnapFlowAppearance {
    static func resolvedAccent(useSystem: Bool) -> Color {
        useSystem ? Color.accentColor : AppTheme.brandAccent
    }

    static func resolvedAccentSoft(useSystem: Bool) -> Color {
        useSystem ? Color.accentColor.opacity(0.14) : AppTheme.brandAccentSoft
    }
}

// MARK: - Environment

private struct SnapFlowAccentKey: EnvironmentKey {
    static let defaultValue: Color = AppTheme.brandAccent
}

private struct SnapFlowAccentSoftKey: EnvironmentKey {
    static let defaultValue: Color = AppTheme.brandAccentSoft
}

extension EnvironmentValues {
    /// 当前解析后的强调色（跟随设置即时更新）
    var snapFlowAccent: Color {
        get { self[SnapFlowAccentKey.self] }
        set { self[SnapFlowAccentKey.self] = newValue }
    }

    var snapFlowAccentSoft: Color {
        get { self[SnapFlowAccentSoftKey.self] }
        set { self[SnapFlowAccentSoftKey.self] = newValue }
    }
}

// MARK: - View

private struct SnapFlowAppearanceModifier: ViewModifier {
    @Bindable var settings: SettingsStore

    func body(content: Content) -> some View {
        // 读取 useSystemAccentColor / appLanguagePreference → Observation 订阅
        let useSystem = settings.useSystemAccentColor
        let locale = settings.resolvedLocale
        let accent = SnapFlowAppearance.resolvedAccent(useSystem: useSystem)
        let soft = SnapFlowAppearance.resolvedAccentSoft(useSystem: useSystem)
        content
            .environment(\.locale, locale)
            .environment(\.snapFlowAccent, accent)
            .environment(\.snapFlowAccentSoft, soft)
            .tint(accent)
            .id(settings.appLanguagePreference) // 语言切换时强制重建文案树
    }
}

extension View {
    /// 绑定全局强调色：设置页切换后，所有挂了同一 `SettingsStore` 的浮层即时变色。
    @ViewBuilder
    func snapFlowAppearance(settings: SettingsStore?) -> some View {
        if let settings {
            modifier(SnapFlowAppearanceModifier(settings: settings))
        } else {
            self
                .environment(\.snapFlowAccent, AppTheme.accent)
                .environment(\.snapFlowAccentSoft, AppTheme.accentSoft)
                .tint(AppTheme.accent)
        }
    }
}
