import AppKit
import SwiftUI

// MARK: - Menu bar fallback chip（系统通知不可用时）

/// 菜单栏锚点就地状态：贴在状态栏图标下方，不抢焦点。
@MainActor
enum MenuBarStatusHUD {
    private static var panel: NSPanel?
    private static weak var anchorButton: NSStatusBarButton?

    static func attach(button: NSStatusBarButton) {
        anchorButton = button
    }

    static func show(_ feedback: FeedbackMessage) {
        close()

        let hosting = NSHostingView(
            rootView: MenuBarStatusChip(feedback: feedback)
                .fixedSize()
        )
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)

        let p = NSPanel(
            contentRect: hosting.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = hosting
        p.setContentSize(hosting.fittingSize)

        position(panel: p)
        p.orderFront(nil)
        panel = p
    }

    static func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    private static func position(panel: NSPanel) {
        var frame = panel.frame
        if let button = anchorButton, let win = button.window {
            let buttonRect = button.convert(button.bounds, to: nil)
            let screenRect = win.convertToScreen(buttonRect)
            frame.origin.x = screenRect.midX - frame.width / 2
            // 菜单栏下方
            frame.origin.y = screenRect.minY - frame.height - 6
        } else if let screen = NSScreen.main {
            let v = screen.visibleFrame
            frame.origin.x = v.midX - frame.width / 2
            frame.origin.y = v.maxY - frame.height - 8
        }
        // 夹紧
        if let screen = NSScreen.screens.first(where: {
            NSMouseInRect(
                NSPoint(x: frame.midX, y: frame.midY),
                $0.frame,
                false
            )
        }) ?? NSScreen.main {
            let v = screen.visibleFrame
            frame.origin.x = min(max(frame.origin.x, v.minX + 4), v.maxX - frame.width - 4)
            frame.origin.y = min(max(frame.origin.y, v.minY + 4), v.maxY - frame.height - 4)
        }
        panel.setFrame(frame, display: true)
    }
}

// MARK: - Center countdown card（延时截图）

/// 屏幕中央倒计时卡片：数字切换时弹簧缩放跳动，不抢焦点。
@MainActor
enum CountdownCenterHUD {
    private static var panel: NSPanel?
    private static var model: CountdownDisplayModel?

    static func show(_ feedback: FeedbackMessage) {
        if let model {
            model.update(message: feedback.message)
            if let panel {
                center(panel: panel)
                panel.orderFront(nil)
            }
            return
        }

        let model = CountdownDisplayModel()
        model.update(message: feedback.message)
        self.model = model

        let hosting = NSHostingView(
            rootView: CountdownCardView(model: model)
                .fixedSize()
        )
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)

        let p = NSPanel(
            contentRect: hosting.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.ignoresMouseEvents = true
        p.contentView = hosting
        p.setContentSize(hosting.fittingSize)

        center(panel: p)
        p.orderFront(nil)
        panel = p
    }

    static func close() {
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }

    private static func center(panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
        guard let screen else { return }
        let v = screen.visibleFrame
        var frame = panel.frame
        frame.origin.x = v.midX - frame.width / 2
        frame.origin.y = v.midY - frame.height / 2
        panel.setFrame(frame, display: true)
    }
}

@MainActor
private final class CountdownDisplayModel: ObservableObject {
    @Published private(set) var displayText: String = ""
    /// 每次跳动递增，驱动缩放动画
    @Published private(set) var beat: Int = 0

    func update(message: String) {
        displayText = Self.digitText(from: message)
        beat += 1
    }

    private static func digitText(from message: String) -> String {
        let digits = message.prefix { $0.isNumber }
        if !digits.isEmpty {
            return String(digits)
        }
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct CountdownCardView: View {
    @ObservedObject var model: CountdownDisplayModel
    @State private var scale: CGFloat = 0.55
    @State private var opacity: Double = 0

    var body: some View {
        Text(model.displayText)
            .font(.system(size: 92, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(AppTheme.accent)
            .frame(minWidth: 148, minHeight: 148)
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(AppTheme.surface.opacity(0.94))
                    .shadow(color: .black.opacity(0.28), radius: 32, y: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(AppTheme.border.opacity(0.55), lineWidth: 1)
            )
            .scaleEffect(scale)
            .opacity(opacity)
            .padding(36)
            .onAppear {
                // 首帧：从缩小态弹入
                scale = 0.55
                opacity = 0
                withAnimation(.spring(response: 0.34, dampingFraction: 0.56)) {
                    scale = 1
                    opacity = 1
                }
            }
            .onChange(of: model.beat) { old, new in
                // 首拍已由 onAppear 处理，后续数字切换再跳动
                guard new > 1, new != old else { return }
                withAnimation(.spring(response: 0.16, dampingFraction: 0.42)) {
                    scale = 1.22
                }
                withAnimation(.spring(response: 0.36, dampingFraction: 0.58).delay(0.05)) {
                    scale = 1
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(format: L10n.string("倒计时 %@"), model.displayText))
    }
}

// MARK: - Shared tint

private struct MenuBarStatusChip: View {
    let feedback: FeedbackMessage

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: feedback.level.symbolName)
                .foregroundStyle(feedback.level.tint)

            Text(feedback.message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(AppTheme.panelBackground)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(AppTheme.border, lineWidth: 1)
            )
            .padding(2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(feedback.message)
    }
}

private extension FeedbackLevel {
    var tint: Color {
        switch self {
        case .progress:
            return AppTheme.accent
        case .info:
            return AppTheme.info
        case .warning:
            return AppTheme.warning
        case .error:
            return AppTheme.danger
        }
    }
}
