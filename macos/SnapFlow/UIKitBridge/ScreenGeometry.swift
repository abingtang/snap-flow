import AppKit
import CoreGraphics
import Foundation

/// 统一 AppKit 点坐标、CG 全局坐标、显示器局部坐标与像素换算。
enum ScreenGeometry {
    /// 主屏高度（AppKit 点），用于 Y 轴翻转。
    static var primaryHeight: CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return screen.deviceDescription[key] as? CGDirectDisplayID ?? CGMainDisplayID()
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { Self.displayID(for: $0) == id }
    }

    static func screenContaining(point: NSPoint) -> NSScreen {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    static func displayBoundsInAppKitPoints(displayID: CGDirectDisplayID) -> CGRect {
        if let screen = screen(for: displayID) {
            return screen.frame
        }
        return CGDisplayBounds(displayID)
    }

    /// AppKit 全局 rect（原点左下）→ 相对某 display 的局部 rect（原点左上，供 ScreenCaptureKit sourceRect）。
    static func appKitGlobalRectToDisplayLocal(_ rect: CGRect, displayBounds: CGRect) -> CGRect {
        let x = rect.minX - displayBounds.minX
        // AppKit y 从下往上；display 局部 y 从上往下
        let yFromTop = displayBounds.maxY - rect.maxY
        return CGRect(x: x, y: yFromTop, width: rect.width, height: rect.height)
    }

    /// AppKit 全局 rect → CG 全局 rect（原点左上）。
    static func appKitGlobalRectToCGGlobal(_ rect: CGRect) -> CGRect {
        let height = primaryHeight
        let flippedY = height - rect.maxY
        return CGRect(x: rect.minX, y: flippedY, width: rect.width, height: rect.height)
    }

    /// 找出 AX / Quartz rect 所属的物理显示器。
    static func displayIndex(forAXRect rect: CGRect, displayBounds: [CGRect]) -> Int? {
        let probe = CGRect(
            x: rect.width == 0 ? rect.minX - 0.5 : rect.minX,
            y: rect.height == 0 ? rect.minY - 0.5 : rect.minY,
            width: max(rect.width, 1),
            height: max(rect.height, 1)
        )
        let candidates = displayBounds.enumerated()
            .compactMap { index, bounds -> (Int, CGFloat)? in
                let intersection = bounds.intersection(probe)
                guard !intersection.isNull else { return nil }
                let area = intersection.width * intersection.height
                return area > 0 ? (index, area) : nil
            }
        guard let best = candidates.max(by: { $0.1 < $1.1 }) else { return nil }
        guard !candidates.contains(where: {
            $0.0 != best.0 && abs($0.1 - best.1) < 0.001
        }) else { return nil }
        return best.0
    }

    /// 按同一块物理显示器，把 AX / Quartz 全局 rect 映射到 AppKit 全局 rect。
    static func axGlobalRectToAppKit(
        _ axRect: CGRect,
        displayBounds: CGRect,
        appKitFrame: CGRect
    ) -> CGRect {
        guard displayBounds.width > 0, displayBounds.height > 0 else { return .zero }
        let scaleX = appKitFrame.width / displayBounds.width
        let scaleY = appKitFrame.height / displayBounds.height
        return CGRect(
            x: appKitFrame.minX + (axRect.minX - displayBounds.minX) * scaleX,
            y: appKitFrame.maxY - (axRect.maxY - displayBounds.minY) * scaleY,
            width: axRect.width * scaleX,
            height: axRect.height * scaleY
        )
    }

    /// Vision 归一化 box（原点左下，0–1）→ 图像像素 box（原点左上）。
    static func visionNormalizedBoxToPixelRect(_ box: CGRect, imageWidth: Int, imageHeight: Int) -> CGRect {
        let w = CGFloat(imageWidth)
        let h = CGFloat(imageHeight)
        let x = box.origin.x * w
        let y = (1 - box.origin.y - box.height) * h
        return CGRect(x: x, y: y, width: box.width * w, height: box.height * h)
    }

    /// 将图像像素 box 映射到屏幕全局点坐标（AppKit），用于 Overlay 定位。
    static func imagePixelRectToAppKitGlobal(
        _ pixelRect: CGRect,
        selection: CaptureRegion
    ) -> CGRect {
        let scale = selection.scaleFactor
        let pointRect = CGRect(
            x: selection.rectInScreenPoints.minX + pixelRect.minX / scale,
            y: selection.rectInScreenPoints.maxY - (pixelRect.minY + pixelRect.height) / scale,
            width: pixelRect.width / scale,
            height: pixelRect.height / scale
        )
        return pointRect
    }
}
