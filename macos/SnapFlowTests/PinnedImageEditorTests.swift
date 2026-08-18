import AppKit
import XCTest
@testable import SnapFlow

final class PinnedImageEditorTests: XCTestCase {
    @MainActor
    func testConfiguredShortcutTogglesSecondaryEditor() {
        let suite = "PinnedImageEditorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.setShortcut("space", for: .pinToggleEditor)
        let window = PinnedImageWindow(
            image: NSImage(size: NSSize(width: 120, height: 80)),
            screenRect: nil,
            settings: settings
        )
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        )!

        window.keyDown(with: event)
        XCTAssertTrue(window.isEditingAnnotations)
        window.keyDown(with: event)
        XCTAssertFalse(window.isEditingAnnotations)
        window.close()
    }

    @MainActor
    func testIdleEditorDragMovesPinAndToolbarTogether() {
        let suite = "PinnedImageEditorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = PinnedImageWindow(
            image: NSImage(size: NSSize(width: 120, height: 80)),
            screenRect: NSRect(x: 800, y: 500, width: 120, height: 80),
            settings: SettingsStore(defaults: defaults)
        )
        window.keyDown(with: keyEvent(window: window, characters: " ", keyCode: 49))
        guard let canvas = findCanvas(in: window.contentView),
              let toolbar = window.childWindows?.first
        else {
            return XCTFail("Expected editor canvas and toolbar")
        }
        let pinOrigin = window.frame.origin
        let toolbarOrigin = toolbar.frame.origin

        canvas.mouseDown(with: mouseEvent(.leftMouseDown, window: window, point: NSPoint(x: 20, y: 20)))
        canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, window: window, point: NSPoint(x: 45, y: 35)))
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, window: window, point: NSPoint(x: 45, y: 35)))

        XCTAssertEqual(window.frame.origin.x - pinOrigin.x, 25, accuracy: 0.5)
        XCTAssertEqual(window.frame.origin.y - pinOrigin.y, 15, accuracy: 0.5)
        XCTAssertEqual(toolbar.frame.origin.x - toolbarOrigin.x, 25, accuracy: 0.5)
        XCTAssertEqual(toolbar.frame.origin.y - toolbarOrigin.y, 15, accuracy: 0.5)
        window.close()
    }

    @MainActor
    private func findCanvas(in view: NSView?) -> AnnotationCanvasView? {
        guard let view else { return nil }
        if let canvas = view as? AnnotationCanvasView { return canvas }
        return view.subviews.lazy.compactMap(findCanvas(in:)).first
    }

    @MainActor
    private func keyEvent(window: NSWindow, characters: String, keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    @MainActor
    private func mouseEvent(_ type: NSEvent.EventType, window: NSWindow, point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }
}
