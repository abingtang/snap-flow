import AppKit

enum LocalShortcutScope {
    case capture
    case pinnedImage
    case ocrResult
    case clipboard
}

enum LocalShortcutAction: String, CaseIterable, Identifiable {
    case captureCancel
    case captureCopy
    case captureSave
    case captureQuickSave
    case capturePin
    case captureUndo
    case captureClearAnnotations
    case captureRedo
    case captureConfirm
    case captureToggleToolbar
    case captureToggleDetection
    case captureSelectAll
    case captureRestoreRegion
    case capturePreviousHistory
    case captureNextHistory
    case captureCopyColor
    case captureCopyAlternateColor
    case captureToggleMagnifier
    case captureCursorUp
    case captureCursorDown
    case captureCursorLeft
    case captureCursorRight
    case captureMoveUp
    case captureMoveDown
    case captureMoveLeft
    case captureMoveRight
    case captureExpandUp
    case captureExpandDown
    case captureExpandLeft
    case captureExpandRight
    case captureShrinkUp
    case captureShrinkDown
    case captureShrinkLeft
    case captureShrinkRight
    case pinToggleEditor
    case pinClose
    case pinRotateClockwise
    case pinRotateCounterclockwise
    case pinFlipHorizontal
    case pinFlipVertical
    case pinZoomIn
    case pinZoomOut
    case pinOpacityUp
    case pinOpacityDown
    case pinCopy
    case pinSave
    case pinOCR
    case pinUndo
    case pinRedo
    case pinClearAnnotations
    // OCR 结果窗内快捷键（可配置）
    case ocrRetry
    case ocrClose
    case ocrCloseCommandW
    case ocrTogglePin
    case ocrFontLarger
    case ocrFontSmaller
    // 剪切板弹窗内快捷键（可配置）
    case clipboardPaste
    case clipboardPastePlain
    case clipboardClose
    case clipboardTogglePreview
    case clipboardTogglePin
    case clipboardDelete
    case clipboardClearUnpinned
    case clipboardPrevious
    case clipboardNext
    case clipboardQuick1
    case clipboardQuick2
    case clipboardQuick3
    case clipboardQuick4
    case clipboardQuick5
    case clipboardQuick6
    case clipboardQuick7
    case clipboardQuick8
    case clipboardQuick9

    var id: String { rawValue }

    var scope: LocalShortcutScope {
        if rawValue.hasPrefix("capture") { return .capture }
        if rawValue.hasPrefix("ocr") { return .ocrResult }
        if rawValue.hasPrefix("clipboard") { return .clipboard }
        return .pinnedImage
    }

