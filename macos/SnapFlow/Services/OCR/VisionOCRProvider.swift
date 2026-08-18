import CoreGraphics
import Foundation

/// 包装现有 Vision `OCRService`。
struct VisionOCRProvider: OCRProvider {
    let serviceID: String
    let kind: OCRServiceKind = .vision
    private let engine: OCRService

    init(serviceID: String = OCRServiceEntry.visionID, engine: OCRService = OCRService()) {
        self.serviceID = serviceID
        self.engine = engine
    }

    func recognize(
        _ image: CGImage,
        languages: [String]?,
        entry: OCRServiceEntry
    ) async throws -> [OCRLine] {
        try await engine.recognize(image, languages: languages)
    }
}
