import AppKit
import CoreGraphics
import Foundation
import Vision
@preconcurrency import ScreenCaptureKit

enum ScrollCaptureError: Error, LocalizedError, Equatable {
    case cancelled
    case captureFailed
    case empty

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return L10n.string("已取消滚动截屏")
        case .captureFailed:
            return L10n.string("滚动截屏采集失败")
        case .empty:
            return L10n.string("未采集到有效画面")
        }
    }
}

/// 滚动截屏专用的短生命周期采集会话。
///
/// 普通截图每次请求都会重新创建 ScreenCaptureKit 对象；滚动截屏则在一次
/// 会话中固定显示器、选区和排除窗口，复用过滤器与配置以支持连续采样。
final class ScrollCaptureSession: @unchecked Sendable {
    private let region: CaptureRegion
    private var cachedFilter: SCContentFilter?
    private var cachedStreamConfig: SCStreamConfiguration?

    init(region: CaptureRegion) {
        self.region = region
    }

    func captureFrame() async throws -> CGImage {
        let rect = region.rectInScreenPoints
        guard rect.width >= 1, rect.height >= 1 else {
            throw ScreenCaptureError.invalidRegion
        }

        if cachedFilter == nil || cachedStreamConfig == nil {
            try await prepareCaptureConfiguration()
        }

        guard let filter = cachedFilter, let configuration = cachedStreamConfig else {
            throw ScreenCaptureError.captureFailed
        }

        return try await withThrowingTaskGroup(of: CGImage.self) { group in
            group.addTask {
                do {
                    return try await SCScreenshotManager.captureImage(
                        contentFilter: filter,
                        configuration: configuration
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    NSLog("[SnapFlow] scroll ScreenCaptureKit error: \(error)")
                    throw ScreenCaptureError.captureFailed
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                throw ScreenCaptureError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func prepareCaptureConfiguration() async throws {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let display = content.displays.first(where: {
                $0.displayID == region.displayID
            }) ?? content.displays.first else {
                throw ScreenCaptureError.noDisplay
            }

            let bundleID = Bundle.main.bundleIdentifier
            let excludedWindows = bundleID.map { id in
                content.windows.filter {
                    $0.owningApplication?.bundleIdentifier == id
                }
            } ?? []
            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            let configuration = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            let displayBounds = ScreenGeometry.displayBoundsInAppKitPoints(
                displayID: display.displayID
            )
            let sourceRect = ScreenGeometry.appKitGlobalRectToDisplayLocal(
                region.rectInScreenPoints,
                displayBounds: displayBounds
            )

            configuration.captureResolution = .best
            configuration.showsCursor = false
            configuration.scalesToFit = false
            configuration.sourceRect = sourceRect
            configuration.width = max(
                Int((region.rectInScreenPoints.width * scale).rounded()),
                1
            )
            configuration.height = max(
                Int((region.rectInScreenPoints.height * scale).rounded()),
                1
            )

            cachedFilter = filter
            cachedStreamConfig = configuration
        } catch let error as ScreenCaptureError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            NSLog("[SnapFlow] prepare scroll capture failed: \(error)")
            throw ScreenCaptureError.captureFailed
        }
    }
}

/// 对连续帧执行 Capso 风格的最小过滤：原始像素完全相同则跳过。
struct ScrollCaptureFrameMatcher {
    static func isByteIdentical(_ lhs: CGImage, _ rhs: CGImage) -> Bool {
        guard lhs.width == rhs.width, lhs.height == rhs.height,
              let dataA = lhs.dataProvider?.data,
              let dataB = rhs.dataProvider?.data
        else {
            return false
        }

        let lengthA = CFDataGetLength(dataA)
        guard lengthA == CFDataGetLength(dataB) else { return false }
        guard lengthA > 0,
              let bytesA = CFDataGetBytePtr(dataA),
              let bytesB = CFDataGetBytePtr(dataB)
        else {
            return lengthA == 0
        }
        return memcmp(bytesA, bytesB, lengthA) == 0
    }

    static func acceptedOffset(_ rawOffset: Int, minimum: Int = 3) -> Int? {
        let offset = abs(rawOffset)
        return offset >= minimum ? offset : nil
    }
}

enum ScrollCaptureStitchResult: Sendable {
    case stitched(yOffset: Int)
    case noChange
    case alignmentFailed
}

/// 只负责将 Vision 得到的新增行追加到已有长图底部。
/// 页头和滚动条检测不参与当前拼接路径，避免引入参考项目中未生效的逻辑。
final class ScrollCaptureStitcher: @unchecked Sendable {
    private(set) var mergedImage: CGImage?
    private(set) var totalHeight = 0

    func setInitialFrame(_ frame: CGImage) {
        mergedImage = frame
        totalHeight = frame.height
    }

    func stitch(newFrame: CGImage, detectedOffset: Int) -> ScrollCaptureStitchResult {
        guard let mergedImage else {
            setInitialFrame(newFrame)
            return .stitched(yOffset: 0)
        }
        guard detectedOffset > 0 else { return .noChange }

        let clampedRows = min(detectedOffset, newFrame.height)
        guard clampedRows > 0 else { return .noChange }

        let newMergedHeight = totalHeight + clampedRows
        guard let context = CGContext(
            data: nil,
            width: mergedImage.width,
            height: newMergedHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: mergedImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return .alignmentFailed
        }

        context.draw(
            mergedImage,
            in: CGRect(
                x: 0,
                y: clampedRows,
                width: mergedImage.width,
                height: totalHeight
            )
        )

        guard let newContent = newFrame.cropping(to: CGRect(
            x: 0,
            y: newFrame.height - clampedRows,
            width: newFrame.width,
            height: clampedRows
        )) else {
            return .alignmentFailed
        }

        context.draw(
            newContent,
            in: CGRect(
                x: 0,
                y: 0,
                width: mergedImage.width,
                height: clampedRows
            )
        )

        guard let result = context.makeImage() else {
            return .alignmentFailed
        }
        self.mergedImage = result
        totalHeight = newMergedHeight
        return .stitched(yOffset: clampedRows)
    }
}

@MainActor
final class ScrollCaptureEngine {
    struct Options: Sendable {
        var interval: TimeInterval = 0.15
        var minimumOffset: Int = 3
        var maxHeight: Int = 30_000
    }

    struct Progress: Sendable {
        let acceptedFrames: Int
        let capturedFrames: Int
        let outputHeight: Int
        let preview: CGImage
        let viewportRatio: Double
        let viewportOffset: Double
        let matchSucceeded: Bool
        let failureMessage: String?
    }

    private let capturer: ScrollCaptureSession
    private let stitcher = ScrollCaptureStitcher()
    private let options: Options

    private(set) var isRunning = false
    private var shouldStop = false
    private var isCancelled = false

    init(region: CaptureRegion, options: Options = Options()) {
        self.capturer = ScrollCaptureSession(region: region)
        self.options = options
    }

    /// 结束采集但保留最近一次已拼接结果，供保存、钉图或复制使用。
    func requestStop() {
        shouldStop = true
    }

    /// 取消采集并丢弃结果。
    func requestCancel() {
        isCancelled = true
        shouldStop = true
    }

    func run(onProgress: ((Progress) -> Void)? = nil) async throws -> CGImage {
        guard !isRunning else { throw ScrollCaptureError.captureFailed }
        isRunning = true
        shouldStop = false
        isCancelled = false
        defer { isRunning = false }

        let firstFrame: CGImage
        do {
            firstFrame = try await capturer.captureFrame()
        } catch {
            if isCancelled { throw ScrollCaptureError.cancelled }
            throw error
        }
        guard firstFrame.width > 0, firstFrame.height > 0 else {
            throw ScrollCaptureError.empty
        }

        stitcher.setInitialFrame(firstFrame)
        var shotA = firstFrame
        var acceptedFrames = 1
        var capturedFrames = 1
        var latestPreview = Self.downsample(firstFrame, maxWidth: 140) ?? firstFrame

        onProgress?(Self.progress(
            acceptedFrames: acceptedFrames,
            capturedFrames: capturedFrames,
            outputHeight: stitcher.totalHeight,
            preview: latestPreview,
            viewportRatio: 1,
            matchSucceeded: true,
            failureMessage: nil
        ))

        while !shouldStop && !isCancelled && stitcher.totalHeight < options.maxHeight {
            try await Task.sleep(for: .seconds(options.interval))
            if isCancelled { throw ScrollCaptureError.cancelled }
            if shouldStop { break }

            let shotB: CGImage
            do {
                shotB = try await capturer.captureFrame()
            } catch {
                if isCancelled { throw ScrollCaptureError.cancelled }
                onProgress?(Self.progress(
                    acceptedFrames: acceptedFrames,
                    capturedFrames: capturedFrames,
                    outputHeight: stitcher.totalHeight,
                    preview: latestPreview,
                    viewportRatio: Self.viewportRatio(
                        frameHeight: firstFrame.height,
                        outputHeight: stitcher.totalHeight
                    ),
                    matchSucceeded: false,
                    failureMessage: L10n.string("当前帧采集失败，已跳过，继续采样。")
                ))
                continue
            }
            capturedFrames += 1

            if ScrollCaptureFrameMatcher.isByteIdentical(shotA, shotB) {
                continue
            }

            guard let rawOffset = Self.detectOffset(imageA: shotA, imageB: shotB) else {
                // 与参考实现保持一致：对齐失败后使用当前帧作为下一次参考帧。
                shotA = shotB
                onProgress?(Self.progress(
                    acceptedFrames: acceptedFrames,
                    capturedFrames: capturedFrames,
                    outputHeight: stitcher.totalHeight,
                    preview: latestPreview,
                    viewportRatio: Self.viewportRatio(
                        frameHeight: firstFrame.height,
                        outputHeight: stitcher.totalHeight
                    ),
                    matchSucceeded: false,
                    failureMessage: L10n.string("当前帧未能对齐，已跳过，继续采样。")
                ))
                continue
            }

            guard let offset = ScrollCaptureFrameMatcher.acceptedOffset(
                rawOffset,
                minimum: options.minimumOffset
            ) else {
                continue
            }

            let remainingHeight = options.maxHeight - stitcher.totalHeight
            guard remainingHeight > 0 else { break }
            let appendOffset = min(offset, remainingHeight)
            switch stitcher.stitch(newFrame: shotB, detectedOffset: appendOffset) {
            case .stitched:
                acceptedFrames += 1
                latestPreview = Self.downsample(
                    stitcher.mergedImage ?? shotB,
                    maxWidth: 140
                ) ?? latestPreview
                onProgress?(Self.progress(
                    acceptedFrames: acceptedFrames,
                    capturedFrames: capturedFrames,
                    outputHeight: stitcher.totalHeight,
                    preview: latestPreview,
                    viewportRatio: Self.viewportRatio(
                        frameHeight: firstFrame.height,
                        outputHeight: stitcher.totalHeight
                    ),
                    matchSucceeded: true,
                    failureMessage: nil
                ))
            case .noChange:
                break
            case .alignmentFailed:
                onProgress?(Self.progress(
                    acceptedFrames: acceptedFrames,
                    capturedFrames: capturedFrames,
                    outputHeight: stitcher.totalHeight,
                    preview: latestPreview,
                    viewportRatio: Self.viewportRatio(
                        frameHeight: firstFrame.height,
                        outputHeight: stitcher.totalHeight
                    ),
                    matchSucceeded: false,
                    failureMessage: L10n.string("当前帧拼接失败，已跳过，继续采样。")
                ))
            }

            shotA = shotB
        }

        if isCancelled { throw ScrollCaptureError.cancelled }
        guard let mergedImage = stitcher.mergedImage else {
            throw ScrollCaptureError.empty
        }
        return mergedImage
    }

    private static func progress(
        acceptedFrames: Int,
        capturedFrames: Int,
        outputHeight: Int,
        preview: CGImage,
        viewportRatio: Double,
        matchSucceeded: Bool,
        failureMessage: String?
    ) -> Progress {
        Progress(
            acceptedFrames: acceptedFrames,
            capturedFrames: capturedFrames,
            outputHeight: outputHeight,
            preview: preview,
            viewportRatio: min(max(viewportRatio, 0), 1),
            // 向下滚动时当前视口始终位于长图底部。
            viewportOffset: 0,
            matchSucceeded: matchSucceeded,
            failureMessage: failureMessage
        )
    }

    private static func viewportRatio(frameHeight: Int, outputHeight: Int) -> Double {
        guard frameHeight > 0, outputHeight > 0 else { return 1 }
        return min(Double(frameHeight) / Double(outputHeight), 1)
    }

    private nonisolated static func detectOffset(imageA: CGImage, imageB: CGImage) -> Int? {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: imageA)
        let handler = VNImageRequestHandler(cgImage: imageB, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observation = request.results?.first
                as? VNImageTranslationAlignmentObservation else {
            return nil
        }
        return Int(round(observation.alignmentTransform.ty))
    }

    private nonisolated static func downsample(
        _ image: CGImage,
        maxWidth: Int
    ) -> CGImage? {
        guard image.width > 0, image.height > 0, maxWidth > 0 else { return nil }
        let scale = min(1, CGFloat(maxWidth) / CGFloat(image.width))
        let width = max(Int((CGFloat(image.width) * scale).rounded()), 1)
        let height = max(Int((CGFloat(image.height) * scale).rounded()), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        return context.makeImage()
    }
}
