import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

/// 负责实时视频/系统音频/麦克风采集和 MP4 临时文件写入；HUD、保存和历史由上层编排。
///
/// 麦克风轨在 `prepareWriter` 时预挂到 `AVAssetWriter`（写入开始后无法新增输入），
/// 仅在实际采样时写入；`containsMicrophone` 以是否写过采样为准。
final class ScreenRecordingEngine: NSObject, @unchecked Sendable {
    private var configuration: ScreenRecordingConfiguration
    private let temporaryDirectory: URL
    private let recordingQueue = DispatchQueue(label: "app.snapflow.screen-recording")
    private let stateLock = NSLock()
    private var stateMachine = ScreenRecordingStateMachine()

    private var stream: SCStream?
    private var streamOutput: ScreenRecordingStreamOutput?
    private var streamConfiguration: SCStreamConfiguration?
    private var streamConfigurationGeneration = 0
    private var systemAudioOutputAvailable = true
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var region: CaptureRegion?
    private var outputSize: (width: Int, height: Int)?
    private var writerSessionStarted = false
    private var hasWrittenFrame = false
    private var hasWrittenSystemAudio = false
    private var hasWrittenMicrophone = false
    private var lastSystemAudioEndTime: CMTime?
    private var lastMicrophoneEndTime: CMTime?
    private var totalPausedDuration: TimeInterval = 0
    private var pauseStartDate: Date?
    private let audioStateLock = NSLock()
    private var systemAudioCaptureState = RecordingSystemAudioCaptureState()
    private var microphoneCapture: RecordingMicrophoneCapture?
    private var microphoneTrackArmed = false
    private var microphoneEnabled = false
    private var microphoneGeneration = 0

    /// ScreenCaptureKit 非预期停止时由上层决定反馈和是否保存有效片段。
    var onUnexpectedStop: ((Error) -> Void)?
    var onSystemAudioConfigurationFailed: ((Bool) -> Void)?
    /// 麦克风启动失败、设备不可用或配置变化后无法恢复；上层应关闭 HUD 按钮并提示。
    var onMicrophoneCaptureFailed: (() -> Void)?
    /// 首选设备不可用并已回退系统默认时回调，便于同步 Settings。
    var onMicrophoneDeviceFellBackToDefault: (() -> Void)?

