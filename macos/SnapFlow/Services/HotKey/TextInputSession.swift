import AppKit

/// 判断当前焦点是否在输入法组字，避免 local monitor 抢走回车 / 空格 / 方向键。
enum TextInputSession {
    /// 输入法候选框或 marked text 未提交。
    static func isComposing(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if let client = responder as? any NSTextInputClient {
            return client.hasMarkedText()
        }
        return false
    }

    /// 焦点在可编辑文本（含 SwiftUI `TextField` 的 field editor）。
    static func isEditing(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder is NSTextView || responder is NSText || responder is NSTextField {
            return true
        }
        if let view = responder as? NSView, view.enclosingScrollView?.documentView is NSTextView {
            return true
        }
        return false
    }
}
