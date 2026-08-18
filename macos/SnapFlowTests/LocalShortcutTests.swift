import AppKit
import XCTest
@testable import SnapFlow

final class LocalShortcutTests: XCTestCase {
    func testMatcherRequiresConfiguredModifiersAndKey() {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "S",
            charactersIgnoringModifiers: "s",
            isARepeat: false,
            keyCode: 1
        )!

        XCTAssertTrue(LocalShortcutMatcher.matches(event, chord: "cmd+shift+s"))
        XCTAssertFalse(LocalShortcutMatcher.matches(event, chord: "cmd+s"))

        let plus = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "+",
            charactersIgnoringModifiers: "=",
            isARepeat: false,
            keyCode: 24
        )!
        XCTAssertTrue(LocalShortcutMatcher.matches(plus, chord: "cmd+plus"))
    }

    func testMatcherRecognizesBacktickAndBrackets() {
        let grave = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option, .command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "`",
            charactersIgnoringModifiers: "`",
            isARepeat: false,
            keyCode: 50
        )!
        XCTAssertTrue(LocalShortcutMatcher.matches(grave, chord: "option+command+`"))
        XCTAssertTrue(LocalShortcutMatcher.matches(grave, chord: "option+command+grave"))

        let leftBracket = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "[",
            charactersIgnoringModifiers: "[",
            isARepeat: false,
            keyCode: 33
        )!
        XCTAssertTrue(LocalShortcutMatcher.matches(leftBracket, chord: "cmd+["))
    }

    @MainActor
    func testCustomizedLocalShortcutPersists() {
        let suite = "LocalShortcutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = SettingsStore(defaults: defaults)
        first.setShortcut("cmd+e", for: .pinToggleEditor)

        let restored = SettingsStore(defaults: defaults)
        XCTAssertEqual(restored.shortcut(for: .pinToggleEditor), "cmd+e")
    }
}
