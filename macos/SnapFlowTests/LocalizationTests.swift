import XCTest
@testable import SnapFlow

@MainActor
final class LocalizationTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "SnapFlow.LocalizationTests.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testSystemPreferenceFallsBackToSupportedLanguages() {
        XCTAssertEqual(
            AppLanguagePreference.bestSupportedLanguageCode(from: ["zh-Hans-CN", "en"]),
            "zh-Hans"
        )
        XCTAssertEqual(
            AppLanguagePreference.bestSupportedLanguageCode(from: ["en-US", "zh-Hans"]),
            "en"
        )
        XCTAssertEqual(
            AppLanguagePreference.bestSupportedLanguageCode(from: ["fr-FR", "de-DE"]),
            "zh-Hans"
        )
        XCTAssertEqual(
            AppLanguagePreference.bestSupportedLanguageCode(from: ["zh-Hant-TW"]),
            "zh-Hans"
        )
    }

    func testSettingsStorePersistsLanguagePreference() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.appLanguagePreference, .system)

        store.appLanguagePreference = .english
        XCTAssertEqual(AppLanguagePreference.load(from: defaults), .english)

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.appLanguagePreference, .english)
        XCTAssertEqual(reloaded.resolvedLocale.identifier, "en")
    }

    func testActionTitlesResolveForEnglishAndChinese() {
        let previous = AppLanguagePreference.load()
        defer { AppLanguagePreference.save(previous) }

        AppLanguagePreference.save(.simplifiedChinese)
        XCTAssertEqual(AppAction.captureScreenshot.title, "区域截图")
        XCTAssertEqual(AppAction.openSettings.title, "偏好设置")

        AppLanguagePreference.save(.english)
        XCTAssertEqual(AppAction.captureScreenshot.title, "Capture Region")
        XCTAssertEqual(AppAction.openSettings.title, "Settings")
        XCTAssertEqual(AppAction.quit.title, "Quit")
    }

    func testSettingsPaneTitlesResolveForEnglish() {
        let previous = AppLanguagePreference.load()
        defer { AppLanguagePreference.save(previous) }

        AppLanguagePreference.save(.english)
        XCTAssertEqual(SettingsPane.history.title, "History")
        XCTAssertEqual(SettingsPane.general.title, "General")
        XCTAssertEqual(SettingsPane.capture.sectionHeader, "Features")
        XCTAssertEqual(SettingsHistoryTab.clipboard.title, "Clipboard History")
    }

    func testBundleLookupIgnoresProcessLocale() {
        // 不依赖 UserDefaults：直接按语言码取 lproj，避免 String(localized:locale:) 回落开发语言
        XCTAssertEqual(
            L10n.string("settings.pane.capture", languageCode: "en"),
            "Capture"
        )
        XCTAssertEqual(
            L10n.string("settings.pane.capture", languageCode: "zh-Hans"),
            "截图"
        )
        XCTAssertEqual(
            L10n.string("language.section_title", languageCode: "en"),
            "Interface Language"
        )
        XCTAssertEqual(
            L10n.string("language.section_tip", languageCode: "en").hasPrefix("Takes effect"),
            true
        )
    }
}
