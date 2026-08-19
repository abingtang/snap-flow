import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// MP4 → GIF 导出；整段视频、最大尺寸 1920×1080、固定 8 FPS、每帧 256 色、无限循环、无音频。
enum RecordingExporter {
    static let gifFrameRate = 8
    static let maximumGIFWorkingSetBytes: Int64 = 512 * 1024 * 1024
    static let minimumFreeSpaceBytes: Int64 = 512 * 1024 * 1024

    struct GIFExportProgress: Equatable, Sendable {
        let completedFrameCount: Int
        let totalFrameCount: Int

        var fractionCompleted: Double {
            guard totalFrameCount > 0 else { return 0 }
            return min(max(Double(completedFrameCount) / Double(totalFrameCount), 0), 1)
        }
    }

    struct GIFExportPlan: Equatable, Sendable {
        let duration: TimeInterval
        let sourceWidth: Int
        let sourceHeight: Int
        let outputWidth: Int
        let outputHeight: Int
        let targetFrameCount: Int
        let estimatedWorkingSetBytes: Int64
        let estimatedOutputBytes: Int64
    }

    /// 线程安全的导出控制器；取消只影响 GIF 临时文件，不删除源 MP4。
    final class GIFExportSession: @unchecked Sendable {
        private let lock = NSLock()
        private var cancellationRequested = false
        private var currentProgress = GIFExportProgress(completedFrameCount: 0, totalFrameCount: 0)

        var progress: GIFExportProgress {
            lock.lock()
            defer { lock.unlock() }
            return currentProgress
        }

        func cancel() {
            lock.lock()
            cancellationRequested = true
            lock.unlock()
        }

        fileprivate var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancellationRequested
        }

        fileprivate func setPlan(_ plan: GIFExportPlan) {
            lock.lock()
            currentProgress = GIFExportProgress(
                completedFrameCount: 0,
                totalFrameCount: plan.targetFrameCount
            )
            lock.unlock()
        }

        fileprivate func update(completedFrameCount: Int) {
            lock.lock()
            currentProgress = GIFExportProgress(
                completedFrameCount: completedFrameCount,
                totalFrameCount: currentProgress.totalFrameCount
            )
            lock.unlock()
        }

