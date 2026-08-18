import XCTest
@testable import SnapFlow

final class CaptureToolbarLayoutTests: XCTestCase {
    private let bounds = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private let editor = NSSize(width: 360, height: 32)
    private let action = NSSize(width: 32, height: 220)
    private let options = NSSize(width: 180, height: 28)

    func testPrefersBelowAndRightWhenAllSidesHaveRoom() {
        let result = layout(selection: NSRect(x: 400, y: 300, width: 400, height: 240))
        XCTAssertFalse(result.editorInside)
        XCTAssertFalse(result.actionInside)
        XCTAssertEqual(result.editor.minY, 300 - 32 - 6, accuracy: 0.5)
        XCTAssertEqual(result.action.minX, 800 + 6, accuracy: 0.5)
    }

    func testUsesTopOutsideWhenBottomIsBlocked() {
        let result = layout(selection: NSRect(x: 400, y: 4, width: 400, height: 200))
        XCTAssertFalse(result.editorInside)
        XCTAssertFalse(result.actionInside)
        XCTAssertEqual(result.editor.minY, 204 + 6, accuracy: 0.5)
        XCTAssertEqual(result.action.minX, 800 + 6, accuracy: 0.5)
    }

    func testUsesLeftOutsideWhenRightIsBlocked() {
        let result = layout(selection: NSRect(x: 1100, y: 300, width: 320, height: 200))
        XCTAssertFalse(result.editorInside)
        XCTAssertFalse(result.actionInside)
        XCTAssertEqual(result.editor.minY, 300 - 32 - 6, accuracy: 0.5)
        XCTAssertEqual(result.action.maxX, 1100 - 6, accuracy: 0.5)
    }

    func testUsesTopAndLeftWhenBottomRightAreBlocked() {
        let result = layout(selection: NSRect(x: 1100, y: 4, width: 320, height: 200))
        XCTAssertFalse(result.editorInside)
        XCTAssertFalse(result.actionInside)
        XCTAssertEqual(result.editor.minY, 204 + 6, accuracy: 0.5)
        XCTAssertEqual(result.action.maxX, 1100 - 6, accuracy: 0.5)
    }

    func testGoesInsideOnlyWhenAllFourOutsideSlotsFail() {
        let result = layout(selection: NSRect(x: 8, y: 8, width: 1424, height: 884))
        XCTAssertTrue(result.editorInside)
        XCTAssertTrue(result.actionInside)
        XCTAssertEqual(result.editor.minY, 8 + 6, accuracy: 0.5)
        XCTAssertGreaterThan(result.action.minY, result.editor.maxY)
        XCTAssertLessThan(result.action.maxX, 8 + 1424)
    }

    func testKeepsActionOutsideLeftWhenOnlyVerticalOutsideSlotsFail() {
        let result = layout(selection: NSRect(x: 1100, y: 4, width: 320, height: 892))
        XCTAssertTrue(result.editorInside)
        XCTAssertFalse(result.actionInside)
        XCTAssertEqual(result.action.maxX, 1100 - 6, accuracy: 0.5)
    }

    func testKeepsEditorOutsideTopWhenOnlyHorizontalOutsideSlotsFail() {
        let result = layout(selection: NSRect(x: 8, y: 4, width: 1424, height: 200))
        XCTAssertFalse(result.editorInside)
        XCTAssertTrue(result.actionInside)
        XCTAssertEqual(result.editor.minY, 204 + 6, accuracy: 0.5)
        XCTAssertLessThan(result.action.maxX, 8 + 1424)
    }

    func testOptionsHeightCanFlipEditorFromBelowToAbove() {
        let tightBelow = NSRect(x: 400, y: 50, width: 400, height: 200)
        let withoutOptions = layout(selection: tightBelow, showsOptions: false)
        XCTAssertFalse(withoutOptions.editorInside)
        XCTAssertEqual(withoutOptions.editor.minY, 50 - 32 - 6, accuracy: 0.5)

        let withOptions = layout(selection: tightBelow, showsOptions: true)
        XCTAssertFalse(withOptions.editorInside)
        XCTAssertEqual(withOptions.editor.minY, 250 + 6, accuracy: 0.5)
        XCTAssertEqual(withOptions.options.minY, withOptions.editor.maxY + 6, accuracy: 0.5)
    }

    private func layout(
        selection: NSRect,
        showsOptions: Bool = false
    ) -> CaptureToolbarLayout.Result {
        CaptureToolbarLayout.frames(
            for: CaptureToolbarLayout.Request(
                bounds: bounds,
                selection: selection,
                editorSize: editor,
                actionSize: action,
                optionsSize: options,
                showsOptions: showsOptions
            )
        )
    }
}
