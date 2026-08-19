import AVFoundation
import CoreGraphics

enum ScreenRecordingVideoEncoding {
    static let maximumPixelWidth = 1_920
    static let maximumPixelHeight = 1_080

    static func outputSettings(width: Int, height: Int) -> [String: Any] {
        let fps = ScreenRecordingConfiguration.frameRate
        let bitrate = bitrate(width: width, height: height, fps: fps)
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
            ],
        ]
    }

    /// 向上取整后再向上调整到偶数，避免裁掉选区最后一个像素。
    static func evenDimensions(width: CGFloat, height: CGFloat) -> (width: Int, height: Int) {
        let roundedWidth = max(Int(width.rounded(.up)), 1)
        let roundedHeight = max(Int(height.rounded(.up)), 1)
        return (
            width: max(((roundedWidth + 1) / 2) * 2, 2),
            height: max(((roundedHeight + 1) / 2) * 2, 2)
        )
    }

    /// 将录制输出限制在产品最大尺寸内，同时保持宽高比。
    static func cappedEvenDimensions(width: CGFloat, height: CGFloat) -> (width: Int, height: Int) {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            return (width: 2, height: 2)
        }

        let scale = min(
            1,
            CGFloat(maximumPixelWidth) / width,
            CGFloat(maximumPixelHeight) / height
        )
        let dimensions = evenDimensions(width: width * scale, height: height * scale)
        return (
            width: min(dimensions.width, maximumPixelWidth),
            height: min(dimensions.height, maximumPixelHeight)
        )
    }

    private static func bitrate(width: Int, height: Int, fps: Int) -> Int {
        guard width > 0, height > 0, fps > 0 else { return 3_000_000 }
        let pixels = Double(width) * Double(height)
        let raw = pixels * Double(fps) * 0.21
        let taper: Double
        if pixels > 3840 * 2160 {
            taper = 0.80
        } else if pixels > 1920 * 1080 {
            taper = 0.92
        } else {
            taper = 1
        }
        return Int(min(max(raw * taper, 3_000_000), 80_000_000).rounded())
    }
}