        fileprivate func checkCancellation() throws {
            if isCancelled {
                throw ExportError.cancelled
            }
        }
    }

    static func exportGIF(
        from videoURL: URL,
        to destinationURL: URL,
        fps: Int = gifFrameRate,
        session: GIFExportSession? = nil
    ) async throws {
        let session = session ?? GIFExportSession()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try exportGIFSynchronously(
                            from: videoURL,
                            to: destinationURL,
                            fps: fps,
                            session: session
                        )
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: {
            session.cancel()
        })
    }

    static func preflightGIF(
        from videoURL: URL,
        to destinationURL: URL,
        fps: Int = gifFrameRate
    ) throws -> GIFExportPlan {
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            throw ExportError.inputFileMissing
        }
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw ExportError.destinationAlreadyExists
        }

        let destinationDirectory = destinationURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: destinationDirectory.path) else {
            throw ExportError.outputDirectoryUnavailable
        }

        let asset = AVURLAsset(url: videoURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw ExportError.missingVideoTrack
        }

        let duration = videoDurationSeconds(asset: asset, track: videoTrack)
        guard duration > 0 else {
            throw ExportError.invalidVideoDuration
        }

        guard let sourceDimensions = videoPixelDimensions(for: videoTrack) else {
            throw ExportError.invalidVideoDimensions
        }
        let outputDimensions = GIFEncoder.outputDimensions(
            width: sourceDimensions.width,
            height: sourceDimensions.height
        )
        let targetFrameCount = try targetFrameCount(for: duration, fps: fps)
        let estimatedWorkingSetBytes = try estimatedWorkingSetBytes(
            sourceWidth: sourceDimensions.width,
            sourceHeight: sourceDimensions.height,
            outputWidth: outputDimensions.width,
            outputHeight: outputDimensions.height
        )
        let estimatedOutputBytes = try estimatedOutputBytes(
            width: outputDimensions.width,
            height: outputDimensions.height,
            frameCount: targetFrameCount
        )

        guard estimatedWorkingSetBytes <= maximumGIFWorkingSetBytes else {
            throw ExportError.resourceLimitExceeded
        }

        let values = try destinationDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let availableCapacity = values.volumeAvailableCapacityForImportantUsage else {
            throw ExportError.diskSpaceUnavailable
        }
        let requiredCapacity = try checkedSum(estimatedOutputBytes, minimumFreeSpaceBytes)
        guard availableCapacity >= requiredCapacity else {
            throw ExportError.insufficientDiskSpace
        }

        return GIFExportPlan(
            duration: duration,
            sourceWidth: sourceDimensions.width,
            sourceHeight: sourceDimensions.height,
            outputWidth: outputDimensions.width,
            outputHeight: outputDimensions.height,
            targetFrameCount: targetFrameCount,
            estimatedWorkingSetBytes: estimatedWorkingSetBytes,
            estimatedOutputBytes: estimatedOutputBytes
        )
    }

    static func exportGIFSynchronously(
        from videoURL: URL,
        to destinationURL: URL,
        fps: Int = gifFrameRate,
        session: GIFExportSession? = nil
    ) throws {
        let session = session ?? GIFExportSession()
        let partURL = destinationURL.appendingPathExtension("part")

        do {
            try session.checkCancellation()
            let plan = try preflightGIF(from: videoURL, to: destinationURL, fps: fps)
            session.setPlan(plan)
            try session.checkCancellation()
            try? FileManager.default.removeItem(at: partURL)

            let asset = AVURLAsset(url: videoURL)
            guard let videoTrack = asset.tracks(withMediaType: .video).first else {
                throw ExportError.missingVideoTrack
            }

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: videoTrack,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                ]
            )
            output.alwaysCopiesSampleData = false

            guard reader.canAdd(output) else {
                throw ExportError.readerSetupFailed
            }
            reader.add(output)

            let encoder = GIFEncoder(url: partURL, fps: fps)
            var sampler = GIFFrameSampler(duration: plan.duration, fps: fps)

            guard reader.startReading() else {
                throw reader.error ?? ExportError.readerFailed
            }

            var firstPresentationTime: TimeInterval?
            var reachedInputEnd = false
            var frameWriteFailed = false
            while reader.status == .reading, !sampler.isComplete {
                try session.checkCancellation()
                reachedInputEnd = false
                autoreleasepool {
                    guard let sampleBuffer = output.copyNextSampleBuffer() else {
                        reachedInputEnd = true
                        return
                    }
                    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                        return
                    }

                    let presentationTime = CMTimeGetSeconds(
                        CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    )
                    guard presentationTime.isFinite else { return }
                    if firstPresentationTime == nil {
                        firstPresentationTime = presentationTime
                    }
                    guard let firstPresentationTime else { return }

                    let relativeTime = max(0, presentationTime - firstPresentationTime)
                    guard let delayTime = sampler.delay(for: relativeTime) else { return }
                    if !encoder.addFrame(pixelBuffer, delayTime: delayTime) {
                        frameWriteFailed = true
                    } else {
                        session.update(completedFrameCount: sampler.keptFrameCount)
                    }
                }

                if frameWriteFailed {
                    throw ExportError.gifFrameWriteFailed
                }
                if reachedInputEnd {
                    break
                }
            }

            try session.checkCancellation()
            if reader.status == .failed || reader.status == .cancelled {
                throw reader.error ?? ExportError.readerFailed
            }
            // 合法 MP4 的最后一帧可能已经覆盖轨道剩余时长，但时间戳采样器
            // 仍会按 ceil(duration * fps) 等待一个不存在的目标帧。Reader
            // 已正常完成且至少读到一帧时，应接受这个自然 EOF；真正的 failed/
            // cancelled 仍在上面报错。
            let reachedNaturalEnd = reachedInputEnd && reader.status == .completed
            if reachedInputEnd, !sampler.isComplete, !reachedNaturalEnd {
                throw ExportError.incompleteVideoFrames
            }
            guard sampler.keptFrameCount > 0 else {
                throw ExportError.noFrames
            }
            guard sampler.isComplete || reachedNaturalEnd else {
                throw ExportError.incompleteVideoFrames
            }
            guard encoder.finish() else {
                throw ExportError.gifFinalizeFailed
            }
            try session.checkCancellation()
            try FileManager.default.moveItem(at: partURL, to: destinationURL)
        } catch {
            try? FileManager.default.removeItem(at: partURL)
            throw error
        }
    }

    static func videoDurationSeconds(asset: AVAsset, track: AVAssetTrack) -> TimeInterval {
        let trackDuration = CMTimeGetSeconds(track.timeRange.duration)
        if trackDuration.isFinite, trackDuration > 0 {
            return trackDuration
        }

        let assetDuration = CMTimeGetSeconds(asset.duration)
        return assetDuration.isFinite ? max(assetDuration, 0) : 0
    }

    private static func videoPixelDimensions(for track: AVAssetTrack) -> (width: Int, height: Int)? {
        let naturalSize = track.naturalSize
        let transformedRect = CGRect(origin: .zero, size: naturalSize)
            .applying(track.preferredTransform)
            .standardized
        let width = Int(abs(transformedRect.width).rounded(.up))
        let height = Int(abs(transformedRect.height).rounded(.up))
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }

    private static func targetFrameCount(for duration: TimeInterval, fps: Int) throws -> Int {
        let normalizedFPS = min(max(fps, 1), gifFrameRate)
        let rawCount = duration * Double(normalizedFPS)
        guard rawCount.isFinite, rawCount <= Double(Int.max) else {
            throw ExportError.resourceLimitExceeded
        }
        return max(1, Int(ceil(rawCount)))
    }

    private static func estimatedWorkingSetBytes(
        sourceWidth: Int,
        sourceHeight: Int,
        outputWidth: Int,
        outputHeight: Int
    ) throws -> Int64 {
        let sourceBytes = try checkedProduct(
            Int64(sourceWidth),
            Int64(sourceHeight),
            4
        )
        let outputBytes = try checkedProduct(
            Int64(outputWidth),
            Int64(outputHeight)
        )
        return try checkedSum(sourceBytes, outputBytes, 16 * 1024 * 1024)
    }

    private static func estimatedOutputBytes(
        width: Int,
        height: Int,
        frameCount: Int
    ) throws -> Int64 {
        let pixels = try checkedProduct(Int64(width), Int64(height))
        return try checkedSum(
            try checkedProduct(pixels, Int64(frameCount), 2),
            64 * 1024
        )
    }

    private static func checkedProduct(_ values: Int64...) throws -> Int64 {
        var result: Int64 = 1
        for value in values {
            let multiplication = result.multipliedReportingOverflow(by: value)
            guard !multiplication.overflow else {
                throw ExportError.resourceLimitExceeded
            }
            result = multiplication.partialValue
        }
        return result
    }

    private static func checkedSum(_ values: Int64...) throws -> Int64 {
        var result: Int64 = 0
        for value in values {
            let addition = result.addingReportingOverflow(value)
            guard !addition.overflow else {
                throw ExportError.resourceLimitExceeded
            }
            result = addition.partialValue
        }
        return result
    }

    enum ExportError: LocalizedError, Equatable {
        case inputFileMissing
        case destinationAlreadyExists
        case outputDirectoryUnavailable
        case missingVideoTrack
        case invalidVideoDuration
        case invalidVideoDimensions
        case readerSetupFailed
        case readerFailed
        case noFrames
        case incompleteVideoFrames
        case gifFrameWriteFailed
        case gifFinalizeFailed
        case cancelled
        case resourceLimitExceeded
        case diskSpaceUnavailable
        case insufficientDiskSpace

        var errorDescription: String? {
            switch self {
            case .inputFileMissing:
                return L10n.string("录制文件不存在，无法导出 GIF")
            case .destinationAlreadyExists:
                return L10n.string("GIF 输出文件已存在，未覆盖原文件")
            case .outputDirectoryUnavailable:
                return L10n.string("GIF 输出目录不可用")
            case .missingVideoTrack:
                return L10n.string("录制文件没有视频轨道，无法导出 GIF")
            case .invalidVideoDuration:
                return L10n.string("录制文件时长无效，无法导出 GIF")
            case .invalidVideoDimensions:
                return L10n.string("录制文件尺寸无效，无法导出 GIF")
            case .readerSetupFailed:
                return L10n.string("无法准备 GIF 导出")
            case .readerFailed:
                return L10n.string("读取录制帧失败")
            case .noFrames:
                return L10n.string("没有可用的视频帧可导出为 GIF")
            case .incompleteVideoFrames:
                return L10n.string("视频帧读取不完整，已停止 GIF 导出")
            case .gifFrameWriteFailed:
                return L10n.string("无法写入 GIF 视频帧")
            case .gifFinalizeFailed:
                return L10n.string("无法完成 GIF 写入")
            case .cancelled:
                return L10n.string("已取消 GIF 导出")
            case .resourceLimitExceeded:
                return L10n.string("GIF 导出预计占用资源过大，已保留 MP4")
            case .diskSpaceUnavailable:
                return L10n.string("无法检查 GIF 导出所需磁盘空间")
            case .insufficientDiskSpace:
                return L10n.string("磁盘空间不足，无法导出 GIF")
            }
        }
    }
}

