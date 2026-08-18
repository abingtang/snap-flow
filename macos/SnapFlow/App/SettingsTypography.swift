import SwiftUI

/// 偏好设置页语义字体：略大于系统默认 caption 层级，提升可读性；并限制 Dynamic Type 上限以免崩版。
enum SettingsTypography {
    /// 页面大标题（右侧顶栏）
    static let pageTitle: Font = .title2.weight(.semibold)
    /// 侧栏项 / 行主标题（约 13→15pt 量级）
    static let rowTitle: Font = .body.weight(.medium)
    /// 行副文案、说明
    static let rowSubtitle: Font = .subheadline
    /// 侧栏分组小标题
    static let sectionHeader: Font = .subheadline.weight(.semibold)
    /// 卡片分组标题（「记录」「最近记录」等）
    static let cardTitle: Font = .body.weight(.semibold)
    /// 紧凑控件 / 次要标签
    static let compact: Font = .subheadline
    /// 状态胶囊等
    static let badge: Font = .caption.weight(.semibold)

    /// 设置页正文区域允许的 Dynamic Type 范围
    static let contentTypeRange = DynamicTypeSize.medium ... DynamicTypeSize.xxxLarge
}

extension View {
    /// 设置页说明/正文：语义字体 + 有限缩放。
    /// `nonisolated`：`FeatureHistoryViews` 等 free function 可能在 nonisolated 上下文调用。
    nonisolated func settingsBodyText() -> some View {
        font(SettingsTypography.rowSubtitle)
            .dynamicTypeSize(SettingsTypography.contentTypeRange)
    }

    nonisolated func settingsRowTitleText() -> some View {
        font(SettingsTypography.rowTitle)
            .dynamicTypeSize(SettingsTypography.contentTypeRange)
    }

    nonisolated func settingsPageTitleText() -> some View {
        font(SettingsTypography.pageTitle)
            .dynamicTypeSize(SettingsTypography.contentTypeRange)
    }

    nonisolated func settingsCardTitleText() -> some View {
        font(SettingsTypography.cardTitle)
            .dynamicTypeSize(SettingsTypography.contentTypeRange)
    }

    nonisolated func settingsCompactText(weight: Font.Weight = .regular) -> some View {
        font(SettingsTypography.compact.weight(weight))
            .dynamicTypeSize(SettingsTypography.contentTypeRange)
    }

    nonisolated func settingsBadgeText(weight: Font.Weight = .semibold) -> some View {
        font(SettingsTypography.badge.weight(weight))
            .dynamicTypeSize(SettingsTypography.contentTypeRange)
    }
}
