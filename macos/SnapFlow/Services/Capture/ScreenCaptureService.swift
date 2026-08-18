import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum ScreenCaptureError: LocalizedError {
    case noDisplay
    case captureFailed
    case invalidRegion
    case timeout

    var errorDescription: String? {
        switch self {
        case .noDisplay: L10n.string("未找到可用显示器")
        case .captureFailed: L10n.string("截图失败，请检查屏幕录制权限")
        case .invalidRegion: L10n.string("选区无效")
        case .timeout: L10n.string("截图超时，请重试")
        }
    }
}

/// 截图在非主线程执行，并带超时，避免霸屏后主线程假死。
final class ScreenCaptureService: ScreenCapturing, @unchecked Sendable {
    private let excludesCurrentApplication: Bool

    init(excludesCurrentApplication: Bool = false) {
        self.excludesCurrentApplication = excludesCurrentApplication
    }

    func capture(region: CaptureRegion) async throws -> CGImage {
        let rect = region.rectInScreenPoints
        guard rect.width >= 1, rect.height >= 1 else {
            throw ScreenCaptureError.invalidRegion
        }

        return try await withThrowingTaskGroup(of: CGImage.self) { group in
            group.addTask {
                try await self.captureWithScreenCaptureKit(region: region)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                throw ScreenCaptureError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func captureWithScreenCaptureKit(region: CaptureRegion) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == region.displayID })
                ?? content.displays.first
        else {
            throw ScreenCaptureError.noDisplay
        }

        let excludedWindows: [SCWindow]
        if excludesCurrentApplication, let bundleID = Bundle.main.bundleIdentifier {
            excludedWindows = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == bundleID
            }
        } else {
            excludedWindows = []
        }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        let config = SCStreamConfiguration()

        let scale = region.scaleFactor
        let pixelWidth = Int((region.rectInScreenPoints.width * scale).rounded())
        let pixelHeight = Int((region.rectInScreenPoints.height * scale).rounded())
        config.width = max(pixelWidth, 1)
        config.height = max(pixelHeight, 1)
        config.scalesToFit = false
        config.showsCursor = false
        config.captureResolution = .best

        let displayBounds = ScreenGeometry.displayBoundsInAppKitPoints(displayID: display.displayID)
        let local = ScreenGeometry.appKitGlobalRectToDisplayLocal(
            region.rectInScreenPoints,
            displayBounds: displayBounds
        )
        config.sourceRect = local

        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            NSLog("[SnapFlow] ScreenCaptureKit error: \(error)")
            throw ScreenCaptureError.captureFailed
        }
    }
}
