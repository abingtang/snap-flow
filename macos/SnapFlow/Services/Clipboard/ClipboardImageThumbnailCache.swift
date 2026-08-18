import AppKit
import ImageIO

/// 剪切板列表 / 预览缩略图：内存 `NSCache` + 磁盘落盘。
///
/// 列表若直接读 `HistoryItem.primaryImageData`，会把 SwiftData external storage
/// 全图 fault 进常驻模型对象，关窗后也无法回收。策略：
/// 1. 优先读磁盘缩略图（不触碰原图 Data）
/// 2. 仅在缺失时短暂 fault 一次原图，立刻写出磁盘缩略图
/// 3. 关闭面板时清空内存缓存；由 `HistoryStore.releaseFaultedImagePayloads()` 换新
///    `ModelContext` 丢掉已 fault 的大块 Data
@MainActor
enum ClipboardImageThumbnailCache {
    /// 列表行（约 48pt @2x）
    nonisolated static let listMaxPixel: CGFloat = 96
    /// 侧栏预览 / 磁盘落盘尺寸（约 260pt 高 @2x）
    nonisolated static let previewMaxPixel: CGFloat = 560

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 160
        cache.totalCostLimit = 28 * 1024 * 1024
        return cache
    }()

    private static let diskDirectory: URL = {
        let root = FeatureHistoryIO.applicationSupportRoot
            .appendingPathComponent("clipboard-thumbs", isDirectory: true)
        FeatureHistoryIO.ensureDirectory(root)
        return root
    }()

    /// 仅内存命中（不读盘、不 fault SwiftData），供列表首帧快速占位。
    static func memoryCached(id: UUID, maxPixel: CGFloat) -> NSImage? {
        cache.object(forKey: cacheKey(id: id, maxPixel: maxPixel))
    }

    /// 把已解码图写入内存缓存。
    static func storeMemory(_ image: NSImage, id: UUID, maxPixel: CGFloat) {
        cache.setObject(
            image,
            forKey: cacheKey(id: id, maxPixel: maxPixel),
            cost: estimatedCost(of: image)
        )
    }

    /// 仅磁盘读（可在后台线程调用）；不写 NSCache。
    nonisolated static func loadThumbnailFromDisk(id: UUID, maxPixel: CGFloat) -> NSImage? {
        loadFromDisk(id: id, maxPixel: maxPixel)
    }

    /// 从原图 Data 在后台生成列表缩略图并落盘（不写 NSCache；调用方主线程 `storeMemory`）。
    /// 供列表冷路径：主线程只短暂 fault Data，解码/写盘在后台，避免多行并发卡死主线程。
    nonisolated static func materializeFromImageData(
        _ data: Data,
        id: UUID,
        listMaxPixel: CGFloat = listMaxPixel
    ) -> NSImage? {
        guard let preview = downsample(data: data, maxPixel: previewMaxPixel) else { return nil }
        writeJPEGToDisk(preview, id: id)
        if listMaxPixel + 0.5 >= previewMaxPixel {
            return preview
        }
        return downsample(data: data, maxPixel: listMaxPixel) ?? preview
    }

    /// 返回不超过 `maxPixel` 的缩略图；无图片时 `nil`。
    /// 同步路径：预览侧栏等可接受阻塞的场景；列表请用异步加载。
    static func thumbnail(for item: HistoryItem, maxPixel: CGFloat) -> NSImage? {
        guard item.hasImageRepresentation else { return nil }
        let key = cacheKey(id: item.id, maxPixel: maxPixel)
        if let hit = cache.object(forKey: key) {
            return hit
        }

        // 磁盘命中：不再读取 SwiftData 原图。
        if let fromDisk = loadFromDisk(id: item.id, maxPixel: maxPixel) {
            cache.setObject(fromDisk, forKey: key, cost: estimatedCost(of: fromDisk))
            return fromDisk
        }

        // 冷路径：短暂 fault 一次，写盘后依赖关窗时 recycle context 释放原图 Data。
        guard let data = item.primaryImageData else { return nil }
        guard let stored = store(imageData: data, for: item.id) else { return nil }
        let thumb: NSImage
        if maxPixel + 0.5 >= previewMaxPixel {
            thumb = stored
        } else {
            thumb = downsampleNSImage(stored, maxPixel: maxPixel) ?? stored
        }
        cache.setObject(thumb, forKey: key, cost: estimatedCost(of: thumb))
        return thumb
    }

    /// 写入时已有原图 Data，同步落盘缩略图，避免列表首次滚动再 fault。
    @discardableResult
    static func store(imageData: Data, for id: UUID) -> NSImage? {
        guard let preview = downsample(data: imageData, maxPixel: previewMaxPixel) else {
            return nil
        }
        writeJPEGToDisk(preview, id: id)
        let previewKey = cacheKey(id: id, maxPixel: previewMaxPixel)
        cache.setObject(preview, forKey: previewKey, cost: estimatedCost(of: preview))
        return preview
    }

    /// 从准备好的 payloads 中找第一张图并落盘。
    static func storeIfNeeded(payloads: [ClipboardPayload], for id: UUID) {
        let imageTypes = Set(
            [
                NSPasteboard.PasteboardType.png,
                .tiff,
                .init("public.jpeg"),
                .init("public.heic"),
            ].map(\.rawValue)
        )
        guard let data = payloads.first(where: { imageTypes.contains($0.type) })?.value else {
            return
        }
        _ = store(imageData: data, for: id)
    }

    static func remove(for id: UUID) {
        let prefix = id.uuidString
        cache.removeObject(forKey: cacheKey(id: id, maxPixel: listMaxPixel))
        cache.removeObject(forKey: cacheKey(id: id, maxPixel: previewMaxPixel))
        let url = diskURL(for: id)
        try? FileManager.default.removeItem(at: url)
        // 兼容旧键清理
        _ = prefix
    }

    static func removeAllMemory() {
        cache.removeAllObjects()
    }

    /// 关闭面板时调用：只清内存；磁盘保留供下次打开。
    static func removeAll() {
        removeAllMemory()
    }

    // MARK: - ImageIO

    /// 使用 `CGImageSource` 缩略图 API，避免先全图解码再缩放。
    nonisolated static func downsample(data: Data, maxPixel: CGFloat) -> NSImage? {
        let maxPx = max(1, Int(maxPixel.rounded()))
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPx,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbOptions as CFDictionary
        ) else {
            return nil
        }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }

    // MARK: - Disk

    nonisolated private static func diskURL(for id: UUID) -> URL {
        // 与 MainActor 上的 diskDirectory 同源路径，避免后台读盘跳主线程。
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("SnapFlow", isDirectory: true)
            .appendingPathComponent("clipboard-thumbs", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).jpg", isDirectory: false)
    }

    nonisolated private static func loadFromDisk(id: UUID, maxPixel: CGFloat) -> NSImage? {
        let url = diskURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // 从文件生成缩略图，不经过 SwiftData。
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }
        let maxPx = max(1, Int(maxPixel.rounded()))
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPx,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbOptions as CFDictionary
        ) else {
            return nil
        }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }

    nonisolated private static func writeJPEGToDisk(_ image: NSImage, id: UUID) {
        let dir = diskURL(for: id).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return
        }
        let url = diskURL(for: id)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            return
        }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.72,
        ]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        if !CGImageDestinationFinalize(dest) {
            NSLog("[SnapFlow] clipboard thumb write failed: \(url.lastPathComponent)")
        }
    }

    private static func downsampleNSImage(_ image: NSImage, maxPixel: CGFloat) -> NSImage? {
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }
        // 已是小图时直接返回
        if max(cgImage.width, cgImage.height) <= Int(maxPixel.rounded()) {
            return image
        }
        // 经 JPEG 再解一次成本低；用 tiff 表示走 ImageIO
        guard let tiff = image.tiffRepresentation else { return image }
        return downsample(data: tiff, maxPixel: maxPixel)
    }

    // MARK: - Private

    nonisolated private static func cacheKey(id: UUID, maxPixel: CGFloat) -> NSString {
        "\(id.uuidString)#\(Int(maxPixel.rounded()))" as NSString
    }

    nonisolated private static func estimatedCost(of image: NSImage) -> Int {
        var rect = NSRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return max(1, cgImage.bytesPerRow * cgImage.height)
        }
        let pixels = max(1, image.size.width * image.size.height)
        return Int(pixels * 4)
    }
}

/// 列表缩略图冷路径门闸：同一时刻只允许一条主线程 fault 原图 Data，避免历史页首屏并发卡死。
@MainActor
enum ClipboardListThumbnailFaultGate {
    private static var locked = false
    private static var waiters: [CheckedContinuation<Void, Never>] = []

    static func withPermit<T>(_ work: () async -> T) async -> T {
        await acquire()
        defer { release() }
        return await work()
    }

    private static func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private static func release() {
        if waiters.isEmpty {
            locked = false
            return
        }
        let next = waiters.removeFirst()
        next.resume()
    }
}
