import CoreGraphics
import Foundation

protocol ScreenCapturing: Sendable {
    func capture(region: CaptureRegion) async throws -> CGImage
}

protocol TextRecognizing: Sendable {
    func recognize(_ image: CGImage, languages: [String]?) async throws -> [OCRLine]
}

@MainActor
protocol Translating: AnyObject {
    /// - Parameters:
    ///   - sourceLanguage: 覆盖源语（`auto` 或 BCP-47）；`nil` 用设置
    ///   - targetLanguage: 覆盖目标（`system` 或 BCP-47）；`nil` 用设置
    func translate(
        _ texts: [String],
        sourceLanguage: String?,
        targetLanguage: String?
    ) async throws -> TranslationResult
}

extension Translating {
    func translate(_ texts: [String]) async throws -> TranslationResult {
        try await translate(texts, sourceLanguage: nil, targetLanguage: nil)
    }
}

protocol TextSelecting: Sendable {
    func selectedText() async -> String?
}
