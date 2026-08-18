import XCTest
@testable import SnapFlow

final class SettingsNavigationTests: XCTestCase {
    private var previousLanguage: AppLanguagePreference!

    override func setUp() {
        super.setUp()
        previousLanguage = AppLanguagePreference.load()
        AppLanguagePreference.save(.simplifiedChinese)
    }

    override func tearDown() {
        AppLanguagePreference.save(previousLanguage)
        super.tearDown()
    }

    func testHistoryTabsStartWithClipboardHistory() {
        XCTAssertEqual(SettingsHistoryTab.initial, .clipboard)
        XCTAssertEqual(SettingsHistoryTab.allCases.first, .clipboard)
        XCTAssertEqual(
            SettingsHistoryTab.allCases.map(\.title),
            ["剪切板历史", "截图历史", "录制历史", "OCR 历史", "翻译历史"]
        )
    }

    func testSidebarUsesSingleHistoryPane() {
        XCTAssertTrue(SettingsPane.allCases.contains(.history))
        for removed in [
            "captureHistory",
            "ocrHistory",
            "translateHistory",
            "clipboardHistory",
            "recordingHistory",
        ] {
            XCTAssertNil(SettingsPane(rawValue: removed), "旧历史侧栏项应已移除: \(removed)")
        }
        XCTAssertEqual(SettingsPane.history.title, "历史")
        XCTAssertTrue(SettingsPane.history.showsSectionHeader)
    }

    func testSidebarSectionsGroupServicesSeparately() {
        XCTAssertEqual(
            SettingsPane.allCases.map(\.rawValue),
            [
                "capture",
                "ocrBasic",
                "translateBasic",
                "clipboard",
                "recording",
                "ocrService",
                "translateService",
                "history",
                "favorites",
                "general",
                "about",
            ]
        )
        XCTAssertEqual(SettingsPane.capture.sectionHeader, "功能")
        XCTAssertEqual(SettingsPane.ocrService.sectionHeader, "服务")
        XCTAssertEqual(SettingsPane.history.sectionHeader, "数据")
        XCTAssertEqual(SettingsPane.general.sectionHeader, "系统")
        XCTAssertTrue(SettingsPane.ocrService.showsSectionHeader)
        XCTAssertFalse(SettingsPane.translateService.showsSectionHeader)
    }
}
