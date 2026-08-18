import AppKit

/// 菜单栏入口：
/// - **左键 / 右键**：均弹出功能菜单（icon + 名称 + 快捷键）
/// - 具体功能：点菜单项，或使用全局快捷键
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let container: AppContainer
    private var statusItem: NSStatusItem?

    init(container: AppContainer) {
        self.container = container
        super.init()
        container.panelPresenter.attach(container: container)
    }

    @discardableResult
    func installStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            if let image = menuBarImage() {
                button.image = image
            } else {
                button.title = "SF"
            }
            button.toolTip = L10n.string("SnapFlow — 点击打开菜单；功能也可通过快捷键触发")
            FeedbackCenter.shared.attach(button: button)
            container.panelPresenter.attach(statusBarButton: button)
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        // 首次填充；之后在 menuNeedsUpdate 刷新快捷键展示
        populateMenu(menu)

        NotificationCenter.default.addObserver(
            forName: .snapFlowLanguageDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let button = self.statusItem?.button else { return }
                button.toolTip = L10n.string("SnapFlow — 点击打开菜单；功能也可通过快捷键触发")
            }
        }
        return item
    }

    private func menuBarImage() -> NSImage? {
        guard let image = NSImage(named: NSImage.Name("BarIcon")) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        populateMenu(menu)
    }

    // MARK: - Menu content

    private func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = container.settings

        // —— 截图 / 贴图 ——
        menu.addItem(menuItem(.captureScreenshot, chord: settings.hotkeyCaptureScreenshot))
        menu.addItem(menuItem(.captureScreenshotDelay3, chord: nil))
        menu.addItem(menuItem(.pasteToScreen, chord: settings.hotkeyPasteToScreen))
        menu.addItem(menuItem(.togglePinnedVisibility, chord: settings.hotkeyTogglePins))
        menu.addItem(menuItem(.togglePinClickThrough, chord: settings.hotkeyClickThrough))
        menu.addItem(.separator())

        // —— 翻译 ——
        menu.addItem(menuItem(.selectionTranslate, chord: settings.hotkeySelectionTranslate))
        menu.addItem(menuItem(.captureTranslate, chord: settings.hotkeyCaptureTranslate))
        menu.addItem(menuItem(.captureImageTranslate, chord: settings.hotkeyCaptureImageTranslate))
        menu.addItem(.separator())

        // —— OCR ——
        menu.addItem(menuItem(.captureOCR, chord: settings.hotkeyCaptureOCR))
        menu.addItem(menuItem(.captureImageOCR, chord: settings.hotkeyCaptureImageOCR))
        menu.addItem(.separator())

        // —— 历史 ——
        menu.addItem(menuItem(.openClipboardHistory, chord: settings.hotkeyClipboard))
        menu.addItem(.separator())

        // —— 设置 / 退出 ——
        menu.addItem(menuItem(.openSettings, chord: "cmd+,"))
        menu.addItem(menuItem(.quit, chord: "cmd+q"))
    }

    private func menuItem(_ action: AppAction, chord: String?) -> NSMenuItem {
        let mi = NSMenuItem(
            title: action.title,
            action: #selector(handleMenuItem(_:)),
            keyEquivalent: ""
        )
        mi.target = self
        mi.representedObject = action.rawValue
        mi.image = templateSymbol(action.menuSymbolName)
        if let chord, !chord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            applyKeyEquivalent(to: mi, chord: chord)
        }
        return mi
    }

    private func templateSymbol(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    /// 将 chord 映射为 NSMenuItem 右侧快捷键展示。
    private func applyKeyEquivalent(to item: NSMenuItem, chord: String) {
        let parts = chord.lowercased()
            .split(separator: "+")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let keyPart = parts.last else { return }

        var mask: NSEvent.ModifierFlags = []
        for p in parts.dropLast() {
            switch p {
            case "ctrl", "control": mask.insert(.control)
            case "opt", "option", "alt": mask.insert(.option)
            case "shift": mask.insert(.shift)
            case "cmd", "command": mask.insert(.command)
            default: break
            }
        }

        if let equiv = Self.keyEquivalent(for: keyPart) {
            item.keyEquivalent = equiv
            item.keyEquivalentModifierMask = mask
            return
        }

        // 无法映射时把符号拼进标题右侧（仍可点击）
        let display = HotKeyChord.displayString(from: chord)
        if !display.isEmpty, let raw = item.representedObject as? String,
           let action = AppAction(rawValue: raw)
        {
            item.title = "\(action.title)  \(display)"
        }
    }

    private static func keyEquivalent(for key: String) -> String? {
        let k = key.lowercased()
        // 单字符主键：字母、数字、标点（含 `）
        if k.count == 1, let ch = k.first {
            if ch.isLetter || ch.isNumber {
                return String(ch)
            }
            if "`~!@#$%^&*()-_=+[{]}\\|;:'\",<.>/?".contains(ch) {
                // 菜单 keyEquivalent 用未 shift 字符；`+` 键用 `=`
                if ch == "+" { return "=" }
                if ch == "~" { return "`" }
                return String(ch)
            }
        }
        switch k {
        case "space": return " "
        case "return", "enter": return "\r"
        case "tab": return "\t"
        case "escape", "esc": return "\u{1b}"
        case "delete", "backspace": return "\u{8}"
        case "forwarddelete": return "\u{7f}"
        case "comma": return ","
        case "period": return "."
        case "minus": return "-"
        case "plus", "equal": return "="
        case "grave": return "`"
        case "leftbracket": return "["
        case "rightbracket": return "]"
        case "backslash": return "\\"
        case "semicolon": return ";"
        case "quote": return "'"
        case "slash": return "/"
        case "f1": return functionKey(NSF1FunctionKey)
        case "f2": return functionKey(NSF2FunctionKey)
        case "f3": return functionKey(NSF3FunctionKey)
        case "f4": return functionKey(NSF4FunctionKey)
        case "f5": return functionKey(NSF5FunctionKey)
        case "f6": return functionKey(NSF6FunctionKey)
        case "f7": return functionKey(NSF7FunctionKey)
        case "f8": return functionKey(NSF8FunctionKey)
        case "f9": return functionKey(NSF9FunctionKey)
        case "f10": return functionKey(NSF10FunctionKey)
        case "f11": return functionKey(NSF11FunctionKey)
        case "f12": return functionKey(NSF12FunctionKey)
        default: return nil
        }
    }

    private static func functionKey(_ key: Int) -> String {
        String(UnicodeScalar(key)!)
    }

    @objc private func handleMenuItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = AppAction(rawValue: raw)
        else { return }

        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.handle(action)
            return
        }
        handleLocally(action)
    }

    private func handleLocally(_ action: AppAction) {
        switch action {
        case .captureScreenshot:
            Task { await container.workflows.runRegionScreenshot(delaySeconds: 0) }
        case .captureScreenshotDelay3:
            Task { await container.workflows.runRegionScreenshot(delaySeconds: 3) }
        case .pasteToScreen:
            container.workflows.pasteClipboardToScreen()
        case .togglePinnedVisibility:
            container.panelPresenter.togglePinnedVisibility()
        case .togglePinClickThrough:
            container.panelPresenter.toggleClickThroughUnderCursor()
        case .captureOCR:
            Task { await container.workflows.runCaptureOCR() }
        case .captureImageOCR:
            Task { await container.workflows.runCaptureImageOCR() }
        case .captureTranslate:
            Task { await container.workflows.runCaptureTranslate() }
        case .captureImageTranslate:
            Task { await container.workflows.runCaptureImageTranslate() }
        case .selectionTranslate:
            Task { await container.workflows.runSelectionTranslate() }
        case .openClipboardHistory:
            container.panelPresenter.showClipboardHistory()
        case .openSettings:
            container.panelPresenter.showSettings()
        case .quit:
            NSApp.terminate(nil)
        }
    }
}
