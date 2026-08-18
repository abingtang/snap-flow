import AppKit

/// 浮窗弹出位置（剪切板历史 / 划词翻译共用）。
enum ClipboardPopupPosition: String, CaseIterable, Identifiable {
    case cursor
    case statusItem
    case window
    case center
    case lastPosition

    var id: Self { self }

    var title: String {
        switch self {
        case .cursor: L10n.string("光标位置")
        case .statusItem: L10n.string("菜单栏图标下方")
        case .window: L10n.string("前台窗口中央")
        case .center: L10n.string("屏幕中央")
        case .lastPosition: L10n.string("上次位置")
        }
    }

    /// 解析「显示器」设置：0 = 主屏，1… = `NSScreen.screens` 下标 + 1。
    static func resolvedScreen(index: Int) -> NSScreen? {
        if index == 0 || index > NSScreen.screens.count {
            NSScreen.main
        } else {
            NSScreen.screens[index - 1]
        }
    }

    @MainActor
    func origin(
        size: NSSize,
        statusBarButton: NSStatusBarButton?,
        popupScreen: Int,
        lastPosition: NSPoint
    ) -> NSPoint {
        switch self {
        case .center:
            if let frame = Self.resolvedScreen(index: popupScreen)?.visibleFrame {
                return Self.centered(size: size, in: frame).origin
            }
        case .window:
            if let frame = NSWorkspace.shared.frontmostApplication?.clipboardWindowFrame {
                return Self.centered(size: size, in: frame).origin
            }
        case .statusItem:
            if let statusBarButton {
                let rectInWindow = statusBarButton.convert(statusBarButton.bounds, to: nil)
                if let screenRect = statusBarButton.window?.convertToScreen(rectInWindow) {
                    let point = NSPoint(x: screenRect.minX, y: screenRect.minY - size.height)
                    return Self.constrained(
                        point,
                        size: size,
                        visibleFrame: statusBarButton.window?.screen?.visibleFrame
                    )
                }
            }
        case .lastPosition:
            if let frame = Self.resolvedScreen(index: popupScreen)?.visibleFrame {
                return Self.lastPositionOrigin(
                    size: size,
                    visibleFrame: frame,
                    relativePosition: lastPosition
                )
            }
        case .cursor:
            break
        }

        let mouse = NSEvent.mouseLocation
        let point = NSPoint(x: mouse.x, y: mouse.y - size.height)
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        return Self.constrained(point, size: size, visibleFrame: screen?.visibleFrame)
    }

    static func constrained(
        _ origin: NSPoint,
        size: NSSize,
        visibleFrame: NSRect?
    ) -> NSPoint {
        guard let frame = visibleFrame else { return origin }
        return NSPoint(
            x: min(max(origin.x, frame.minX), frame.maxX - size.width),
            y: min(max(origin.y, frame.minY), frame.maxY - size.height)
        )
    }

    static func lastPositionOrigin(
        size: NSSize,
        visibleFrame: NSRect,
        relativePosition: NSPoint
    ) -> NSPoint {
        let anchorX = visibleFrame.minX + visibleFrame.width * relativePosition.x
        let anchorY = visibleFrame.minY + visibleFrame.height * relativePosition.y
        return NSPoint(x: anchorX - size.width / 2, y: anchorY - size.height)
    }

    private static func centered(size: NSSize, in frame: NSRect) -> NSRect {
        NSRect(
            x: (frame.width - size.width) / 2 + frame.minX + 1,
            y: (frame.height - size.height) / 2 + frame.minY + 1,
            width: size.width,
            height: size.height
        )
    }
}

extension NSRunningApplication {
    /// 前台 App 首个可见窗口 frame（AppKit 坐标，原点左下）。
    var clipboardWindowFrame: NSRect? {
        let options: CGWindowListOption = [.excludeDesktopElements, .optionOnScreenOnly]
        guard let windowInfo = CGWindowListCopyWindowInfo(options, CGWindowID(0)) as? [[String: Any]]
        else { return nil }

        for info in windowInfo {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? UInt32,
                  ownerPID == processIdentifier,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let screen = NSScreen.screens.first,
                  let x = bounds["X"] as? Double,
                  let y = bounds["Y"] as? Double,
                  let width = bounds["Width"] as? Double,
                  let height = bounds["Height"] as? Double
            else { continue }

            return NSRect(
                x: x,
                y: screen.frame.height - y - height,
                width: width,
                height: height
            )
        }
        return nil
    }
}
