import CoreGraphics
import AVFoundation
import XCTest
@testable import SnapFlow

final class ScreenRecordingEngineTests: XCTestCase {
    func testEvenDimensionsRoundUpToEvenPixels() {
        let first = ScreenRecordingVideoEncoding.evenDimensions(width: 1921.1, height: 1080)
        XCTAssertEqual(first.width, 1922)
        XCTAssertEqual(first.height, 1080)

        let second = ScreenRecordingVideoEncoding.evenDimensions(width: 1, height: 1)
        XCTAssertEqual(second.width, 2)
        XCTAssertEqual(second.height, 2)
    }

    func testCappedDimensionsScaleLandscapeRegionToMaximum() {
        let dimensions = ScreenRecordingVideoEncoding.cappedEvenDimensions(
            width: 3840,
            height: 2160
        )

        XCTAssertEqual(dimensions.width, 1920)
        XCTAssertEqual(dimensions.height, 1080)
    }

    func testCappedDimensionsPreservePortraitAspectRatio() {
        let dimensions = ScreenRecordingVideoEncoding.cappedEvenDimensions(
            width: 1080,
            height: 1920
        )

        XCTAssertEqual(dimensions.width, 608)
        XCTAssertEqual(dimensions.height, 1080)
    }

    func testCappedDimensionsKeepSmallerRegionUnchanged() {
        let dimensions = ScreenRecordingVideoEncoding.cappedEvenDimensions(
            width: 1280,
            height: 720
        )

        XCTAssertEqual(dimensions.width, 1280)
        XCTAssertEqual(dimensions.height, 720)
    }

    func testRegionPixelDimensionsUseTheRecordingMaximum() {
        let region = CaptureRegion(
            rectInScreenPoints: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            displayID: 1,
            scaleFactor: 2
        )

        let dimensions = ScreenRecordingRegionGeometry.pixelDimensions(for: region)

        XCTAssertEqual(dimensions.width, 1920)
        XCTAssertEqual(dimensions.height, 1080)
    }

