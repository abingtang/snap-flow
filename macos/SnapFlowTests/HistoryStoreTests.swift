import AppKit
import SwiftData
import XCTest
@testable import SnapFlow

@MainActor
final class HistoryStoreTests: XCTestCase {
    func testSwiftDataPersistsDedupeAndClearKeepsPinnedItems() throws {
        let settings = try makeSettings()
        let container = try makeContainer()
        let store = HistoryStore(settings: settings, modelContainer: container)

        insert("普通内容", into: store)
        insert("需要固定", into: store)
        let pinnedID = try XCTUnwrap(store.items.first?.id)
        store.togglePin(id: pinnedID)
        insert("普通内容", into: store)

        let reloaded = HistoryStore(settings: settings, modelContainer: container)
        XCTAssertEqual(reloaded.items.count, 2)
        XCTAssertEqual(reloaded.items.first { $0.string == "普通内容" }?.copyCount, 2)
        XCTAssertEqual(reloaded.pinnedItems.compactMap(\.string), ["需要固定"])

        reloaded.clearUnpinned()
        XCTAssertEqual(reloaded.items.compactMap(\.string), ["需要固定"])
        XCTAssertTrue(reloaded.items[0].isPinned)
    }

    func testFavoriteSurvivesClearUnpinnedAndSearchScope() throws {
        let settings = try makeSettings()
        let container = try makeContainer()
        let store = HistoryStore(settings: settings, modelContainer: container)

        insert("普通一条", into: store)
        insert("收藏这条", into: store)
        let favoriteID = try XCTUnwrap(store.items.first { $0.string == "收藏这条" }?.id)
        store.toggleFavorite(id: favoriteID)

        XCTAssertEqual(store.favoriteItems.count, 1)
        XCTAssertEqual(store.search("", scope: .favorites).compactMap(\.string), ["收藏这条"])

        store.clearUnpinned()
        XCTAssertEqual(store.items.compactMap(\.string), ["收藏这条"])
        XCTAssertTrue(store.items[0].isFavorite)

        store.clearFavorites()
        XCTAssertTrue(store.favoriteItems.isEmpty)
        // 取消收藏后条目仍在（未删除）
        XCTAssertEqual(store.items.compactMap(\.string), ["收藏这条"])
    }

    func testImagePayloadRoundTripsThroughSwiftData() throws {
        let settings = try makeSettings()
        let container = try makeContainer()
        let store = HistoryStore(settings: settings, modelContainer: container)
        let image = NSImage(size: NSSize(width: 24, height: 16), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let data = try XCTUnwrap(image.tiffRepresentation)

        store.insert(
            payloads: [ClipboardPayload(type: NSPasteboard.PasteboardType.tiff.rawValue, value: data)],
            application: "com.apple.TextEdit",
            isUniversalClipboard: false
        )

        let reloaded = HistoryStore(settings: settings, modelContainer: container)
        let item = try XCTUnwrap(reloaded.items.first)
        XCTAssertEqual(item.kind, .image)
        XCTAssertNotNil(item.image)
        XCTAssertEqual(item.application, "com.apple.TextEdit")
    }

    func testMarkAsLatestCopyMovesAfterPinnedAndBumpsTime() throws {
        let settings = try makeSettings()
        let container = try makeContainer()
        let store = HistoryStore(settings: settings, modelContainer: container)

        insert("旧条目", into: store)
        insert("中间", into: store)
        insert("要置顶固定", into: store)
        let pinnedID = try XCTUnwrap(store.items.first { $0.string == "要置顶固定" }?.id)
        store.togglePin(id: pinnedID)

        let oldID = try XCTUnwrap(store.items.first { $0.string == "旧条目" }?.id)
        let beforeCount = try XCTUnwrap(store.items.first { $0.id == oldID }?.copyCount)
        store.markAsLatestCopy(id: oldID)

        let ordered = store.search("", scope: .clipboard).compactMap(\.string)
        // 固定项在最前，被选中的「旧条目」紧随其后（非固定区顶部）
        XCTAssertEqual(ordered.first, "要置顶固定")
        XCTAssertEqual(ordered.dropFirst().first, "旧条目")
        let promoted = try XCTUnwrap(store.items.first { $0.id == oldID })
        XCTAssertEqual(promoted.copyCount, beforeCount + 1)
        XCTAssertGreaterThanOrEqual(promoted.createdAt, store.items.first { $0.string == "中间" }?.createdAt ?? .distantPast)
    }

    func testMixedTextAndImageWritesAsSeparatePasteboardItems() throws {
        let settings = try makeSettings()
        let container = try makeContainer()
        let store = HistoryStore(settings: settings, modelContainer: container)
        let image = NSImage(size: NSSize(width: 24, height: 16), flipped: false) { rect in
            NSColor.systemGreen.setFill()
            rect.fill()
            return true
        }
        let imageData = try XCTUnwrap(image.tiffRepresentation)

        store.insert(
            payloads: [
                ClipboardPayload(
                    type: NSPasteboard.PasteboardType.string.rawValue,
                    value: Data("123123".utf8)
                ),
                ClipboardPayload(
                    type: NSPasteboard.PasteboardType.tiff.rawValue,
                    value: imageData
                ),
                ClipboardPayload(
                    type: NSPasteboard.PasteboardType.fileURL.rawValue,
                    value: Data("file:///tmp/SnapFlowTests.png".utf8)
                ),
            ],
            application: "com.tencent.xinWeChat",
            isUniversalClipboard: false
        )

        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(item.string, "123123")
        XCTAssertNotNil(item.image)

        let monitor = PasteboardMonitor(historyStore: store, settings: settings)
        XCTAssertEqual(
            monitor.pasteboardContentGroups(for: item, includeFileContents: false).count,
            2
        )
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("SnapFlowTests.\(UUID().uuidString)"))
        XCTAssertTrue(monitor.writeToPasteboard(item, pasteboard: pasteboard))

        let writtenItems = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(writtenItems.count, 3)
        XCTAssertTrue(
            writtenItems.contains {
                $0.types.contains(.string)
            }
        )
        XCTAssertTrue(
            writtenItems.contains {
                $0.types.contains(.tiff)
            }
        )
    }

