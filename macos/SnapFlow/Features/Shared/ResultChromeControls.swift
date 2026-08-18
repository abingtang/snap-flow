import AppKit
import SwiftUI

// MARK: - 结果窗共用 chrome（OCR / 截图翻译 / 划词等）

/// 结果浮层统一壳：圆角、边框、面板底、前景与 tint（强调色走 Environment）。
struct ResultPanelChromeModifier: ViewModifier {
    var cornerRadius: CGFloat = 12
    @Environment(\.snapFlowAccent) private var accent

    func body(content: Content) -> some View {
        content
            .background(AppTheme.panelBackground)
            .foregroundStyle(AppTheme.textPrimary)
            .tint(accent)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
    }
}

extension View {
    /// OCR / 截图翻译结果窗统一外壳
    func resultPanelChrome(cornerRadius: CGFloat = 12) -> some View {
        modifier(ResultPanelChromeModifier(cornerRadius: cornerRadius))
    }
}

/// 顶栏 / 底栏图标按钮（hover / pressed / 手型 / accessibility）
struct OCRChromeIconButton: View {
    let symbol: String
    let tooltip: String
    var isAccent: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    @Environment(\.snapFlowAccent) private var accent
    @State private var isHovered = false

    init(
        symbol: String,
        tooltip: String,
        isAccent: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.symbol = symbol
        self.tooltip = tooltip
        self.isAccent = isAccent
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(
            OCRPressableChromeStyle(
                isHovered: isHovered && !isDisabled,
                idleFill: isAccent ? accent.opacity(0.15) : AppTheme.textPrimary.opacity(0.06),
                hoverFill: isAccent ? accent.opacity(0.22) : AppTheme.textPrimary.opacity(0.12),
                pressedFill: isAccent ? accent.opacity(0.28) : AppTheme.textPrimary.opacity(0.16),
                idleForeground: isAccent ? accent : AppTheme.textSecondary,
                hoverForeground: isAccent ? accent : AppTheme.textPrimary
            )
        )
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1)
        .onHover { hovering in
            isHovered = hovering
            if !isDisabled { updateHandCursor(hovering) }
        }
        .help(tooltip)
        .accessibilityLabel(tooltip)
        .animation(.easeOut(duration: 0.1), value: isHovered)
    }
}

/// 带文字的轻量按钮（如图下「隐藏识别框」）
struct OCRChromeTextButton: View {
    let title: String
    let symbol: String
    let tooltip: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(
            OCRPressableChromeStyle(
                isHovered: isHovered,
                idleFill: .clear,
                hoverFill: AppTheme.textPrimary.opacity(0.10),
                pressedFill: AppTheme.textPrimary.opacity(0.14),
                idleForeground: AppTheme.textSecondary,
                hoverForeground: AppTheme.textPrimary
            )
        )
        .onHover { hovering in
            isHovered = hovering
            updateHandCursor(hovering)
        }
        .help(tooltip)
        .accessibilityLabel(tooltip)
        .animation(.easeOut(duration: 0.1), value: isHovered)
    }
}

/// 根据 hover + pressed 渲染背景/前景
struct OCRPressableChromeStyle: ButtonStyle {
    var isHovered: Bool
    var idleFill: Color
    var hoverFill: Color
    var pressedFill: Color
    var idleForeground: Color
    var hoverForeground: Color

    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = {
            if configuration.isPressed { return pressedFill }
            if isHovered { return hoverFill }
            return idleFill
        }()
        let fg = (isHovered || configuration.isPressed) ? hoverForeground : idleForeground

        return configuration.label
            .foregroundStyle(fg)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fill)
            )
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// 结果窗顶栏状态文案（识别中提示等）
struct ResultChromeStatusHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(AppTheme.textSecondary)
            .lineLimit(1)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}
