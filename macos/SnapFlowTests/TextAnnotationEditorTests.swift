import AppKit
import XCTest
@testable import SnapFlow

@MainActor
final class TextAnnotationEditorTests: XCTestCase {
    func testSelectionFrameChangePreservesAnnotationScreenPosition() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 180),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: window.contentView!.bounds)
        window.contentView = root
        let canvas = AnnotationCanvasView(frame: NSRect(x: 10, y: 20, width: 100, height: 100))
        root.addSubview(canvas)
        canvas.tool = .pen

        canvas.mouseDown(with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: NSPoint(x: 30, y: 50), in: window)))
        canvas.mouseDragged(with: try XCTUnwrap(mouseEvent(.leftMouseDragged, at: NSPoint(x: 50, y: 70), in: window)))
        canvas.mouseUp(with: try XCTUnwrap(mouseEvent(.leftMouseUp, at: NSPoint(x: 50, y: 70), in: window)))
        let oldLocalStart = try XCTUnwrap(canvas.strokes.first).start
        let oldScreenStart = NSPoint(
            x: oldLocalStart.x + canvas.frame.minX,
            y: oldLocalStart.y + canvas.frame.minY
        )

        canvas.setSelectionFrame(NSRect(x: 40, y: 30, width: 120, height: 110))

        let newLocalStart = try XCTUnwrap(canvas.strokes.first).start
        let newScreenStart = NSPoint(
            x: newLocalStart.x + canvas.frame.minX,
            y: newLocalStart.y + canvas.frame.minY
        )
        XCTAssertEqual(canvas.strokes.count, 1)
        XCTAssertEqual(newScreenStart, oldScreenStart)
    }

    func testEraserPreviewMatchesCurrentWidth() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let canvas = AnnotationCanvasView(frame: window.contentView!.bounds)
        window.contentView = canvas
        canvas.tool = .eraser
        canvas.eraserWidth = 24

        canvas.mouseMoved(
            with: try XCTUnwrap(mouseEvent(.mouseMoved, at: NSPoint(x: 50, y: 40), in: window))
        )

        XCTAssertEqual(canvas.eraserPreviewRect, NSRect(x: 38, y: 28, width: 24, height: 24))
    }

    func testEraserClearsAnnotationsWithoutSamplingBaseImage() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let canvas = AnnotationCanvasView(frame: window.contentView!.bounds)
        window.contentView = canvas
        canvas.baseImage = splitColorImage()

        canvas.tool = .pen
        canvas.strokeColor = .systemBlue
        canvas.penWidth = 12
        canvas.mouseDown(with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: NSPoint(x: 20, y: 50), in: window)))
        canvas.mouseDragged(with: try XCTUnwrap(mouseEvent(.leftMouseDragged, at: NSPoint(x: 80, y: 50), in: window)))
        canvas.mouseUp(with: try XCTUnwrap(mouseEvent(.leftMouseUp, at: NSPoint(x: 80, y: 50), in: window)))

        canvas.tool = .eraser
        canvas.eraserMode = .smear
        canvas.eraserWidth = 20
        canvas.mouseDown(with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: NSPoint(x: 50, y: 40), in: window)))
        canvas.mouseDragged(with: try XCTUnwrap(mouseEvent(.leftMouseDragged, at: NSPoint(x: 50, y: 60), in: window)))
        canvas.mouseUp(with: try XCTUnwrap(mouseEvent(.leftMouseUp, at: NSPoint(x: 50, y: 60), in: window)))

        let image = try XCTUnwrap(canvas.compositeCGImage())
        let color = try XCTUnwrap(pixelColor(in: image, x: 45, y: 50))

        XCTAssertGreaterThan(color.redComponent, 0.9)
        XCTAssertLessThan(color.greenComponent, 0.4)
    }

    func testRectEraserClearsRegionWithoutBrushWidth() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 100),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let canvas = AnnotationCanvasView(frame: window.contentView!.bounds)
        window.contentView = canvas
        canvas.baseImage = splitColorImage()

        canvas.tool = .pen
        canvas.strokeColor = .systemBlue
        canvas.penWidth = 16
        canvas.mouseDown(with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: NSPoint(x: 10, y: 50), in: window)))
        canvas.mouseDragged(with: try XCTUnwrap(mouseEvent(.leftMouseDragged, at: NSPoint(x: 110, y: 50), in: window)))
        canvas.mouseUp(with: try XCTUnwrap(mouseEvent(.leftMouseUp, at: NSPoint(x: 110, y: 50), in: window)))

        canvas.tool = .eraser
        canvas.eraserMode = .rect
        canvas.mouseDown(with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: NSPoint(x: 40, y: 30), in: window)))
        canvas.mouseDragged(with: try XCTUnwrap(mouseEvent(.leftMouseDragged, at: NSPoint(x: 90, y: 70), in: window)))
        canvas.mouseUp(with: try XCTUnwrap(mouseEvent(.leftMouseUp, at: NSPoint(x: 90, y: 70), in: window)))

        XCTAssertEqual(canvas.strokes.last?.tool, .eraser)
        XCTAssertEqual(canvas.strokes.last?.eraserMode, .rect)

        let image = try XCTUnwrap(canvas.compositeCGImage())
        // 框选中心应露出底图红色
        let erased = try XCTUnwrap(pixelColor(in: image, x: 60, y: 50))
        XCTAssertGreaterThan(erased.redComponent, 0.9)
        XCTAssertLessThan(erased.greenComponent, 0.4)

        // 框选外的笔迹仍在（偏左）
        let kept = try XCTUnwrap(pixelColor(in: image, x: 20, y: 50))
        XCTAssertLessThan(kept.redComponent, 0.5)
    }

    func testEraserPreviewHiddenInRectMode() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let canvas = AnnotationCanvasView(frame: window.contentView!.bounds)
        window.contentView = canvas
        canvas.tool = .eraser
        canvas.eraserMode = .rect
        canvas.eraserWidth = 24
        canvas.mouseMoved(
            with: try XCTUnwrap(mouseEvent(.mouseMoved, at: NSPoint(x: 50, y: 40), in: window))
        )
        XCTAssertNil(canvas.eraserPreviewRect)
    }

    func testActiveShapeCanBeEditedAfterDrawing() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 120),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let canvas = AnnotationCanvasView(frame: window.contentView!.bounds)
        window.contentView = canvas
        canvas.tool = .shape

        canvas.mouseDown(with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: window)))
        canvas.mouseDragged(with: try XCTUnwrap(mouseEvent(.leftMouseDragged, at: NSPoint(x: 100, y: 70), in: window)))
        canvas.mouseUp(with: try XCTUnwrap(mouseEvent(.leftMouseUp, at: NSPoint(x: 100, y: 70), in: window)))

        XCTAssertEqual(canvas.strokes.count, 1)
        canvas.apply(
            options: AnnotateOptionsBar.Style(
                color: .systemBlue,
                lineWidth: 9,
                filled: true,
                shapeKind: .ellipse
            )
        )

        let stroke = try XCTUnwrap(canvas.strokes.first)
        XCTAssertTrue(stroke.color.isEqual(NSColor.systemBlue))
        XCTAssertEqual(stroke.lineWidth, 9)
        XCTAssertEqual(stroke.shapeKind, .ellipse)
        XCTAssertEqual(stroke.text, "fill")
    }

    func testAdjustingPenWidthUpdatesActiveShapeLineWidth() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 120),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let canvas = AnnotationCanvasView(frame: window.contentView!.bounds)
        window.contentView = canvas
        canvas.tool = .shape

        canvas.mouseDown(with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: window)))
        canvas.mouseDragged(with: try XCTUnwrap(mouseEvent(.leftMouseDragged, at: NSPoint(x: 100, y: 70), in: window)))
        canvas.mouseUp(with: try XCTUnwrap(mouseEvent(.leftMouseUp, at: NSPoint(x: 100, y: 70), in: window)))

        let originalWidth = try XCTUnwrap(canvas.strokes.first).lineWidth

        // scrollWheel 将正向滚轮增量转换为 +1；这里直接验证其共享的线宽调整逻辑。
        canvas.adjustPenWidth(delta: 1)

        let updated = try XCTUnwrap(canvas.strokes.first)
        XCTAssertEqual(updated.lineWidth, originalWidth + 1, accuracy: 0.5)
        XCTAssertEqual(canvas.penWidth, originalWidth + 1, accuracy: 0.5)
    }

    func testActiveArrowResizesFromEndpointAndChangesAngle() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 140),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let canvas = AnnotationCanvasView(frame: window.contentView!.bounds)
        window.contentView = canvas
        canvas.tool = .arrow

        canvas.mouseDown(with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: NSPoint(x: 30, y: 30), in: window)))
        canvas.mouseDragged(with: try XCTUnwrap(mouseEvent(.leftMouseDragged, at: NSPoint(x: 110, y: 50), in: window)))
        canvas.mouseUp(with: try XCTUnwrap(mouseEvent(.leftMouseUp, at: NSPoint(x: 110, y: 50), in: window)))

        let original = try XCTUnwrap(canvas.strokes.first)
        let target = NSPoint(x: original.start.x, y: original.start.y + 40)
        canvas.mouseDown(with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: original.start, in: window)))
        canvas.mouseDragged(with: try XCTUnwrap(mouseEvent(.leftMouseDragged, at: target, in: window)))
        canvas.mouseUp(with: try XCTUnwrap(mouseEvent(.leftMouseUp, at: target, in: window)))

        let resized = try XCTUnwrap(canvas.strokes.first)
        XCTAssertEqual(resized.start.x, target.x, accuracy: 0.5)
        XCTAssertEqual(resized.start.y, target.y, accuracy: 0.5)
        XCTAssertEqual(resized.end.x, original.end.x, accuracy: 0.5)
        XCTAssertEqual(resized.end.y, original.end.y, accuracy: 0.5)
    }

    func testChangingAnnotationToolClearsActiveStroke() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 140),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let canvas = AnnotationCanvasView(frame: window.contentView!.bounds)
        window.contentView = canvas
        canvas.tool = .shape

        canvas.mouseDown(with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: window)))
        canvas.mouseDragged(with: try XCTUnwrap(mouseEvent(.leftMouseDragged, at: NSPoint(x: 100, y: 70), in: window)))
        canvas.mouseUp(with: try XCTUnwrap(mouseEvent(.leftMouseUp, at: NSPoint(x: 100, y: 70), in: window)))

        XCTAssertNotNil(canvas.activeStroke)
        XCTAssertEqual(canvas.strokes.count, 1)

        canvas.tool = .arrow

        XCTAssertNil(canvas.activeStroke)
        XCTAssertEqual(canvas.strokes.count, 1)
    }

    func testPenCanChangeWidthButDoesNotResizeAsAStroke() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 140),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let canvas = AnnotationCanvasView(frame: window.contentView!.bounds)
        window.contentView = canvas
        canvas.tool = .pen
        canvas.penWidth = 4

        canvas.mouseDown(with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: window)))
        canvas.mouseDragged(with: try XCTUnwrap(mouseEvent(.leftMouseDragged, at: NSPoint(x: 60, y: 45), in: window)))
        canvas.mouseDragged(with: try XCTUnwrap(mouseEvent(.leftMouseDragged, at: NSPoint(x: 100, y: 70), in: window)))
        canvas.mouseUp(with: try XCTUnwrap(mouseEvent(.leftMouseUp, at: NSPoint(x: 100, y: 70), in: window)))

        let original = try XCTUnwrap(canvas.strokes.first)
        canvas.adjustPenWidth(delta: 1)
        let widened = try XCTUnwrap(canvas.strokes.first)
        XCTAssertEqual(widened.lineWidth, 5, accuracy: 0.5)

        canvas.tool = .none
        let target = NSPoint(x: widened.end.x + 20, y: widened.end.y + 15)
        canvas.mouseDown(with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: widened.end, in: window)))
        canvas.mouseDragged(with: try XCTUnwrap(mouseEvent(.leftMouseDragged, at: target, in: window)))
        canvas.mouseUp(with: try XCTUnwrap(mouseEvent(.leftMouseUp, at: target, in: window)))

        let moved = try XCTUnwrap(canvas.strokes.first)
        XCTAssertEqual(moved.points.count, original.points.count)
        XCTAssertEqual(moved.start.x - widened.start.x, 20, accuracy: 0.5)
        XCTAssertEqual(moved.start.y - widened.start.y, 15, accuracy: 0.5)
        XCTAssertEqual(moved.end.x - widened.end.x, 20, accuracy: 0.5)
        XCTAssertEqual(moved.end.y - widened.end.y, 15, accuracy: 0.5)
    }

    func testHighlighterSupportsStraightLineAndAreaModes() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 160),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let canvas = AnnotationCanvasView(frame: window.contentView!.bounds)
        window.contentView = canvas
        canvas.tool = .highlighter
        canvas.highlighterMode = .line

        canvas.mouseDown(with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: window)))
        canvas.mouseDragged(with: try XCTUnwrap(mouseEvent(.leftMouseDragged, at: NSPoint(x: 60, y: 35), in: window)))
        canvas.mouseDragged(with: try XCTUnwrap(mouseEvent(.leftMouseDragged, at: NSPoint(x: 100, y: 55), in: window)))
        canvas.mouseUp(with: try XCTUnwrap(mouseEvent(.leftMouseUp, at: NSPoint(x: 100, y: 55), in: window)))

        let line = try XCTUnwrap(canvas.strokes.first)
        XCTAssertEqual(line.highlighterMode, .line)
        XCTAssertEqual(line.points.count, 1)
        XCTAssertEqual(line.end.x, 100, accuracy: 0.5)
        XCTAssertEqual(line.end.y, 55, accuracy: 0.5)

        let lineTarget = NSPoint(x: line.end.x + 15, y: line.end.y + 25)
        canvas.mouseDown(with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: line.end, in: window)))
        canvas.mouseDragged(with: try XCTUnwrap(mouseEvent(.leftMouseDragged, at: lineTarget, in: window)))
        canvas.mouseUp(with: try XCTUnwrap(mouseEvent(.leftMouseUp, at: lineTarget, in: window)))
        let resizedLine = try XCTUnwrap(canvas.strokes.first)
        XCTAssertEqual(resizedLine.end.x, lineTarget.x, accuracy: 0.5)
        XCTAssertEqual(resizedLine.end.y, lineTarget.y, accuracy: 0.5)

        canvas.highlighterMode = .area
        canvas.mouseDown(with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: NSPoint(x: 20, y: 90), in: window)))
        canvas.mouseDragged(with: try XCTUnwrap(mouseEvent(.leftMouseDragged, at: NSPoint(x: 80, y: 130), in: window)))
        canvas.mouseUp(with: try XCTUnwrap(mouseEvent(.leftMouseUp, at: NSPoint(x: 80, y: 130), in: window)))

        let area = try XCTUnwrap(canvas.strokes.last)
        XCTAssertEqual(area.highlighterMode, .area)
        XCTAssertEqual(area.points.count, 1)
        XCTAssertEqual(area.bounds.width, 60, accuracy: 0.5)
        XCTAssertEqual(area.bounds.height, 40, accuracy: 0.5)

        let rightHandle = NSPoint(x: area.bounds.maxX + 5, y: area.bounds.midY)
        canvas.mouseDown(with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: rightHandle, in: window)))
        canvas.mouseDragged(with: try XCTUnwrap(mouseEvent(.leftMouseDragged, at: NSPoint(x: rightHandle.x + 20, y: rightHandle.y), in: window)))
        canvas.mouseUp(with: try XCTUnwrap(mouseEvent(.leftMouseUp, at: NSPoint(x: rightHandle.x + 20, y: rightHandle.y), in: window)))

        let resizedArea = try XCTUnwrap(canvas.strokes.last)
        XCTAssertEqual(resizedArea.bounds.width, 80, accuracy: 0.5)
        XCTAssertEqual(resizedArea.bounds.height, 40, accuracy: 0.5)
    }

    func testExistingShapeCanBeSelectedForSecondEdit() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 120),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let canvas = AnnotationCanvasView(frame: window.contentView!.bounds)
        window.contentView = canvas
        canvas.tool = .shape

        canvas.mouseDown(with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: window)))
        canvas.mouseDragged(with: try XCTUnwrap(mouseEvent(.leftMouseDragged, at: NSPoint(x: 100, y: 70), in: window)))
        canvas.mouseUp(with: try XCTUnwrap(mouseEvent(.leftMouseUp, at: NSPoint(x: 100, y: 70), in: window)))

        let originalStart = try XCTUnwrap(canvas.strokes.first).start
        canvas.tool = .none
        canvas.mouseDown(with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: NSPoint(x: 60, y: 45), in: window)))
        canvas.mouseDragged(with: try XCTUnwrap(mouseEvent(.leftMouseDragged, at: NSPoint(x: 70, y: 55), in: window)))
        canvas.mouseUp(with: try XCTUnwrap(mouseEvent(.leftMouseUp, at: NSPoint(x: 70, y: 55), in: window)))
        canvas.apply(options: AnnotateOptionsBar.Style(color: .systemGreen, lineWidth: 6))

        let stroke = try XCTUnwrap(canvas.strokes.first)
        XCTAssertEqual(stroke.start.x, originalStart.x + 10, accuracy: 0.5)
        XCTAssertEqual(stroke.start.y, originalStart.y + 10, accuracy: 0.5)
        XCTAssertTrue(stroke.color.isEqual(NSColor.systemGreen))
        XCTAssertEqual(stroke.lineWidth, 6)
    }

    func testActiveShapeCanBeResizedFromSelectionHandle() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 120),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let canvas = AnnotationCanvasView(frame: window.contentView!.bounds)
        window.contentView = canvas
        canvas.tool = .shape

        canvas.mouseDown(with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: window)))
        canvas.mouseDragged(with: try XCTUnwrap(mouseEvent(.leftMouseDragged, at: NSPoint(x: 100, y: 70), in: window)))
        canvas.mouseUp(with: try XCTUnwrap(mouseEvent(.leftMouseUp, at: NSPoint(x: 100, y: 70), in: window)))

        let original = try XCTUnwrap(canvas.strokes.first)
        let handle = NSPoint(x: original.bounds.maxX + 5, y: original.bounds.midY)
        canvas.mouseDown(with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: handle, in: window)))
        canvas.mouseDragged(
            with: try XCTUnwrap(
                mouseEvent(.leftMouseDragged, at: NSPoint(x: handle.x + 20, y: handle.y), in: window)
            )
        )
        canvas.mouseUp(
            with: try XCTUnwrap(
                mouseEvent(.leftMouseUp, at: NSPoint(x: handle.x + 20, y: handle.y), in: window)
            )
        )

        let resized = try XCTUnwrap(canvas.strokes.first)
        XCTAssertEqual(resized.start.x, original.start.x, accuracy: 0.5)
        XCTAssertEqual(resized.end.x, original.end.x + 20, accuracy: 0.5)
        XCTAssertEqual(resized.start.y, original.start.y, accuracy: 0.5)
        XCTAssertEqual(resized.end.y, original.end.y, accuracy: 0.5)
    }

    func testActiveShapeCanBeResizedFromCornerHandleInBothDirections() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 120),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let canvas = AnnotationCanvasView(frame: window.contentView!.bounds)
        window.contentView = canvas
        canvas.tool = .shape

        canvas.mouseDown(with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: window)))
        canvas.mouseDragged(with: try XCTUnwrap(mouseEvent(.leftMouseDragged, at: NSPoint(x: 100, y: 70), in: window)))
        canvas.mouseUp(with: try XCTUnwrap(mouseEvent(.leftMouseUp, at: NSPoint(x: 100, y: 70), in: window)))

        let original = try XCTUnwrap(canvas.strokes.first)
        let handle = NSPoint(x: original.bounds.maxX + 5, y: original.bounds.maxY + 5)
        let target = NSPoint(x: handle.x + 20, y: handle.y + 15)
        canvas.mouseDown(with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: handle, in: window)))
        canvas.mouseDragged(with: try XCTUnwrap(mouseEvent(.leftMouseDragged, at: target, in: window)))
        canvas.mouseUp(with: try XCTUnwrap(mouseEvent(.leftMouseUp, at: target, in: window)))

        let resized = try XCTUnwrap(canvas.strokes.first)
        XCTAssertEqual(resized.start.x, original.start.x, accuracy: 0.5)
        XCTAssertEqual(resized.start.y, original.start.y, accuracy: 0.5)
        XCTAssertEqual(resized.end.x, original.end.x + 20, accuracy: 0.5)
        XCTAssertEqual(resized.end.y, original.end.y + 15, accuracy: 0.5)
    }

    func testShapeOptionsExposeLineWidthControl() {
        let optionsBar = AnnotateOptionsBar()

        optionsBar.show(for: .shape)

        XCTAssertNotNil(optionsBar.subviews.first { $0.toolTip == "线宽" })
    }

    func testResizeDoesNotChangeFontSize() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let canvas = NSView(frame: window.contentView!.bounds)
        window.contentView = canvas
        let editor = TextAnnotationEditor(
            stroke: AnnotationStroke(
                tool: .text,
                points: [NSPoint(x: 100, y: 100)],
                start: NSPoint(x: 100, y: 100),
                end: NSPoint(x: 100, y: 100),
                lineWidth: 14
            )
        )
        canvas.addSubview(editor)

        let top = NSPoint(
            x: editor.stroke.start.x,
            y: editor.stroke.start.y + editor.stroke.textBoxHeight / 2
        )
        editor.mouseDown(with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: top, in: window)))
        editor.mouseDragged(
            with: try XCTUnwrap(
                mouseEvent(.leftMouseDragged, at: NSPoint(x: top.x, y: top.y + 40), in: window)
            )
        )
        editor.mouseUp(
            with: try XCTUnwrap(
                mouseEvent(.leftMouseUp, at: NSPoint(x: top.x, y: top.y + 40), in: window)
            )
        )

        XCTAssertEqual(editor.stroke.lineWidth, 14)
    }

    func testTopRightCornerClosesInsteadOfResizing() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let canvas = NSView(frame: window.contentView!.bounds)
        window.contentView = canvas
        let editor = TextAnnotationEditor(
            stroke: AnnotationStroke(
                tool: .text,
                points: [NSPoint(x: 100, y: 100)],
                start: NSPoint(x: 100, y: 100),
                end: NSPoint(x: 100, y: 100)
            )
        )
        var didCancel = false
        editor.onCancel = { didCancel = true }
        canvas.addSubview(editor)

        let topRight = NSPoint(
            x: editor.stroke.start.x + editor.stroke.textBoxWidth / 2,
            y: editor.stroke.start.y + editor.stroke.textBoxHeight / 2
        )
        editor.mouseDown(with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: topRight, in: window)))

        XCTAssertTrue(didCancel)
        XCTAssertNil(editor.superview)
    }

    func testTextBodyUsesNativeTextViewAfterResize() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let canvas = NSView(frame: window.contentView!.bounds)
        window.contentView = canvas
        let editor = TextAnnotationEditor(
            stroke: AnnotationStroke(
                tool: .text,
                points: [NSPoint(x: 100, y: 100)],
                start: NSPoint(x: 100, y: 100),
                end: NSPoint(x: 100, y: 100),
                text: "测试文字"
            )
        )
        canvas.addSubview(editor)
        editor.beginEditing()

        for _ in 0..<10 {
            let edge = NSPoint(
                x: editor.stroke.start.x + editor.stroke.textBoxWidth / 2,
                y: editor.stroke.start.y
            )
            editor.mouseDown(with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: edge, in: window)))
            editor.mouseDragged(
                with: try XCTUnwrap(
                    mouseEvent(.leftMouseDragged, at: NSPoint(x: edge.x + 10, y: edge.y), in: window)
                )
            )
            editor.mouseUp(
                with: try XCTUnwrap(
                    mouseEvent(.leftMouseUp, at: NSPoint(x: edge.x + 10, y: edge.y), in: window)
                )
            )
        }

        let textView = try XCTUnwrap(canvas.hitTest(editor.stroke.start) as? NSTextView)
        window.makeFirstResponder(textView)
        textView.insertText("追加", replacementRange: textView.selectedRange())

        XCTAssertTrue(textView.string.contains("追加"))
        XCTAssertTrue(window.firstResponder === textView)
    }

    func testRepeatedResizeRemainsResponsiveWhileIdle() async throws {
        MainThreadWatchdog.shared.install()
        MainThreadWatchdog.shared.beginCaptureSession()
        defer { MainThreadWatchdog.shared.endCaptureSession() }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let canvas = NSView(frame: window.contentView!.bounds)
        window.contentView = canvas
        let editor = TextAnnotationEditor(
            stroke: AnnotationStroke(
                tool: .text,
                points: [NSPoint(x: 100, y: 100)],
                start: NSPoint(x: 100, y: 100),
                end: NSPoint(x: 100, y: 100)
            )
        )
        canvas.addSubview(editor)
        editor.beginEditing()
        let textView = try XCTUnwrap(window.firstResponder as? NSTextView)
        textView.string = "测试文字"

        for _ in 0..<5 {
            let edge = NSPoint(
                x: editor.stroke.start.x + editor.stroke.textBoxWidth / 2,
                y: editor.stroke.start.y
            )
            editor.mouseDown(with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: edge, in: window)))
            XCTAssertTrue(window.firstResponder is NSTextView)
            editor.mouseDragged(
                with: try XCTUnwrap(
                    mouseEvent(.leftMouseDragged, at: NSPoint(x: edge.x + 10, y: edge.y), in: window)
                )
            )
            editor.mouseUp(
                with: try XCTUnwrap(
                    mouseEvent(.leftMouseUp, at: NSPoint(x: edge.x + 10, y: edge.y), in: window)
                )
            )
        }

        let body = editor.stroke.start
        editor.mouseDown(with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: body, in: window)))
        editor.mouseUp(with: try XCTUnwrap(mouseEvent(.leftMouseUp, at: body, in: window)))

        try await Task.sleep(for: .seconds(3))
        XCTAssertFalse(editor.isTransforming)
        XCTAssertTrue(window.firstResponder is NSTextView)
    }

    func testResizeRestoresTextInputFocus() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let canvas = NSView(frame: window.contentView!.bounds)
        window.contentView = canvas

        let stroke = AnnotationStroke(
            tool: .text,
            points: [NSPoint(x: 100, y: 100)],
            start: NSPoint(x: 100, y: 100),
            end: NSPoint(x: 100, y: 100),
            textBoxWidth: 40,
            textBoxHeight: 28
        )
        let editor = TextAnnotationEditor(stroke: stroke)
        canvas.addSubview(editor)
        editor.beginEditing()
        XCTAssertTrue(window.firstResponder is NSTextView)

        let down = try XCTUnwrap(mouseEvent(.leftMouseDown, at: NSPoint(x: 120, y: 100), in: window))
        let dragged = try XCTUnwrap(mouseEvent(.leftMouseDragged, at: NSPoint(x: 160, y: 100), in: window))
        let up = try XCTUnwrap(mouseEvent(.leftMouseUp, at: NSPoint(x: 160, y: 100), in: window))

        editor.mouseDown(with: down)
        editor.mouseDragged(with: dragged)
        editor.mouseUp(with: up)

        XCTAssertTrue(window.firstResponder is NSTextView)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent? {
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
        )
    }

    private func splitColorImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 100, height: 100))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 50, height: 100).fill()
        NSColor.systemGreen.setFill()
        NSRect(x: 50, y: 0, width: 50, height: 100).fill()
        image.unlockFocus()
        return image
    }

    private func pixelColor(in image: CGImage, x: Int, y: Int) -> NSColor? {
        NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
    }
}
