import AppKit
import Foundation
import Fuse
import Observation
import SwiftData

@Model
final class HistoryItem {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var fingerprint: String
    var title: String
    var searchText: String
    var application: String?
    var createdAt: Date
    var firstCreatedAt: Date
    var copyCount: Int
    var isPinned: Bool
    var pinShortcut: String?
    var isUniversalClipboard: Bool
    /// 收藏：与剪切板同结构；清空未固定 / 条数裁剪时保留。
    /// 属性级默认值便于 SwiftData 轻量迁移旧库。
    var isFavorite: Bool = false
    var favoritedAt: Date?
    @Relationship(deleteRule: .cascade, inverse: \HistoryItemContent.item)
    var contents: [HistoryItemContent]

    init(
        fingerprint: String,
        title: String,
        searchText: String,
        application: String?,
        createdAt: Date = .now,
        isUniversalClipboard: Bool,
        contents: [HistoryItemContent],
        isFavorite: Bool = false,
        favoritedAt: Date? = nil
    ) {
        self.id = UUID()
        self.fingerprint = fingerprint
        self.title = title
        self.searchText = searchText
        self.application = application
        self.createdAt = createdAt
        self.firstCreatedAt = createdAt
        self.copyCount = 1
        self.isPinned = false
        self.isUniversalClipboard = isUniversalClipboard
        self.isFavorite = isFavorite
        self.favoritedAt = favoritedAt
        self.contents = contents
    }
}

/// 列表筛选范围。
enum HistoryListScope: Sendable {
    /// 剪切板历史（全部条目）
    case clipboard
    /// 仅收藏
    case favorites
}

@Model
final class HistoryItemContent {
    var type: String
    @Attribute(.externalStorage) var value: Data?
    var item: HistoryItem?

    init(type: String, value: Data?) {
        self.type = type
        self.value = value
    }
}

struct ClipboardPayload: Sendable {
    let type: String
    let value: Data
}

extension HistoryItem {
    private static let imageContentTypes = Set(
        [
            NSPasteboard.PasteboardType.png,
            .tiff,
            .init("public.jpeg"),
            .init("public.heic"),
        ].map(\.rawValue)
    )

    var string: String? {
        guard let data = content(for: .string) else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
    }

    /// 是否含图片类型（只看 type，不读取 external storage 的 value）。
    var hasImageRepresentation: Bool {
        contents.contains { Self.imageContentTypes.contains($0.type) }
    }

    /// 第一份图片原始 Data；访问会 fault external storage，列表 UI 应优先用缩略图缓存。
    var primaryImageData: Data? {
        contents.lazy
            .filter { Self.imageContentTypes.contains($0.type) }
            .compactMap(\.value)
            .first
    }

    /// 全分辨率图（粘贴 / OCR / 翻译等需要原图时使用）。列表展示请用 `ClipboardImageThumbnailCache`。
    var image: NSImage? {
        primaryImageData.flatMap(NSImage.init(data:))
    }

    var fileURLs: [URL] {
        contents
            .filter { $0.type == NSPasteboard.PasteboardType.fileURL.rawValue }
            .compactMap(\.value)
            .compactMap { String(data: $0, encoding: .utf8) }
            .compactMap(URL.init(string:))
    }

    var kind: ClipboardItemKind {
        if !fileURLs.isEmpty { return .file }
        if hasImageRepresentation {
            return .image
        }
        return .text
    }

    func content(for type: NSPasteboard.PasteboardType) -> Data? {
        contents.first { $0.type == type.rawValue }?.value
    }
}

enum ClipboardItemKind: String, CaseIterable {
    case text
    case image
    case file
}