/// 按时间戳选择 GIF 帧，并把总时长分配到固定帧率的 GIF 延迟中。
struct GIFFrameSampler {
    let targetFPS: Int
    let duration: TimeInterval
    let expectedFrameCount: Int

    private let frameDuration: TimeInterval
    private var nextTargetTime: TimeInterval = 0
    private(set) var keptFrameCount = 0

    var isComplete: Bool {
        keptFrameCount >= expectedFrameCount
    }

    init(duration: TimeInterval, fps: Int = RecordingExporter.gifFrameRate) {
        let normalizedFPS = min(max(fps, 1), 8)
        let normalizedDuration = duration.isFinite ? max(duration, 0) : 0
        targetFPS = normalizedFPS
        self.duration = normalizedDuration
        frameDuration = 1.0 / Double(normalizedFPS)
        expectedFrameCount = max(
            1,
            Int(ceil(normalizedDuration * Double(normalizedFPS)))
        )
    }

    mutating func delay(for relativePresentationTime: TimeInterval) -> TimeInterval? {
        guard relativePresentationTime.isFinite, !isComplete else { return nil }
        guard relativePresentationTime + 0.000001 >= nextTargetTime else { return nil }

        let remaining = duration - Double(keptFrameCount) * frameDuration
        guard remaining > 0 else { return nil }

        let delay = max(0.01, min(frameDuration, remaining))
        keptFrameCount += 1
        nextTargetTime = Double(keptFrameCount) * frameDuration
        return delay
    }
}
