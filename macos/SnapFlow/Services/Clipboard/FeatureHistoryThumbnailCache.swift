import AppKit
import ImageIO

/// 功能历史（截图 / OCR / 翻译）列表缩略图：内存缓存 + 后台读盘。
@MainActor
enum FeatureHistoryThumbnailCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 80
        cache.totalCostLimit = 12 * 1024 * 1024
        return cache
    }()

    static func memoryCached(url: URL) -> NSImage? {
        cache.object(forKey: url.path as NSString)
    }

    static func store(_ image: NSImage, for url: URL) {
        cache.setObject(image, forKey: url.path as NSString, cost: estimatedCost(of: image))
    }

    /// 后台从磁盘加载；调用方在主线程写入内存缓存。
    nonisolated static func loadFromDisk(url: URL, maxPixel: CGFloat = 120) -> NSImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary)
        else {
            return NSImage(contentsOf: url)
        }
        let maxPx = max(1, Int(maxPixel.rounded()))
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPx,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbOptions as CFDictionary
        ) {
            return NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
        }
        return NSImage(contentsOf: url)
    }

    static func removeAll() {
        cache.removeAllObjects()
    }

    private static func estimatedCost(of image: NSImage) -> Int {
        var rect = NSRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return max(1, cgImage.bytesPerRow * cgImage.height)
        }
        let pixels = max(1, image.size.width * image.size.height)
        return Int(pixels * 4)
    }
}