@MainActor
@Observable
final class HistoryStore {
    private(set) var items: [HistoryItem] = []
    /// 列表世代号：增删改/排序后递增，UI 用此轻量依赖刷新，避免 `items.map(\.id)`。
    private(set) var listEpoch: UInt64 = 0
    private let settings: SettingsStore
    private let modelContainer: ModelContainer
    private var context: ModelContext
    private let clipboardPersistence: ClipboardHistoryPersistence
    private var itemByFingerprint: [String: HistoryItem] = [:]
    private var lastMarkedCopyAt: [UUID: Date] = [:]

    /// 剪切板库目录：`Application Support/SnapFlow/ClipboardHistory/`。
    private let storageDirectoryURL: URL

    init(
        settings: SettingsStore,
        modelContainer: ModelContainer? = nil,
        inMemory: Bool = false
    ) {
        self.settings = settings
        self.storageDirectoryURL = ClipboardHistoryStorage.directoryURL
        do {
            let container: ModelContainer
            if let providedContainer = modelContainer {
                container = providedContainer
            } else if inMemory {
                let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
                container = try ModelContainer(
                    for: HistoryItem.self,
                    HistoryItemContent.self,
                    configurations: configuration
                )
            } else {
                FeatureHistoryIO.ensureDirectory(ClipboardHistoryStorage.directoryURL)
                let configuration = ModelConfiguration(
                    "clipboard-history",
                    schema: Schema([HistoryItem.self, HistoryItemContent.self]),
                    url: ClipboardHistoryStorage.storeURL,
                    cloudKitDatabase: .none
                )
                container = try ModelContainer(
                    for: HistoryItem.self,
                    HistoryItemContent.self,
                    configurations: configuration
                )
            }
            self.modelContainer = container
            self.context = ModelContext(container)
            self.clipboardPersistence = ClipboardHistoryPersistence(modelContainer: container)
            reload()
        } catch {
            fatalError("Unable to create clipboard SwiftData store: \(error)")
        }
    }

    /// 丢掉已 fault 进内存的大图 Data：换新 `ModelContext` 后重新 fetch。
    /// 供剪切板面板关闭后调用；打开面板期间不要调用（会替换 `items` 实例）。
    func releaseFaultedImagePayloads() {
        do {
            try context.save()
        } catch {
            NSLog("[SnapFlow] clipboard context save before recycle failed: \(error)")
        }
        items = []
        itemByFingerprint.removeAll(keepingCapacity: true)
        context = ModelContext(modelContainer)
        reload()
    }

    /// 在访达中打开剪切板历史数据目录（优先选中 `clipboard-history.store`）。
    @discardableResult
    func revealDirectoryInFinder() -> Bool {
        let fm = FileManager.default
        FeatureHistoryIO.ensureDirectory(storageDirectoryURL)
        let store = ClipboardHistoryStorage.storeURL
        if fm.fileExists(atPath: store.path) {
            NSWorkspace.shared.activateFileViewerSelecting([store])
            return true
        }
        if let stores = try? fm.contentsOfDirectory(
            at: storageDirectoryURL,
            includingPropertiesForKeys: nil
        ).filter({ $0.pathExtension == "store" }),
           !stores.isEmpty
        {
            NSWorkspace.shared.activateFileViewerSelecting(stores)
            return true
        }
        return FeatureHistoryIO.revealDirectoryInFinder(storageDirectoryURL)
    }

    var pinnedItems: [HistoryItem] {
        items.filter(\.isPinned).sorted { $0.createdAt > $1.createdAt }
    }

    var unpinnedItems: [HistoryItem] {
        items.filter { !$0.isPinned }.sorted { $0.createdAt > $1.createdAt }
    }

    /// 收藏列表（按收藏时间新→旧）。
    var favoriteItems: [HistoryItem] {
        items
            .filter(\.isFavorite)
            .sorted {
                ($0.favoritedAt ?? $0.createdAt) > ($1.favoritedAt ?? $1.createdAt)
            }
    }

