import AppKit
import AVFoundation
import Foundation
import Observation

/// 单条录制历史；仅登记 SnapFlow 自己生成的媒体。
struct RecordingHistoryItem: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var filePath: String
    var format: ScreenRecordingFormat
    var createdAt: Date
    var durationSeconds: TimeInterval
    var pixelWidth: Int
    var pixelHeight: Int
    var displayID: UInt32
    var containsSystemAudio: Bool
    var containsMicrophone: Bool
    var isFavorite: Bool
    var endedAbnormally: Bool
    /// SnapFlow 自有文件：删除历史时一并删媒体。
    var isOwnedBySnapFlow: Bool
    var fileByteSize: Int64
    var thumbnailFileName: String?

    var fileURL: URL { URL(fileURLWithPath: filePath) }

    var fileExists: Bool {
        FileManager.default.fileExists(atPath: filePath)
    }

    var displayTitle: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }
}

enum RecordingHistoryFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case mp4
    case gif
    case favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: L10n.string("全部")
        case .mp4: "MP4"
        case .gif: "GIF"
        case .favorites: L10n.string("收藏")
        }
    }
}

/// 独立录制历史：JSON 索引 + 缩略图目录，不扫描用户目录。
@MainActor
@Observable
final class RecordingHistoryStore {
    private(set) var items: [RecordingHistoryItem] = []
    private(set) var isOverLimitWithOnlyFavorites = false
    private(set) var indexLoadFailed = false

    private let settings: SettingsStore
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(settings: SettingsStore, fileManager: FileManager = .default) {
        self.settings = settings
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        load()
        pruneIfNeeded()
    }

    static var rootDirectory: URL {
        FeatureHistoryIO.applicationSupportRoot
            .appendingPathComponent("RecordingHistory", isDirectory: true)
    }

    static var indexURL: URL {
        rootDirectory.appendingPathComponent("index.json")
    }

    static var thumbnailsDirectory: URL {
        rootDirectory.appendingPathComponent("thumbnails", isDirectory: true)
    }

    var totalMediaBytes: Int64 {
        items.reduce(0) { $0 + max(0, $1.fileByteSize) }
    }

    func filtered(_ filter: RecordingHistoryFilter) -> [RecordingHistoryItem] {
        let sorted = items.sorted { $0.createdAt > $1.createdAt }
        switch filter {
        case .all:
            return sorted
        case .mp4:
            return sorted.filter { $0.format == .mp4 }
        case .gif:
            return sorted.filter { $0.format == .gif }
        case .favorites:
            return sorted.filter(\.isFavorite)
        }
    }

    @discardableResult
    func register(
        fileURL: URL,
        format: ScreenRecordingFormat,
        createdAt: Date = Date(),
        durationSeconds: TimeInterval,
        pixelWidth: Int,
        pixelHeight: Int,
        displayID: CGDirectDisplayID,
        containsSystemAudio: Bool,
        containsMicrophone: Bool,
        endedAbnormally: Bool = false,
        isOwnedBySnapFlow: Bool = true
    ) -> RecordingHistoryItem? {
        guard settings.recordingHistoryEnabled else { return nil }

        FeatureHistoryIO.ensureDirectory(Self.rootDirectory)
        FeatureHistoryIO.ensureDirectory(Self.thumbnailsDirectory)

        let byteSize = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        var item = RecordingHistoryItem(
            id: UUID().uuidString,
            filePath: fileURL.path,
            format: format,
            createdAt: createdAt,
            durationSeconds: durationSeconds,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            displayID: UInt32(displayID),
            containsSystemAudio: containsSystemAudio,
            containsMicrophone: containsMicrophone,
            isFavorite: false,
            endedAbnormally: endedAbnormally,
            isOwnedBySnapFlow: isOwnedBySnapFlow,
            fileByteSize: byteSize,
            thumbnailFileName: nil
        )
        items.insert(item, at: 0)
        persist()
        pruneIfNeeded()
        Task { [weak self] in
            await self?.generateThumbnail(for: item.id)
        }
        // 重新读取以反映 prune 后的状态。
        if let updated = items.first(where: { $0.id == item.id }) {
            item = updated
        }
        return item
    }

    func setFavorite(_ favorite: Bool, id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isFavorite = favorite
        persist()
        pruneIfNeeded()
    }

    func toggleFavorite(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isFavorite.toggle()
        persist()
        pruneIfNeeded()
    }

