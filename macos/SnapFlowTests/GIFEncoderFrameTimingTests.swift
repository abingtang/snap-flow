import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SnapFlow

/// GIF 导出必须在源帧率非整除目标帧率时仍保持真实时长。
final class GIFEncoderFrameTimingTests: XCTestCase {
    private func makePixelBuffer(width: Int = 4, height: Int = 4) -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        guard let buffer = pixelBuffer else { fatalError("pixelBuffer was nil") }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0xFF, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func totalDuration(targetFPS: Int, sourceFPS: Int, frames: Int) -> Double {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapflow-gif-timing-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder = GIFEncoder(url: url, fps: targetFPS, sourceFPS: sourceFPS)
        for _ in 0..<frames {
            encoder.addFrame(makePixelBuffer())
        }
        XCTAssertTrue(encoder.finish())

        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            XCTFail("Could not open GIF")
            return 0
        }
        var total: Double = 0
        let count = CGImageSourceGetCount(imageSource)
        for index in 0..<count {
            guard
                let props = CGImageSourceCopyPropertiesAtIndex(imageSource, index, nil) as? [CFString: Any],
                let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            else { continue }
            let delay = (gif[kCGImagePropertyGIFDelayTime] as? Double)
                ?? (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? 0
            total += delay
        }
        return total
    }

    func testNonMultipleSourceFrameRatePlaysInRealTime() {
        let total = totalDuration(targetFPS: 15, sourceFPS: 24, frames: 24)
        XCTAssertEqual(total, 1.0, accuracy: 0.1)
    }

    func testMultipleSourceFrameRateStaysInRealTime() {
        let total = totalDuration(targetFPS: 15, sourceFPS: 30, frames: 30)
        XCTAssertEqual(total, 1.0, accuracy: 0.1)
    }

    func testDelayUsesKeepEveryOverSourceFPS() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapflow-gif-delay-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoder = GIFEncoder(url: url, fps: 15, sourceFPS: 30)
        XCTAssertEqual(encoder.delayTimeSeconds, 2.0 / 30.0, accuracy: 0.0001)
    }
}

final class RecordingFilenameTemplateTests: XCTestCase {
    func testDefaultTemplateRendersDateAndTime() {
        let date = Date(timeIntervalSince1970: 1_700_000_000) // fixed
        let name = RecordingFilenameTemplate.render(
            template: RecordingFilenameTemplate.defaultTemplate,
            fileExtension: "mp4",
            date: date,
            counter: 1
        )
        XCTAssertTrue(name.hasPrefix("SnapFlow-rec-"))
        XCTAssertTrue(name.hasSuffix(".mp4"))
        XCTAssertFalse(name.contains("{"))
    }

    func testUnknownTokensStayLiteralAndIllegalCharactersSanitized() {
        let name = RecordingFilenameTemplate.render(
            template: "Snap/{type}?{bogus}",
            fileExtension: "mp4",
            date: Date(),
            counter: 3,
            typeToken: "recording"
        )
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains("?"))
        XCTAssertTrue(name.contains("recording"))
        XCTAssertTrue(name.contains("bogus"))
        XCTAssertTrue(name.hasSuffix(".mp4"))
    }

    func testCounterAndRandTokens() {
        let base = RecordingFilenameTemplate.renderBase(
            template: "rec-{counter:3}-{rand:4}",
            date: Date(),
            counter: 7,
            typeToken: "recording"
        )
        XCTAssertTrue(base.contains("007") || base.contains("7"))
        let parts = base.split(separator: "-")
        XCTAssertGreaterThanOrEqual(parts.count, 2)
    }
}
