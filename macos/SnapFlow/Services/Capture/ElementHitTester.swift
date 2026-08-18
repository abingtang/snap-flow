import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// 界面元素检测（Snipaste Tab 切换窗口/元素）
/// 使用 Accessibility `AXUIElementCopyElementAtPosition`。
enum ElementHitTester {
    struct DetectedElement: Sendable, Equatable {
        let role: String
        let title: String
        /// AppKit 全局坐标（原点左下）
        let frame: CGRect
    }

    /// 在屏幕点（AppKit 全局）命中 UI 元素框；需辅助功能权限。
    static func hitTest(point appKitGlobal: CGPoint) -> DetectedElement? {
        guard AXIsProcessTrusted() else { return nil }

        // AX 使用 CG 坐标系（原点左上，相对主屏）
        let primaryH = ScreenGeometry.primaryHeight
        let cgX = Float(appKitGlobal.x)
        let cgY = Float(primaryH - appKitGlobal.y)

        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(system, cgX, cgY, &element)
        guard err == .success, let element else { return nil }

        // 向上找带 frame 的节点
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let cur = current else { break }
            if let frame = frame(of: cur), frame.width >= 4, frame.height >= 4 {
                let role = stringAttr(cur, kAXRoleAttribute as String) ?? ""
                let title = stringAttr(cur, kAXTitleAttribute as String)
                    ?? stringAttr(cur, kAXDescriptionAttribute as String)
                    ?? ""
                // 过滤过大几乎全屏的无意义节点
                if frame.width > 20, frame.height > 12 {
                    return DetectedElement(role: role, title: title, frame: frame)
                }
            }
            current = parent(of: cur)
        }
        return nil
    }

    /// 滚轮层级：从当前元素向上/向下找父/子（简化：只向上）
    static func parentFrame(of elementFrame: CGRect, at point: CGPoint) -> CGRect? {
        // 再 hit 一次后取父级 frame
        guard let hit = hitTest(point: point) else { return nil }
        // 若父级更大则返回
        let primaryH = ScreenGeometry.primaryHeight
        let cgX = Float(point.x)
        let cgY = Float(primaryH - point.y)
        let system = AXUIElementCreateSystemWide()
        var cur: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, cgX, cgY, &cur) == .success,
              let cur else { return hit.frame }
        if let p = parent(of: cur), let f = frame(of: p), f.width > hit.frame.width {
            return f
        }
        return hit.frame
    }

    // MARK: - AX helpers

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &ref) == .success,
              let ref else { return nil }
        return (ref as! AXUIElement)
    }

    private static func stringAttr(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
              let s = ref as? String else { return nil }
        return s
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef
        else { return nil }

        var pos = CGPoint.zero
        var size = CGSize.zero
        // AXValue
        if CFGetTypeID(posRef) == AXValueGetTypeID() {
            AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        } else { return nil }
        if CFGetTypeID(sizeRef) == AXValueGetTypeID() {
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        } else { return nil }

        // pos 是 CG 原点左上 → AppKit 左下
        let primaryH = ScreenGeometry.primaryHeight
        let appKitY = primaryH - pos.y - size.height
        return CGRect(x: pos.x, y: appKitY, width: size.width, height: size.height)
    }
}
