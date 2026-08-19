import AVFoundation
import CoreVideo
import ImageIO
import XCTest
@testable import SnapFlow

/// GIF 导出使用时间戳采样，并以每帧自适应调色板控制画质和有界内存。
final class GIFEncoderFrameTimingTests: XCTestCase {
    private func makePixelBuffer(
        width: Int = 4,
        height: Int = 4,
        patterned: Bool = false
    ) -> CVPixelBuffer {
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
            if patterned {
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                for y in 0..<height {
                    for x in 0..<width {
                        let offset = y * bytesPerRow + x * 4
                        bytes[offset] = UInt8((x * 17 + y * 29) & 0xFF)
                        bytes[offset + 1] = UInt8((x * 31 + y * 13) & 0xFF)
                        bytes[offset + 2] = UInt8((x * 7 + y * 47) & 0xFF)
                    }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func makeGIF(frameCount: Int, delayTime: TimeInterval) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapflow-gif-timing-\(UUID().uuidString).gif")

        let encoder = GIFEncoder(url: url, fps: 8)
        for _ in 0..<frameCount {
            XCTAssertTrue(encoder.addFrame(makePixelBuffer(), delayTime: delayTime))
        }
        XCTAssertTrue(encoder.finish())
        return url
    }

    private func totalDuration(of url: URL) -> (frameCount: Int, duration: Double) {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            XCTFail("Could not open GIF")
            return (0, 0)
        }
        var total: Double = 0
        let count = CGImageSourceGetCount(imageSource)
        for index in 0..<count {
            guard
                let props = CGImageSourceCopyPropertiesAtIndex(imageSource, index, nil) as? [CFString: Any],
                let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            else { continue }
            let delay = (gif[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
                ?? (gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                ?? 0
            total += delay
        }
        return (count, total)
    }

    private func makeTestVideo(
        frameCount: Int = 8,
        fps: Int32 = 8,
        endTime: CMTime? = nil
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapflow-exporter-input-(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 16,
                AVVideoHeightKey: 16,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 200_000,
                    AVVideoExpectedSourceFrameRateKey: fps,
                ],
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 16,
                kCVPixelBufferHeightKey as String: 16,
            ]
        )
        guard writer.canAdd(input) else { throw TestError.writerSetupFailed }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? TestError.writerSetupFailed
        }
        writer.startSession(atSourceTime: .zero)

        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
            let time = CMTime(value: Int64(index), timescale: fps)
            guard adaptor.append(makePixelBuffer(width: 16, height: 16, patterned: true), withPresentationTime: time) else {
                throw writer.error ?? TestError.writerFailed
            }
        }
        input.markAsFinished()
        if let endTime {
            writer.endSession(atSourceTime: endTime)
        }

        let finished = expectation(description: "test video finished")
        writer.finishWriting { finished.fulfill() }
        wait(for: [finished], timeout: 5)
        guard writer.status == .completed else {
            throw writer.error ?? TestError.writerFailed
        }
        return url
    }

    private enum TestError: Error {
        case writerSetupFailed
        case writerFailed
    }

    func testOutputDimensionsMatchVideoPixelCap() {
        let landscape = GIFEncoder.outputDimensions(width: 1_920, height: 1_080)
        XCTAssertEqual(landscape.width, 1_920)
        XCTAssertEqual(landscape.height, 1_080)

        let portrait = GIFEncoder.outputDimensions(width: 1_080, height: 1_920)
        XCTAssertEqual(portrait.width, 607)
        XCTAssertEqual(portrait.height, 1_080)

        let fourK = GIFEncoder.outputDimensions(width: 3_840, height: 2_160)
        XCTAssertEqual(fourK.width, 1_920)
        XCTAssertEqual(fourK.height, 1_080)

        let small = GIFEncoder.outputDimensions(width: 800, height: 600)
        XCTAssertEqual(small.width, 800)
        XCTAssertEqual(small.height, 600)
    }

    func testTimestampSamplerKeepsOneSecondAtCommonSourceFrameRates() {
        for sourceFPS in [24, 30, 60] {
            var sampler = GIFFrameSampler(duration: 1.0, fps: 8)
            var delays: [Double] = []
            for frame in 0..<sourceFPS {
                let timestamp = Double(frame) / Double(sourceFPS)
                if let delay = sampler.delay(for: timestamp) {
                    delays.append(delay)
                }
            }

            XCTAssertEqual(delays.count, 8, "sourceFPS=\(sourceFPS)")
            XCTAssertEqual(delays.reduce(0, +), 1.0, accuracy: 0.01)
            XCTAssertTrue(sampler.isComplete)
        }
    }

    func testStreamingGIFCanBeDecodedAndKeepsDuration() {
        let url = makeGIF(frameCount: 8, delayTime: 0.125)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = totalDuration(of: url)
        XCTAssertEqual(result.frameCount, 8)
        XCTAssertEqual(result.duration, 1.0, accuracy: 0.1)
    }

