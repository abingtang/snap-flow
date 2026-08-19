import CoreVideo
import Foundation

/// 将视频帧编码为无限循环 GIF；每帧自适应 256 色，优先保证有界内存和导出稳定性。
final class GIFEncoder {
    static let maximumPixelWidth = ScreenRecordingVideoEncoding.maximumPixelWidth
    static let maximumPixelHeight = ScreenRecordingVideoEncoding.maximumPixelHeight

    private static let paletteColorCount = 256
    private static let histogramBinCount = 16 * 16 * 16
    // ponytail: 4 位色彩桶保持固定工作集；若真机渐变仍有明显色带，再升级 5 位或有序抖动。

    private static let fallbackPalette: [UInt8] = {
        var values: [UInt8] = []
        values.reserveCapacity(paletteColorCount * 3)
        for red in 0..<8 {
            for green in 0..<8 {
                for blue in 0..<4 {
                    values.append(UInt8((red * 255) / 7))
                    values.append(UInt8((green * 255) / 7))
                    values.append(UInt8(blue * 85))
                }
            }
        }
        return values
    }()

    private let url: URL
    private let targetFPS: Int
    private let defaultDelayTime: TimeInterval
    private let lock = NSLock()

    private var fileHandle: FileHandle?
    private var targetWidth = 0
    private var targetHeight = 0
    private var indexedPixels: [UInt8] = []
    private var framePalette = GIFEncoder.fallbackPalette
    private var histogramCounts = Array(repeating: 0, count: GIFEncoder.histogramBinCount)
    private var histogramRedSums = Array(repeating: 0, count: GIFEncoder.histogramBinCount)
    private var histogramGreenSums = Array(repeating: 0, count: GIFEncoder.histogramBinCount)
    private var histogramBlueSums = Array(repeating: 0, count: GIFEncoder.histogramBinCount)
    private var binToPaletteIndex = Array(repeating: UInt8(0), count: GIFEncoder.histogramBinCount)
    private var histogramOrder = Array(0..<GIFEncoder.histogramBinCount)
    private var delayRemainder: Double = 0
    private var frameCount = 0
    private var failed = false
    private var finished = false

