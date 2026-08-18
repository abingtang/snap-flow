import AppKit
import SwiftData
import XCTest
@testable import SnapFlow

@MainActor
final class ClipboardImageThumbnailCacheTests: XCTestCase {
    override func tearDown() {
        ClipboardImageThumbnailCache.removeAll()
        super.tearDown()
    }

    func testDownsampleLimitsLongestEdge() throws {
        let source = makeSolidImage(width: 2400, height: 1600)
        let data = try XCTUnwrap(source.tiffRepresentation)

        let thumb = try XCTUnwrap(
            ClipboardImageThumbnailCache.downsample(
                data: data,
                maxPixel: ClipboardImageThumbnailCache.listMaxPixel
            )
        )
        let longest = max(thumb.size.width, thumb.size.height)
        XCTAssertLessThanOrEqual(longest, ClipboardImageThumbnailCache.listMaxPixel + 1)
        XCTAssertGreaterThan(longest, 0)
    }

    func testThumbnailForHistoryItemUsesCacheAndClearEmptiesIt() throws {
        let settings = try makeSettings()
        let container = try makeContainer()
        let store = HistoryStore(settings: settings, modelContainer: container)
        let source = makeSolidImage(width: 1800, height: 1200)
        let data = try XCTUnwrap(source.tiffRepresentation)

        store.insert(
            payloads: [ClipboardPayload(type: NSPasteboard.PasteboardType.tiff.rawValue, value: data)],
            application: "com.apple.TextEdit",
            isUniversalClipboard: false
        )
        let item = try XCTUnwrap(store.items.first)
        XCTAssertTrue(item.hasImageRepresentation)

        let first = try XCTUnwrap(
            ClipboardImageThumbnailCache.thumbnail(
                for: item,
                maxPixel: ClipboardImageThumbnailCache.listMaxPixel
            )
        )
        let second = try XCTUnwrap(
            ClipboardImageThumbnailCache.thumbnail(
                for: item,
                maxPixel: ClipboardImageThumbnailCache.listMaxPixel
            )
        )
        // NSCache 命中应返回同一实例，避免重复解码。
        XCTAssertTrue(first === second)

        ClipboardImageThumbnailCache.removeAll()
        // 清内存后应走磁盘，仍能拿到缩略图且最长边受限。
        let third = try XCTUnwrap(
            ClipboardImageThumbnailCache.thumbnail(
                for: item,
                maxPixel: ClipboardImageThumbnailCache.listMaxPixel
            )
        )
        XCTAssertLessThanOrEqual(
            max(third.size.width, third.size.height),
            ClipboardImageThumbnailCache.listMaxPixel + 1
        )
        ClipboardImageThumbnailCache.remove(for: item.id)
    }

    func testReleaseFaultedImagePayloadsRecyclesItems() throws {
        let settings = try makeSettings()
        let container = try makeContainer()
        let store = HistoryStore(settings: settings, modelContainer: container)
        let source = makeSolidImage(width: 800, height: 600)
        let data = try XCTUnwrap(source.tiffRepresentation)
        store.insert(
            payloads: [ClipboardPayload(type: NSPasteboard.PasteboardType.tiff.rawValue, value: data)],
            application: nil,
            isUniversalClipboard: false
        )
        XCTAssertEqual(store.items.count, 1)
        let id = try XCTUnwrap(store.items.first?.id)
        // 模拟列表滚动 fault 原图
        _ = store.items.first?.primaryImageData
        store.releaseFaultedImagePayloads()
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.id, id)
        XCTAssertTrue(store.items.first?.hasImageRepresentation == true)
    }

    func testHasImageRepresentationAndPrimaryImageData() throws {
        let settings = try makeSettings()
        let container = try makeContainer()
        let store = HistoryStore(settings: settings, modelContainer: container)
        let source = makeSolidImage(width: 64, height: 48)
        let data = try XCTUnwrap(source.tiffRepresentation)

        store.insert(
            payloads: [ClipboardPayload(type: NSPasteboard.PasteboardType.tiff.rawValue, value: data)],
            application: nil,
            isUniversalClipboard: false
        )
        let item = try XCTUnwrap(store.items.first)
        XCTAssertTrue(item.hasImageRepresentation)
        XCTAssertEqual(item.kind, .image)
        XCTAssertNotNil(item.primaryImageData)
    }

    // MARK: - Helpers

    private func makeSolidImage(width: Int, height: Int) -> NSImage {
        let size = NSSize(width: width, height: height)
        return NSImage(size: size, flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: HistoryItem.self,
            HistoryItemContent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func makeSettings() throws -> SettingsStore {
        let suite = "ClipboardImageThumbnailCacheTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(defaults: defaults)
    }
}
