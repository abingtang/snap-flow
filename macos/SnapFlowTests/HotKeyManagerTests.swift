import Carbon
import XCTest
@testable import SnapFlow

final class HotKeyManagerTests: XCTestCase {
    func testRecommendedTwoModifierChordsParse() {
        let capture = HotKeyChord.parse(SettingsStore.RecommendedHotkey.captureScreenshot)
        let ocr = HotKeyChord.parse(SettingsStore.RecommendedHotkey.captureOCR)
        let translate = HotKeyChord.parse(SettingsStore.RecommendedHotkey.captureTranslate)
        let clipboard = HotKeyChord.parse(SettingsStore.RecommendedHotkey.clipboard)

        XCTAssertEqual(capture?.keyCode, 1) // S
        XCTAssertEqual(capture?.modifiers, UInt32(controlKey | optionKey))

        XCTAssertEqual(ocr?.keyCode, 31) // O
        XCTAssertEqual(ocr?.modifiers, UInt32(optionKey | cmdKey))

        XCTAssertEqual(translate?.keyCode, 17) // T
        XCTAssertEqual(clipboard?.keyCode, 9) // V
        XCTAssertEqual(clipboard?.modifiers, UInt32(optionKey | cmdKey))
    }

    @MainActor
    func testLegacyAndSnipasteDefaultsMigrateToRecommended() {
        let suite = "HotKeyManagerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("f1", forKey: "hotkey.captureScreenshot")
        defaults.set("f3", forKey: "hotkey.pasteToScreen")
        defaults.set("shift+f3", forKey: "hotkey.togglePins")
        defaults.set("ctrl+option+command+o", forKey: "hotkey.captureOCR")
        defaults.set("", forKey: "hotkey.captureTranslate")
        defaults.set("cmd+shift+c", forKey: "hotkey.clipboard")

        let settings = SettingsStore(defaults: defaults)

        XCTAssertEqual(settings.hotkeyCaptureScreenshot, "ctrl+option+s")
        XCTAssertEqual(settings.hotkeyPasteToScreen, "ctrl+option+p")
        XCTAssertEqual(settings.hotkeyTogglePins, "ctrl+option+h")
        XCTAssertEqual(settings.hotkeyCaptureOCR, "option+command+o")
        XCTAssertEqual(settings.hotkeyCaptureTranslate, "option+command+t")
        XCTAssertEqual(settings.hotkeyClipboard, "option+command+v")
        XCTAssertEqual(settings.snipHistoryLimit, 100)
    }

    @MainActor
    func testCustomHotkeyIsPreserved() {
        let suite = "HotKeyManagerTests.custom.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("ctrl+shift+a", forKey: "hotkey.captureScreenshot")

        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.hotkeyCaptureScreenshot, "ctrl+shift+a")
    }

    @MainActor
    func testRestoreRecommendedHotkeys() {
        let suite = "HotKeyManagerTests.restore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("ctrl+shift+z", forKey: "hotkey.captureScreenshot")

        let settings = SettingsStore(defaults: defaults)
        settings.restoreSnipasteHotkeys()
        XCTAssertEqual(settings.hotkeyCaptureScreenshot, SettingsStore.RecommendedHotkey.captureScreenshot)
        XCTAssertEqual(settings.hotkeySelectionTranslate, SettingsStore.RecommendedHotkey.selectionTranslate)
    }

    func testPunctuationAndDigitKeyCodesParse() {
        // 用户反馈录不上的 ` 等标点 + 数字行
        XCTAssertEqual(HotKeyChord.parse("option+command+`")?.keyCode, 50)
        XCTAssertEqual(HotKeyChord.parse("option+command+grave")?.keyCode, 50)
        XCTAssertEqual(HotKeyChord.parse("ctrl+[")?.keyCode, 33)
        XCTAssertEqual(HotKeyChord.parse("ctrl+]")?.keyCode, 30)
        XCTAssertEqual(HotKeyChord.parse("cmd+\\")?.keyCode, 42)
        XCTAssertEqual(HotKeyChord.parse("cmd+;")?.keyCode, 41)
        XCTAssertEqual(HotKeyChord.parse("cmd+'")?.keyCode, 39)
        XCTAssertEqual(HotKeyChord.parse("cmd+/")?.keyCode, 44)
        XCTAssertEqual(HotKeyChord.parse("cmd+,")?.keyCode, 43)
        XCTAssertEqual(HotKeyChord.parse("cmd+.")?.keyCode, 47)
        XCTAssertEqual(HotKeyChord.parse("cmd+-")?.keyCode, 27)
        XCTAssertEqual(HotKeyChord.parse("cmd+plus")?.keyCode, 24)
        XCTAssertEqual(HotKeyChord.parse("cmd+equal")?.keyCode, 24)
        XCTAssertEqual(HotKeyChord.parse("option+1")?.keyCode, 18)
        XCTAssertEqual(HotKeyChord.parse("option+0")?.keyCode, 29)
        XCTAssertEqual(HotKeyChord.parse("cmd+delete")?.keyCode, 51)
        XCTAssertEqual(HotKeyChord.keyName(forKeyCode: 50), "`")
        XCTAssertEqual(HotKeyChord.prettyKeyName("`"), "`")
    }
}
