import AppKit
import Foundation

// MARK: - Retention helpers

enum HistoryRetentionOption: Int, CaseIterable, Identifiable, Hashable {
    case oneDay = 1
    case threeDays = 3
    case sevenDays = 7
    case fourteenDays = 14
    case thirtyDays = 30
    /// 0 = 永久（仍受条数上限约束）
    case forever = 0

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .oneDay: L10n.string("1 天")
        case .threeDays: L10n.string("3 天")
        case .sevenDays: L10n.string("7 天")
        case .fourteenDays: L10n.string("14 天")
        case .thirtyDays: L10n.string("30 天")
        case .forever: L10n.string("永久")
        }
    }

    static func from(storedDays: Int) -> HistoryRetentionOption {
        allCases.first { $0.rawValue == storedDays } ?? .sevenDays
    }
}

enum FeatureHistoryIO {
    static var applicationSupportRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("SnapFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func writePNG(_ image: NSImage, to url: URL) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return false }
        do {
            try png.write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("[SnapFlow] history image save failed: \(error)")
            return false
        }
    }

    static func writePNG(cgImage: CGImage, to url: URL) -> Bool {
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        return writePNG(image, to: url)
    }

    /// 生成用于列表的缩略图（最长边 ≤ maxSide）。
    static func makeThumbnail(from image: NSImage, maxSide: CGFloat = 120) -> NSImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = NSSize(width: floor(size.width * scale), height: floor(size.height * scale))
        guard target.width >= 1, target.height >= 1 else { return nil }
        let thumb = NSImage(size: target)
        thumb.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .medium
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1
        )
        thumb.unlockFocus()
        return thumb
    }

    static func makeThumbnail(from cgImage: CGImage, maxSide: CGFloat = 120) -> NSImage? {
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        return makeThumbnail(from: image, maxSide: maxSide)
    }

    static func previewText(_ text: String, maxChars: Int = 80) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return L10n.string("（无文字）") }
        if collapsed.count <= maxChars { return collapsed }
        return String(collapsed.prefix(maxChars)) + "…"
    }

    static func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// 确保目录存在并在访达中打开。
    @discardableResult
    static func revealDirectoryInFinder(_ url: URL) -> Bool {
        ensureDirectory(url)
        return NSWorkspace.shared.open(url)
    }

    /// 若文件存在则选中显示，否则打开其父目录。
    @discardableResult
    static func revealFileInFinder(_ url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return true
        }
        return revealDirectoryInFinder(url.deletingLastPathComponent())
    }
}

// MARK: - Codable geometry / OCR lines

struct CodableRect: Codable, Hashable, Sendable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct CodableCaptureRegion: Codable, Hashable, Sendable {
    var rect: CodableRect
    var displayID: UInt32
    var scaleFactor: CGFloat

    init(_ region: CaptureRegion) {
        rect = CodableRect(region.rectInScreenPoints)
        displayID = region.displayID
        scaleFactor = region.scaleFactor
    }

    var captureRegion: CaptureRegion {
        CaptureRegion(
            rectInScreenPoints: rect.cgRect,
            displayID: CGDirectDisplayID(displayID),
            scaleFactor: scaleFactor
        )
    }
}

struct CodableOCRLine: Codable, Hashable, Sendable {
    var id: UUID
    var text: String
    var boundingBox: CodableRect
    var confidence: Float

    init(_ line: OCRLine) {
        id = line.id
        text = line.text
        boundingBox = CodableRect(line.boundingBox)
        confidence = line.confidence
    }

    var ocrLine: OCRLine {
        OCRLine(
            id: id,
            text: text,
            boundingBox: boundingBox.cgRect,
            confidence: confidence
        )
    }
}

struct TranslationServiceSnapshot: Codable, Hashable, Sendable, Identifiable {
    var id: String { serviceID }
    var serviceID: String
    var displayName: String
    var text: String
    var statusMessage: String?
}

enum TranslationHistoryKind: String, Codable, Sendable {
    case selection
    case screenTranslate

    var badgeTitle: String {
        switch self {
        case .selection: L10n.string("划词")
        case .screenTranslate: L10n.string("截图翻译")
        }
    }
}

/// 启动时清理 + 通用「清除全部」入口。
@MainActor
enum FeatureHistoryMaintenance {
    static func pruneAll(settings: SettingsStore) {
        SnipHistoryStore.shared.applyPolicy(from: settings)
        SnipHistoryStore.shared.prune()
        OCRHistoryStore.shared.applyPolicy(from: settings)
        OCRHistoryStore.shared.prune()
        TranslationHistoryStore.shared.applyPolicy(from: settings)
        TranslationHistoryStore.shared.prune()
    }

    static func clearAllFeatureHistory(settings: SettingsStore) {
        SnipHistoryStore.shared.clearAll()
        OCRHistoryStore.shared.clearAll()
        TranslationHistoryStore.shared.clearAll()
        _ = settings
    }
}
