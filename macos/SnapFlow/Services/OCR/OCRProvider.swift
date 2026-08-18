import CoreGraphics
import Foundation

/// 单个 OCR 后端。
protocol OCRProvider: Sendable {
    var serviceID: String { get }
    var kind: OCRServiceKind { get }

    func recognize(
        _ image: CGImage,
        languages: [String]?,
        entry: OCRServiceEntry
    ) async throws -> [OCRLine]
}