    var state: ScreenRecordingState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stateMachine.state
    }

    init(
        configuration: ScreenRecordingConfiguration = ScreenRecordingConfiguration(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.configuration = configuration
        self.temporaryDirectory = temporaryDirectory
        super.init()
    }

    func start(
        region: CaptureRegion,
        excludedWindowIDs: [CGWindowID] = []
    ) async throws {
        guard region.rectInScreenPoints.width > 0,
              region.rectInScreenPoints.height > 0,
              region.rectInScreenPoints.minX.isFinite,
              region.rectInScreenPoints.minY.isFinite
        else {
            throw ScreenRecordingError.invalidRegion
        }

        guard beginRecording() else {
            throw ScreenRecordingError.notRecording
        }

        resetSystemAudioState(desiredEnabled: configuration.systemAudioEnabled)
        systemAudioOutputAvailable = true
        microphoneEnabled = configuration.microphoneEnabled
        microphoneTrackArmed = false
        recordingQueue.sync {
            hasWrittenSystemAudio = false
            hasWrittenMicrophone = false
            lastSystemAudioEndTime = nil
            lastMicrophoneEndTime = nil
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            try ensureRecordingIsActive()

            guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
                throw ScreenRecordingError.noDisplay
            }

            let displayBounds = ScreenGeometry.displayBoundsInAppKitPoints(
                displayID: display.displayID
            )
            let sourceRect = ScreenRecordingRegionGeometry.displayLocalRect(
                for: region,
                displayBounds: displayBounds
            )
            let pixelSize = ScreenRecordingRegionGeometry.pixelDimensions(for: region)
            let filter = SCContentFilter(
                display: display,
                excludingWindows: excludedWindowIDs.compactMap { windowID in
                    content.windows.first(where: { $0.windowID == windowID })
                }
            )

            let outputURL = makeTemporaryOutputURL()
            recordingQueue.sync { self.outputURL = outputURL }
            try prepareWriter(url: outputURL, pixelSize: pixelSize)

            let streamConfiguration = SCStreamConfiguration()
            streamConfiguration.sourceRect = sourceRect
            streamConfiguration.width = pixelSize.width
            streamConfiguration.height = pixelSize.height
            streamConfiguration.minimumFrameInterval = CMTime(
                value: 1,
                timescale: CMTimeScale(ScreenRecordingConfiguration.frameRate)
            )
            streamConfiguration.showsCursor = configuration.showsCursor
            // Start without audio so an unavailable audio source cannot fail the video stream.
            // The requested state is applied immediately after the stream starts.
            streamConfiguration.capturesAudio = false
            streamConfiguration.sampleRate = 44_100
            streamConfiguration.channelCount = 2
            streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
            streamConfiguration.scalesToFit = false
            if #available(macOS 14.0, *) {
                streamConfiguration.colorSpaceName = CGColorSpace.sRGB
            }

            let output = ScreenRecordingStreamOutput()
            output.onFrame = { [weak self] pixelBuffer, presentationTime in
                self?.handleFrame(pixelBuffer: pixelBuffer, presentationTime: presentationTime)
            }
            output.onAudioSampleBuffer = { [weak self] sampleBuffer in
                self?.handleSystemAudioSampleBuffer(sampleBuffer)
            }
            output.onStopped = { [weak self] error in
                self?.handleUnexpectedStreamStop(error)
            }

            let stream = SCStream(
                filter: filter,
                configuration: streamConfiguration,
                delegate: output
            )
            try stream.addStreamOutput(
                output,
                type: .screen,
                sampleHandlerQueue: recordingQueue
            )
            let audioOutputAvailable = (try? stream.addStreamOutput(
                output,
                type: .audio,
                sampleHandlerQueue: recordingQueue
            )) != nil

            self.region = region
            self.outputURL = outputURL
            self.outputSize = pixelSize
            self.streamOutput = output
            self.stream = stream
            self.streamConfiguration = streamConfiguration
            self.systemAudioOutputAvailable = audioOutputAvailable
            self.streamConfigurationGeneration += 1
            try ensureRecordingIsActive()
            try await stream.startCapture()
            try ensureRecordingIsActive()
            installSystemAudioState(appliedEnabled: false)
            if audioOutputAvailable {
                scheduleSystemAudioConfigurationUpdate()
            } else if configuration.systemAudioEnabled {
                onSystemAudioConfigurationFailed?(false)
            }

            // AVAssetWriter 在 startWriting 后不能新增音轨；麦克风输入已在 prepareWriter 预挂。
            // 录制开始后即可懒启动采集，未采样时 containsMicrophone 仍为 false。
            microphoneTrackArmed = true
            if configuration.microphoneEnabled {
                startMicrophoneCapture()
            }
        } catch {
            await cleanupAfterFailedStart()
            throw mapStartError(error)
        }
    }

    func pause() {
        stateLock.lock()
        guard stateMachine.pause() else {
            stateLock.unlock()
            return
        }
        pauseStartDate = Date()
        stateLock.unlock()
        microphoneCapture?.pause()
    }

    func resume() {
        stateLock.lock()
        guard stateMachine.resume() else {
            stateLock.unlock()
            return
        }
        if let pauseStartDate {
            totalPausedDuration += Date().timeIntervalSince(pauseStartDate)
            self.pauseStartDate = nil
        }
        stateLock.unlock()

        if microphoneEnabled {
            if let microphoneCapture {
                do {
                    try microphoneCapture.resume()
                } catch {
                    handleMicrophoneStartFailure()
                }
            } else {
                startMicrophoneCapture()
            }
        }
    }

    /// 停止只会完成一次；重复调用会返回 nil，不会重复结束 writer。
    func stop() async throws -> ScreenRecordingOutput? {
        guard beginStopping() else { return nil }
        invalidateSystemAudioConfigurationUpdates()
        stopMicrophoneCapture()
        await stopStream()

        let (writer, hasFrame, hasSystemAudio, hasMicrophone, outputURL, outputSize) =
            finishWriterOnRecordingQueue()
        if let writer {
            await writer.finishWriting()
        }

        let writerError = writer?.error
        resetAfterFinish()

        guard let outputURL, let outputSize else {
            throw ScreenRecordingError.writerSetupFailed
        }
        if let writerError {
            removeTemporaryFile(at: outputURL)
            throw writerError
        }
        guard hasFrame else {
            removeTemporaryFile(at: outputURL)
            throw ScreenRecordingError.noFrames
        }
        return ScreenRecordingOutput(
            url: outputURL,
            pixelWidth: outputSize.width,
            pixelHeight: outputSize.height,
            containsSystemAudio: hasSystemAudio,
            containsMicrophone: hasMicrophone
        )
    }

    func cancel() async {
        guard beginStopping() else { return }
        invalidateSystemAudioConfigurationUpdates()
        stopMicrophoneCapture()
        await stopStream()
        let outputURL = recordingQueue.sync { () -> URL? in
            writer?.cancelWriting()
            clearWriterState()
            return self.outputURL
        }
        if let outputURL {
            removeTemporaryFile(at: outputURL)
        }
        resetAfterFinish()
    }

    private func beginRecording() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stateMachine.start()
    }

    private func beginStopping() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stateMachine.beginStopping()
    }

    private func ensureRecordingIsActive() throws {
        guard state == .recording else { throw ScreenRecordingError.cancelled }
    }

    func setSystemAudioEnabled(_ enabled: Bool) {
        guard state == .recording || state == .paused else { return }
        guard systemAudioOutputAvailable else {
            onSystemAudioConfigurationFailed?(false)
            return
        }
        requestSystemAudioState(enabled)
        scheduleSystemAudioConfigurationUpdate()
    }

    /// 录制中动态开关麦克风；切换只影响后续时间线，不回填开启前的静音。
    func setMicrophoneEnabled(_ enabled: Bool) {
        guard state == .recording || state == .paused else { return }
        configuration.microphoneEnabled = enabled
        microphoneEnabled = enabled

        if let capture = microphoneCapture {
            if enabled, state == .recording {
                do {
                    try capture.resume()
                } catch {
                    handleMicrophoneStartFailure()
                }
            } else {
                capture.pause()
            }
        } else if RecordingMicrophoneActivationPolicy.shouldStartCapture(
            isEnabled: enabled,
            hasRecorder: false,
            isRecording: state == .recording,
            trackArmed: microphoneTrackArmed
        ) {
            startMicrophoneCapture()
        }
    }

    /// 切换输入设备；仅影响后续采样。设备不可用时回退默认，仍失败则停用麦克风。
    func setMicrophoneDeviceUID(_ uid: String?) {
        guard configuration.microphoneDeviceUID != uid else { return }
        configuration.microphoneDeviceUID = uid

        guard state == .recording || state == .paused else { return }
        stopMicrophoneCapture()
        if RecordingMicrophoneActivationPolicy.shouldStartCapture(
            isEnabled: microphoneEnabled,
            hasRecorder: false,
            isRecording: state == .recording,
            trackArmed: microphoneTrackArmed
        ) {
            startMicrophoneCapture()
        }
    }

    private func resetSystemAudioState(desiredEnabled: Bool) {
        audioStateLock.lock()
        systemAudioCaptureState.reset(desiredEnabled: desiredEnabled)
        audioStateLock.unlock()
    }

    private func requestSystemAudioState(_ enabled: Bool) {
        audioStateLock.lock()
        systemAudioCaptureState.request(enabled)
        audioStateLock.unlock()
    }

    private func installSystemAudioState(appliedEnabled: Bool) {
        audioStateLock.lock()
        systemAudioCaptureState.install(appliedEnabled: appliedEnabled)
        audioStateLock.unlock()
    }

    private func beginNextSystemAudioUpdate() -> Bool? {
        audioStateLock.lock()
        defer { audioStateLock.unlock() }
        return systemAudioCaptureState.beginNextUpdate()
    }

    private func completeSystemAudioUpdate(appliedEnabled: Bool) {
        audioStateLock.lock()
        systemAudioCaptureState.completeUpdate(appliedEnabled: appliedEnabled)
        audioStateLock.unlock()
    }

    private func failSystemAudioUpdate() -> Bool {
        audioStateLock.lock()
        defer { audioStateLock.unlock() }
        return systemAudioCaptureState.failUpdate()
    }

    private func mayWriteSystemAudio() -> Bool {
        audioStateLock.lock()
        defer { audioStateLock.unlock() }
        return systemAudioCaptureState.mayWriteAudio
    }

    private func scheduleSystemAudioConfigurationUpdate() {
        guard systemAudioOutputAvailable,
              let stream,
              let currentConfiguration = streamConfiguration,
              let updatedConfiguration = currentConfiguration.copy() as? SCStreamConfiguration,
              let targetEnabled = beginNextSystemAudioUpdate()
        else { return }

        let generation = streamConfigurationGeneration
        updatedConfiguration.capturesAudio = targetEnabled
        Task { @MainActor [weak self, stream] in
            do {
                try await stream.updateConfiguration(updatedConfiguration)
                guard let self,
                      self.streamConfigurationGeneration == generation,
                      self.stream === stream
                else { return }

                self.streamConfiguration = updatedConfiguration
                self.completeSystemAudioUpdate(appliedEnabled: targetEnabled)
                self.scheduleSystemAudioConfigurationUpdate()
            } catch {
                guard let self,
                      self.streamConfigurationGeneration == generation,
                      self.stream === stream
                else { return }

                let appliedEnabled = self.failSystemAudioUpdate()
                self.onSystemAudioConfigurationFailed?(appliedEnabled)
            }
        }
    }

    private func invalidateSystemAudioConfigurationUpdates() {
        streamConfigurationGeneration += 1
        streamConfiguration = nil
        resetSystemAudioState(desiredEnabled: false)
    }

    private func prepareWriter(
        url: URL,
        pixelSize: (width: Int, height: Int)
    ) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: ScreenRecordingVideoEncoding.outputSettings(
                width: pixelSize.width,
                height: pixelSize.height
            )
        )
        input.expectsMediaDataInRealTime = true

        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: pixelSize.width,
            kCVPixelBufferHeightKey as String: pixelSize.height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourceAttributes
        )

        guard writer.canAdd(input) else {
            throw ScreenRecordingError.writerSetupFailed
        }
        writer.add(input)

        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: RecordingAudioEncoding.systemAudioOutputSettings()
        )
        audioInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(audioInput) else {
            throw ScreenRecordingError.writerSetupFailed
        }
        writer.add(audioInput)

        // 必须在 startWriting 前挂上麦克风输入，才能在录制中动态开启；
        // 未产生采样时 containsMicrophone 仍为 false。
        let micInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: RecordingAudioEncoding.microphoneOutputSettings()
        )
        micInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(micInput) else {
            throw ScreenRecordingError.writerSetupFailed
        }
        writer.add(micInput)

        guard writer.startWriting() else {
            throw writer.error ?? ScreenRecordingError.writerSetupFailed
        }

        recordingQueue.sync {
            self.writer = writer
            self.videoInput = input
            self.pixelBufferAdaptor = adaptor
            self.systemAudioInput = audioInput
            self.microphoneInput = micInput
            self.outputURL = url
            self.outputSize = pixelSize
            self.writerSessionStarted = false
            self.hasWrittenFrame = false
            self.hasWrittenSystemAudio = false
            self.hasWrittenMicrophone = false
            self.lastSystemAudioEndTime = nil
            self.lastMicrophoneEndTime = nil
            self.totalPausedDuration = 0
            self.pauseStartDate = nil
        }
    }

    private func handleFrame(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard state == .recording, presentationTime.isValid else { return }

        let adjustedTime = adjustedPresentationTime(presentationTime)
        guard let input = videoInput,
              let adaptor = pixelBufferAdaptor,
              input.isReadyForMoreMediaData
        else { return }

        if !writerSessionStarted {
            startWriterSession(at: adjustedTime)
        }
        if adaptor.append(pixelBuffer, withPresentationTime: adjustedTime) {
            hasWrittenFrame = true
        }
    }

    private func handleSystemAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard state == .recording,
              sampleBuffer.numSamples > 0,
              mayWriteSystemAudio(),
              let input = systemAudioInput,
              input.isReadyForMoreMediaData
        else { return }

        let sourceTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard sourceTime.isValid else { return }
        let presentationTime = adjustedPresentationTime(sourceTime)
        if !writerSessionStarted {
            startWriterSession(at: presentationTime)
        }

        // 首次开启系统声音时不回填开启前的历史时间线；只补齐已经开始音轨后的断流间隙。
        let gapStart = lastSystemAudioEndTime
        if let gapStart, CMTimeCompare(gapStart, presentationTime) < 0 {
            let fill = appendSilence(
                into: input,
                like: sampleBuffer,
                from: gapStart,
                to: presentationTime
            )
            lastSystemAudioEndTime = fill.lastEnd
            guard fill.completed else { return }
        }

        guard let restamped = RecordingAudioTimeline.restamp(
            sampleBuffer,
            to: presentationTime
        ), input.append(restamped)
        else { return }

        hasWrittenSystemAudio = true
        lastSystemAudioEndTime = RecordingAudioTimeline.sampleEndTime(
            presentationTime: presentationTime,
            sampleBuffer: restamped
        )
    }

    private func handleMicrophoneSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard state == .recording,
              microphoneEnabled,
              sampleBuffer.numSamples > 0,
              let input = microphoneInput,
              input.isReadyForMoreMediaData
        else { return }

        let sourceTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard sourceTime.isValid else { return }
        let presentationTime = adjustedPresentationTime(sourceTime)
        if !writerSessionStarted {
            startWriterSession(at: presentationTime)
        }

        // 与系统音频一致：首次开启不回填开启前时间线，只补齐已开始音轨后的断流间隙。
        let gapStart = lastMicrophoneEndTime
        if let gapStart, CMTimeCompare(gapStart, presentationTime) < 0 {
            let fill = appendSilence(
                into: input,
                like: sampleBuffer,
                from: gapStart,
                to: presentationTime
            )
            lastMicrophoneEndTime = fill.lastEnd
            guard fill.completed else { return }
        }

        guard let restamped = RecordingAudioTimeline.restamp(
            sampleBuffer,
            to: presentationTime
        ), input.append(restamped)
        else { return }

        hasWrittenMicrophone = true
        lastMicrophoneEndTime = RecordingAudioTimeline.sampleEndTime(
            presentationTime: presentationTime,
            sampleBuffer: restamped
        )
    }

    private struct SilenceAppendResult {
        let lastEnd: CMTime
        let completed: Bool
    }

    private func appendSilence(
        into input: AVAssetWriterInput,
        like reference: CMSampleBuffer,
        from start: CMTime,
        to end: CMTime
    ) -> SilenceAppendResult {
        guard let formatDescription = CMSampleBufferGetFormatDescription(reference),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              asbd.mSampleRate > 0
        else {
            return SilenceAppendResult(lastEnd: start, completed: true)
        }

        let framesPerChunk = max(1, reference.numSamples)
        let chunks = RecordingAudioTimeline.silenceFrameChunks(
            from: start,
            to: end,
            sampleRate: asbd.mSampleRate,
            maximumFramesPerChunk: framesPerChunk
        )
        var cursor = start
        for frameCount in chunks {
            guard input.isReadyForMoreMediaData,
                  let silent = RecordingAudioTimeline.makeSilence(
                      like: reference,
                      at: cursor,
                      frameCount: frameCount,
                      formatDescription: formatDescription,
                      sampleRate: asbd.mSampleRate
                  ),
                  input.append(silent)
            else {
                return SilenceAppendResult(lastEnd: cursor, completed: false)
            }
            cursor = CMTimeAdd(
                cursor,
                CMTime(
                    value: CMTimeValue(frameCount),
                    timescale: CMTimeScale(asbd.mSampleRate)
                )
            )
        }
        return SilenceAppendResult(lastEnd: cursor, completed: true)
    }

    private func startWriterSession(at time: CMTime) {
        guard let writer, !writerSessionStarted else { return }
        writer.startSession(atSourceTime: time)
        writerSessionStarted = true
    }

    private func adjustedPresentationTime(_ time: CMTime) -> CMTime {
        stateLock.lock()
        let pausedDuration = totalPausedDuration
        stateLock.unlock()
        guard pausedDuration > 0 else { return time }
        return CMTimeSubtract(
            time,
            CMTimeMakeWithSeconds(pausedDuration, preferredTimescale: max(time.timescale, 1))
        )
    }

    private func stopStream() async {
        let stream = self.stream
        self.stream = nil
        guard let stream else { return }
        try? await stream.stopCapture()
        streamOutput = nil
        recordingQueue.sync {}
    }

    private func finishWriterOnRecordingQueue() -> (
        writer: AVAssetWriter?,
        hasFrame: Bool,
        hasSystemAudio: Bool,
        hasMicrophone: Bool,
        outputURL: URL?,
        outputSize: (width: Int, height: Int)?
    ) {
        recordingQueue.sync {
            videoInput?.markAsFinished()
            systemAudioInput?.markAsFinished()
            microphoneInput?.markAsFinished()
            let result = (
                writer,
                hasWrittenFrame,
                hasWrittenSystemAudio,
                hasWrittenMicrophone,
                outputURL,
                outputSize
            )
            clearWriterState()
            return result
        }
    }

    private func clearWriterState() {
        writer = nil
        videoInput = nil
        pixelBufferAdaptor = nil
        systemAudioInput = nil
        microphoneInput = nil
        writerSessionStarted = false
        hasWrittenFrame = false
        hasWrittenSystemAudio = false
        hasWrittenMicrophone = false
        lastSystemAudioEndTime = nil
        lastMicrophoneEndTime = nil
    }

    private func startMicrophoneCapture() {
        guard RecordingMicrophoneActivationPolicy.shouldStartCapture(
            isEnabled: microphoneEnabled,
            hasRecorder: microphoneCapture != nil,
            isRecording: state == .recording,
            trackArmed: microphoneTrackArmed
        ) else { return }

        let preferredUID = configuration.microphoneDeviceUID
        let availableUIDs = RecordingAudioInputDevices.available().map(\.uid)
        let resolved = RecordingMicrophoneDeviceFallback.resolve(
            preferredUID: preferredUID,
            availableUIDs: availableUIDs
        )
        if resolved.fellBack {
            configuration.microphoneDeviceUID = nil
            onMicrophoneDeviceFellBackToDefault?()
        }

        microphoneGeneration += 1
        let generation = microphoneGeneration
        let capture = RecordingMicrophoneCapture(deviceUID: resolved.uid)
        capture.onSampleBuffer = { [weak self] sampleBuffer in
            guard let self else { return }
            self.recordingQueue.async { [weak self] in
                guard let self, self.microphoneGeneration == generation else { return }
                self.handleMicrophoneSampleBuffer(sampleBuffer)
            }
        }
        capture.onConfigurationFailed = { [weak self] in
            guard let self else { return }
            self.recordingQueue.async { [weak self] in
                self?.handleMicrophoneConfigurationChange()
            }
        }
        microphoneCapture = capture
        do {
            try capture.start()
        } catch {
            handleMicrophoneStartFailure()
        }
    }

    private func stopMicrophoneCapture() {
        microphoneGeneration += 1
        microphoneCapture?.stop()
        microphoneCapture = nil
        // 预挂轨保持 armed，便于录制中再次开启。
        microphoneTrackArmed = true
    }

    private func handleMicrophoneStartFailure() {
        stopMicrophoneCapture()
        microphoneEnabled = false
        configuration.microphoneEnabled = false
        onMicrophoneCaptureFailed?()
    }

    private func handleMicrophoneConfigurationChange() {
        guard state == .recording || state == .paused else { return }
        guard microphoneEnabled else { return }

        // 设备被移除：先停再尝试默认输入；仍失败则仅停用麦克风。
        let previousUID = configuration.microphoneDeviceUID
        stopMicrophoneCapture()
        let availableUIDs = RecordingAudioInputDevices.available().map(\.uid)
        if availableUIDs.isEmpty {
            handleMicrophoneStartFailure()
            return
        }
        if previousUID != nil {
            configuration.microphoneDeviceUID = nil
            onMicrophoneDeviceFellBackToDefault?()
        }
        if state == .recording {
            startMicrophoneCapture()
            if microphoneCapture == nil {
                handleMicrophoneStartFailure()
            }
        }
    }

    private func cleanupAfterFailedStart() async {
        invalidateSystemAudioConfigurationUpdates()
        stopMicrophoneCapture()
        await stopStream()
        let outputURL = recordingQueue.sync { () -> URL? in
            writer?.cancelWriting()
            clearWriterState()
            return self.outputURL
        }
        if let outputURL {
            removeTemporaryFile(at: outputURL)
        }
        resetAfterFinish()
    }

    private func resetAfterFinish() {
        microphoneGeneration += 1
        microphoneCapture?.stop()
        microphoneCapture = nil
        microphoneEnabled = false
        microphoneTrackArmed = false
        stateLock.lock()
        stateMachine.reset()
        pauseStartDate = nil
        totalPausedDuration = 0
        stateLock.unlock()
        region = nil
        outputURL = nil
        outputSize = nil
    }

    private func mapStartError(_ error: Error) -> Error {
        if let error = error as? ScreenRecordingError {
            return error
        }
        if error is CancellationError {
            return ScreenRecordingError.cancelled
        }
        return ScreenRecordingError.captureFailed
    }

    private func handleUnexpectedStreamStop(_ error: Error?) {
        guard state == .recording || state == .paused else { return }
        let reportedError = error ?? ScreenRecordingError.captureFailed
        Task { [weak self] in
            guard let self else { return }
            await self.cancel()
            self.onUnexpectedStop?(reportedError)
        }
    }

    private func makeTemporaryOutputURL() -> URL {
        temporaryDirectory
            .appendingPathComponent("SnapFlow-recording-(UUID().uuidString).mp4")
    }

    private func removeTemporaryFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

private final class ScreenRecordingStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onAudioSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onStopped: ((Error?) -> Void)?

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        switch type {
        case .screen:
            guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
            onFrame?(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        case .audio:
            guard sampleBuffer.numSamples > 0 else { return }
            onAudioSampleBuffer?(sampleBuffer)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped?(error)
    }
}
