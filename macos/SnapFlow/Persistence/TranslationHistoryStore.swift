import AppKit
import Foundation
import Observation

/// 翻译历史：划词 / 截图翻译（不含原图翻译叠层）。
@MainActor
@Observable
final class TranslationHistoryStore {
    static let shared = TranslationHistoryStore()

    struct Record: Identifiable, Codable, Hashable {
        let id: UUID
        let createdAt: Date
        let kind: TranslationHistoryKind
        let sourceText: String
        let sourceSelection: String
        let targetSelection: String
        let services: [TranslationServiceSnapshot]
        /// 截图翻译专用
        let imageFileName: String?
        let thumbFileName: String?
        let ocrText: String?
        let ocrServiceID: String?
        let lines: [CodableOCRLine]?
        let pixelWidth: Int?
        let pixelHeight: Int?

        var primaryTranslation: String {
            services.first(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.text
                ?? services.first?.statusMessage
                ?? ""
        }
    }

    private(set) var records: [Record] = []
    var maxCount: Int = 100
    var recordingEnabled: Bool = true
    var retentionDays: Int = 7

    private let directory: URL
    private let indexURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        directory = FeatureHistoryIO.applicationSupportRoot
            .appendingPathComponent("TranslationHistory", isDirectory: true)
        FeatureHistoryIO.ensureDirectory(directory)
        indexURL = directory.appendingPathComponent("index.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    func applyPolicy(from settings: SettingsStore) {
        maxCount = max(0, settings.translationHistoryLimit)
        recordingEnabled = settings.translationHistoryEnabled
        retentionDays = settings.historyRetentionDays
    }

    func recordSelection(
        sourceText: String,
        sourceSelection: String,
        targetSelection: String,
        services: [TranslationServiceSnapshot]
    ) {
        guard recordingEnabled, maxCount > 0 else { return }
        let hasContent = services.contains {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // 至少有一条成功译文才记；全失败不记
        guard hasContent else { return }

        let record = Record(
            id: UUID(),
            createdAt: Date(),
            kind: .selection,
            sourceText: sourceText,
            sourceSelection: sourceSelection,
            targetSelection: targetSelection,
            services: services,
            imageFileName: nil,
            thumbFileName: nil,
            ocrText: nil,
            ocrServiceID: nil,
            lines: nil,
            pixelWidth: nil,
            pixelHeight: nil
        )
        records.insert(record, at: 0)
        prune()
        persist()
    }

    func recordScreenTranslate(
        image: NSImage,
        cgImage: CGImage,
        sourceText: String,
        sourceSelection: String,
        targetSelection: String,
        services: [TranslationServiceSnapshot],
        ocrText: String,
        ocrServiceID: String,
        lines: [OCRLine]
    ) {
        guard recordingEnabled, maxCount > 0 else { return }
        let hasContent = services.contains {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard hasContent else { return }

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
            kind: .screenTranslate,
            sourceText: sourceText,
            sourceSelection: sourceSelection,
            targetSelection: targetSelection,
            services: services,
            imageFileName: imageName,
            thumbFileName: thumbName,
            ocrText: ocrText,
            ocrServiceID: ocrServiceID,
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

    func imageFileURL(for record: Record) -> URL? {
        guard let name = record.imageFileName else { return nil }
        return directory.appendingPathComponent(name)
    }

    func thumbnailFileURL(for record: Record) -> URL? {
        if let name = record.thumbFileName {
            return directory.appendingPathComponent(name)
        }
        return imageFileURL(for: record)
    }

    func loadImage(for record: Record) -> NSImage? {
        guard let url = imageFileURL(for: record) else { return nil }
        return NSImage(contentsOf: url)
    }

    func loadThumbnail(for record: Record) -> NSImage? {
        if let name = record.thumbFileName,
           let thumb = NSImage(contentsOf: directory.appendingPathComponent(name))
        {
            return thumb
        }
        return loadImage(for: record)
    }

    func ocrLines(for record: Record) -> [OCRLine] {
        (record.lines ?? []).map(\.ocrLine)
    }

    /// 翻译历史缓存目录（Application Support/SnapFlow/TranslationHistory）。
    var storageDirectoryURL: URL { directory }

    /// 在访达中打开翻译历史目录。
    @discardableResult
    func revealDirectoryInFinder() -> Bool {
        FeatureHistoryIO.revealDirectoryInFinder(directory)
    }

    /// 在访达中选中该条原图（无图或丢失则打开目录）。
    @discardableResult
    func revealInFinder(_ record: Record) -> Bool {
        if let url = imageFileURL(for: record) {
            return FeatureHistoryIO.revealFileInFinder(url)
        }
        return revealDirectoryInFinder()
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
            NSLog("[SnapFlow] translation history index save failed: \(error)")
        }
    }

    private func removeFiles(for record: Record) {
        if let name = record.imageFileName {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        if let name = record.thumbFileName {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
