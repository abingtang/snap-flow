import AppKit
import Foundation
import Observation

/// 截图历史：成功截图记录 + 上次区域（R）+ 设置页可浏览列表。
/// 与框选 prev/next 共用同一数据源。
@MainActor
@Observable
final class SnipHistoryStore {
    static let shared = SnipHistoryStore()

    struct Record: Identifiable, Codable, Hashable {
        let id: UUID
        let region: CodableCaptureRegion
        let imageFileName: String
        let thumbFileName: String
        let createdAt: Date
        let pixelWidth: Int
        let pixelHeight: Int

        var captureRegion: CaptureRegion { region.captureRegion }
    }

    private(set) var lastSuccessfulRegion: CaptureRegion?
    /// 新→旧
    private(set) var records: [Record] = []
    /// 浏览历史时的游标；-1 表示当前实时截图
    private(set) var browseIndex: Int = -1
    var maxCount: Int = 100
    var recordingEnabled: Bool = true
    /// 0 = 永久
    var retentionDays: Int = 7

    fileprivate let directory: URL
    private let indexURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        let base = FeatureHistoryIO.applicationSupportRoot
        directory = base.appendingPathComponent("SnipHistory", isDirectory: true)
        FeatureHistoryIO.ensureDirectory(directory)
        indexURL = directory.appendingPathComponent("index.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        load()
        // 兼容旧版：目录里有散落 PNG、无 index 时扫描
        if records.isEmpty {
            migrateLoosePNGsIfNeeded()
        }
    }

    func applyPolicy(from settings: SettingsStore) {
        maxCount = max(0, settings.snipHistoryLimit)
        recordingEnabled = settings.snipHistoryEnabled
        retentionDays = settings.historyRetentionDays
    }

    func recordSuccess(region: CaptureRegion, image: NSImage) {
        lastSuccessfulRegion = region
        guard recordingEnabled, maxCount > 0 else { return }

        let id = UUID()
        let imageName = "\(id.uuidString).png"
        let thumbName = "\(id.uuidString)_thumb.png"
        let imageURL = directory.appendingPathComponent(imageName)
        let thumbURL = directory.appendingPathComponent(thumbName)
        guard FeatureHistoryIO.writePNG(image, to: imageURL) else { return }
        if let thumb = FeatureHistoryIO.makeThumbnail(from: image) {
            _ = FeatureHistoryIO.writePNG(thumb, to: thumbURL)
        } else {
            _ = FeatureHistoryIO.writePNG(image, to: thumbURL)
        }

        let pixelSize = imagePixelSize(image)
        let record = Record(
            id: id,
            region: CodableCaptureRegion(region),
            imageFileName: imageName,
            thumbFileName: thumbName,
            createdAt: Date(),
            pixelWidth: pixelSize.width,
            pixelHeight: pixelSize.height
        )
        records.insert(record, at: 0)
        browseIndex = -1
        prune()
        persist()
    }

    func resetBrowse() {
        browseIndex = -1
    }

    /// 上一条历史；无则 nil（records 新→旧，browse 从最新往旧）
    func previous() -> Record? {
        guard !records.isEmpty else { return nil }
        if browseIndex < 0 {
            browseIndex = 0
        } else if browseIndex < records.count - 1 {
            browseIndex += 1
        }
        return records[browseIndex]
    }

    /// 下一条历史（更靠近「当前」）
    func next() -> Record? {
        guard !records.isEmpty else { return nil }
        if browseIndex < 0 {
            return nil
        }
        if browseIndex > 0 {
            browseIndex -= 1
            return records[browseIndex]
        }
        browseIndex = -1
        return nil
    }

    func loadImage(for record: Record) -> NSImage? {
        NSImage(contentsOf: directory.appendingPathComponent(record.imageFileName))
    }

    func thumbnailFileURL(for record: Record) -> URL {
        directory.appendingPathComponent(record.thumbFileName)
    }

    func loadThumbnail(for record: Record) -> NSImage? {
        let thumb = NSImage(contentsOf: thumbnailFileURL(for: record))
        return thumb ?? loadImage(for: record)
    }

    /// 截图文件目录（Application Support/SnapFlow/SnipHistory）。
    var storageDirectoryURL: URL { directory }

    func imageFileURL(for record: Record) -> URL {
        directory.appendingPathComponent(record.imageFileName)
    }

