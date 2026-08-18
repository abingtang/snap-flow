import AppKit
import SwiftUI

/// 全局语义主题色。修改此处即可同步浅色与深色模式。
///
/// 浅色：冷中性灰底 + 白卡片，减少旧版偏黄「纸质」感，层次与系统设置更接近。
/// 深色：保持原有石墨灰体系，不在此调整。
enum AppTheme {
    /// UserDefaults 键：与 `SettingsStore.useSystemAccentColor` 同步。
    static let useSystemAccentDefaultsKey = "appearance.useSystemAccentColor"

    // 页面底 → 侧栏/面板 → 卡片 → 内嵌区 → 悬停（浅色逐级拉开对比）
    static let windowBackground = color(light: 0xF2F3F5, dark: 0x15171A)
    static let panelBackground = color(light: 0xF7F8FA, dark: 0x202327)
    static let surface = color(light: 0xFFFFFF, dark: 0x292C31)
    static let surfaceMuted = color(light: 0xEEF0F3, dark: 0x31353A)
    static let surfaceHover = color(light: 0xE5E7EC, dark: 0x3B4046)

    // 正文接近系统 label；次级/三级保证白底上可读
    static let textPrimary = color(light: 0x1A1C1F, dark: 0xF4F1EA)
    static let textSecondary = color(light: 0x5C6370, dark: 0xB9B5AC)
    static let textTertiary = color(light: 0x8B919A, dark: 0x858179)

    static let border = color(light: 0xD5D8DE, dark: 0x454950)
    static let separator = color(light: 0xE4E6EB, dark: 0x383C42)

    /// 品牌强调色（关闭「跟随系统」时使用）；浅色略加深以保证白底对比
    static let brandAccent = color(light: 0x4F63E0, dark: 0x8191FF)
    static let brandAccentSoft = color(light: 0xE9ECFB, dark: 0x303850)

    /// 解析后的强调色：可选跟随系统 Accent Color。
    static var accent: Color {
        usesSystemAccent ? Color.accentColor : brandAccent
    }

    static var accentSoft: Color {
        usesSystemAccent ? Color.accentColor.opacity(0.14) : brandAccentSoft
    }

    static let onAccent = Color.white

    static var usesSystemAccent: Bool {
        UserDefaults.standard.bool(forKey: useSystemAccentDefaultsKey)
    }

    static let success = color(light: 0x1F8A52, dark: 0x55C68A)
    static let warning = color(light: 0xC47A12, dark: 0xF0A34A)
    static let danger = color(light: 0xD03D3D, dark: 0xFF7373)
    static let info = color(light: 0x1A8A8A, dark: 0x55C7C7)

    static let nsTextPrimary = nsColor(light: 0x1A1C1F, dark: 0xF4F1EA)
    static let nsTextSecondary = nsColor(light: 0x5C6370, dark: 0xB9B5AC)
    static let nsTextTertiary = nsColor(light: 0x8B919A, dark: 0x858179)
    static let nsWindowBackground = nsColor(light: 0xF2F3F5, dark: 0x15171A)
    static let nsPanelBackground = nsColor(light: 0xF7F8FA, dark: 0x202327)
    static let nsSurface = nsColor(light: 0xFFFFFF, dark: 0x292C31)
    static let nsSurfaceMuted = nsColor(light: 0xEEF0F3, dark: 0x31353A)
    static let nsBorder = nsColor(light: 0xD5D8DE, dark: 0x454950)
    static let nsSeparator = nsColor(light: 0xE4E6EB, dark: 0x383C42)
    static let nsSuccess = nsColor(light: 0x1F8A52, dark: 0x55C68A)
    static let nsWarning = nsColor(light: 0xC47A12, dark: 0xF0A34A)
    static let nsDanger = nsColor(light: 0xD03D3D, dark: 0xFF7373)
    static let nsAccent = NSColor(name: nil) { appearance in
        if UserDefaults.standard.bool(forKey: useSystemAccentDefaultsKey) {
            return .controlAccentColor
        }
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return rgb(isDark ? 0x8191FF : 0x4F63E0)
    }

    /// 截图画布上的工具条固定保持深底，避免被截图内容吞没；明暗模式只微调层次。
    static let nsCaptureBarBackground = nsColor(light: 0x34363B, dark: 0x202226)
    static let nsCaptureText = NSColor.white.withAlphaComponent(0.92)
    static let nsCaptureBorder = NSColor.white.withAlphaComponent(0.08)
    static let nsCaptureSeparator = NSColor.white.withAlphaComponent(0.20)
    static let nsCaptureHover = NSColor.white.withAlphaComponent(0.16)
    static let nsCaptureHoverStrong = NSColor.white.withAlphaComponent(0.18)
    static let nsCaptureOutline = NSColor.white.withAlphaComponent(0.25)
    static let nsCapturePressed = NSColor.white.withAlphaComponent(0.30)
    static let nsCaptureField = NSColor.white.withAlphaComponent(0.08)

    private static func color(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: nsColor(light: light, dark: dark))
    }

    private static func nsColor(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        }
    }

    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
