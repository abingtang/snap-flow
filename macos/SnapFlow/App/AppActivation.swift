import AppKit
import CoreGraphics

/// 应用激活策略：激活后恢复「受保护窗」（偏好设置）的全局叠放，避免被抬到最前。
///
/// 根因：只要 SnapFlow 成为 active app，系统常会把它的普通窗口抬到其它 App 之上；
/// 选区结束时 key 还会回落到偏好设置，再次 `orderFront`。
/// 做法：
/// 1. 激活前记录设置窗上方是谁；激活后 `order(.below:)` 塞回原叠放。
/// 2. 截图/录制会话内禁止设置窗自动成为 key（用户点进设置窗则恢复）。
@MainActor
enum AppActivation {
    /// 由 `PanelPresenter` 在创建/销毁设置窗时挂上。
    static weak var stackingProtectedWindow: NSWindow?

    /// 截图选区 / 录制等会话：禁止受保护窗自动成为 key。
    private(set) static var suppressProtectedWindowKeyFocus = false

    /// 进入选区/录制等会激活 App 的交互层。
    static func beginOverlayChrome() {
        suppressProtectedWindowKeyFocus = true
        resignProtectedWindowKeyIfNeeded()
    }

    /// 离开选区/录制交互层（可再次点击设置窗聚焦）。
    static func endOverlayChrome() {
        suppressProtectedWindowKeyFocus = false
    }

    /// 用户点进设置窗时调用，允许其成为 key。
    static func noteProtectedWindowUserInteraction() {
        suppressProtectedWindowKeyFocus = false
    }

    /// 受保护窗当前是否允许成为 key（供 `SettingsWindow` 使用）。
    static var protectedWindowCanBecomeKey: Bool {
        !suppressProtectedWindowKeyFocus
    }

    /// 激活本应用，并尽量不改变受保护窗相对其它 App 的叠放。
    static func activateWithoutRaisingAllWindows() {
        let anchor = captureProtectedStackAnchor()
        activateApplication()
        restoreProtectedStackAnchor(anchor)
        resignProtectedWindowKeyIfNeeded()
    }

    /// 激活并仅前置指定浮层 / 交互窗。
    static func focus(_ windows: [NSWindow], makeKey key: NSWindow? = nil) {
        guard !windows.isEmpty else { return }

        let anchor = captureProtectedStackAnchor()
        activateApplication()

        // accessory 应用没有 Dock 主窗口，单独 orderFrontRegardless 在部分系统状态下
        // 只能让窗口保持 visible，不能可靠地压过当前前台 App；先 makeKeyAndOrderFront，
        // 再 orderFrontRegardless，兼容新建窗和已经被其它 App 盖住的旧窗。
        for window in windows {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
        let keyWindow = key ?? windows.first
        keyWindow?.makeKey()
        restoreProtectedStackAnchor(anchor)
        resignProtectedWindowKeyIfNeeded()

        // 状态栏菜单收起、应用激活和窗口排序可能分属不同的 run loop；下一拍再确认
        // 一次，避免“窗口 isVisible 但仍在其它 App 后面”的偶发状态。
        DispatchQueue.main.async { [weak keyWindow] in
            guard let keyWindow else { return }
            activateApplication()
            for window in windows where window.isVisible {
                window.orderFrontRegardless()
            }
            keyWindow.makeKey()
            restoreProtectedStackAnchor(anchor)
            resignProtectedWindowKeyIfNeeded()
        }
    }

    /// 激活并前置单个窗（成为 key）。
    static func focus(_ window: NSWindow) {
        focus([window], makeKey: window)
    }

    /// 激活并前置当前应用的普通窗口。
    ///
    /// 与 `focus` 不同，这个方法不恢复受保护窗的跨应用叠放关系；适用于用户
    /// 明确重新打开的设置/欢迎窗口——目标窗口本身就应该回到最上层。
    static func bringToFront(_ window: NSWindow, makeKey: Bool = true) {
        activateApplication()
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        if makeKey {
            window.makeKeyAndOrderFront(nil)
        }
        window.orderFrontRegardless()

        // 状态栏菜单关闭后，窗口服务器有时会在当前 run loop 末尾重新计算层级。
        // 再执行一次只影响这个目标窗口，不会把应用内其它窗口整体抬起。
        DispatchQueue.main.async { [weak window] in
            guard let window, window.isVisible else { return }
            activateApplication()
            if makeKey {
                window.makeKeyAndOrderFront(nil)
            }
            window.orderFrontRegardless()
        }
    }

    /// 只激活当前应用，不主动调整应用内窗口顺序。
    ///
    /// `NSApp.activate()` 是 accessory 应用的首选 API；同时调用
    /// `NSRunningApplication.activate` 作为窗口服务器层兜底，解决从全局热键或
    /// 状态栏菜单重新呼出窗口时应用仍处于 inactive 的情况。
    private static func activateApplication() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        }
        _ = NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
    }

    // MARK: - Stack restore

    /// 激活前：记录「盖在受保护窗正上方」的窗口号（前→后列表中的前一项）。
    private static func captureProtectedStackAnchor() -> Int? {
        guard let protected = stackingProtectedWindow,
              protected.isVisible,
              protected.windowNumber > 0
        else { return nil }

        let protectedNumber = protected.windowNumber
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        // 列表为前→后；找到 protected 的前一个即「压在它上面」的窗。
        var previousNumber: Int?
        for entry in info {
            guard let number = entry[kCGWindowNumber as String] as? Int else { continue }
            // 跳过完全透明/零面积（部分系统装饰）
            if let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat] {
                let w = bounds["Width"] ?? 0
                let h = bounds["Height"] ?? 0
                if w < 2 || h < 2 { continue }
            }
            if number == protectedNumber {
                return previousNumber
            }
            previousNumber = number
        }
        return nil
    }

    /// 激活后：把受保护窗塞回「anchor 下方」。anchor 为 nil 表示原先全局最前或未解析到。
    private static func restoreProtectedStackAnchor(_ windowNumberAbove: Int?) {
        guard let protected = stackingProtectedWindow,
              protected.isVisible,
              protected.windowNumber > 0
        else { return }

        guard let above = windowNumberAbove, above > 0, above != protected.windowNumber else {
            // 原先就在最前：不 orderBack，避免无故沉底；仅靠禁止成为 key 防止抢焦点。
            return
        }

        // 锚点窗仍在屏上才相对排序
        let stillThere = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]]
        let exists = stillThere?.contains {
            ($0[kCGWindowNumber as String] as? Int) == above
        } ?? false
        if exists {
            protected.order(.below, relativeTo: above)
        }
    }

    private static func resignProtectedWindowKeyIfNeeded() {
        guard suppressProtectedWindowKeyFocus,
              let protected = stackingProtectedWindow,
              protected.isKeyWindow
        else { return }
        // accessory App 允许无 key window；把 key 让给其它 SnapFlow 窗（若有）
        if let other = NSApp.windows.first(where: {
            $0 !== protected && $0.isVisible && $0.canBecomeKey
        }) {
            other.makeKey()
        } else {
            protected.makeFirstResponder(nil)
        }
    }
}
