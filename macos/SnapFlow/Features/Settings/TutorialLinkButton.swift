import AppKit
import SwiftUI

/// 配置页统一的官方申请教程入口。
struct TutorialLinkButton: View {
    let destination: URL
    @State private var isHovered = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(destination)
        } label: {
            Label(L10n.string("查看申请教程"), systemImage: "arrow.up.right.square")
                .settingsCompactText(weight: .semibold)
                .foregroundStyle(AppTheme.onAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .buttonStyle(TutorialLinkButtonStyle(isHovered: isHovered))
        .onHover { hovering in
            isHovered = hovering
            updateHandCursor(hovering)
        }
        .help(L10n.string("打开官方申请教程"))
        .accessibilityHint(L10n.string("打开官方申请教程"))
    }
}

private struct TutorialLinkButtonStyle: ButtonStyle {
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovered ? AppTheme.accent.opacity(0.86) : AppTheme.accent)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(AppTheme.onAccent.opacity(isHovered ? 0.34 : 0.18), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
