import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 云端/自定义上传前缩放；框坐标回映到原图像素。
enum OCRImagePrep {
    static let maxEdge: CGFloat = 2048

    struct Prepared: Sendable {
        let image: CGImage
        /// original / scaled（>1 表示缩小了）
        let scaleX: CGFloat
        let scaleY: CGFloat

        func mapBoxToOriginal(_ box: CGRect) -> CGRect {
            CGRect(
                x: box.origin.x * scaleX,
                y: box.origin.y * scaleY,
                width: box.size.width * scaleX,
                height: box.size.height * scaleY
            )
        }

        func mapLinesToOriginal(_ lines: [OCRLine]) -> [OCRLine] {
            lines.map { line in
                OCRLine(
                    id: line.id,
                    text: line.text,
                    boundingBox: mapBoxToOriginal(line.boundingBox),
                    confidence: line.confidence
                )
            }
        }
    }

    /// 若最长边超过 `maxEdge` 则等比缩小，否则原图。
    static func prepareForUpload(_ image: CGImage, maxEdge: CGFloat = maxEdge) -> Prepared {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let longest = max(w, h)
        guard longest > maxEdge, longest > 0 else {
            return Prepared(image: image, scaleX: 1, scaleY: 1)
        }
        let ratio = maxEdge / longest
        let newW = max(1, Int((w * ratio).rounded()))
        let newH = max(1, Int((h * ratio).rounded()))
        guard let scaled = resize(image, width: newW, height: newH) else {
            return Prepared(image: image, scaleX: 1, scaleY: 1)
        }
        return Prepared(
            image: scaled,
            scaleX: w / CGFloat(newW),
            scaleY: h / CGFloat(newH)
        )
    }

    /// 规范为 sRGB 8-bit，避免 ScreenCapture 特殊像素格式导致编码失败。
    static func normalizeForEncode(_ image: CGImage) -> CGImage {
        let w = image.width
        let h = image.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    static func pngData(from image: CGImage) -> Data? {
        let normalized = normalizeForEncode(image)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, normalized, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func jpegData(from image: CGImage, quality: CGFloat = 0.92) -> Data? {
        let normalized = normalizeForEncode(image)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, normalized, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// 云 OCR 用：JPEG base64（无换行）。失败时回退 PNG。
    static func base64ForCloudOCR(from image: CGImage) -> String? {
        let prepared = prepareForUpload(image)
        if let jpeg = jpegData(from: prepared.image) {
            return jpeg.base64EncodedString(options: [])
        }
        if let png = pngData(from: prepared.image) {
            return png.base64EncodedString(options: [])
        }
        return nil
    }

    /// `application/x-www-form-urlencoded`：必须把 `+` 编成 `%2B`，否则 base64 被当空格损坏。
    static func formURLEncodedBody(_ fields: [(String, String)]) -> Data? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let pairs = fields.compactMap { key, value -> String? in
            guard let ek = key.addingPercentEncoding(withAllowedCharacters: allowed),
                  let ev = value.addingPercentEncoding(withAllowedCharacters: allowed)
            else { return nil }
            return "\(ek)=\(ev)"
        }
        return pairs.joined(separator: "&").data(using: .utf8)
    }

    /// 验证用小样图：白底黑字「SnapFlow OCR」
    static func sampleVerificationImage() -> CGImage? {
        let width = 320
        let height = 80
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        // 简单像素块文字不可用 CoreText 时退化为条纹；用 Core Text 绘制
        let text = "SnapFlow OCR" as CFString
        let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1),
        ]
        let attrStr = CFAttributedStringCreate(nil, text, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attrStr)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        ctx.textPosition = CGPoint(
            x: (CGFloat(width) - bounds.width) / 2,
            y: (CGFloat(height) - bounds.height) / 2
        )
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }

    private static func resize(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
