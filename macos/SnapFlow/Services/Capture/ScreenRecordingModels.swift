import CoreGraphics
import Foundation

enum ScreenRecordingState: Equatable, Sendable {
    case idle
    case recording
    case paused
    case stopping
}

enum ScreenRecordingFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case mp4
    case gif

    var id: String { rawValue }

    var fileExtension: String { rawValue }

    var displayName: String {
        switch self {
        case .mp4: "MP4"
        case .gif: "GIF"
        }
    }
}

/// 停止后的保存策略：每次询问 / 总是 MP4 / 总是 GIF。
enum RecordingSavePreference: String, CaseIterable, Identifiable, Sendable {
    case ask
    case alwaysMP4
    case alwaysGIF

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ask: L10n.string("每次询问")
        case .alwaysMP4: L10n.string("总是 MP4")
        case .alwaysGIF: L10n.string("总是 GIF")
        }
    }

    /// `nil` 表示需要弹窗询问。
    var fixedFormat: ScreenRecordingFormat? {
        switch self {
        case .ask: nil
        case .alwaysMP4: .mp4
        case .alwaysGIF: .gif
        }
    }
}

enum ScreenRecordingError: LocalizedError, Equatable {
    case invalidRegion
    case noDisplay
    case captureFailed
    case writerSetupFailed
    case noFrames
    case notRecording
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidRegion:
            return L10n.string("录制区域无效")
        case .noDisplay:
            return L10n.string("未找到录制目标显示器")
        case .captureFailed:
            return L10n.string("屏幕录制采集失败，请检查屏幕录制权限")
        case .writerSetupFailed:
            return L10n.string("无法准备录制文件")
        case .noFrames:
            return L10n.string("没有采集到有效视频帧")
        case .notRecording:
            return L10n.string("当前没有正在进行的录制")
        case .cancelled:
            return L10n.string("录制已取消")
        }
    }
}

struct ScreenRecordingConfiguration: Equatable, Sendable {
    /// 产品契约固定为 30 FPS，不作为用户设置暴露。
    static let frameRate = 30

    var showsCursor: Bool
    var systemAudioEnabled: Bool
    var microphoneEnabled: Bool
    /// `nil` 表示系统默认输入设备。
    var microphoneDeviceUID: String?

    init(
        showsCursor: Bool = true,
        systemAudioEnabled: Bool = false,
        microphoneEnabled: Bool = false,
        microphoneDeviceUID: String? = nil
    ) {
        self.showsCursor = showsCursor
        self.systemAudioEnabled = systemAudioEnabled
        self.microphoneEnabled = microphoneEnabled
        self.microphoneDeviceUID = microphoneDeviceUID
    }
}

struct ScreenRecordingOutput: Equatable, Sendable {
    let url: URL
    let pixelWidth: Int
    let pixelHeight: Int
    let containsSystemAudio: Bool
    /// 仅当实际写入过麦克风采样时为 true；预挂空轨不算有效麦克风音轨。
    let containsMicrophone: Bool
}

struct RecordingSystemAudioCaptureState: Sendable {
    private(set) var desiredEnabled = false
    private(set) var appliedEnabled = false
    private(set) var updateInFlight = false

    var mayWriteAudio: Bool {
        desiredEnabled && appliedEnabled && !updateInFlight
    }

    mutating func reset(desiredEnabled: Bool) {
        self.desiredEnabled = desiredEnabled
        appliedEnabled = false
        updateInFlight = false
    }

    mutating func install(appliedEnabled: Bool) {
        self.appliedEnabled = appliedEnabled
        updateInFlight = false
    }

    mutating func request(_ enabled: Bool) {
        desiredEnabled = enabled
    }

    mutating func beginNextUpdate() -> Bool? {
        guard !updateInFlight, desiredEnabled != appliedEnabled else { return nil }
        updateInFlight = true
        return desiredEnabled
    }

    mutating func completeUpdate(appliedEnabled: Bool) {
        self.appliedEnabled = appliedEnabled
        updateInFlight = false
    }

    @discardableResult
    mutating func failUpdate() -> Bool {
        desiredEnabled = appliedEnabled
        updateInFlight = false
        return appliedEnabled
    }
}

enum ScreenRecordingRegionGeometry {
    static func pixelDimensions(for region: CaptureRegion) -> (width: Int, height: Int) {
        ScreenRecordingVideoEncoding.cappedEvenDimensions(
            width: region.rectInScreenPoints.width * max(region.scaleFactor, 1),
            height: region.rectInScreenPoints.height * max(region.scaleFactor, 1)
        )
    }

    static func displayLocalRect(for region: CaptureRegion, displayBounds: CGRect) -> CGRect {
        ScreenGeometry.appKitGlobalRectToDisplayLocal(
            region.rectInScreenPoints,
            displayBounds: displayBounds
        )
    }
}

struct ScreenRecordingStateMachine: Sendable {
    private(set) var state: ScreenRecordingState = .idle

    @discardableResult
    mutating func start() -> Bool {
        guard state == .idle else { return false }
        state = .recording
        return true
    }

    @discardableResult
    mutating func pause() -> Bool {
        guard state == .recording else { return false }
        state = .paused
        return true
    }

    @discardableResult
    mutating func resume() -> Bool {
        guard state == .paused else { return false }
        state = .recording
        return true
    }

    @discardableResult
    mutating func beginStopping() -> Bool {
        guard state == .recording || state == .paused else { return false }
        state = .stopping
        return true
    }

    mutating func reset() {
        state = .idle
    }
}
