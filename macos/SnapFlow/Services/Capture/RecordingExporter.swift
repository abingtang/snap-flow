import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// MP4 → GIF 导出；整段视频、原像素尺寸、固定 15 FPS、无限循环、无音频。
enum RecordingExporter {
    static let gifFrameRate = 15

    static func exportGIF(
        from videoURL: URL,
        to destinationURL: URL,
        fps: Int = gifFrameRate
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try exportGIFSynchronously(from: videoURL, to: destinationURL, fps: fps)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func exportGIFSynchronously(
        from videoURL: URL,
        to destinationURL: URL,
        fps: Int = gifFrameRate
    ) throws {
        do {
            try? FileManager.default.removeItem(at: destinationURL)

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

            let sourceFPS = normalizedSourceFPS(videoTrack.nominalFrameRate)
            let encoder = GIFEncoder(url: destinationURL, fps: fps, sourceFPS: sourceFPS)

            guard reader.startReading() else {
                throw reader.error ?? ExportError.readerFailed
            }

            var frameCount = 0
            while reader.status == .reading {
                guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
                encoder.addFrame(pixelBuffer)
                frameCount += 1
            }

            if reader.status == .failed || reader.status == .cancelled {
                throw reader.error ?? ExportError.readerFailed
            }
            guard frameCount > 0 else {
                throw ExportError.noFrames
            }
            guard encoder.finish() else {
                throw ExportError.gifFinalizeFailed
            }
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    static func normalizedSourceFPS(_ nominalFrameRate: Float) -> Int {
        let rounded = Int(nominalFrameRate.rounded())
        return rounded > 0 ? rounded : ScreenRecordingConfiguration.frameRate
    }

    enum ExportError: LocalizedError {
        case missingVideoTrack
        case readerSetupFailed
        case readerFailed
        case noFrames
        case gifFinalizeFailed

        var errorDescription: String? {
            switch self {
            case .missingVideoTrack:
                return L10n.string("录制文件没有视频轨道，无法导出 GIF")
            case .readerSetupFailed:
                return L10n.string("无法准备 GIF 导出")
            case .readerFailed:
                return L10n.string("读取录制帧失败")
            case .noFrames:
                return L10n.string("没有可用的视频帧可导出为 GIF")
            case .gifFinalizeFailed:
                return L10n.string("无法完成 GIF 写入")
            }
        }
    }
}