    var title: String {
        switch self {
        case .captureCancel: L10n.string("取消截屏")
        case .captureCopy: L10n.string("复制截图")
        case .captureSave: L10n.string("保存截图")
        case .captureQuickSave: L10n.string("快捷保存")
        case .capturePin: L10n.string("贴到屏幕")
        case .captureUndo: L10n.string("撤销标注")
        case .captureClearAnnotations: L10n.string("清除全部标注")
        case .captureRedo: L10n.string("重做标注")
        case .captureConfirm: L10n.string("确认并复制")
        case .captureToggleToolbar: L10n.string("显示/隐藏标注工具栏")
        case .captureToggleDetection: L10n.string("切换窗口/元素检测")
        case .captureSelectAll: L10n.string("选择全屏")
        case .captureRestoreRegion: L10n.string("恢复上次选区")
        case .capturePreviousHistory: L10n.string("上一条截图历史")
        case .captureNextHistory: L10n.string("下一条截图历史")
        case .captureCopyColor: L10n.string("复制光标颜色")
        case .captureCopyAlternateColor: L10n.string("复制另一格式颜色")
        case .captureToggleMagnifier: L10n.string("显示/隐藏放大镜")
        case .captureCursorUp: L10n.string("光标上移")
        case .captureCursorDown: L10n.string("光标下移")
        case .captureCursorLeft: L10n.string("光标左移")
        case .captureCursorRight: L10n.string("光标右移")
        case .captureMoveUp: L10n.string("选区上移")
        case .captureMoveDown: L10n.string("选区下移")
        case .captureMoveLeft: L10n.string("选区左移")
        case .captureMoveRight: L10n.string("选区右移")
        case .captureExpandUp: L10n.string("选区向上扩大")
        case .captureExpandDown: L10n.string("选区向下扩大")
        case .captureExpandLeft: L10n.string("选区向左扩大")
        case .captureExpandRight: L10n.string("选区向右扩大")
        case .captureShrinkUp: L10n.string("选区从上缩小")
        case .captureShrinkDown: L10n.string("选区从下缩小")
        case .captureShrinkLeft: L10n.string("选区从左缩小")
        case .captureShrinkRight: L10n.string("选区从右缩小")
        case .pinToggleEditor: L10n.string("打开/关闭标注工具栏")
        case .pinClose: L10n.string("关闭贴图")
        case .pinRotateClockwise: L10n.string("顺时针旋转")
        case .pinRotateCounterclockwise: L10n.string("逆时针旋转")
        case .pinFlipHorizontal: L10n.string("水平翻转")
        case .pinFlipVertical: L10n.string("垂直翻转")
        case .pinZoomIn: L10n.string("放大贴图")
        case .pinZoomOut: L10n.string("缩小贴图")
        case .pinOpacityUp: L10n.string("提高不透明度")
        case .pinOpacityDown: L10n.string("降低不透明度")
        case .pinCopy: L10n.string("复制贴图")
        case .pinSave: L10n.string("保存贴图")
        case .pinOCR: L10n.string("识别贴图文字")
        case .pinUndo: L10n.string("撤销贴图标注")
        case .pinRedo: L10n.string("重做贴图标注")
        case .pinClearAnnotations: L10n.string("清除贴图标注")
        case .ocrRetry: L10n.string("重试识别")
        case .ocrClose: L10n.string("关闭窗口")
        case .ocrCloseCommandW: L10n.string("关闭窗口（备用）")
        case .ocrTogglePin: L10n.string("钉住/取消钉住窗口")
        case .ocrFontLarger: L10n.string("字号放大")
        case .ocrFontSmaller: L10n.string("字号缩小")
        case .clipboardPaste: L10n.string("粘贴所选内容")
        case .clipboardPastePlain: L10n.string("粘贴为纯文本")
        case .clipboardClose: L10n.string("关闭剪切板")
        case .clipboardTogglePreview: L10n.string("显示/隐藏预览")
        case .clipboardTogglePin: L10n.string("固定/取消固定")
        case .clipboardDelete: L10n.string("删除所选内容")
        case .clipboardClearUnpinned: L10n.string("清空未固定内容")
        case .clipboardPrevious: L10n.string("选择上一项")
        case .clipboardNext: L10n.string("选择下一项")
        case .clipboardQuick1: L10n.string("快速粘贴第 1 项")
        case .clipboardQuick2: L10n.string("快速粘贴第 2 项")
        case .clipboardQuick3: L10n.string("快速粘贴第 3 项")
        case .clipboardQuick4: L10n.string("快速粘贴第 4 项")
        case .clipboardQuick5: L10n.string("快速粘贴第 5 项")
        case .clipboardQuick6: L10n.string("快速粘贴第 6 项")
        case .clipboardQuick7: L10n.string("快速粘贴第 7 项")
        case .clipboardQuick8: L10n.string("快速粘贴第 8 项")
        case .clipboardQuick9: L10n.string("快速粘贴第 9 项")
        }
    }

