import AVFoundation
import CoreMedia

enum RecordingAudioEncoding {
    static func systemAudioOutputSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 44_100,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
    }

    /// 麦克风 AAC 输出；单声道匹配典型输入，与系统音频独立不预混。
    static func microphoneOutputSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44_100,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
    }
}

enum RecordingAudioTimeline {
    static func silenceFrameChunks(
        from start: CMTime,
        to end: CMTime,
        sampleRate: Double,
        maximumFramesPerChunk: Int
    ) -> [Int] {
        guard start.isValid,
              end.isValid,
              sampleRate > 0,
              maximumFramesPerChunk > 0,
              CMTimeCompare(start, end) < 0
        else { return [] }

        let timescale = CMTimeScale(sampleRate.rounded())
        guard timescale > 0 else { return [] }
        let duration = CMTimeSubtract(end, start)
        let durationInFrames = CMTimeConvertScale(
            duration,
            timescale: timescale,
            method: .roundTowardZero
        )
        guard durationInFrames.value > 0 else { return [] }

        var remaining = Int(durationInFrames.value)
        var chunks: [Int] = []
        while remaining > 0 {
            let frameCount = min(remaining, maximumFramesPerChunk)
            chunks.append(frameCount)
            remaining -= frameCount
        }
        return chunks
    }

    static func sampleEndTime(
        presentationTime: CMTime,
        sampleBuffer: CMSampleBuffer
    ) -> CMTime {
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        if duration.isValid, CMTimeCompare(duration, .zero) > 0 {
            return CMTimeAdd(presentationTime, duration)
        }

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              asbd.mSampleRate > 0
        else { return presentationTime }
        return CMTimeAdd(
            presentationTime,
            CMTime(
                value: CMTimeValue(CMSampleBufferGetNumSamples(sampleBuffer)),
                timescale: CMTimeScale(asbd.mSampleRate)
            )
        )
    }

    static func restamp(
        _ sampleBuffer: CMSampleBuffer,
        to presentationTime: CMTime
    ) -> CMSampleBuffer? {
        var timingCount = CMItemCount()
        CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &timingCount
        )

        let originalDuration: CMTime
        if timingCount > 0 {
            var originalTiming = [CMSampleTimingInfo](
                repeating: CMSampleTimingInfo(),
                count: Int(timingCount)
            )
            CMSampleBufferGetSampleTimingInfoArray(
                sampleBuffer,
                entryCount: timingCount,
                arrayToFill: &originalTiming,
                entriesNeededOut: &timingCount
            )
            originalDuration = originalTiming.first?.duration ?? .invalid
        } else {
            originalDuration = .invalid
        }

        var newTiming = CMSampleTimingInfo(
            duration: originalDuration,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var newBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &newTiming,
            sampleBufferOut: &newBuffer
        )
        guard status == noErr else { return nil }
        return newBuffer
    }

    static func makeSilence(
        like reference: CMSampleBuffer,
        at presentationTime: CMTime,
        frameCount: Int,
        formatDescription: CMAudioFormatDescription,
        sampleRate: Double
    ) -> CMSampleBuffer? {
        guard let sourceBlock = CMSampleBufferGetDataBuffer(reference) else { return nil }
        let referenceLength = CMBlockBufferGetDataLength(sourceBlock)
        let referenceFrameCount = CMSampleBufferGetNumSamples(reference)
        guard referenceLength > 0, referenceFrameCount > 0, frameCount > 0 else { return nil }

        let bytesPerFrame = referenceLength / referenceFrameCount
        let length = bytesPerFrame * frameCount
        guard bytesPerFrame > 0, length > 0, sampleRate > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr,
        let blockBuffer
        else { return nil }

        guard CMBlockBufferFillDataBytes(
            with: 0,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: length
        ) == kCMBlockBufferNoErr
        else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleSize = bytesPerFrame
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr
        else { return nil }
        return sampleBuffer
    }
}
