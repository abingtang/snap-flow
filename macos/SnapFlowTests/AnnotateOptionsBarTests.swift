import AppKit
import XCTest
@testable import SnapFlow

@MainActor
final class AnnotateOptionsBarTests: XCTestCase {
    func testNumericFieldsAcceptKeyboardValuesAndClampRanges() throws {
        let bar = AnnotateOptionsBar(frame: .zero)

        bar.show(for: .pen)
        let lineWidthField = try XCTUnwrap(numericFields(in: bar).first)
        lineWidthField.stringValue = "7"
        XCTAssertTrue(lineWidthField.sendAction(lineWidthField.action, to: lineWidthField.target))
        XCTAssertEqual(bar.style.lineWidth, 7)

        bar.show(for: .text)
        let fontSizeField = try XCTUnwrap(numericFields(in: bar).first)
        fontSizeField.stringValue = "999"
        XCTAssertTrue(fontSizeField.sendAction(fontSizeField.action, to: fontSizeField.target))
        XCTAssertEqual(bar.style.fontSize, 120)
        XCTAssertEqual(fontSizeField.stringValue, "120")

        for tool in [AnnotateTool.shape, .arrow, .pen, .highlighter, .eraser, .text, .number] {
            bar.show(for: tool)
            XCTAssertEqual(numericFields(in: bar).count, 1, "\(tool) 应提供一个数字输入框")
        }

        bar.show(for: .mosaic)
        XCTAssertTrue(bar.isHidden, "马赛克不应显示二级选项条")
        XCTAssertEqual(numericFields(in: bar).count, 0)
        XCTAssertEqual(bar.frame.size, .zero)
    }

    func testMosaicHidesSecondaryOptionsBar() {
        let bar = AnnotateOptionsBar(frame: .zero)
        bar.show(for: .pen)
        XCTAssertFalse(bar.isHidden)

        bar.show(for: .mosaic)
        XCTAssertTrue(bar.isHidden)
        XCTAssertTrue(bar.subviews.isEmpty)
        XCTAssertEqual(bar.frame.size, .zero)
    }

    func testHitTestReturnsNumericFieldForMouseFocus() throws {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
        let bar = AnnotateOptionsBar(frame: NSRect(x: 20, y: 20, width: 300, height: 50))
        parent.addSubview(bar)
        bar.show(for: .pen)
        bar.frame = NSRect(origin: bar.frame.origin, size: bar.preferredSize())
        bar.layoutSubtreeIfNeeded()

        let field = try XCTUnwrap(numericFields(in: bar).first)
        let pointInBar = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: bar)
        let pointInParent = bar.convert(pointInBar, to: parent)

        XCTAssertTrue(bar.hitTest(pointInParent) === field)
    }

    func testShowingSameToolPreservesNumericFieldAndDraftText() throws {
        let bar = AnnotateOptionsBar(frame: .zero)
        bar.show(for: .pen)

        let field = try XCTUnwrap(numericFields(in: bar).first)
        field.stringValue = "17"

        // 截图窗口鼠标移动时会重复布局二级工具栏，不能因此重建输入框。
        bar.show(for: .pen)

        let refreshedField = try XCTUnwrap(numericFields(in: bar).first)
        XCTAssertTrue(refreshedField === field)
        XCTAssertEqual(refreshedField.stringValue, "17")
    }

    func testCursorUsesTextCursorInsideWidthInputAndArrowOutsideControls() throws {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
        let bar = AnnotateOptionsBar(frame: NSRect(x: 20, y: 20, width: 300, height: 50))
        parent.addSubview(bar)
        bar.show(for: .pen)
        bar.frame = NSRect(origin: bar.frame.origin, size: bar.preferredSize())
        bar.layoutSubtreeIfNeeded()

        let field = try XCTUnwrap(numericFields(in: bar).first)
        let fieldPoint = field.convert(
            NSPoint(x: field.bounds.midX, y: field.bounds.midY),
            to: bar
        )
        XCTAssertTrue(bar.cursor(at: fieldPoint) === NSCursor.iBeam)

        let backgroundPoint = NSPoint(x: bar.bounds.maxX - 1, y: bar.bounds.maxY - 1)
        XCTAssertTrue(bar.cursor(at: backgroundPoint) === NSCursor.arrow)
    }

    func testHighlighterOptionsExposeLineAndAreaChoices() {
        let bar = AnnotateOptionsBar(frame: .zero)

        bar.show(for: .highlighter)

        XCTAssertEqual(bar.style.highlighterMode, .line)
        XCTAssertNotNil(bar.subviews.first { $0.toolTip == "直线" })
        XCTAssertNotNil(bar.subviews.first { $0.toolTip == "区域" })
    }

    func testEraserOptionsToggleSmearAndRectModes() {
        let bar = AnnotateOptionsBar(frame: .zero)
        bar.show(for: .eraser)

        XCTAssertEqual(bar.style.eraserMode, .smear)
        XCTAssertNotNil(bar.subviews.first { $0.toolTip == "涂抹" })
        XCTAssertNotNil(bar.subviews.first { $0.toolTip == "框选" })
        XCTAssertEqual(numericFields(in: bar).count, 1, "涂抹模式应显示粗细")

        // 切到框选：粗细隐藏
        bar.style.eraserMode = .rect
        bar.show(for: .eraser)
        XCTAssertEqual(bar.style.eraserMode, .rect)
        XCTAssertEqual(numericFields(in: bar).count, 0, "框选模式不应显示粗细")

        bar.style.eraserMode = .smear
        bar.show(for: .eraser)
        XCTAssertEqual(numericFields(in: bar).count, 1, "回到涂抹应恢复粗细")
    }

    func testEachToolKeepsIndependentColorAndSizeDefaultsRed() {
        let bar = AnnotateOptionsBar(frame: .zero)

        bar.show(for: .pen)
        XCTAssertTrue(bar.style.color.isEqual(NSColor.systemRed))
        bar.style.color = .systemBlue
        bar.style.lineWidth = 9

        bar.show(for: .arrow)
        XCTAssertTrue(bar.style.color.isEqual(NSColor.systemRed), "箭头应使用独立默认红色，不受画笔影响")
        XCTAssertEqual(bar.style.lineWidth, 3)
        bar.style.color = .systemGreen
        bar.style.lineWidth = 5

        bar.show(for: .pen)
        XCTAssertTrue(bar.style.color.isEqual(NSColor.systemBlue), "画笔应记住自己的蓝色")
        XCTAssertEqual(bar.style.lineWidth, 9)

        bar.show(for: .arrow)
        XCTAssertTrue(bar.style.color.isEqual(NSColor.systemGreen))
        XCTAssertEqual(bar.style.lineWidth, 5)

        bar.show(for: .text)
        XCTAssertTrue(bar.style.color.isEqual(NSColor.systemRed), "文字默认红色")
        bar.style.fontSize = 28

        bar.show(for: .pen)
        XCTAssertEqual(bar.style.lineWidth, 9)
        bar.show(for: .text)
        XCTAssertEqual(bar.style.fontSize, 28)
    }

    private func numericFields(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { subview -> [NSTextField] in
            let current = (subview as? NSTextField).map { [$0] } ?? []
            return current + numericFields(in: subview)
        }
    }
}
