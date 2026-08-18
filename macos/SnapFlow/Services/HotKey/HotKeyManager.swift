import AppKit
import Carbon
import Foundation

/// 基于 Carbon RegisterEventHotKey 的全局热键（无第三方依赖）。
@MainActor
final class HotKeyManager {
    var onAction: ((AppAction) -> Void)?

    private let settings: SettingsStore
    private var hotKeys: [UInt32: EventHotKeyRef] = [:]
    private var actionByID: [UInt32: AppAction] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1
    /// 偏好设置录制快捷键时为 true：不注册、不回调。
    private(set) var isSuspended = false

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func registerDefaults() {
        unregisterAll()
        installHandlerIfNeeded()
        // 录制中禁止重新挂上全局热键，避免刚改完 chord 又被 registerDefaults 抢跑
        guard !isSuspended else { return }

        // 全局功能热键：截图/贴图/OCR/翻译/剪切板
        register(action: .captureScreenshot, chord: settings.hotkeyCaptureScreenshot)
        register(action: .pasteToScreen, chord: settings.hotkeyPasteToScreen)
        register(action: .togglePinnedVisibility, chord: settings.hotkeyTogglePins)
        register(action: .togglePinClickThrough, chord: settings.hotkeyClickThrough)
        register(action: .captureOCR, chord: settings.hotkeyCaptureOCR)
        register(action: .captureImageOCR, chord: settings.hotkeyCaptureImageOCR)
        register(action: .captureTranslate, chord: settings.hotkeyCaptureTranslate)
        register(action: .captureImageTranslate, chord: settings.hotkeyCaptureImageTranslate)
        register(action: .selectionTranslate, chord: settings.hotkeySelectionTranslate)
        register(action: .openClipboardHistory, chord: settings.hotkeyClipboard)
    }

    func unregisterAll() {
        for (_, ref) in hotKeys {
            UnregisterEventHotKey(ref)
        }
        hotKeys.removeAll()
        actionByID.removeAll()
    }

    /// 录制快捷键：卸掉全部 Carbon 全局热键，避免录制时触发截图/OCR 等。
    func suspend() {
        isSuspended = true
        unregisterAll()
    }

    /// 结束录制：恢复全局热键注册。
    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        registerDefaults()
    }

    // MARK: - Register

    private func register(action: AppAction, chord: String) {
        guard !chord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let parsed = HotKeyChord.parse(chord) else {
            NSLog("[SnapFlow] invalid hotkey for \(action): \(chord)")
            return
        }
        let id = nextID
        nextID += 1
        var hotKeyRef: EventHotKeyRef?
        var hotKeyID = EventHotKeyID(signature: OSType(0x534E464C), /* SNFL */ id: id)
        let status = RegisterEventHotKey(
            parsed.keyCode,
            parsed.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr, let hotKeyRef else {
            NSLog("[SnapFlow] failed to register hotkey \(chord) status=\(status)")
            return
        }
        hotKeys[id] = hotKeyRef
        actionByID[id] = action
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData, let event else { return noErr }
                var hkID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in
                    guard !manager.isSuspended else { return }
                    if let action = manager.actionByID[hkID.id] {
                        manager.onAction?(action)
                    }
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &eventHandler
        )
    }
}

// MARK: - Chord parsing

