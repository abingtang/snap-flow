import AppKit
import CoreGraphics
import Foundation

/// Snipaste 风格窗口智能识别：列出可截取窗口，命中测试。
struct DetectedWindow: Sendable, Equatable {
    let windowID: CGWindowID
    let name: String
    let ownerName: String
    /// AppKit 全局坐标（原点左下）
    let frame: CGRect
}

enum WindowHitTester {
    /// 刷新当前屏幕上的窗口列表（前台优先）。
    static func onScreenWindows(excludingPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> [DetectedWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var result: [DetectedWindow] = []
        for info in infoList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID != excludingPID else { continue }
            guard let alpha = info[kCGWindowAlpha as String] as? CGFloat, alpha > 0.01 else { continue }
            guard let boundsAny = info[kCGWindowBounds as String] else { continue }
            let boundsDict: [String: CGFloat]
            if let d = boundsAny as? [String: CGFloat] {
                boundsDict = d
            } else if let d = boundsAny as? [String: NSNumber] {
                boundsDict = d.mapValues { CGFloat(truncating: $0) }
            } else if let d = boundsAny as? NSDictionary {
                var tmp: [String: CGFloat] = [:]
                for (k, v) in d {
                    guard let key = k as? String else { continue }
                    if let n = v as? NSNumber { tmp[key] = CGFloat(truncating: n) }
                    else if let f = v as? CGFloat { tmp[key] = f }
                }
                boundsDict = tmp
            } else {
                continue
            }

            // CG 窗口 bounds：原点左上
            let cgX = boundsDict["X"] ?? 0
            let cgY = boundsDict["Y"] ?? 0
            let w = boundsDict["Width"] ?? 0
            let h = boundsDict["Height"] ?? 0
            guard w >= 40, h >= 40 else { continue }

            let cgRect = CGRect(x: cgX, y: cgY, width: w, height: h)
            let appKitRect = cgGlobalRectToAppKit(cgRect)
            let windowID = CGWindowID((info[kCGWindowNumber as String] as? Int) ?? 0)
            let name = (info[kCGWindowName as String] as? String) ?? ""
            let owner = (info[kCGWindowOwnerName as String] as? String) ?? ""

            // 过滤菜单栏、Dock 等
            if owner == "Window Server" || owner == "Dock" { continue }

            result.append(
                DetectedWindow(
                    windowID: windowID,
                    name: name,
                    ownerName: owner,
                    frame: appKitRect
                )
            )
        }
        // CGWindowList 一般从前到后 = 上到下 z-order，保持顺序便于命中
        return result
    }

    /// 命中最上层窗口（列表前部优先）。
    static func hitTest(point: CGPoint, windows: [DetectedWindow]) -> DetectedWindow? {
        for w in windows {
            if w.frame.contains(point) {
                return w
            }
        }
        return nil
    }

    /// 点是否在某屏内时，返回相对该屏的窗口局部 rect（AppKit 屏内坐标）。
    static func localFrame(of window: DetectedWindow, on screen: NSScreen) -> CGRect? {
        let inter = window.frame.intersection(screen.frame)
        guard inter.width > 1, inter.height > 1 else { return nil }
        return CGRect(
            x: inter.minX - screen.frame.minX,
            y: inter.minY - screen.frame.minY,
            width: inter.width,
            height: inter.height
        )
    }

    // MARK: - Coord

    /// CG 全局（原点左上）→ AppKit 全局（原点左下，相对主屏）
    private static func cgGlobalRectToAppKit(_ cg: CGRect) -> CGRect {
        // 使用 NSScreen 联合包围盒更稳妥
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        // CG 的 Y 是从主屏顶部向下；AppKit 从主屏底部向上
        // 更通用：用主屏高度
        let primaryH = ScreenGeometry.primaryHeight
        // 多屏时 CG 坐标体系与主屏 top-left 对齐
        let appKitY = primaryH - cg.origin.y - cg.height
        return CGRect(x: cg.origin.x, y: appKitY, width: cg.width, height: cg.height)
    }
}