    func search(_ query: String, scope: HistoryListScope = .clipboard) -> [HistoryItem] {
        let base: [HistoryItem]
        switch scope {
        case .clipboard:
            base = filteredClipboardItems
        case .favorites:
            base = favoriteItems
        }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }
        let exact = base.filter { $0.searchText.localizedCaseInsensitiveContains(query) }
        guard exact.isEmpty else { return exact }

        let fuse = Fuse(threshold: 0.7)
        let pattern = fuse.createPattern(from: query)
        return base.compactMap { item -> (HistoryItem, Double)? in
            guard let result = fuse.search(pattern, in: String(item.searchText.prefix(5_000))) else {
                return nil
            }
            return (item, result.score)
        }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
    }

    /// 将已有条目视为「最新复制」：刷新时间、累加次数并排到列表前部（固定项仍排在所有非固定项之前）。
    /// 短时间重复调用（如双击先选中再粘贴）只累加一次 `copyCount`。
    @discardableResult
    func markAsLatestCopy(id: UUID) -> HistoryItem? {
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        let now = Date()
        if now.timeIntervalSince(lastMarkedCopyAt[id] ?? .distantPast) > 0.45 {
            item.copyCount += 1
            lastMarkedCopyAt[id] = now
        }
        item.createdAt = now
        saveAndReload()
        return items.first(where: { $0.id == id })
    }

    func insert(
        payloads: [ClipboardPayload],
        application: String?,
        isUniversalClipboard: Bool
    ) {
        let prepared = ClipboardHistoryPreparation.prepare(payloads)
        insert(
            preparedClipboardItem: prepared,
            application: application,
            isUniversalClipboard: isUniversalClipboard
        )
    }

    /// 使用已在后台准备好的剪切板内容，避免主线程重复计算指纹和图片元数据。
    func insert(
        preparedClipboardItem prepared: ClipboardHistoryPreparedItem,
        application: String?,
        isUniversalClipboard: Bool
    ) {
        guard !prepared.payloads.isEmpty else { return }
        let now = Date()

        if let existing = itemByFingerprint[prepared.fingerprint] {
            existing.createdAt = now
            existing.copyCount += 1
            existing.application = application
            existing.isUniversalClipboard = isUniversalClipboard
            sortItemsByCreatedAt()
            saveWithoutReload()
            return
        }

        let contents = prepared.payloads.map { HistoryItemContent(type: $0.type, value: $0.value) }
        let item = HistoryItem(
            fingerprint: prepared.fingerprint,
            title: prepared.title,
            searchText: prepared.searchText,
            application: application,
            isUniversalClipboard: isUniversalClipboard,
            contents: contents
        )
        context.insert(item)
        items.append(item)
        itemByFingerprint[item.fingerprint] = item
        // 插入时用已有 Data 写缩略图，列表滚动不必再 fault 原图。
        ClipboardImageThumbnailCache.storeIfNeeded(payloads: prepared.payloads, for: item.id)
        let removedItems = trimIfNeeded()
        for removed in removedItems {
            ClipboardImageThumbnailCache.remove(for: removed.id)
        }
        removeItemsFromMemory(removedItems)
        sortItemsByCreatedAt()
        saveWithoutReload()
    }

    /// 自动剪切板记录在后台模型上下文中保存，完成后只将结果合并到主线程内存列表。
    func insertFromClipboardMonitor(
        preparedClipboardItem prepared: ClipboardHistoryPreparedItem,
        application: String?,
        isUniversalClipboard: Bool
    ) async {
        do {
            guard let result = try await clipboardPersistence.insert(
                prepared: prepared,
                application: application,
                isUniversalClipboard: isUniversalClipboard,
                historyLimit: settings.historyLimit
            ) else {
                return
            }
            applyClipboardHistoryWriteResult(result)
            ClipboardImageThumbnailCache.storeIfNeeded(payloads: prepared.payloads, for: result.itemID)
            for removedID in result.removedItemIDs {
                ClipboardImageThumbnailCache.remove(for: removedID)
            }
        } catch {
            NSLog("[SnapFlow] background clipboard SwiftData save failed: \(error)")
        }
    }

    /// 手动「添加自定义收藏」使用的来源标识（列表用星标图标区分）。
    static let manualFavoriteApplicationID = "com.snapflow.favorites.manual"

    /// 加入收藏：已存在同内容则标收藏；否则新建一条（剪切板同构）。
    @discardableResult
    func addFavorite(
        payloads: [ClipboardPayload],
        application: String? = "com.snapflow.app"
    ) -> HistoryItem? {
        guard !payloads.isEmpty else { return nil }
        let fingerprint = Self.fingerprint(payloads)
        let now = Date()

        if let existing = items.first(where: { $0.fingerprint == fingerprint }) {
            existing.isFavorite = true
            existing.favoritedAt = now
            existing.createdAt = now
            if let application { existing.application = application }
            saveAndReload()
            return existing
        }

        let contents = payloads.map { HistoryItemContent(type: $0.type, value: $0.value) }
        let metadata = Self.metadata(for: payloads)
        let item = HistoryItem(
            fingerprint: fingerprint,
            title: metadata.title,
            searchText: metadata.searchText,
            application: application,
            isUniversalClipboard: false,
            contents: contents,
            isFavorite: true,
            favoritedAt: now
        )
        context.insert(item)
        items.append(item)
        ClipboardImageThumbnailCache.storeIfNeeded(payloads: payloads, for: item.id)
        saveAndReload()
        return item
    }

    @discardableResult
    func addFavorite(text: String, application: String? = "com.snapflow.app") -> HistoryItem? {
        guard let payloads = Self.textPayloads(text) else { return nil }
        return addFavorite(payloads: payloads, application: application)
    }

    @discardableResult
    func addFavorite(image: NSImage, application: String? = "com.snapflow.app") -> HistoryItem? {
        guard let payloads = Self.imagePayloads(image) else { return nil }
        return addFavorite(payloads: payloads, application: application)
    }

    /// 文本 + 图同时收藏（OCR / 截图翻译）。
    @discardableResult
    func addFavorite(
        text: String?,
        image: NSImage?,
        application: String? = "com.snapflow.app"
    ) -> HistoryItem? {
        let payloads = Self.combinedPayloads(text: text, image: image)
        guard !payloads.isEmpty else { return nil }
        return addFavorite(payloads: payloads, application: application)
    }

    // MARK: Favorite query / toggle（无 Toast，由 UI 用实心星反馈）

    func isTextFavorited(_ text: String) -> Bool {
        guard let payloads = Self.textPayloads(text) else { return false }
        return isFavorited(payloads: payloads)
    }

    func isFavorited(text: String?, image: NSImage?) -> Bool {
        let payloads = Self.combinedPayloads(text: text, image: image)
        guard !payloads.isEmpty else { return false }
        return isFavorited(payloads: payloads)
    }

    func isFavorited(image: NSImage) -> Bool {
        guard let payloads = Self.imagePayloads(image) else { return false }
        return isFavorited(payloads: payloads)
    }

    func isFavorited(payloads: [ClipboardPayload]) -> Bool {
        guard !payloads.isEmpty else { return false }
        let fingerprint = Self.fingerprint(payloads)
        return items.first(where: { $0.fingerprint == fingerprint })?.isFavorite == true
    }

    /// 切换纯文本收藏；返回当前是否已收藏。
    @discardableResult
    func toggleFavorite(text: String, application: String? = "com.snapflow.app") -> Bool {
        guard let payloads = Self.textPayloads(text) else { return false }
        return toggleFavorite(payloads: payloads, application: application)
    }

    @discardableResult
    func toggleFavorite(
        text: String?,
        image: NSImage?,
        application: String? = "com.snapflow.app"
    ) -> Bool {
        let payloads = Self.combinedPayloads(text: text, image: image)
        guard !payloads.isEmpty else { return false }
        return toggleFavorite(payloads: payloads, application: application)
    }

    @discardableResult
    func toggleFavorite(image: NSImage, application: String? = "com.snapflow.app") -> Bool {
        guard let payloads = Self.imagePayloads(image) else { return false }
        return toggleFavorite(payloads: payloads, application: application)
    }

    @discardableResult
    func toggleFavorite(
        payloads: [ClipboardPayload],
        application: String? = "com.snapflow.app"
    ) -> Bool {
        guard !payloads.isEmpty else { return false }
        let fingerprint = Self.fingerprint(payloads)
        if let existing = items.first(where: { $0.fingerprint == fingerprint }) {
            existing.isFavorite.toggle()
            existing.favoritedAt = existing.isFavorite ? Date() : nil
            if existing.isFavorite, let application {
                existing.application = application
            }
            saveAndReload()
            return existing.isFavorite
        }
        _ = addFavorite(payloads: payloads, application: application)
        return true
    }

    private static func textPayloads(_ text: String) -> [ClipboardPayload]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return [
            ClipboardPayload(type: NSPasteboard.PasteboardType.string.rawValue, value: data),
        ]
    }

    private static func imagePayloads(_ image: NSImage) -> [ClipboardPayload]? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        return [
            ClipboardPayload(type: NSPasteboard.PasteboardType.png.rawValue, value: png),
        ]
    }

    private static func combinedPayloads(text: String?, image: NSImage?) -> [ClipboardPayload] {
        var payloads: [ClipboardPayload] = []
        if let text, let t = textPayloads(text) {
            payloads.append(contentsOf: t)
        }
        if let image, let i = imagePayloads(image) {
            payloads.append(contentsOf: i)
        }
        return payloads
    }

    func togglePin(id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        item.isPinned.toggle()
        if !item.isPinned { item.pinShortcut = nil }
        saveAndReload()
    }

    func toggleFavorite(id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        item.isFavorite.toggle()
        item.favoritedAt = item.isFavorite ? Date() : nil
        saveAndReload()
    }

    func setFavorite(_ favorite: Bool, id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        item.isFavorite = favorite
        item.favoritedAt = favorite ? (item.favoritedAt ?? Date()) : nil
        saveAndReload()
    }

    func setPinShortcut(_ chord: String?, id: UUID) {
        guard let item = items.first(where: { $0.id == id }), item.isPinned else { return }
        let chord = chord?.isEmpty == true ? nil : chord
        if let chord {
            items.filter { $0.id != id && $0.pinShortcut == chord }.forEach {
                $0.pinShortcut = nil
            }
        }
        item.pinShortcut = chord
        saveAndReload()
    }

    func delete(id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        ClipboardImageThumbnailCache.remove(for: item.id)
        context.delete(item)
        saveAndReload()
    }

    /// 从收藏移除（不删除条目本身；若无其它引用仍保留在剪切板列表）。
    func removeFavorite(id: UUID) {
        setFavorite(false, id: id)
    }

    func clearFavorites() {
        items.filter(\.isFavorite).forEach {
            $0.isFavorite = false
            $0.favoritedAt = nil
        }
        saveAndReload()
    }

    func clearUnpinned() {
        // 固定与收藏均保留
        let removing = items.filter { !$0.isPinned && !$0.isFavorite }
        for item in removing {
            ClipboardImageThumbnailCache.remove(for: item.id)
        }
        removing.forEach(context.delete)
        saveAndReload()
    }

    func trimToCurrentLimit() {
        let removed = trimIfNeeded()
        for item in removed {
            ClipboardImageThumbnailCache.remove(for: item.id)
        }
        saveAndReload()
    }

    private var filteredClipboardItems: [HistoryItem] {
        (pinnedItems + unpinnedItems).filter {
            switch $0.kind {
            case .text: settings.clipboardRecordsText
            case .image: settings.clipboardRecordsImages
            case .file: settings.clipboardRecordsFiles
            }
        }
    }

    private func reload() {
        let descriptor = FetchDescriptor<HistoryItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        items = (try? context.fetch(descriptor)) ?? []
        rebuildFingerprintIndex()
        bumpListEpoch()
    }

    private func rebuildFingerprintIndex() {
        itemByFingerprint.removeAll(keepingCapacity: true)
        for item in items where itemByFingerprint[item.fingerprint] == nil {
            itemByFingerprint[item.fingerprint] = item
        }
        let currentIDs = Set(items.map(\.id))
        lastMarkedCopyAt = lastMarkedCopyAt.filter { currentIDs.contains($0.key) }
    }

    private func sortItemsByCreatedAt() {
        items.sort { $0.createdAt > $1.createdAt }
    }

    private func bumpListEpoch() {
        listEpoch &+= 1
    }

    private func removeItemsFromMemory(_ removedItems: [HistoryItem]) {
        removeItemsFromMemory(ids: Set(removedItems.map(\.id)))
    }

    private func removeItemsFromMemory(ids removedIDs: Set<UUID>) {
        guard !removedIDs.isEmpty else { return }
        let removedFingerprints = itemByFingerprint.compactMap { fingerprint, item in
            removedIDs.contains(item.id) ? fingerprint : nil
        }
        items.removeAll { removedIDs.contains($0.id) }
        for fingerprint in removedFingerprints {
            itemByFingerprint.removeValue(forKey: fingerprint)
        }
    }

    private func applyClipboardHistoryWriteResult(_ result: ClipboardHistoryWriteResult) {
        removeItemsFromMemory(ids: result.removedItemIDs)

        let item = itemByFingerprint[result.fingerprint] ?? fetchItem(id: result.itemID)
        guard let item else { return }

        item.createdAt = result.createdAt
        item.copyCount = result.copyCount
        item.application = result.application
        item.isUniversalClipboard = result.isUniversalClipboard
        if !items.contains(where: { $0.id == item.id }) {
            items.append(item)
        }
        itemByFingerprint[result.fingerprint] = item
        sortItemsByCreatedAt()
        // 后台合并写入后通知 UI 重建筛选缓存。
        bumpListEpoch()
    }

    private func fetchItem(id: UUID) -> HistoryItem? {
        let descriptor = FetchDescriptor<HistoryItem>(
            predicate: #Predicate { $0.id == id }
        )
        do {
            return try context.fetch(descriptor).first
        } catch {
            NSLog("[SnapFlow] clipboard history merge fetch failed: \(error)")
            return nil
        }
    }

    private func saveAndReload() {
        do {
            try context.save()
            reload()
        } catch {
            NSLog("[SnapFlow] clipboard SwiftData save failed: \(error)")
        }
    }

    private func saveWithoutReload() {
        do {
            try context.save()
            // 内存 items 已改但未 reload，仍需通知 UI 重建筛选缓存。
            bumpListEpoch()
        } catch {
            NSLog("[SnapFlow] clipboard SwiftData save failed: \(error)")
        }
    }

    @discardableResult
    private func trimIfNeeded() -> [HistoryItem] {
        let limit = max(settings.historyLimit, 10)
        // 裁剪时跳过固定与收藏
        let overflow = Array(unpinnedItems
            .filter { !$0.isFavorite }
            .dropFirst(limit))
        overflow.forEach(context.delete)
        return overflow
    }

    private static func fingerprint(_ payloads: [ClipboardPayload]) -> String {
        ClipboardHistoryPreparation.fingerprint(payloads)
    }

    private static func metadata(for payloads: [ClipboardPayload]) -> (title: String, searchText: String) {
        let metadata = ClipboardHistoryPreparation.metadata(for: payloads)
        return (metadata.title, metadata.searchText)
    }
}
