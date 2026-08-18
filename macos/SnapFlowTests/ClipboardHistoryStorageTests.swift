import XCTest
@testable import SnapFlow

final class ClipboardHistoryStorageTests: XCTestCase {
    func testStorePathsUseClipboardHistoryDirectoryAndNamedStore() {
        let dir = ClipboardHistoryStorage.directoryURL
        let store = ClipboardHistoryStorage.storeURL
        XCTAssertEqual(dir.lastPathComponent, "ClipboardHistory")
        XCTAssertTrue(dir.path.hasSuffix("SnapFlow/ClipboardHistory") || dir.path.hasSuffix("SnapFlow/ClipboardHistory/"))
        XCTAssertEqual(store.lastPathComponent, "clipboard-history.store")
        XCTAssertEqual(store.deletingLastPathComponent().lastPathComponent, "ClipboardHistory")
        XCTAssertEqual(
            ClipboardHistoryStorage.supportDirectoryURL.lastPathComponent,
            ".clipboard-history_SUPPORT"
        )
    }
}