    /// 删除历史；自有文件同步删媒体与缩略图；缺失/外部文件只删元数据。
    func delete(id: String, deleteMediaIfOwned: Bool = true) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: index)
        if deleteMediaIfOwned, item.isOwnedBySnapFlow, item.fileExists {
            try? fileManager.removeItem(at: item.fileURL)
        }
        if let thumb = item.thumbnailFileName {
            let thumbURL = Self.thumbnailsDirectory.appendingPathComponent(thumb)
            try? fileManager.removeItem(at: thumbURL)
        }
        persist()
        refreshOverLimitFlag()
    }

    func item(id: String) -> RecordingHistoryItem? {
        items.first(where: { $0.id == id })
    }

    func reload() {
        load()
        pruneIfNeeded()
    }

    func openInDefaultApp(id: String) {
        guard let item = item(id: id), item.fileExists else {
            FeedbackCenter.shared.post(L10n.string("录制文件不存在或已被移动"), level: .error)
            return
        }
        NSWorkspace.shared.open(item.fileURL)
    }

    func revealInFinder(id: String) {
        guard let item = item(id: id) else { return }
        if item.fileExists {
            _ = FeatureHistoryIO.revealFileInFinder(item.fileURL)
        } else {
            FeedbackCenter.shared.post(L10n.string("文件已不存在，仅保留历史记录"), level: .error)
        }
    }

    /// 打开媒体目录 `~/Movies/SnapFlow/`。
    @discardableResult
    func revealDirectoryInFinder() -> Bool {
        try? fileManager.createDirectory(
            at: ScreenRecordingFileStore.directory,
            withIntermediateDirectories: true
        )
        return FeatureHistoryIO.revealDirectoryInFinder(ScreenRecordingFileStore.directory)
    }

    /// 清空历史；自有媒体一并删除。
    func clearAll(deleteMediaIfOwned: Bool = true) {
        let ids = items.map(\.id)
        for id in ids {
            delete(id: id, deleteMediaIfOwned: deleteMediaIfOwned)
        }
    }

    func pruneIfNeeded() {
        guard settings.recordingHistoryEnabled else {
            isOverLimitWithOnlyFavorites = false
            return
        }

        var changed = false
        let retentionDays = settings.historyRetentionDays
        if retentionDays > 0 {
            let cutoff = Date().addingTimeInterval(-TimeInterval(retentionDays) * 24 * 3600)
            let expired = items.filter { !$0.isFavorite && $0.createdAt < cutoff }
            for item in expired {
                delete(id: item.id)
                changed = true
            }
        }

        // 数量上限：优先删除最旧未收藏项。
        let limit = max(0, settings.recordingHistoryLimit)
        if limit > 0 {
            while items.count > limit {
                guard let victim = items
                    .filter({ !$0.isFavorite })
                    .min(by: { $0.createdAt < $1.createdAt })
                else { break }
                delete(id: victim.id)
                changed = true
            }
        }

        // 媒体大小上限。
        let maxBytes = settings.recordingHistoryMaxMediaBytes
        if maxBytes > 0 {
            while totalMediaBytes > maxBytes {
                guard let victim = items
                    .filter({ !$0.isFavorite })
                    .min(by: { $0.createdAt < $1.createdAt })
                else { break }
                delete(id: victim.id)
                changed = true
            }
        }

        refreshOverLimitFlag()
        if changed {
            // delete 已 persist
        }
    }

    private func refreshOverLimitFlag() {
        let limit = max(0, settings.recordingHistoryLimit)
        let maxBytes = settings.recordingHistoryMaxMediaBytes
        let countOver = limit > 0 && items.count > limit
        let sizeOver = maxBytes > 0 && totalMediaBytes > maxBytes
        let onlyFavoritesLeft = !items.isEmpty && items.allSatisfy(\.isFavorite)
        isOverLimitWithOnlyFavorites = (countOver || sizeOver) && onlyFavoritesLeft
    }

    private func load() {
        FeatureHistoryIO.ensureDirectory(Self.rootDirectory)
        FeatureHistoryIO.ensureDirectory(Self.thumbnailsDirectory)
        let url = Self.indexURL
        guard fileManager.fileExists(atPath: url.path) else {
            items = []
            indexLoadFailed = false
            return
        }
        do {
            let data = try Data(contentsOf: url)
            items = try decoder.decode([RecordingHistoryItem].self, from: data)
            indexLoadFailed = false
            settings.recordingIndexCorruptedNotice = false
        } catch {
            // 损坏时备份并空索引，不扫描目录、不删媒体。
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let backup = Self.rootDirectory
                .appendingPathComponent("index.corrupt-\(stamp).json")
            try? fileManager.moveItem(at: url, to: backup)
            items = []
            indexLoadFailed = true
            settings.recordingIndexCorruptedNotice = true
            persist()
        }
    }

    private func persist() {
        FeatureHistoryIO.ensureDirectory(Self.rootDirectory)
        do {
            let data = try encoder.encode(items)
            let temp = Self.indexURL.appendingPathExtension("tmp")
            try data.write(to: temp, options: .atomic)
            if fileManager.fileExists(atPath: Self.indexURL.path) {
                try fileManager.removeItem(at: Self.indexURL)
            }
            try fileManager.moveItem(at: temp, to: Self.indexURL)
        } catch {
            NSLog("[SnapFlow] recording history persist failed: \(error)")
        }
    }

    private func generateThumbnail(for id: String) async {
        guard let item = item(id: id), item.fileExists else { return }
        let thumbName = "\(id).jpg"
        let thumbURL = Self.thumbnailsDirectory.appendingPathComponent(thumbName)
        let generated = await Task.detached(priority: .utility) {
            Self.makeThumbnailJPEG(from: item.fileURL, to: thumbURL)
        }.value
        guard generated else { return }
        await MainActor.run {
            guard let index = self.items.firstIndex(where: { $0.id == id }) else { return }
            self.items[index].thumbnailFileName = thumbName
            self.persist()
        }
    }

    nonisolated private static func makeThumbnailJPEG(from fileURL: URL, to destination: URL) -> Bool {
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        do {
            let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
            let image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
            else { return false }
            try data.write(to: destination, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func thumbnailImage(for item: RecordingHistoryItem) -> NSImage? {
        guard let name = item.thumbnailFileName else { return nil }
        let url = Self.thumbnailsDirectory.appendingPathComponent(name)
        return NSImage(contentsOf: url)
    }
}