/// 全局 / 局部 / 录制共用的 chord 解析与主键表（ANSI US keyCode，与 macOS HIToolbox 一致）。
struct HotKeyChord: Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    static func parse(_ string: String) -> HotKeyChord? {
        let parts = string.lowercased()
            .split(separator: "+")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let keyPart = parts.last else { return nil }
        var mods: UInt32 = 0
        for p in parts.dropLast() {
            switch p {
            case "ctrl", "control": mods |= UInt32(controlKey)
            case "opt", "option", "alt": mods |= UInt32(optionKey)
            case "cmd", "command": mods |= UInt32(cmdKey)
            case "shift": mods |= UInt32(shiftKey)
            default: break
            }
        }
        guard let code = keyCode(for: keyPart) else { return nil }
        return HotKeyChord(keyCode: code, modifiers: mods)
    }

    /// 主键名 → Carbon/NSEvent keyCode（含别名）。
    static func keyCode(for key: String) -> UInt32? {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return nameToKeyCode[normalized]
    }

    /// keyCode → 录制用规范名（优先单字符，便于展示与菜单 keyEquivalent）。
    static func keyName(forKeyCode code: UInt16) -> String? {
        keyCodeToName[UInt32(code)]
    }

    /// 事件是否匹配 chord 中的主键（优先 keyCode，再回退字符）。
    static func eventMatchesKey(_ event: NSEvent, key: String) -> Bool {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let code = keyCode(for: normalized), event.keyCode == UInt16(code) {
            return true
        }
        // 字母数字：兼容旧 chord 与布局差异
        if normalized.count == 1,
           let ch = normalized.first,
           ch.isLetter || ch.isNumber
        {
            return event.charactersIgnoringModifiers?.lowercased() == normalized
        }
        return false
    }

    /// 展示用主键文案。
    static func prettyKeyName(_ key: String) -> String {
        let k = key.lowercased()
        switch k {
        case "escape", "esc": return "⎋"
        case "return", "enter": return "↩"
        case "space": return "␣"
        case "tab": return "⇥"
        case "delete", "backspace": return "⌫"
        case "forwarddelete": return "⌦"
        case "up": return "↑"
        case "down": return "↓"
        case "left": return "←"
        case "right": return "→"
        case "home": return "↖"
        case "end": return "↘"
        case "pageup": return "⇞"
        case "pagedown": return "⇟"
        case "comma", ",": return ","
        case "period", ".": return "."
        case "plus", "equal", "=": return "+"
        case "minus", "-": return "−"
        case "grave", "`": return "`"
        case "leftbracket", "[": return "["
        case "rightbracket", "]": return "]"
        case "backslash", "\\": return "\\"
        case "semicolon", ";": return ";"
        case "quote", "'": return "'"
        case "slash", "/": return "/"
        case "capslock": return "⇪"
        default:
            if k.count == 1 { return k.uppercased() }
            if k.hasPrefix("f"), k.count <= 3, k.dropFirst().allSatisfy(\.isNumber) {
                return k.uppercased()
            }
            if k.hasPrefix("keypad") {
                return k.replacingOccurrences(of: "keypad", with: L10n.string("小键盘"))
            }
            return key
        }
    }

    // MARK: Tables (ANSI US)

    /// 名称 / 别名 → keyCode
    private static let nameToKeyCode: [String: UInt32] = {
        var m: [String: UInt32] = [:]
        func put(_ names: String..., code: UInt32) {
            for n in names { m[n.lowercased()] = code }
        }

        // 字母
        put("a", code: 0); put("s", code: 1); put("d", code: 2); put("f", code: 3)
        put("h", code: 4); put("g", code: 5); put("z", code: 6); put("x", code: 7)
        put("c", code: 8); put("v", code: 9); put("b", code: 11); put("q", code: 12)
        put("w", code: 13); put("e", code: 14); put("r", code: 15); put("y", code: 16)
        put("t", code: 17); put("o", code: 31); put("u", code: 32); put("i", code: 34)
        put("p", code: 35); put("l", code: 37); put("j", code: 38); put("k", code: 40)
        put("n", code: 45); put("m", code: 46)

        // 数字行
        put("1", code: 18); put("2", code: 19); put("3", code: 20); put("4", code: 21)
        put("5", code: 23); put("6", code: 22); put("7", code: 26); put("8", code: 28)
        put("9", code: 25); put("0", code: 29)

        // 标点（主键盘）——含用户常录不上的 ` [ ] \ ; ' / 等
        put("`", "grave", code: 50)
        put("-", "minus", code: 27)
        put("=", "equal", "plus", code: 24) // = / + 同键；历史 chord 用 plus
        put("[", "leftbracket", code: 33)
        put("]", "rightbracket", code: 30)
        put("\\", "backslash", code: 42)
        put(";", "semicolon", code: 41)
        put("'", "quote", code: 39)
        put(",", "comma", code: 43)
        put(".", "period", code: 47)
        put("/", "slash", code: 44)

        // 编辑 / 导航
        put("space", code: 49)
        put("tab", code: 48)
        put("return", "enter", code: 36)
        put("escape", "esc", code: 53)
        put("delete", "backspace", code: 51)
        put("forwarddelete", code: 117)
        put("left", code: 123)
        put("right", code: 124)
        put("down", code: 125)
        put("up", code: 126)
        put("home", code: 115)
        put("end", code: 119)
        put("pageup", code: 116)
        put("pagedown", code: 121)
        put("help", code: 114)
        put("capslock", code: 57)

        // F 键
        put("f1", code: 122); put("f2", code: 120); put("f3", code: 99); put("f4", code: 118)
        put("f5", code: 96); put("f6", code: 97); put("f7", code: 98); put("f8", code: 100)
        put("f9", code: 101); put("f10", code: 109); put("f11", code: 103); put("f12", code: 111)
        put("f13", code: 105); put("f14", code: 107); put("f15", code: 113)
        put("f16", code: 106); put("f17", code: 64); put("f18", code: 79); put("f19", code: 80)
        put("f20", code: 90)

        // 小键盘
        put("keypad0", code: 82); put("keypad1", code: 83); put("keypad2", code: 84)
        put("keypad3", code: 85); put("keypad4", code: 86); put("keypad5", code: 87)
        put("keypad6", code: 88); put("keypad7", code: 89); put("keypad8", code: 91)
        put("keypad9", code: 92)
        put("keypaddecimal", code: 65)
        put("keypadmultiply", code: 67)
        put("keypadplus", code: 69)
        put("keypadclear", code: 71)
        put("keypaddivide", code: 75)
        put("keypadenter", code: 76)
        put("keypadminus", code: 78)
        put("keypadequals", code: 81)

        return m
    }()

    /// keyCode → 规范录制名（每个 code 一个主名）
    private static let keyCodeToName: [UInt32: String] = {
        // 字母 / 数字 / 单字符标点优先；功能键用单词
        var m: [UInt32: String] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
            11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
            24: "equal", 25: "9", 26: "7", 27: "minus", 28: "8", 29: "0",
            30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p",
            36: "return", 37: "l", 38: "j", 39: "'", 40: "k", 41: ";",
            42: "\\", 43: ",", 44: "/", 45: "n", 46: "m", 47: ".",
            48: "tab", 49: "space", 50: "`", 51: "delete", 53: "escape",
            57: "capslock",
            64: "f17", 65: "keypaddecimal", 67: "keypadmultiply", 69: "keypadplus",
            71: "keypadclear", 75: "keypaddivide", 76: "keypadenter", 78: "keypadminus",
            79: "f18", 80: "f19", 81: "keypadequals",
            82: "keypad0", 83: "keypad1", 84: "keypad2", 85: "keypad3", 86: "keypad4",
            87: "keypad5", 88: "keypad6", 89: "keypad7", 90: "f20", 91: "keypad8", 92: "keypad9",
            96: "f5", 97: "f6", 98: "f7", 99: "f3", 100: "f8", 101: "f9",
            103: "f11", 105: "f13", 106: "f16", 107: "f14", 109: "f10",
            111: "f12", 113: "f15", 114: "help", 115: "home", 116: "pageup",
            117: "forwarddelete", 118: "f4", 119: "end", 120: "f2", 121: "pagedown",
            122: "f1", 123: "left", 124: "right", 125: "down", 126: "up",
        ]
        return m
    }()
}
