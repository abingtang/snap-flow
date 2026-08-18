import AppKit
import SwiftUI

/// 首次启动引导：分页介绍能力 + 权限授权，回到 App 时自动刷新授权状态。
struct OnboardingView: View {
    let container: AppContainer
    let onDone: () -> Void

    @State private var page = 0
    @State private var screenGranted = false
    @State private var accessibilityGranted = false

    private let pageCount = 3

    var body: some View {
        VStack(spacing: 0) {
            pageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            footer
        }
        .padding(24)
        .frame(width: 520, height: 440)
        .foregroundStyle(AppTheme.textPrimary)
        .tint(AppTheme.accent)
        .background(AppTheme.windowBackground)
        .onAppear { refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    // MARK: - Pages

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case 0:
            featurePage(
                symbol: "camera.viewfinder",
                title: L10n.string("区域截图与贴图"),
                bullets: [
                    L10n.string("菜单栏图标或全局快捷键开始框选"),
                    L10n.string("悬停智能识窗，单击即选；拖拽自由框选"),
                    L10n.string("框选后工具栏：钉图 / 复制 / 保存 / 标注 / OCR"),
                    String(format: L10n.string("%@ 取消；更多快捷键可在偏好设置中修改"), container.settings.shortcutLabel(for: .captureCancel)),
                ]
            )
        case 1:
            featurePage(
                symbol: "text.viewfinder",
                title: L10n.string("识字、翻译与剪切板"),
                bullets: [
                    L10n.string("OCR：框选后直接识别，左图右文可编辑复制"),
                    L10n.string("划词翻译：选中文本一键对照多种服务结果"),
                    L10n.string("截图翻译：框选画面做图文对照译文"),
                    L10n.string("剪切板历史：搜索、固定、收藏与快捷键粘贴"),
                ]
            )
        default:
            permissionsPage
        }
    }

    private func featurePage(symbol: String, title: String, bullets: [String]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 48, height: 48)
                    .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("欢迎使用 SnapFlow"))
                        .font(.title2.bold())
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(bullets.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppTheme.accent)
                            .padding(.top, 2)
                        Text(line)
                            .font(.callout)
                            .foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 48, height: 48)
                    .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("权限授权"))
                        .font(.title2.bold())
                    Text(L10n.string("截图需要屏幕录制；划词翻译可选辅助功能"))
                        .font(.callout)
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }

            permissionCard(
                title: L10n.string("屏幕录制"),
                detail: L10n.string("区域截图、OCR、截图翻译必需。未授权时无法截取屏幕内容。"),
                granted: screenGranted,
                actionTitle: screenGranted ? L10n.string("已授权") : L10n.string("请求 / 打开设置")
            ) {
                _ = container.permissions.ensureScreenRecording()
                if !container.permissions.isScreenRecordingGranted() {
                    container.permissions.openSystemSettings(for: .screenRecording)
                }
                refreshPermissions()
            }

            permissionCard(
                title: L10n.string("辅助功能（可选）"),
                detail: L10n.string("仅划词翻译、模拟粘贴等需要；可稍后在通用设置中授权。"),
                granted: accessibilityGranted,
                actionTitle: accessibilityGranted ? L10n.string("已授权") : L10n.string("请求 / 打开设置")
            ) {
                _ = container.permissions.ensureAccessibility()
                if !container.permissions.isAccessibilityGranted() {
                    container.permissions.openSystemSettings(for: .accessibility)
                }
                refreshPermissions()
            }

            Text(L10n.string("从系统设置返回后，授权状态会自动刷新。"))
                .font(.caption)
                .foregroundStyle(AppTheme.textTertiary)

            Spacer(minLength: 0)
        }
    }

    private func permissionCard(
        title: String,
        detail: String,
        granted: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline)
                    Text(granted ? L10n.string("已授权") : L10n.string("需要授权"))
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(granted ? AppTheme.success : AppTheme.warning)
                        .background(
                            (granted ? AppTheme.success : AppTheme.warning).opacity(0.16),
                            in: Capsule()
                        )
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(actionTitle, action: action)
                .disabled(granted)
                .pointingHandOnHover(enabled: !granted)
        }
        .padding(12)
        .background(AppTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            pageDots

            Spacer(minLength: 8)

            if page > 0 {
                Button(L10n.string("上一步")) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        page -= 1
                    }
                }
                .keyboardShortcut(.cancelAction)
                .pointingHandOnHover()
            }

            if page < pageCount - 1 {
                Button(L10n.string("继续")) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        page += 1
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .pointingHandOnHover()
            } else {
                Button(L10n.string("开始使用")) {
                    container.settings.completeOnboarding()
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .pointingHandOnHover()
            }
        }
        .padding(.top, 16)
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<pageCount, id: \.self) { index in
                Circle()
                    .fill(index == page ? AppTheme.accent : AppTheme.border)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: L10n.string("第 %lld 页，共 %lld 页"), page + 1, pageCount))
    }

    // MARK: - Permissions

    private func refreshPermissions() {
        screenGranted = container.permissions.isScreenRecordingGranted()
        accessibilityGranted = container.permissions.isAccessibilityGranted()
    }
}
