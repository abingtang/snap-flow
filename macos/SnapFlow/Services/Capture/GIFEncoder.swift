import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 将视频帧编码为无限循环 GIF；目标 15 FPS，按源帧率抽帧并写入正确 delay。
final class GIFEncoder {
    private let url: URL
    private let targetFPS: Int
    private let sourceEstimatedFPS: Int
    private let keepEvery: Int
    private let frameProperties: [CFString: Any]
    private let gifProperties: [CFString: Any]
    private var destination: CGImageDestination?
    private var inputFrameCount = 0
    private var frameCount = 0
    private let lock = NSLock()

    /// 测试与诊断：每个保留帧的 delay（秒）= keepEvery / sourceFPS。
    var delayTimeSeconds: Float {
        Float(keepEvery) / Float(sourceEstimatedFPS)
    }

    var keptFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return frameCount
    }

    init(url: URL, fps: Int = 15, sourceFPS: Int) {
        self.url = url
        self.targetFPS = min(max(fps, 1), 15)
        self.sourceEstimatedFPS = max(sourceFPS, self.targetFPS)
        self.keepEvery = max(1, self.sourceEstimatedFPS / self.targetFPS)

        // 每个保留帧覆盖 keepEvery 个源帧，delay 为 keepEvery/sourceFPS，
        // 而非固定 1/targetFPS，否则非整除源帧率会放慢播放。
        let delayTime = Float(self.keepEvery) / Float(self.sourceEstimatedFPS)
        frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delayTime,
                kCGImagePropertyGIFLoopCount: 0,
            ] as [CFString: Any],
        ]
        gifProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0,
            ] as [CFString: Any],
        ]

        destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.gif.identifier as CFString,
            Int.max,
            nil
        )
        if let destination {
            CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)
        }
    }

    func addFrame(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        defer { lock.unlock() }

        inputFrameCount += 1
        guard (inputFrameCount - 1) % keepEvery == 0 else { return }
        guard let destination else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return }

        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let sourceContext = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ), let sourceImage = sourceContext.makeImage() else {
            return
        }

        guard let ownedContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return }
        ownedContext.draw(sourceImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let ownedImage = ownedContext.makeImage() else { return }

        CGImageDestinationAddImage(destination, ownedImage, frameProperties as CFDictionary)
        frameCount += 1
    }

    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let destination, frameCount > 0 else { return false }
        let ok = CGImageDestinationFinalize(destination)
        self.destination = nil
        return ok
    }
}