    func testStreamingGIFKeepsVideoMaximumFrameSize() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapflow-gif-size-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder = GIFEncoder(url: url, fps: 8)
        XCTAssertTrue(encoder.addFrame(makePixelBuffer(width: 1_920, height: 1_080)))
        XCTAssertTrue(encoder.finish())

        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
                as? [CFString: Any]
        else {
            XCTFail("Could not read GIF properties")
            return
        }
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 1_920)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 1_080)
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
    }

    func testStreamingGIFUsesAdaptive256ColorLocalPalette() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapflow-gif-palette-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder = GIFEncoder(url: url, fps: 8)
        XCTAssertTrue(encoder.addFrame(makePixelBuffer(width: 96, height: 96, patterned: true)))
        XCTAssertTrue(encoder.finish())

        let data = try Data(contentsOf: url)
        guard let descriptorIndex = data.dropFirst(13).firstIndex(of: 0x2C) else {
            XCTFail("Could not find GIF image descriptor")
            return
        }
        let descriptorOffset = data.distance(from: data.startIndex, to: descriptorIndex)
        let packedFields = data[descriptorOffset + 9]
        XCTAssertEqual(packedFields & 0x80, 0x80)
        XCTAssertEqual(packedFields & 0x07, 0x07)
        XCTAssertEqual(data[descriptorOffset + 10 + 256 * 3], 8)
    }

    func testStreamingGIFHandlesDictionaryReset() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapflow-gif-lzw-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder = GIFEncoder(url: url, fps: 8)
        XCTAssertTrue(encoder.addFrame(makePixelBuffer(width: 96, height: 96, patterned: true)))
        XCTAssertTrue(encoder.finish())

        let result = totalDuration(of: url)
        XCTAssertEqual(result.frameCount, 1)
        XCTAssertEqual(result.duration, 0.12, accuracy: 0.01)

        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else {
            XCTFail("Could not decode GIF pixels")
            return
        }
        XCTAssertEqual(image.width, 96)
        XCTAssertEqual(image.height, 96)
    }

    func testGIFExportLeavesOnlyCompletedDestinationAfterStreaming() throws {
        let videoURL = try makeTestVideo()
        let gifURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapflow-exporter-output-(UUID().uuidString).gif")
        defer {
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: gifURL)
            try? FileManager.default.removeItem(at: gifURL.appendingPathExtension("part"))
        }

        try RecordingExporter.exportGIFSynchronously(from: videoURL, to: gifURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: gifURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gifURL.appendingPathExtension("part").path))
        let result = totalDuration(of: gifURL)
        XCTAssertEqual(result.frameCount, 8)
        XCTAssertEqual(result.duration, 1.0, accuracy: 0.15)
    }

    func testGIFExportAcceptsNaturalEndWhenTrackDurationSlightlyExceedsLastFrame() throws {
        let videoURL = try makeTestVideo(
            frameCount: 8,
            fps: 8,
            endTime: CMTime(value: 1_001, timescale: 1_000)
        )
        let gifURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapflow-exporter-boundary-(UUID().uuidString).gif")
        defer {
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: gifURL)
            try? FileManager.default.removeItem(at: gifURL.appendingPathExtension("part"))
        }

        try RecordingExporter.exportGIFSynchronously(from: videoURL, to: gifURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: gifURL.path))
        let result = totalDuration(of: gifURL)
        XCTAssertEqual(result.frameCount, 8)
        XCTAssertEqual(result.duration, 1.0, accuracy: 0.15)
    }

    func testGIFExportPreflightRejectsMissingInput() {
        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapflow-missing-(UUID().uuidString).mp4")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapflow-missing-output-(UUID().uuidString).gif")

        XCTAssertThrowsError(try RecordingExporter.preflightGIF(from: inputURL, to: outputURL)) { error in
            XCTAssertEqual(error as? RecordingExporter.ExportError, .inputFileMissing)
        }
    }

    func testGIFExportPreflightReportsBoundedPlan() throws {
        let videoURL = try makeTestVideo()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapflow-preflight-\(UUID().uuidString).gif")
        defer {
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        let plan = try RecordingExporter.preflightGIF(from: videoURL, to: outputURL)

        XCTAssertEqual(plan.duration, 1.0, accuracy: 0.15)
        XCTAssertEqual(plan.targetFrameCount, 8)
        XCTAssertEqual(plan.outputWidth, 16)
        XCTAssertEqual(plan.outputHeight, 16)
        XCTAssertLessThanOrEqual(plan.outputWidth, 1_920)
        XCTAssertLessThanOrEqual(plan.outputHeight, 1_080)
        XCTAssertLessThanOrEqual(
            plan.estimatedWorkingSetBytes,
            RecordingExporter.maximumGIFWorkingSetBytes
        )
        XCTAssertGreaterThan(plan.estimatedOutputBytes, 0)
    }

    func testGIFExportFailureKeepsExistingDestinationAndCleansPart() throws {
        let videoURL = try makeTestVideo()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapflow-existing-\(UUID().uuidString).gif")
        let existingData = Data("existing destination".utf8)
        try existingData.write(to: outputURL)
        defer {
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: outputURL.appendingPathExtension("part"))
        }

        XCTAssertThrowsError(
            try RecordingExporter.exportGIFSynchronously(from: videoURL, to: outputURL)
        ) { error in
            XCTAssertEqual(error as? RecordingExporter.ExportError, .destinationAlreadyExists)
        }
        XCTAssertEqual(try Data(contentsOf: outputURL), existingData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.appendingPathExtension("part").path))
    }

    func testCancelledGIFExportStopsBeforeReadingInput() {
        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapflow-cancelled-(UUID().uuidString).mp4")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapflow-cancelled-output-(UUID().uuidString).gif")
        let session = RecordingExporter.GIFExportSession()
        session.cancel()

        XCTAssertThrowsError(
            try RecordingExporter.exportGIFSynchronously(
                from: inputURL,
                to: outputURL,
                session: session
            )
        ) { error in
            XCTAssertEqual(error as? RecordingExporter.ExportError, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.appendingPathExtension("part").path))
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