    /// 在访达中打开历史目录。
    @discardableResult
    func revealDirectoryInFinder() -> Bool {
        FeatureHistoryIO.revealDirectoryInFinder(directory)
    }

    /// 在访达中选中该条截图文件。
    @discardableResult
    func revealInFinder(_ record: Record) -> Bool {
        FeatureHistoryIO.revealFileInFinder(imageFileURL(for: record))
    }

    func delete(id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let record = records.remove(at: index)
        removeFiles(for: record)
        if browseIndex >= records.count {
            browseIndex = records.isEmpty ? -1 : records.count - 1
        }
        persist()
    }

    func clearAll() {
        for record in records {
            removeFiles(for: record)
        }
        records.removeAll()
        browseIndex = -1
        persist()
    }

    func prune() {
        let before = records.count
        if retentionDays > 0 {
            let cutoff = Date().addingTimeInterval(-TimeInterval(retentionDays) * 24 * 3600)
            let expired = records.filter { $0.createdAt < cutoff }
            for record in expired {
                removeFiles(for: record)
            }
            records.removeAll { $0.createdAt < cutoff }
        }
        while maxCount > 0, records.count > maxCount {
            let old = records.removeLast()
            removeFiles(for: old)
        }
        if browseIndex >= records.count {
            browseIndex = records.isEmpty ? -1 : records.count - 1
        }
        if records.count != before {
            persist()
        }
    }

    /// 快捷保存目录
    static var quickSaveDirectory: URL {
        let pics = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = pics.appendingPathComponent("SnapFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func quickSaveFileURL(quality: Int = -1) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let ext = SnipImageExport.fileExtension(quality: quality)
        return quickSaveDirectory.appendingPathComponent("SnapFlow_\(f.string(from: Date())).\(ext)")
    }

    // MARK: - Private

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? decoder.decode([Record].self, from: data)
        else {
            records = []
            return
        }
        records = decoded.sorted { $0.createdAt > $1.createdAt }
        if let first = records.first {
            lastSuccessfulRegion = first.captureRegion
        }
    }

    private func persist() {
        do {
            let data = try encoder.encode(records)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            NSLog("[SnapFlow] snip history index save failed: \(error)")
        }
    }

    private func removeFiles(for record: Record) {
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(record.imageFileName)
        )
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(record.thumbFileName)
        )
    }

    private func imagePixelSize(_ image: NSImage) -> (width: Int, height: Int) {
        var rect = NSRect(origin: .zero, size: image.size)
        if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return (cg.width, cg.height)
        }
        return (Int(image.size.width), Int(image.size.height))
    }

    /// 旧版只写 UUID.png、无 index：按文件修改时间导入。
    private func migrateLoosePNGsIfNeeded() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let pngs = files.filter {
            $0.pathExtension.lowercased() == "png"
                && !$0.lastPathComponent.contains("_thumb")
                && $0.lastPathComponent != "index.json"
        }
        guard !pngs.isEmpty else { return }

        var imported: [Record] = []
        for url in pngs {
            let idString = url.deletingPathExtension().lastPathComponent
            let id = UUID(uuidString: idString) ?? UUID()
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let date = values?.contentModificationDate ?? Date()
            let image = NSImage(contentsOf: url)
            let pixelSize = image.map { imagePixelSize($0) } ?? (width: 0, height: 0)
            let thumbName = "\(id.uuidString)_thumb.png"
            let thumbURL = directory.appendingPathComponent(thumbName)
            if !fm.fileExists(atPath: thumbURL.path), let image {
                if let thumb = FeatureHistoryIO.makeThumbnail(from: image) {
                    _ = FeatureHistoryIO.writePNG(thumb, to: thumbURL)
                }
            }
            // 区域未知：占位零区，仅保留图；R 恢复可能不准
            let placeholder = CaptureRegion(
                rectInScreenPoints: .zero,
                displayID: CGMainDisplayID(),
                scaleFactor: NSScreen.main?.backingScaleFactor ?? 2
            )
            imported.append(
                Record(
                    id: id,
                    region: CodableCaptureRegion(placeholder),
                    imageFileName: url.lastPathComponent,
                    thumbFileName: thumbName,
                    createdAt: date,
                    pixelWidth: pixelSize.width,
                    pixelHeight: pixelSize.height
                )
            )
        }
        records = imported.sorted { $0.createdAt > $1.createdAt }
        if let first = records.first {
            lastSuccessfulRegion = first.captureRegion
        }
        persist()
    }
}