    /// 偏好设置行前置 SF Symbol，与录制/剪切板设置行图标风格一致。
    var systemImage: String {
        switch self {
        case .captureCancel, .pinClose, .ocrClose, .ocrCloseCommandW, .clipboardClose:
            "xmark.circle"
        case .captureCopy, .pinCopy:
            "doc.on.doc"
        case .captureSave, .pinSave:
            "square.and.arrow.down"
        case .captureQuickSave:
            "square.and.arrow.down.on.square"
        case .capturePin:
            "pin"
        case .captureUndo, .pinUndo:
            "arrow.uturn.backward"
        case .captureClearAnnotations, .pinClearAnnotations:
            "eraser"
        case .captureRedo, .pinRedo:
            "arrow.uturn.forward"
        case .captureConfirm:
            "checkmark.circle"
        case .captureToggleToolbar, .pinToggleEditor:
            "hammer"
        case .captureToggleDetection:
            "square.on.square.dashed"
        case .captureSelectAll:
            "rectangle.dashed"
        case .captureRestoreRegion:
            "arrow.counterclockwise"
        case .capturePreviousHistory:
            "chevron.left"
        case .captureNextHistory:
            "chevron.right"
        case .captureCopyColor, .captureCopyAlternateColor:
            "eyedropper"
        case .captureToggleMagnifier:
            "plus.magnifyingglass"
        case .captureCursorUp, .captureCursorDown, .captureCursorLeft, .captureCursorRight:
            "cursorarrow"
        case .captureMoveUp, .captureMoveDown, .captureMoveLeft, .captureMoveRight:
            "arrow.up.and.down.and.arrow.left.and.right"
        case .captureExpandUp, .captureExpandDown, .captureExpandLeft, .captureExpandRight:
            "arrow.up.left.and.arrow.down.right"
        case .captureShrinkUp, .captureShrinkDown, .captureShrinkLeft, .captureShrinkRight:
            "arrow.down.right.and.arrow.up.left"
        case .pinRotateClockwise:
            "rotate.right"
        case .pinRotateCounterclockwise:
            "rotate.left"
        case .pinFlipHorizontal:
            "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .pinFlipVertical:
            "arrow.up.and.down.righttriangle.up.righttriangle.down"
        case .pinZoomIn:
            "plus.magnifyingglass"
        case .pinZoomOut:
            "minus.magnifyingglass"
        case .pinOpacityUp:
            "circle.lefthalf.filled"
        case .pinOpacityDown:
            "circle.righthalf.filled"
        case .pinOCR:
            "text.viewfinder"
        case .ocrRetry:
            "arrow.clockwise"
        case .ocrTogglePin:
            "pin"
        case .ocrFontLarger:
            "textformat.size.larger"
        case .ocrFontSmaller:
            "textformat.size.smaller"
        case .clipboardPaste:
            "doc.on.clipboard"
        case .clipboardPastePlain:
            "text.alignleft"
        case .clipboardTogglePreview:
            "eye"
        case .clipboardTogglePin:
            "pin"
        case .clipboardDelete:
            "trash"
        case .clipboardClearUnpinned:
            "trash.circle"
        case .clipboardPrevious:
            "chevron.up"
        case .clipboardNext:
            "chevron.down"
        case .clipboardQuick1: "1.circle"
        case .clipboardQuick2: "2.circle"
        case .clipboardQuick3: "3.circle"
        case .clipboardQuick4: "4.circle"
        case .clipboardQuick5: "5.circle"
        case .clipboardQuick6: "6.circle"
        case .clipboardQuick7: "7.circle"
        case .clipboardQuick8: "8.circle"
        case .clipboardQuick9: "9.circle"
        }
    }

