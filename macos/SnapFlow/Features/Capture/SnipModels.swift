import AppKit
import CoreGraphics
import Foundation

/// 截图会话最终动作（与 Snipaste 工具栏对齐）
enum SnipAction: String, Sendable {
    case pin
    case copy
    case save
    case ocr
    case imageOCR
    case translate
    case imageTranslate
    case scrollCapture // 滚动截屏（广截屏）
    case record // 录制当前截图选区
    case quickSave // Ctrl+Shift+S 快捷保存
    case confirm // 兼容：复制 + 贴图
    case cancelled
}

/// 框选完成后的行为
enum SnipPurpose: Sendable {
    /// 常规截图：框选后进入标注工具栏
    case annotate
    /// OCR：框选完成后直接返回，不出现工具栏
    case ocrImmediate
}

/// 选区会话结果
struct SnipResult: Sendable {
    let region: CaptureRegion
    let image: NSImage
    let cgImage: CGImage
    let action: SnipAction
}

/// 框选 UI 视觉（对齐参考截图：浅蓝描边）
enum SnipStyle {
    static let dim = NSColor.black.withAlphaComponent(0.45)
    /// 参考图浅蓝描边
    static let stroke = NSColor(calibratedRed: 0.35, green: 0.62, blue: 1.0, alpha: 1)
    static let handleFill = NSColor.white
    static let handleSize: CGFloat = 8
    /// 框选描边（加粗 1pt：原 1.5 → 2.5）
    static let borderWidth: CGFloat = 2.5
    static let labelBG = NSColor.black.withAlphaComponent(0.75)
    static let labelFG = NSColor.white
    static let toolbarBG = AppTheme.nsCaptureBarBackground.withAlphaComponent(0.92)
    /// 操作提示卡片底色（可四角避让）
    static let helpBG = NSColor(calibratedWhite: 0.10, alpha: 0.82)
}
