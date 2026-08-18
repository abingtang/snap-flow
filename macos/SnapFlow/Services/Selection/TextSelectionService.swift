import AppKit
import ApplicationServices
import Foundation

/// 读取当前选中文本。
///
/// 策略（由稳到兜底）：
/// 1. 前台 App（非自身）的焦点元素 `AXSelectedText`
/// 2. 系统焦点元素 `AXSelectedText`
/// 3. `AXSelectedTextRange` + `AXValue` 截取
/// 4. 模拟 ⌘C 读剪切板再还原（兼容 Electron / 浏览器 / 大量自定义控件）
final class TextSelectionService: TextSelecting, @unchecked Sendable {
    /// 模拟复制后等待剪切板更新的最长时间。
    private let copyTimeoutMs: UInt64 = 350
    private let copyPollMs: UInt64 = 20

    func selectedText() async -> String? {
        if let ax = await accessibilitySelectedText() {
            return ax
        }
        return await pasteboardSelectedText()
    }

    /// 只通过辅助功能读取选中文本，不触碰系统剪切板。
    func accessibilitySelectedText() async -> String? {
        // 先 AX（主线程，快）
        if let ax = await MainActor.run(body: { readSelectedTextViaAccessibility() }) {
            let trimmed = ax.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return ax }
        }
        return nil
    }

    /// 通过模拟 ⌘C 读取选中文本；调用方负责在此期间抑制剪切板历史监听。
    func pasteboardSelectedText() async -> String? {
        await readSelectedTextViaCopyCommand()
    }

    // MARK: - Accessibility

    @MainActor
    private func readSelectedTextViaAccessibility() -> String? {
        let ourPID = ProcessInfo.processInfo.processIdentifier

        // 1) 前台 App（排除自己）——热键触发后系统焦点有时会漂到菜单栏 App
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ourPID
        {
            if let text = readSelectedText(fromAppPID: front.processIdentifier) {
                return text
            }
        }

        // 2) 系统级焦点元素
        let system = AXUIElementCreateSystemWide()
        if let focused = copyElement(system, kAXFocusedUIElementAttribute as CFString),
           let text = readSelectedText(from: focused)
        {
            return text
        }

        // 3) 系统焦点 App 再取一次焦点元素
        if let app = copyElement(system, kAXFocusedApplicationAttribute as CFString),
           let focused = copyElement(app, kAXFocusedUIElementAttribute as CFString),
           let text = readSelectedText(from: focused)
        {
            return text
        }

        return nil
    }

    @MainActor
    private func readSelectedText(fromAppPID pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        // 焦点元素
        if let focused = copyElement(app, kAXFocusedUIElementAttribute as CFString),
           let text = readSelectedText(from: focused)
        {
            return text
        }
        // 部分 App 选区挂在窗口而非 focused UIElement
        if let window = copyElement(app, kAXFocusedWindowAttribute as CFString),
           let text = readSelectedText(from: window)
        {
            return text
        }
        return nil
    }

    /// 单元素：SelectedText → SelectedTextRange+Value
    private func readSelectedText(from element: AXUIElement) -> String? {
        if let text = copyStringAttribute(element, kAXSelectedTextAttribute as CFString) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return text }
        }
        if let text = selectedTextFromRangeAndValue(element) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return text }
        }
        return nil
    }

    /// 用选区 range 从完整 value 截取（Safari / 部分原生控件常用）
    private func selectedTextFromRangeAndValue(_ element: AXUIElement) -> String? {
        var rangeRef: CFTypeRef?
        let rangeStatus = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        )
        guard rangeStatus == .success, let rangeRef else { return nil }

        var cfRange = CFRange()
        // AXValue → CFRange
        let axValue = rangeRef as! AXValue
        guard AXValueGetValue(axValue, .cfRange, &cfRange),
              cfRange.length > 0
        else {
            return nil
        }

        guard let full = copyStringAttribute(element, kAXValueAttribute as CFString) else {
            return nil
        }

        let ns = full as NSString
        guard cfRange.location >= 0,
              cfRange.location + cfRange.length <= ns.length
        else {
            return nil
        }
        return ns.substring(with: NSRange(location: cfRange.location, length: cfRange.length))
    }

    // MARK: - ⌘C 回退

    /// 保存剪切板 → 向系统发送 ⌘C → 读取新文本 → 还原剪切板。
    private func readSelectedTextViaCopyCommand() async -> String? {
        let snapshot = await MainActor.run { PasteboardSnapshot.capture() }
        let beforeCount = snapshot.changeCount

        // AppWorkflows 会在调用本方法期间临时抑制监听，完成还原后立即重置监听基线。

        await MainActor.run {
            Self.postCommandC()
        }

        // 轮询等待 changeCount 变化
        let deadline = ContinuousClock.now + .milliseconds(Int64(copyTimeoutMs))
        var copied: String?
        while ContinuousClock.now < deadline {
            let current = await MainActor.run { () -> (Int, String?) in
                let pb = NSPasteboard.general
                return (pb.changeCount, pb.string(forType: .string))
            }
            if current.0 != beforeCount {
                let text = current.1?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !text.isEmpty {
                    copied = current.1
                }
                break
            }
            try? await Task.sleep(for: .milliseconds(Int64(copyPollMs)))
        }

        await MainActor.run {
            snapshot.restore()
        }

        guard let copied else { return nil }
        let trimmed = copied.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : copied
    }

    /// 虚拟键码 `c` = 8；需要辅助功能权限才能注入。
    @MainActor
    private static func postCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyC: CGKeyCode = 8
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: false)
        else {
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // hid tap 对前台 App 更可靠
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - AX helpers

    private func copyElement(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success, let value else { return nil }
        return (value as! AXUIElement)
    }

    private func copyStringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success, let value else { return nil }
        if let str = value as? String { return str }
        if CFGetTypeID(value) == CFStringGetTypeID() {
            return (value as! CFString) as String
        }
        // 部分控件返回 NSAttributedString
        if let attr = value as? NSAttributedString {
            return attr.string
        }
        return nil
    }
}

// MARK: - Pasteboard snapshot

/// 通用剪切板快照，用于 ⌘C 取词后还原用户原内容。
private struct PasteboardSnapshot: @unchecked Sendable {
    let changeCount: Int
    let items: [[String: Data]]

    @MainActor
    static func capture(from pasteboard: NSPasteboard = .general) -> PasteboardSnapshot {
        var items: [[String: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var map: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    map[type.rawValue] = data
                }
            }
            if !map.isEmpty {
                items.append(map)
            }
        }
        return PasteboardSnapshot(changeCount: pasteboard.changeCount, items: items)
    }

    @MainActor
    func restore(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let pbItems: [NSPasteboardItem] = items.map { map in
            let item = NSPasteboardItem()
            for (type, data) in map {
                item.setData(data, forType: .init(type))
            }
            return item
        }
        pasteboard.writeObjects(pbItems)
    }
}
