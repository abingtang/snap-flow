import AppKit
import Foundation
import UserNotifications

/// 全局反馈等级；成功结果由具体业务界面自行表达，不通过全局提示展示。
/// - `progress`：延时截图倒计时，屏幕中央卡片跳动
/// - 其它等级：macOS 系统通知；未授权时回退到菜单栏 HUD
enum FeedbackLevel: Int, Equatable, Sendable {
    case progress
    case info
    case warning
    case error

    var defaultDuration: TimeInterval {
        switch self {
        case .progress:
            // 略大于 1s 节拍，防止两次 tick 之间闪断
            return 1.15
        case .info:
            return 1.8
        case .warning:
            return 3
        case .error:
            return 4.5
        }
    }

    var symbolName: String {
        switch self {
        case .progress:
            return "arrow.triangle.2.circlepath"
        case .info:
            return "info.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.octagon.fill"
        }
    }

    /// 系统通知副标题（进度不走系统通知）
    var systemNotificationSubtitle: String {
        switch self {
        case .progress:
            return ""
        case .info:
            return L10n.string("提示")
        case .warning:
            return L10n.string("注意")
        case .error:
            return L10n.string("错误")
        }
    }
}

struct FeedbackMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    let message: String
    let level: FeedbackLevel
    let duration: TimeInterval

    init(message: String, level: FeedbackLevel, duration: TimeInterval) {
        self.id = UUID()
        self.message = message
        self.level = level
        self.duration = duration
    }
}

/// 统一管理全局反馈：倒计时用中央卡片，其余用系统通知。
@MainActor
final class FeedbackCenter {
    static let shared = FeedbackCenter()

    private var dismissalTask: Task<Void, Never>?
    private(set) var currentMessage: FeedbackMessage?

    private init() {}

    func attach(button: NSStatusBarButton) {
        MenuBarStatusHUD.attach(button: button)
        // 尽早触发授权，避免首条非进度提示时再弹系统对话框
        Task { _ = await Self.ensureNotificationAuthorization() }
    }

    func post(
        _ message: String,
        level: FeedbackLevel = .info,
        duration: TimeInterval? = nil
    ) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let feedback = FeedbackMessage(
            message: trimmed,
            level: level,
            duration: max(0.1, duration ?? level.defaultDuration)
        )

        // 倒计时：屏幕中央卡片，按数字切换跳动
        if level == .progress {
            presentCountdown(feedback)
            return
        }

        // 非进度：关掉倒计时/回退 HUD，再发系统通知
        dismissLocalOverlay()
        Task { @MainActor in
            let allowed = await Self.ensureNotificationAuthorization()
            if allowed {
                await Self.deliverSystemNotification(feedback)
            } else {
                // 用户拒绝或系统不可用时回退菜单栏，避免完全无反馈
                presentMenuBarHUD(feedback)
            }
        }
    }

    func dismiss() {
        dismissLocalOverlay()
    }

    // MARK: - Countdown center card

    private func presentCountdown(_ feedback: FeedbackMessage) {
        dismissalTask?.cancel()
        // 倒计时期间关掉可能残留的菜单栏回退条
        MenuBarStatusHUD.close()
        currentMessage = feedback
        CountdownCenterHUD.show(feedback)

        let messageID = feedback.id
        dismissalTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(feedback.duration))
            } catch {
                return
            }
            guard let self, self.currentMessage?.id == messageID else { return }
            self.dismissLocalOverlay()
        }
    }

    // MARK: - Menu bar HUD（系统通知不可用时的回退）

    private func presentMenuBarHUD(_ feedback: FeedbackMessage) {
        dismissalTask?.cancel()
        CountdownCenterHUD.close()
        currentMessage = feedback
        MenuBarStatusHUD.show(feedback)

        let messageID = feedback.id
        dismissalTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(feedback.duration))
            } catch {
                return
            }
            guard let self, self.currentMessage?.id == messageID else { return }
            self.dismissLocalOverlay()
        }
    }

    private func dismissLocalOverlay() {
        dismissalTask?.cancel()
        dismissalTask = nil
        currentMessage = nil
        MenuBarStatusHUD.close()
        CountdownCenterHUD.close()
    }

    // MARK: - System notification

    private static func ensureNotificationAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                return false
            }
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    private static func deliverSystemNotification(_ feedback: FeedbackMessage) async {
        let content = UNMutableNotificationContent()
        content.title = "SnapFlow"
        let subtitle = feedback.level.systemNotificationSubtitle
        if !subtitle.isEmpty {
            content.subtitle = subtitle
        }
        content.body = feedback.message
        // 提示类静音；注意/错误带系统默认提示音
        switch feedback.level {
        case .warning, .error:
            content.sound = .default
        case .info, .progress:
            content.sound = nil
        }

        let request = UNNotificationRequest(
            identifier: "snapflow.feedback.\(feedback.id.uuidString)",
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            // 投递失败时在主线程回退菜单栏
            await MainActor.run {
                FeedbackCenter.shared.presentMenuBarHUD(feedback)
            }
        }
    }
}
