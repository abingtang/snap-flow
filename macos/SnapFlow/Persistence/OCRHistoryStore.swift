import AppKit
import Foundation
import Observation

/// OCR 识别历史：图 + 全文 + 识别框，本地 Application Support。
@MainActor
@Observable
final class OCRHistoryStore {
    static let shared = OCRHistoryStore()

    struct Record: Identifiable, Codable, Hashable {
        let id: UUID
        let createdAt: Date
        let imageFileName: String
        let thumbFileName: String
        let text: String
        let serviceID: String
        let serviceDisplayName: String
        let lines: [CodableOCRLine]
        let pixelWidth: Int
        let pixelHeight: Int
    }

    private(set) var records: [Record] = []
    var maxCount: Int = 100
    var recordingEnabled: Bool = true
    /// 0 = 永久
    var retentionDays: Int = 7

    private let directory: URL
    private let indexURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        directory = FeatureHistoryIO.applicationSupportRoot
            .appendingPathComponent("OCRHistory", isDirectory: true)
        FeatureHistoryIO.ensureDirectory(directory)
        indexURL = directory.appendingPathComponent("index.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    func applyPolicy(from settings: SettingsStore) {
        maxCount = max(0, settings.ocrHistoryLimit)
        recordingEnabled = settings.ocrHistoryEnabled
        retentionDays = settings.historyRetentionDays
    }

    /// 识别完成快照（含无字）；失败不调用。
    func recordSuccess(
        image: NSImage,
        cgImage: CGImage,
        text: String,
        lines: [OCRLine],
        serviceID: String,
        serviceDisplayName: String
    ) {
        guard recordingEnabled, maxCount > 0 else { return }

        let id = UUID()
        let imageName = "\(id.uuidString).png"
        let thumbName = "\(id.uuidString)_thumb.png"
        let imageURL = directory.appendingPathComponent(imageName)
        let thumbURL = directory.appendingPathComponent(thumbName)
        guard FeatureHistoryIO.writePNG(cgImage: cgImage, to: imageURL) else { return }
        if let thumb = FeatureHistoryIO.makeThumbnail(from: image)
            ?? FeatureHistoryIO.makeThumbnail(from: cgImage)
        {
            _ = FeatureHistoryIO.writePNG(thumb, to: thumbURL)
        } else {
            _ = FeatureHistoryIO.writePNG(cgImage: cgImage, to: thumbURL)
        }

        let record = Record(
            id: id,
            createdAt: Date(),
            imageFileName: imageName,
            thumbFileName: thumbName,
            text: text,
            serviceID: serviceID,
            serviceDisplayName: serviceDisplayName,
            lines: lines.map(CodableOCRLine.init),
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height
        )
        records.insert(record, at: 0)
        prune()
        persist()
    }

    func delete(id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let record = records.remove(at: index)
        removeFiles(for: record)
        persist()
    }

    func clearAll() {
        for record in records {
            removeFiles(for: record)
        }
        records.removeAll()
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
        if records.count != before {
            persist()
        }
    }

    func imageFileURL(for record: Record) -> URL {
        directory.appendingPathComponent(record.imageFileName)
    }

    func thumbnailFileURL(for record: Record) -> URL {
        directory.appendingPathComponent(record.thumbFileName)
    }

    func loadImage(for record: Record) -> NSImage? {
        NSImage(contentsOf: imageFileURL(for: record))
    }

    func loadThumbnail(for record: Record) -> NSImage? {
        let thumb = NSImage(contentsOf: thumbnailFileURL(for: record))
        return thumb ?? loadImage(for: record)
    }

    func ocrLines(for record: Record) -> [OCRLine] {
        record.lines.map(\.ocrLine)
    }

    /// OCR 历史缓存目录（Application Support/SnapFlow/OCRHistory）。
    var storageDirectoryURL: URL { directory }

    /// 在访达中打开 OCR 历史目录。
    @discardableResult
    func revealDirectoryInFinder() -> Bool {
        FeatureHistoryIO.revealDirectoryInFinder(directory)
    }

    /// 在访达中选中该条原图（丢失则打开目录）。
    @discardableResult
    func revealInFinder(_ record: Record) -> Bool {
        FeatureHistoryIO.revealFileInFinder(imageFileURL(for: record))
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
    }

    private func persist() {
        do {
            let data = try encoder.encode(records)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            NSLog("[SnapFlow] OCR history index save failed: \(error)")
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
}