    func testOutputSettingsUseFixedHighProfileThirtyFPS() {
        let settings = ScreenRecordingVideoEncoding.outputSettings(width: 1920, height: 1080)
        XCTAssertEqual(settings[AVVideoCodecKey] as? AVVideoCodecType, .h264)

        let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]
        XCTAssertEqual(
            compression?[AVVideoExpectedSourceFrameRateKey] as? Int,
            ScreenRecordingConfiguration.frameRate
        )
        XCTAssertEqual(
            compression?[AVVideoProfileLevelKey] as? String,
            AVVideoProfileLevelH264HighAutoLevel
        )
    }

    func testRegionMapsToDisplayLocalCoordinatesAndPixels() {
        let region = CaptureRegion(
            rectInScreenPoints: CGRect(x: 130, y: 240, width: 101.2, height: 50.1),
            displayID: 1,
            scaleFactor: 2
        )
        let local = ScreenRecordingRegionGeometry.displayLocalRect(
            for: region,
            displayBounds: CGRect(x: 100, y: 200, width: 800, height: 600)
        )

        XCTAssertEqual(local.origin.x, 30, accuracy: 0.001)
        XCTAssertEqual(local.origin.y, 509.9, accuracy: 0.001)
        XCTAssertEqual(local.width, 101.2, accuracy: 0.001)
        XCTAssertEqual(local.height, 50.1, accuracy: 0.001)
        let pixels = ScreenRecordingRegionGeometry.pixelDimensions(for: region)
        XCTAssertEqual(pixels.width, 204)
        XCTAssertEqual(pixels.height, 102)
    }

    func testStateMachineRejectsInvalidTransitionsAndSupportsPause() {
        var machine = ScreenRecordingStateMachine()
        XCTAssertFalse(machine.pause())
        XCTAssertTrue(machine.start())
        XCTAssertFalse(machine.start())
        XCTAssertTrue(machine.pause())
        XCTAssertTrue(machine.resume())
        XCTAssertTrue(machine.beginStopping())
        XCTAssertFalse(machine.beginStopping())
        machine.reset()
        XCTAssertEqual(machine.state, .idle)
    }

    func testSystemAudioStateBlocksWritesUntilConfigurationApplies() {
        var state = RecordingSystemAudioCaptureState()
        state.reset(desiredEnabled: false)
        state.install(appliedEnabled: false)
        state.request(true)

        XCTAssertEqual(state.beginNextUpdate(), true)
        XCTAssertFalse(state.mayWriteAudio)

        state.completeUpdate(appliedEnabled: true)
        XCTAssertTrue(state.mayWriteAudio)
    }

    func testSystemAudioStateSchedulesDisableAfterRapidToggle() {
        var state = RecordingSystemAudioCaptureState()
        state.reset(desiredEnabled: false)
        state.install(appliedEnabled: false)
        state.request(true)

        XCTAssertEqual(state.beginNextUpdate(), true)
        state.request(false)
        state.completeUpdate(appliedEnabled: true)

        XCTAssertFalse(state.mayWriteAudio)
        XCTAssertEqual(state.beginNextUpdate(), false)
        state.completeUpdate(appliedEnabled: false)
        XCTAssertNil(state.beginNextUpdate())
    }

    func testSilenceFrameChunksUseWholeFramesOnly() {
        let chunks = RecordingAudioTimeline.silenceFrameChunks(
            from: .zero,
            to: CMTime(value: 1, timescale: 10),
            sampleRate: 44_100,
            maximumFramesPerChunk: 1_024
        )

        XCTAssertEqual(chunks, [1_024, 1_024, 1_024, 1_024, 314])
        XCTAssertEqual(chunks.reduce(0, +), 4_410)
    }

    func testMicrophoneActivationPolicyRequiresArmedRecordingAndEnabled() {
        XCTAssertFalse(
            RecordingMicrophoneActivationPolicy.shouldStartCapture(
                isEnabled: true,
                hasRecorder: false,
                isRecording: false,
                trackArmed: true
            )
        )
        XCTAssertTrue(
            RecordingMicrophoneActivationPolicy.shouldStartCapture(
                isEnabled: true,
                hasRecorder: false,
                isRecording: true,
                trackArmed: true
            )
        )
        XCTAssertFalse(
            RecordingMicrophoneActivationPolicy.shouldStartCapture(
                isEnabled: true,
                hasRecorder: true,
                isRecording: true,
                trackArmed: true
            )
        )
        XCTAssertFalse(
            RecordingMicrophoneActivationPolicy.shouldStartCapture(
                isEnabled: false,
                hasRecorder: false,
                isRecording: true,
                trackArmed: true
            )
        )
        XCTAssertFalse(
            RecordingMicrophoneActivationPolicy.shouldStartCapture(
                isEnabled: true,
                hasRecorder: false,
                isRecording: true,
                trackArmed: false
            )
        )
    }

    func testMicrophoneDeviceFallbackUsesDefaultWhenPreferredMissing() {
        let available = ["built-in", "usb-mic"]
        let present = RecordingMicrophoneDeviceFallback.resolve(
            preferredUID: "built-in",
            availableUIDs: available
        )
        XCTAssertEqual(present.uid, "built-in")
        XCTAssertFalse(present.fellBack)

        let missing = RecordingMicrophoneDeviceFallback.resolve(
            preferredUID: "bluetooth-gone",
            availableUIDs: available
        )
        XCTAssertNil(missing.uid)
        XCTAssertTrue(missing.fellBack)

        let systemDefault = RecordingMicrophoneDeviceFallback.resolve(
            preferredUID: nil,
            availableUIDs: available
        )
        XCTAssertNil(systemDefault.uid)
        XCTAssertFalse(systemDefault.fellBack)
    }

    func testMicrophoneFailureDisablesOnlyMicrophoneNotVideo() {
        XCTAssertTrue(
            RecordingMicrophoneDeviceFallback.shouldDisableMicrophoneWhenUnavailable(
                preferredFellBack: true,
                captureStartSucceeded: false
            )
        )
        XCTAssertFalse(
            RecordingMicrophoneDeviceFallback.shouldDisableMicrophoneWhenUnavailable(
                preferredFellBack: true,
                captureStartSucceeded: true
            )
        )
    }

    func testMicrophoneEncodingUsesMonoAACSeparateFromSystemAudio() {
        let mic = RecordingAudioEncoding.microphoneOutputSettings()
        let system = RecordingAudioEncoding.systemAudioOutputSettings()
        XCTAssertEqual((mic[AVNumberOfChannelsKey] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((system[AVNumberOfChannelsKey] as? NSNumber)?.intValue, 2)
        XCTAssertEqual((mic[AVFormatIDKey] as? NSNumber)?.uint32Value, kAudioFormatMPEG4AAC)
        XCTAssertEqual((mic[AVSampleRateKey] as? NSNumber)?.doubleValue, 44_100)
    }

    func testRecordingConfigurationDefaultsMicrophoneOff() {
        let config = ScreenRecordingConfiguration()
        XCTAssertFalse(config.microphoneEnabled)
        XCTAssertNil(config.microphoneDeviceUID)
        XCTAssertFalse(config.systemAudioEnabled)
    }

    func testScreenRecordingOutputTracksIndependentAudioFlags() {
        let output = ScreenRecordingOutput(
            url: URL(fileURLWithPath: "/tmp/test.mp4"),
            pixelWidth: 100,
            pixelHeight: 100,
            containsSystemAudio: true,
            containsMicrophone: false
        )
        XCTAssertTrue(output.containsSystemAudio)
        XCTAssertFalse(output.containsMicrophone)
    }
}