    var defaultChord: String {
        switch self {
        case .captureCancel, .pinClose, .ocrClose, .clipboardClose: "escape"
        case .captureCopy, .pinCopy: "cmd+c"
        case .captureSave, .pinSave: "cmd+s"
        case .captureQuickSave: "cmd+shift+s"
        case .capturePin: "cmd+t"
        case .captureUndo: "cmd+z"
        case .captureClearAnnotations: "cmd+shift+z"
        case .captureRedo: "cmd+y"
        case .captureConfirm: "enter"
        case .captureToggleToolbar, .pinToggleEditor: "space"
        case .captureToggleDetection: "tab"
        case .captureSelectAll: "cmd+a"
        case .captureRestoreRegion: "r"
        case .capturePreviousHistory: "comma"
        case .captureNextHistory: "period"
        case .captureCopyColor: "c"
        case .captureCopyAlternateColor: "shift+c"
        case .captureToggleMagnifier: "m"
        case .captureCursorUp: "w"
        case .captureCursorDown: "s"
        case .captureCursorLeft: "a"
        case .captureCursorRight: "d"
        case .captureMoveUp: "up"
        case .captureMoveDown: "down"
        case .captureMoveLeft: "left"
        case .captureMoveRight: "right"
        case .captureExpandUp: "cmd+up"
        case .captureExpandDown: "cmd+down"
        case .captureExpandLeft: "cmd+left"
        case .captureExpandRight: "cmd+right"
        case .captureShrinkUp: "shift+up"
        case .captureShrinkDown: "shift+down"
        case .captureShrinkLeft: "shift+left"
        case .captureShrinkRight: "shift+right"
        case .pinRotateClockwise: "1"
        case .pinRotateCounterclockwise: "2"
        case .pinFlipHorizontal: "3"
        case .pinFlipVertical: "4"
        case .pinZoomIn: "plus"
        case .pinZoomOut: "minus"
        case .pinOpacityUp: "cmd+plus"
        case .pinOpacityDown: "cmd+minus"
        case .pinOCR: "cmd+o"
        case .pinUndo: "cmd+z"
        case .pinRedo: "cmd+y"
        case .pinClearAnnotations: "cmd+shift+z"
        case .ocrRetry: "cmd+r"
        case .ocrCloseCommandW: "cmd+w"
        case .ocrTogglePin: "cmd+shift+p"
        case .ocrFontLarger: "cmd+plus"
        case .ocrFontSmaller: "cmd+minus"
        case .clipboardPaste: "enter"
        case .clipboardPastePlain: "shift+enter"
        case .clipboardTogglePreview: "space"
        case .clipboardTogglePin: "option+p"
        case .clipboardDelete: "option+delete"
        case .clipboardClearUnpinned: "cmd+option+delete"
        case .clipboardPrevious: "up"
        case .clipboardNext: "down"
        case .clipboardQuick1: "cmd+1"
        case .clipboardQuick2: "cmd+2"
        case .clipboardQuick3: "cmd+3"
        case .clipboardQuick4: "cmd+4"
        case .clipboardQuick5: "cmd+5"
        case .clipboardQuick6: "cmd+6"
        case .clipboardQuick7: "cmd+7"
        case .clipboardQuick8: "cmd+8"
        case .clipboardQuick9: "cmd+9"
        }
    }
}

enum LocalShortcutMatcher {
    private static let supportedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    static func matches(_ event: NSEvent, chord: String) -> Bool {
        // 偏好设置录制快捷键时，不匹配任何局部 chord（含剪切板固定快捷键）
        if HotkeyRecordingStore.recordingActiveFlag { return false }

        let parts = chord.lowercased()
            .split(separator: "+")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, !key.isEmpty else { return false }

        var expected: NSEvent.ModifierFlags = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command": expected.insert(.command)
            case "ctrl", "control": expected.insert(.control)
            case "opt", "option", "alt": expected.insert(.option)
            case "shift": expected.insert(.shift)
            default: return false
            }
        }
        if key == "plus" {
            // 历史：cmd+plus 表示 ⌘⇧=（放大）；匹配时要求带 shift
            expected.insert(.shift)
        }
        guard event.modifierFlags.intersection(supportedModifiers) == expected else { return false }

        return HotKeyChord.eventMatchesKey(event, key: key)
    }
}
