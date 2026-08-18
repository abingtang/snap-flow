import AVFoundation
import CoreGraphics

enum ScreenRecordingVideoEncoding {
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