    func testTransientPasteboardSuppressionDoesNotConsumeNextCopy() async throws {
        let settings = try makeSettings()
        let container = try makeContainer()
        let store = HistoryStore(settings: settings, modelContainer: container)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("SnapFlowTests.\(UUID().uuidString)"))
        let monitor = PasteboardMonitor(
            historyStore: store,
            settings: settings,
            pasteboard: pasteboard
        )

        monitor.beginTransientChangeSuppression()
        pasteboard.clearContents()
        pasteboard.setString("模拟取词内容", forType: .string)
        monitor.endTransientChangeSuppression()

        pasteboard.clearContents()
        pasteboard.setString("用户真实复制", forType: .string)
        await monitor.poll()

        XCTAssertEqual(store.items.compactMap(\.string), ["用户真实复制"])
    }

    func testHistoryListWindowingUsesInitialAndIncrementalBatches() {
        XCTAssertEqual(HistoryListWindowing.initialCount(totalCount: 12), 12)
        XCTAssertEqual(HistoryListWindowing.initialCount(totalCount: 200), 40)
        XCTAssertEqual(
            HistoryListWindowing.nextCount(current: 40, totalCount: 200),
            60
        )
        XCTAssertEqual(
            HistoryListWindowing.nextCount(current: 190, totalCount: 200),
            200
        )
    }

    func testHistoryListWindowingPrefetchesNearBatchEnd() {
        XCTAssertFalse(
            HistoryListWindowing.shouldLoadMore(
                itemIndex: 20,
                visibleCount: 40,
                totalCount: 200
            )
        )
        XCTAssertTrue(
            HistoryListWindowing.shouldLoadMore(
                itemIndex: 37,
                visibleCount: 40,
                totalCount: 200
            )
        )
        XCTAssertFalse(
            HistoryListWindowing.shouldLoadMore(
                itemIndex: 39,
                visibleCount: 40,
                totalCount: 40
            )
        )
    }

    func testHistoryListWindowingExpandsToKeepSelectedItemVisible() {
        XCTAssertEqual(
            HistoryListWindowing.countRequired(toShow: 8, totalCount: 200),
            40
        )
        XCTAssertEqual(
            HistoryListWindowing.countRequired(toShow: 43, totalCount: 200),
            60
        )
        XCTAssertEqual(
            HistoryListWindowing.countRequired(toShow: 195, totalCount: 200),
            200
        )
    }

    func testHistoryListWindowingCountsOnlyInsertedIDs() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        XCTAssertEqual(
            HistoryListWindowing.insertedCount(
                currentIDs: [third, first, second],
                previousIDs: [first, second]
            ),
            1
        )
        XCTAssertEqual(
            HistoryListWindowing.insertedCount(
                currentIDs: [first, second],
                previousIDs: [first, second]
            ),
            0
        )
    }

    private func insert(_ string: String, into store: HistoryStore) {
        store.insert(
            payloads: [
                ClipboardPayload(
                    type: NSPasteboard.PasteboardType.string.rawValue,
                    value: Data(string.utf8)
                ),
            ],
            application: nil,
            isUniversalClipboard: false
        )
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: HistoryItem.self,
            HistoryItemContent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func makeSettings() throws -> SettingsStore {
        let suite = "HistoryStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(defaults: defaults)
    }
}
