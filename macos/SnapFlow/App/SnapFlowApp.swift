import AppKit
import SwiftUI

@main
struct SnapFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 不在此放 SettingsView，避免与 PanelPresenter 自建窗双开。
        // 系统 ⌘, 仍可能打开 Settings 场景，用 Redirect 立刻关掉并打开唯一设置窗。
        Settings {
            SettingsSceneRedirect {
                appDelegate.container.panelPresenter.showSettings()
            }
        }
    }
}

/// 占位：系统 Settings 窗出现时转去我们的设置窗并关闭自己。
private struct SettingsSceneRedirect: View {
    let openAppSettings: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
            .onAppear {
                openAppSettings()
                DispatchQueue.main.async {
                    // 关掉系统拉起的 Settings 宿主窗，只留自建「SnapFlow 设置」
                    for window in NSApp.windows {
                        let id = window.identifier?.rawValue ?? ""
                        if id == "snapflow.settings" { continue }
                        // SwiftUI Settings 窗通常可关闭且不是 status / 贴图
                        if window.isVisible,
                           window.styleMask.contains(.titled),
                           window.title != L10n.string("SnapFlow 设置"),
                           !(window is NSPanel)
                        {
                            // 更稳妥：只关标题像设置、且 content 几乎为空的窗
                            if window.frame.width < 400 || window.title.isEmpty || window.title == "Settings" {
                                window.close()
                            }
                        }
                    }
                    // 再兜底：所有非 snapflow.settings 且刚出现的小窗
                    for window in NSApp.windows where window.isVisible {
                        if window.identifier?.rawValue == "snapflow.settings" { continue }
                        if window.contentView is NSHostingView<SettingsSceneRedirect>
                            || String(describing: type(of: window)).contains("Settings")
                        {
                            window.orderOut(nil)
                        }
                    }
                }
            }
    }
}