    var keptFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return frameCount
    }

    init(url: URL, fps: Int = 8) {
        self.url = url
        targetFPS = min(max(fps, 1), 8)
        defaultDelayTime = 1.0 / Double(targetFPS)
    }

    static func outputDimensions(width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (1, 1) }

        let scale = min(
            1,
            Double(maximumPixelWidth) / Double(width),
            Double(maximumPixelHeight) / Double(height)
        )
        return (
            width: max(Int((Double(width) * scale).rounded(.down)), 1),
            height: max(Int((Double(height) * scale).rounded(.down)), 1)
        )
    }

    /// 添加一帧；只保留当前索引像素，不保留已经写入的历史帧。
    @discardableResult
    func addFrame(
        _ pixelBuffer: CVPixelBuffer,
        delayTime: TimeInterval? = nil
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !failed, !finished else { return false }

        return autoreleasepool {
            guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
                failed = true
                return false
            }

            let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
            let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
            guard sourceWidth > 0, sourceHeight > 0 else {
                failed = true
                return false
            }

            if fileHandle == nil {
                let dimensions = Self.outputDimensions(width: sourceWidth, height: sourceHeight)
                targetWidth = dimensions.width
                targetHeight = dimensions.height
                indexedPixels = Array(repeating: 0, count: targetWidth * targetHeight)
            }

            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

            guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
                  makeIndexedPixels(
                      baseAddress: baseAddress,
                      sourceWidth: sourceWidth,
                      sourceHeight: sourceHeight,
                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer)
                  )
            else {
                failed = true
                return false
            }

            if fileHandle == nil, !openFile() {
                failed = true
                return false
            }

            do {
                try writeFrame(delayTime: delayTime ?? defaultDelayTime)
                frameCount += 1
                return true
            } catch {
                failed = true
                return false
            }
        }
    }

    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !failed, !finished, frameCount > 0, fileHandle != nil else {
            try? fileHandle?.close()
            fileHandle = nil
            return false
        }

        do {
            try write([0x3B])
            try fileHandle?.close()
            fileHandle = nil
            finished = true
            return true
        } catch {
            failed = true
            try? fileHandle?.close()
            fileHandle = nil
            return false
        }
    }

    deinit {
        try? fileHandle?.close()
    }

    private func openFile() -> Bool {
        do {
            try? FileManager.default.removeItem(at: url)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                return false
            }
            fileHandle = try FileHandle(forWritingTo: url)
            try writeHeader(width: targetWidth, height: targetHeight)
            return true
        } catch {
            try? fileHandle?.close()
            fileHandle = nil
            return false
        }
    }

    private func makeIndexedPixels(
        baseAddress: UnsafeMutableRawPointer,
        sourceWidth: Int,
        sourceHeight: Int,
        bytesPerRow: Int
    ) -> Bool {
        guard targetWidth > 0, targetHeight > 0, bytesPerRow >= sourceWidth * 4 else {
            return false
        }

        let source = baseAddress.assumingMemoryBound(to: UInt8.self)

        // 只统计当前输出帧；4096 个色彩桶不会随录制时长增长。
        for index in 0..<Self.histogramBinCount {
            histogramCounts[index] = 0
            histogramRedSums[index] = 0
            histogramGreenSums[index] = 0
            histogramBlueSums[index] = 0
        }

        for targetY in 0..<targetHeight {
            let sourceY = min(sourceHeight - 1, targetY * sourceHeight / targetHeight)
            let sourceRow = source.advanced(by: sourceY * bytesPerRow)

            for targetX in 0..<targetWidth {
                let sourceX = min(sourceWidth - 1, targetX * sourceWidth / targetWidth)
                let sourceOffset = sourceX * 4
                let blue = sourceRow[sourceOffset]
                let green = sourceRow[sourceOffset + 1]
                let red = sourceRow[sourceOffset + 2]
                let bin = (Int(red >> 4) << 8) | (Int(green >> 4) << 4) | Int(blue >> 4)
                histogramCounts[bin] += 1
                histogramRedSums[bin] += Int(red)
                histogramGreenSums[bin] += Int(green)
                histogramBlueSums[bin] += Int(blue)
            }
        }

        histogramOrder.sort {
            let leftCount = histogramCounts[$0]
            let rightCount = histogramCounts[$1]
            return leftCount == rightCount ? $0 < $1 : leftCount > rightCount
        }

        for paletteIndex in 0..<Self.paletteColorCount {
            let bin = histogramOrder[paletteIndex]
            let paletteOffset = paletteIndex * 3
            let count = histogramCounts[bin]
            if count > 0 {
                framePalette[paletteOffset] = UInt8(histogramRedSums[bin] / count)
                framePalette[paletteOffset + 1] = UInt8(histogramGreenSums[bin] / count)
                framePalette[paletteOffset + 2] = UInt8(histogramBlueSums[bin] / count)
            } else {
                framePalette[paletteOffset] = Self.fallbackPalette[paletteOffset]
                framePalette[paletteOffset + 1] = Self.fallbackPalette[paletteOffset + 1]
                framePalette[paletteOffset + 2] = Self.fallbackPalette[paletteOffset + 2]
            }
        }

        for bin in 0..<Self.histogramBinCount {
            let count = histogramCounts[bin]
            guard count > 0 else { continue }
            let red = histogramRedSums[bin] / count
            let green = histogramGreenSums[bin] / count
            let blue = histogramBlueSums[bin] / count

            var bestPaletteIndex = 0
            var bestDistance = Int.max
            for paletteIndex in 0..<Self.paletteColorCount {
                let paletteOffset = paletteIndex * 3
                let redDelta = red - Int(framePalette[paletteOffset])
                let greenDelta = green - Int(framePalette[paletteOffset + 1])
                let blueDelta = blue - Int(framePalette[paletteOffset + 2])
                let distance = redDelta * redDelta
                    + greenDelta * greenDelta
                    + blueDelta * blueDelta
                if distance < bestDistance {
                    bestDistance = distance
                    bestPaletteIndex = paletteIndex
                }
            }
            binToPaletteIndex[bin] = UInt8(bestPaletteIndex)
        }

        for targetY in 0..<targetHeight {
            let sourceY = min(sourceHeight - 1, targetY * sourceHeight / targetHeight)
            let sourceRow = source.advanced(by: sourceY * bytesPerRow)
            let targetRowStart = targetY * targetWidth

            for targetX in 0..<targetWidth {
                let sourceX = min(sourceWidth - 1, targetX * sourceWidth / targetWidth)
                let sourceOffset = sourceX * 4
                let blue = sourceRow[sourceOffset]
                let green = sourceRow[sourceOffset + 1]
                let red = sourceRow[sourceOffset + 2]
                let bin = (Int(red >> 4) << 8) | (Int(green >> 4) << 4) | Int(blue >> 4)
                indexedPixels[targetRowStart + targetX] = binToPaletteIndex[bin]
            }
        }
        return true
    }

    private func writeHeader(width: Int, height: Int) throws {
        try write(Array("GIF89a".utf8))
        try writeUInt16(width)
        try writeUInt16(height)
        // Global color table is a 256-color fallback; each frame writes its own adaptive table.
        try write([0xF7, 0x00, 0x00])
        try write(Self.fallbackPalette)
        // NETSCAPE loop extension: loop forever.
        try write([0x21, 0xFF, 0x0B])
        try write(Array("NETSCAPE2.0".utf8))
        try write([0x03, 0x01, 0x00, 0x00, 0x00])
    }

    private func writeFrame(delayTime: TimeInterval) throws {
        let delayUnits = quantizedDelayUnits(delayTime)
        try write([
            0x21, 0xF9, 0x04, 0x00,
            UInt8(delayUnits & 0xFF),
            UInt8((delayUnits >> 8) & 0xFF),
            0x00, 0x00,
        ])
        try write([0x2C])
        try writeUInt16(0)
        try writeUInt16(0)
        try writeUInt16(targetWidth)
        try writeUInt16(targetHeight)
        // Local color table: 256 colors, adapted to the current frame.
        try write([0x87])
        try write(framePalette)

        let minimumCodeSize = 8
        try write([UInt8(minimumCodeSize)])
        try writeSubBlocks(Self.lzwData(for: indexedPixels, minimumCodeSize: minimumCodeSize))
    }

    private func quantizedDelayUnits(_ delayTime: TimeInterval) -> Int {
        let safeDelay = delayTime.isFinite ? max(delayTime, 0.01) : defaultDelayTime
        let totalUnits = safeDelay * 100 + delayRemainder
        let units = min(max(Int(totalUnits.rounded(.down)), 1), 65_535)
        delayRemainder = max(totalUnits - Double(units), 0)
        return units
    }

    private func writeSubBlocks(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let count = min(255, bytes.count - offset)
            try write([UInt8(count)])
            try write(Array(bytes[offset..<(offset + count)]))
            offset += count
        }
        try write([0x00])
    }

    private func writeUInt16(_ value: Int) throws {
        try write([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
        ])
    }

    private func write(_ bytes: [UInt8]) throws {
        guard let fileHandle else { throw EncoderError.fileUnavailable }
        try fileHandle.write(contentsOf: Data(bytes))
    }

    private static func lzwData(for pixels: [UInt8], minimumCodeSize: Int) -> [UInt8] {
        guard let first = pixels.first else { return [] }

        let clearCode = 1 << minimumCodeSize
        let endCode = clearCode + 1
        var nextCode = endCode + 1
        var codeSize = minimumCodeSize + 1
        var dictionary: [UInt64: Int] = [:]
        dictionary.reserveCapacity(4_096)

        var writer = GIFBitWriter()
        writer.write(clearCode, bitCount: codeSize)
        var prefix = Int(first)

        for pixel in pixels.dropFirst() {
            let key = (UInt64(prefix) << 8) | UInt64(pixel)
            if let code = dictionary[key] {
                prefix = code
                continue
            }

            writer.write(prefix, bitCount: codeSize)
            if nextCode < 4_096 {
                dictionary[key] = nextCode
                nextCode += 1
                // GIF 解码器会在读到下一条码后才完成同一条字典项；位宽要延后一条码扩大。
                if nextCode > (1 << codeSize), codeSize < 12 {
                    codeSize += 1
                }
            } else {
                writer.write(clearCode, bitCount: codeSize)
                dictionary.removeAll(keepingCapacity: true)
                codeSize = minimumCodeSize + 1
                nextCode = endCode + 1
            }
            prefix = Int(pixel)
        }

        writer.write(prefix, bitCount: codeSize)
        writer.write(endCode, bitCount: codeSize)
        return writer.finish()
    }

    private enum EncoderError: Error {
        case fileUnavailable
    }
}

private struct GIFBitWriter {
    private var bytes: [UInt8] = []
    private var bitBuffer: UInt32 = 0
    private var bitCount = 0

    mutating func write(_ value: Int, bitCount: Int) {
        bitBuffer |= UInt32(value) << self.bitCount
        self.bitCount += bitCount
        while self.bitCount >= 8 {
            bytes.append(UInt8(bitBuffer & 0xFF))
            bitBuffer >>= 8
            self.bitCount -= 8
        }
    }

    mutating func finish() -> [UInt8] {
        if bitCount > 0 {
            bytes.append(UInt8(bitBuffer & 0xFF))
        }
        return bytes
    }
}
