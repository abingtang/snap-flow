import CoreGraphics
import Foundation

/// 单行 OCR 结果。`boundingBox` 使用**图像像素坐标**，原点在左上，y 向下。
struct OCRLine: Identifiable, Sendable, Hashable {
    let id: UUID
    let text: String
    let boundingBox: CGRect
    let confidence: Float

    init(
        id: UUID = UUID(),
        text: String,
        boundingBox: CGRect,
        confidence: Float
    ) {
        self.id = id
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
}

struct OverlayLine: Identifiable, Sendable, Hashable {
    let id: UUID
    let source: String
    let translated: String
    let boundingBox: CGRect
}

/// 区域选取结果：屏幕全局点坐标（AppKit，原点左下）与所属 display。
struct CaptureRegion: Sendable, Hashable {
    /// 全局屏幕坐标（points，AppKit：原点在主屏左下）
    let rectInScreenPoints: CGRect
    let displayID: CGDirectDisplayID
    let scaleFactor: CGFloat
}
