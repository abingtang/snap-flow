import Foundation

enum AppAction: String, CaseIterable, Identifiable, Sendable {
    /// 主路径：区域截图（框选 → 截图 → 预览/复制）
    case captureScreenshot
    case captureScreenshotDelay3
    /// Snipaste Paste：剪贴板贴到屏幕
    case pasteToScreen
    case togglePinnedVisibility
    case togglePinClickThrough
    case captureOCR
    /// 原图 OCR：框选后在截图区域叠原文，支持一键翻译
    case captureImageOCR
    /// 截图翻译：框选后出左图右多服务译文窗
    case captureTranslate
    /// 原图翻译：框选后在截图区域叠译文
    case captureImageTranslate
    case selectionTranslate
    case openClipboardHistory
    case openSettings
    case quit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .captureScreenshot: L10n.string("区域截图")
        case .captureScreenshotDelay3: L10n.string("延时 3 秒截图")
        case .pasteToScreen: L10n.string("贴到屏幕")
        case .togglePinnedVisibility: L10n.string("隐藏/显示全部贴图")
        case .togglePinClickThrough: L10n.string("贴图鼠标穿透")
        case .captureOCR: L10n.string("截图 OCR")
        case .captureImageOCR: L10n.string("原图 OCR")
        case .captureTranslate: L10n.string("截图翻译")
        case .captureImageTranslate: L10n.string("原图翻译")
        case .selectionTranslate: L10n.string("划词翻译")
        case .openClipboardHistory: L10n.string("剪切板历史")
        case .openSettings: L10n.string("偏好设置")
        case .quit: L10n.string("退出")
        }
    }

    /// 菜单栏下拉图标（SF Symbol）
    var menuSymbolName: String {
        switch self {
        case .captureScreenshot: "camera.viewfinder"
        case .captureScreenshotDelay3: "timer"
        case .pasteToScreen: "pin"
        case .togglePinnedVisibility: "eye"
        case .togglePinClickThrough: "cursorarrow.rays"
        case .captureOCR: "text.viewfinder"
        case .captureImageOCR: "text.below.photo"
        case .captureTranslate: "globe"
        case .captureImageTranslate: "photo.on.rectangle.angled"
        case .selectionTranslate: "character.cursor.ibeam"
        case .openClipboardHistory: "clipboard"
        case .openSettings: "gearshape"
        case .quit: "power"
        }
    }
}
