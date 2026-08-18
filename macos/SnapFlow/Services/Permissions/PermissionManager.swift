import AppKit
import ApplicationServices
import AVFoundation
import Foundation
import ScreenCaptureKit

enum AppPermission: String, Sendable {
    case screenRecording
    case accessibility
    case microphone

    var title: String {
        switch self {
        case .screenRecording: L10n.string("屏幕录制")
        case .accessibility: L10n.string("辅助功能")
        case .microphone: L10n.string("麦克风")
        }
    }

    var message: String {
        switch self {
        case .screenRecording:
            L10n.string("SnapFlow 需要屏幕录制权限以进行区域截图、OCR 与屏幕翻译。")
        case .accessibility:
            L10n.string("SnapFlow 需要辅助功能权限以读取划选文本（划词翻译），并将剪切板历史自动粘贴回原应用。")
        case .microphone:
            L10n.string("SnapFlow 需要麦克风权限，以便在屏幕录制时采集你的旁白或讲解声音。拒绝后仍可录制视频与系统声音。")
        }
    }
}

@MainActor
final class PermissionManager {
    func isScreenRecordingGranted() -> Bool {
        // CGPreflight 在部分系统上不完全可靠；结合 SCShareableContent 探测。
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        return false
    }

    func isAccessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// 同步、不弹窗的麦克风权限检查。
    func isMicrophoneGranted() -> Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    /// 用户已明确拒绝麦克风；系统不会再次弹窗，需引导到系统设置。
    func isMicrophoneDenied() -> Bool {
        AVAudioApplication.shared.recordPermission == .denied
    }

    /// 尝试请求屏幕录制；若已拒绝则返回 false。
    @discardableResult
    func ensureScreenRecording() -> Bool {
        if isScreenRecordingGranted() { return true }
        // 触发系统对话框（首次）
        let granted = CGRequestScreenCaptureAccess()
        return granted
    }

    /// 辅助功能无法弹系统对话框，只能引导用户去设置。
    @discardableResult
    func ensureAccessibility() -> Bool {
        if isAccessibilityGranted() { return true }
        // 使用字符串键避免 Swift 6 对 kAXTrustedCheckOptionPrompt 全局可变状态的并发诊断
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// 懒请求麦克风权限；仅在用户首次开启麦克风时调用，默认关闭时不弹窗。
    func requestMicrophonePermission() async -> Bool {
        if isMicrophoneGranted() { return true }
        if isMicrophoneDenied() { return false }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func openSystemSettings(for permission: AppPermission) {
        let urlString: String
        switch permission {
        case .screenRecording:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .microphone:
            // macOS 13+ 隐私与安全性面板；旧路径作回退。
            urlString = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// 探测 ScreenCaptureKit 是否真正可用（权限变更后更准确）。
    func probeScreenCaptureKit() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }
}
