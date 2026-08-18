import AppKit
import Foundation
import UniformTypeIdentifiers

/// 截图保存编码：按「图像质量」设置输出 PNG（无损）或 JPEG（有损）。
///
/// 约定（与常见截图工具一致）：
/// - `-1`：自动 → PNG 无损
/// - `100`：不压缩 → PNG 无损
/// - `0...99`：JPEG，质量因子 = 值 / 100（0 为最高压缩）
enum SnipImageExport {
    struct Payload {
        let data: Data
        let fileExtension: String

        var contentType: UTType {
            fileExtension == "png" ? .png : .jpeg
        }
    }

    /// 规范化质量：仅允许 `-1` 或 `0...100`。
    static func normalizedQuality(_ value: Int) -> Int {
        if value < 0 { return -1 }
        return min(100, value)
    }

    /// 是否使用无损 PNG。
    static func usesLosslessPNG(quality: Int) -> Bool {
        let q = normalizedQuality(quality)
        return q < 0 || q >= 100
    }

    static func fileExtension(quality: Int) -> String {
        usesLosslessPNG(quality: quality) ? "png" : "jpg"
    }

    static func encode(_ image: NSImage, quality: Int) -> Payload? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }

        if usesLosslessPNG(quality: quality) {
            guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
            return Payload(data: png, fileExtension: "png")
        }

        let q = normalizedQuality(quality)
        let factor = CGFloat(q) / 100.0
        guard let jpeg = rep.representation(
            using: .jpeg,
            properties: [.compressionFactor: factor]
        ) else { return nil }
        return Payload(data: jpeg, fileExtension: "jpg")
    }

    /// 默认文件名：`prefix-yyyyMMdd-HHmmss.ext`
    static func defaultFileName(
        prefix: String = "SnapFlow",
        quality: Int,
        date: Date = Date()
    ) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(prefix)-\(f.string(from: date)).\(fileExtension(quality: quality))"
    }

    /// 写入目标 URL；若扩展名与质量不匹配，会替换为正确扩展名后的 URL。
    @discardableResult
    static func write(
        _ image: NSImage,
        quality: Int,
        to url: URL
    ) throws -> URL {
        guard let payload = encode(image, quality: quality) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var out = url
        let preferredExt = payload.fileExtension
        if out.pathExtension.lowercased() != preferredExt {
            out = out.deletingPathExtension().appendingPathExtension(preferredExt)
        }
        try payload.data.write(to: out, options: .atomic)
        return out
    }
}
