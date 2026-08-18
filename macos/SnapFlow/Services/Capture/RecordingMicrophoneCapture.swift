import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

/// 决定是否应启动麦克风采集；避免重复创建 recorder 或在暂停态强开。
enum RecordingMicrophoneActivationPolicy {
    static func shouldStartCapture(
        isEnabled: Bool,
        hasRecorder: Bool,
        isRecording: Bool,
        trackArmed: Bool
    ) -> Bool {
        isEnabled && !hasRecorder && isRecording && trackArmed
    }
}

/// 设备移除后的回退策略：优先系统默认；无法回退则停用麦克风。
enum RecordingMicrophoneDeviceFallback {
    /// - Returns: 解析后的 UID（`nil` 表示系统默认），以及是否发生了回退。
    static func resolve(
        preferredUID: String?,
        availableUIDs: [String]
    ) -> (uid: String?, fellBack: Bool) {
        guard let preferredUID else {
            return (nil, false)
        }
        if availableUIDs.contains(preferredUID) {
            return (preferredUID, false)
        }
        // 首选设备不在列表中：回退系统默认（nil）。
        return (nil, true)
    }

    /// 回退后仍无法建立输入时，应停用麦克风而不是中断视频。
    static func shouldDisableMicrophoneWhenUnavailable(
        preferredFellBack: Bool,
        captureStartSucceeded: Bool
    ) -> Bool {
        !captureStartSucceeded
    }
}

/// 经 `AVAudioEngine` 采集麦克风 PCM，并转为 `CMSampleBuffer` 供 `AVAssetWriter` 写入。
final class RecordingMicrophoneCapture: @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case audioUnitUnavailable
        case inputFormatUnavailable
        case converterUnavailable

        var errorDescription: String? {
            switch self {
            case .audioUnitUnavailable:
                return L10n.string("所选麦克风不可用")
            case .inputFormatUnavailable:
                return L10n.string("麦克风输入格式不可用")
            case .converterUnavailable:
                return L10n.string("无法创建麦克风音频转换器")
            }
        }
    }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let outputFormat: AVAudioFormat
    private let deviceUID: String?
    private var paused = false
    private var tapInstalled = false
    private var configurationObserver: NSObjectProtocol?

    var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    /// 设备配置变化（拔出等）时回调；上层可尝试回退默认设备或停用麦克风。
    var onConfigurationFailed: (() -> Void)?

    init(deviceUID: String?) {
        self.deviceUID = deviceUID
        outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 44_100,
            channels: 1,
            interleaved: true
        )!
    }

    deinit {
        stop()
    }

    /// 启动麦克风；失败抛出，便于 HUD 恢复关闭状态并保留视频。
    func start() throws {
        if let deviceUID, let deviceID = RecordingAudioInputDevices.deviceID(forUID: deviceUID) {
            guard let audioUnit = engine.inputNode.audioUnit else {
                throw CaptureError.audioUnitUnavailable
            }
            var id = deviceID
            // 尽力设置；失败时仍使用系统默认输入。
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioObjectID>.size)
            )
            if status != noErr {
                // 指定设备无法切换时仍尝试默认输入，由上层决定是否提示。
            }
        } else if deviceUID != nil {
            // 持久化设备已拔出：回退默认输入。
        }

        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.inputFormatUnavailable
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw CaptureError.converterUnavailable
        }
        self.converter = converter

        do {
            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                self?.handle(buffer: buffer)
            }
            tapInstalled = true
            try engine.start()
            installConfigurationObserver()
        } catch {
            stop()
            throw error
        }
    }

    func pause() {
        guard !paused else { return }
        paused = true
        engine.pause()
    }

    func resume() throws {
        guard paused else { return }
        try engine.start()
        paused = false
    }

    func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        paused = false
        converter = nil
    }

    private func installConfigurationObserver() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.onConfigurationFailed?()
        }
    }

    private func handle(buffer: AVAudioPCMBuffer) {
        guard !paused else { return }

        let frameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate
        )
        guard frameCapacity > 0,
              let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity)
        else { return }

        var conversionError: NSError?
        // 非隔离局部状态供转换器回调一次性喂入输入缓冲。
        final class SupplyFlag: @unchecked Sendable {
            var supplied = false
        }
        let supply = SupplyFlag()
        guard let converter else { return }
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if supply.supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supply.supplied = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, conversionError == nil else { return }

        if let sampleBuffer = Self.makeSampleBuffer(from: converted, format: outputFormat) {
            onSampleBuffer?(sampleBuffer)
        }
    }

    private static func makeSampleBuffer(
        from buffer: AVAudioPCMBuffer,
        format: AVAudioFormat
    ) -> CMSampleBuffer? {
        var formatDescription: CMAudioFormatDescription?
        var basicDescription = format.streamDescription.pointee
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &basicDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard let formatDescription else { return nil }

        var blockBuffer: CMBlockBuffer?
        let dataByteSize = Int(buffer.frameLength) * Int(format.streamDescription.pointee.mBytesPerFrame)
        guard dataByteSize > 0,
              let channelData = buffer.int16ChannelData?[0]
        else { return nil }

        let allocationStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataByteSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataByteSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard allocationStatus == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let replaceStatus = CMBlockBufferReplaceDataBytes(
            with: channelData,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: dataByteSize
        )
        guard replaceStatus == kCMBlockBufferNoErr else { return nil }

        let sampleSize = MemoryLayout<Int16>.size
        var sampleSizes: [Int] = [sampleSize]
        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSizes,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr, let sampleBuffer else { return nil }

        // 与 SCStream 共用 host-time 时钟域，便于引擎重标时间线。
        let presentationTime = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var timedBuffer: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &timedBuffer
        )
        return timedBuffer ?? sampleBuffer
    }
}
