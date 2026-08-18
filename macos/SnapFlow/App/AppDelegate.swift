import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let container = AppContainer()

    private var statusItem: NSStatusItem?
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 主线程看门狗：截图霸屏卡死时约 2.5s 强制退出，避免整机无法操作
        MainThreadWatchdog.shared.install()

        let controller = MenuBarController(container: container)
        menuBarController = controller
        statusItem = controller.installStatusItem()

        do {
            _ = try container.settings.synchronizeLaunchAtLogin()
        } catch {
            container.settings.refreshLaunchAtLogin()
            FeedbackCenter.shared.post(
                L10n.string("settings.general.launch_at_login_error"),
                level: .error
            )
        }

        container.hotKeyManager.onAction = { [weak self] action in
            MainThreadWatchdog.shared.noteMainAlive()
            self?.handle(action)
        }
        container.hotKeyManager.registerDefaults()
        // 偏好设置录制快捷键时：暂停 Carbon 全局热键，结束后恢复
        HotkeyRecordingStore.shared.onRecordingActiveChange = { [hotKeyManager = container.hotKeyManager] active in
            if active {
                hotKeyManager.suspend()
            } else {
                hotKeyManager.resume()
            }
        }
        container.pasteboardMonitor.start()

        if !container.settings.hasCompletedOnboarding {
            container.panelPresenter.showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出前强制拆掉选区遮罩，避免进程被调试器挂起时残留霸屏
        MainThreadWatchdog.shared.endCaptureSession()
        container.workflows.cancelRecording()
        RegionSelectorController.forceCancel()
        container.hotKeyManager.unregisterAll()
        container.pasteboardMonitor.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func handle(_ action: AppAction) {
        switch action {
        case .captureScreenshot:
            Task { await container.workflows.runRegionScreenshot(delaySeconds: 0) }
        case .captureScreenshotDelay3:
            Task { await container.workflows.runRegionScreenshot(delaySeconds: 3) }
        case .pasteToScreen:
            container.workflows.pasteClipboardToScreen()
        case .togglePinnedVisibility:
            container.panelPresenter.togglePinnedVisibility()
        case .togglePinClickThrough:
            container.panelPresenter.toggleClickThroughUnderCursor()
        case .captureOCR:
            Task { await container.workflows.runCaptureOCR() }
        case .captureImageOCR:
            Task { await container.workflows.runCaptureImageOCR() }
        case .captureTranslate:
            Task { await container.workflows.runCaptureTranslate() }
        case .captureImageTranslate:
            Task { await container.workflows.runCaptureImageTranslate() }
        case .selectionTranslate:
            Task { await container.workflows.runSelectionTranslate() }
        case .openClipboardHistory:
            container.panelPresenter.showClipboardHistory()
        case .openSettings:
            container.panelPresenter.showSettings()
        case .quit:
            NSApp.terminate(nil)
        }
    }
}
