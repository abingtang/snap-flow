import AppKit

/// 选区内标注画布
@MainActor
final class AnnotationCanvasView: NSView {
    private enum ActiveResizeHandle: String {
        case start
        case end
        case none
        case n
        case s
        case e
        case w
        case ne
        case nw
        case se
        case sw
    }

    var onIdleMouseEvent: ((NSEvent) -> Void)?
    var onSelectionChanged: (() -> Void)?

    /// 是否自行管理光标。截图会话内由 `RegionSelectionView` 统一管理，应设为 `false`，避免与父视图抢光标导致闪烁。
    var managesCursor: Bool = true

    var tool: AnnotateTool = .none {
        didSet {
            if tool != .eraser { eraserHoverPoint = nil }
            if oldValue != tool {
                activeDragStart = nil
                activeDragStroke = nil
                activeResizeHandle = .none
                activeResizeStart = nil
                activeResizeStroke = nil
                // 切换主标注工具即结束当前元素的激活态；控制点编辑过程中不会切换工具。
                setSelectedStroke(nil)
            }
            if managesCursor { updateCursor() }
            needsDisplay = true
        }
    }

    var baseImage: NSImage?
    private(set) var strokes: [AnnotationStroke] = []
    private var redoStack: [AnnotationStroke] = []
    private var draft: AnnotationStroke?
    private var selectedStrokeId: UUID?
    private var activeDragStart: CGPoint?
    private var activeDragStroke: AnnotationStroke?
    private var activeResizeHandle: ActiveResizeHandle = .none
    private var activeResizeStart: CGPoint?
    private var activeResizeStroke: AnnotationStroke?
    private var nextNumber = 1
    private var eraserTrackingArea: NSTrackingArea?
    private var eraserHoverPoint: CGPoint?
    /// 画布上滚轮调笔宽的累计（触控板需积够阈值才变 1 档）
    private var scrollWheelAccum: CGFloat = 0
    private let scrollWheelStepThreshold: CGFloat = 32

    var strokeColor: NSColor = .systemRed
    var penWidth: CGFloat = 2.5
    var highlightWidth: CGFloat = 10
    var eraserWidth: CGFloat = 16
    var filledShapes: Bool = false
    var arrowStyle: Int = 0
    var shapeKind: ShapeKind = .rectangle
    var highlighterMode: HighlighterMode = .line
    var eraserMode: EraserMode = .smear
    var fontSize: CGFloat = 14
    var fontBold: Bool = false
    var fontItalic: Bool = false

    /// 当前文字编辑器（Snipaste 风格变换框）
    private var textBoxEditor: TextAnnotationEditor?
    private var selectedTextId: UUID?
    var isTextEditing: Bool { textBoxEditor != nil }
    var acceptsDrawInput: Bool { tool.isDrawable || textBoxEditor != nil || selectedTextId != nil }
    var activeStroke: AnnotationStroke? {
        if let textBoxEditor { return textBoxEditor.stroke }
        guard let selectedStrokeId else { return nil }
        return strokes.first { $0.id == selectedStrokeId }
    }
    var activeStrokeTool: AnnotateTool? { activeStroke?.tool }
    var activeOptionsStyle: AnnotateOptionsBar.Style? {
        guard let stroke = activeStroke else { return nil }
        var style = AnnotateOptionsBar.Style()
        style.color = stroke.color
        style.lineWidth = min(max(stroke.lineWidth, 1), 24)
        style.filled = stroke.text == "fill"
        style.arrowStyle = stroke.number
        style.shapeKind = stroke.shapeKind
        style.highlighterMode = stroke.highlighterMode
        style.eraserMode = stroke.tool == .eraser ? stroke.eraserMode : eraserMode
        style.fontSize = min(max(stroke.tool == .text || stroke.tool == .number ? stroke.lineWidth : fontSize, 8), 120)
        style.bold = fontBold
        style.italic = fontItalic
        return style
    }
    var eraserPreviewRect: NSRect? {
        // 仅涂抹模式显示圆形笔刷预览；框选模式用拖拽矩形
        guard tool == .eraser, eraserMode == .smear, let point = eraserHoverPoint else { return nil }
        return NSRect(
            x: point.x - eraserWidth / 2,
            y: point.y - eraserWidth / 2,
            width: eraserWidth,
            height: eraserWidth
        )
    }

    func textInteractionCursor(at point: CGPoint) -> NSCursor? {
        textBoxEditor?.interactionCursor(at: point)
    }

    func setSelectionFrame(_ newFrame: NSRect) {
        let offset = CGPoint(
            x: frame.minX - newFrame.minX,
            y: frame.minY - newFrame.minY
        )
        if offset != .zero {
            for index in strokes.indices {
                translate(&strokes[index], by: offset)
            }
            for index in redoStack.indices {
                translate(&redoStack[index], by: offset)
            }
            if var draft {
                translate(&draft, by: offset)
                self.draft = draft
            }
        }
        frame = newFrame
        needsDisplay = true
    }

    private func translate(_ stroke: inout AnnotationStroke, by offset: CGPoint) {
        stroke.points = stroke.points.map {
            CGPoint(x: $0.x + offset.x, y: $0.y + offset.y)
        }
        stroke.start.x += offset.x
        stroke.start.y += offset.y
        stroke.end.x += offset.x
        stroke.end.y += offset.y
    }

    func apply(options: AnnotateOptionsBar.Style, updatingActiveStroke: Bool = true) {
        strokeColor = options.color
        // 选项条 lineWidth 与各工具笔宽 1:1，禁止再 *3/*2.5 后写回，否则会钳到 24 并反复跳变
        penWidth = min(24, max(1, options.lineWidth))
        highlightWidth = min(40, max(4, options.lineWidth))
        if options.eraserMode == .smear || tool != .eraser {
            eraserWidth = min(24, max(1, options.lineWidth))
        }
        filledShapes = options.filled
        arrowStyle = options.arrowStyle
        shapeKind = options.shapeKind
        highlighterMode = options.highlighterMode
        eraserMode = options.eraserMode
        fontSize = options.fontSize
        fontBold = options.bold
        fontItalic = options.italic
        if updatingActiveStroke,
           let active = activeStroke,
           (tool == .none || tool == active.tool)
        {
            textBoxEditor?.applyStyle(
                color: strokeColor,
                fontSize: fontSize,
                bold: fontBold,
                italic: fontItalic
            )
            if let id = selectedStrokeId,
               let idx = strokes.firstIndex(where: { $0.id == id })
            {
                var updated = strokes[idx]
                updated.color = strokeColor
                if updated.tool == .text || updated.tool == .number {
                    updated.lineWidth = fontSize
                } else if updated.tool == .eraser {
                    updated.eraserMode = options.eraserMode
                    if options.eraserMode == .smear {
                        updated.lineWidth = eraserWidth
                    }
                } else {
                    updated.lineWidth = options.lineWidth
                }
                if updated.tool == .shape {
                    updated.shapeKind = options.shapeKind
                    updated.text = options.filled ? "fill" : ""
                } else if updated.tool == .arrow {
                    updated.number = options.arrowStyle
                } else if updated.tool == .highlighter {
                    updated.highlighterMode = options.highlighterMode
                }
                strokes[idx] = updated
            }
            needsDisplay = true
        }
        if managesCursor {
            window?.invalidateCursorRects(for: self)
        }
        needsDisplay = true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        // 用于文字框边缘光标
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let eraserTrackingArea { removeTrackingArea(eraserTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        eraserTrackingArea = area
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func undo() {
        commitTextIfNeeded()
        guard !strokes.isEmpty else { return }
        let last = strokes.removeLast()
        redoStack.append(last)
        if selectedStrokeId == last.id { setSelectedStroke(nil) }
        if last.tool == .number { nextNumber = max(1, nextNumber - 1) }
        needsDisplay = true
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        strokes.append(s)
        setSelectedStroke(s.id)
        if s.tool == .number { nextNumber = max(nextNumber, s.number + 1) }
        needsDisplay = true
    }

    func clearAll() {
        commitTextIfNeeded()
        textBoxEditor?.removeFromSuperview()
        textBoxEditor = nil
        selectedTextId = nil
        setSelectedStroke(nil)
        strokes.removeAll()
        redoStack.removeAll()
        draft = nil
        nextNumber = 1
        needsDisplay = true
    }

    func adjustPenWidth(delta: CGFloat) {
        guard abs(delta) > 0.001 else { return }
        let direction: CGFloat = delta > 0 ? 1 : -1
        penWidth = min(24, max(1, penWidth + direction))
        highlightWidth = min(40, max(4, highlightWidth + direction))
        // 橡皮粗细仅涂抹模式可调；与选项条 lineWidth 1…24 对齐
        if tool != .eraser || eraserMode == .smear {
            eraserWidth = min(24, max(1, eraserWidth + direction))
        }

        var activeStrokeChanged = false
        if let active = activeStroke,
           let id = selectedStrokeId,
           let index = strokes.firstIndex(where: { $0.id == id })
        {
            var updated = strokes[index]
            let adjustment: CGFloat
            let minimum: CGFloat
            let maximum: CGFloat
            switch active.tool {
            case .shape, .arrow, .pen, .mosaic, .highlighter:
                adjustment = direction
                minimum = 1
                maximum = 24
            case .eraser:
                if active.eraserMode == .smear {
                    adjustment = direction
                    minimum = 1
                    maximum = 24
                } else {
                    adjustment = 0
                    minimum = 0
                    maximum = 0
                }
            case .text, .number, .none, .undo, .redo:
                adjustment = 0
                minimum = 0
                maximum = 0
            }
            if adjustment != 0 {
                let width = min(max(updated.lineWidth + adjustment, minimum), maximum)
                if updated.lineWidth != width {
                    updated.lineWidth = width
                    strokes[index] = updated
                    activeStrokeChanged = true
                }
            }
        }
        // 同步选项条（有无选中笔画都要写回当前工具记忆的粗细）
        _ = activeStrokeChanged
        onSelectionChanged?()
        needsDisplay = true
    }

    /// 滚轮调节字号（文字 / 序号工具，含编辑中文本框）
    func adjustFontSize(delta: CGFloat) {
        guard abs(delta) > 0.001 else { return }
        let direction: CGFloat = delta > 0 ? 1 : -1
        let next = min(120, max(8, fontSize + direction))
        guard next != fontSize else { return }
        fontSize = next
        textBoxEditor?.applyStyle(
            color: strokeColor,
            fontSize: fontSize,
            bold: fontBold,
            italic: fontItalic
        )
        if let id = selectedStrokeId ?? selectedTextId,
           let index = strokes.firstIndex(where: { $0.id == id }),
           strokes[index].tool == .text || strokes[index].tool == .number
        {
            var updated = strokes[index]
            updated.lineWidth = fontSize
            strokes[index] = updated
        }
        onSelectionChanged?()
        needsDisplay = true
    }

    /// 把当前画布笔触参数合并进选项样式（用于滚轮后写回各工具独立记忆）
    func mergeCanvasBrush(into style: AnnotateOptionsBar.Style, for tool: AnnotateTool) -> AnnotateOptionsBar.Style {
        var next = style
        next.color = strokeColor
        next.bold = fontBold
        next.italic = fontItalic
        next.filled = filledShapes
        next.arrowStyle = arrowStyle
        next.shapeKind = shapeKind
        next.highlighterMode = highlighterMode
        next.eraserMode = eraserMode
        switch tool {
        case .text, .number:
            next.fontSize = fontSize
        case .eraser:
            next.lineWidth = eraserWidth
        case .highlighter:
            next.lineWidth = highlightWidth
        default:
            next.lineWidth = penWidth
        }
        return next
    }

    private func updateCursor() {
        guard managesCursor else { return }
        switch tool {
        case .text:
            NSCursor.iBeam.set()
        case .none:
            NSCursor.arrow.set()
        default:
            NSCursor.crosshair.set()
        }
    }

    override func resetCursorRects() {
        discardCursorRects()
        // 父视图统一管光标时不要注册 cursor rect，否则会与 NSCursor.set 互抢闪烁
        guard managesCursor else { return }
        switch tool {
        case .text:
            addCursorRect(bounds, cursor: .iBeam)
        case .none:
            addCursorRect(bounds, cursor: .arrow)
        default:
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        eraserHoverPoint = (tool == .eraser && eraserMode == .smear)
            ? convert(event.locationInWindow, from: nil)
            : nil
        if managesCursor {
            updateCursor()
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        eraserHoverPoint = nil
        needsDisplay = true
    }

    // MARK: - Composite

    func compositeImage() -> NSImage? {
        commitTextIfNeeded()
        guard let base = baseImage else { return nil }
        let size = base.size
        guard size.width > 0, size.height > 0 else { return nil }
        let makeBitmap = {
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: max(Int(size.width * 2), 1),
                pixelsHigh: max(Int(size.height * 2), 1),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        }
        guard let annotations = makeBitmap(), let rep = makeBitmap() else { return nil }
        annotations.size = size
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: annotations)
        let sx = size.width / max(bounds.width, 1)
        let sy = size.height / max(bounds.height, 1)
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.saveGState()
        ctx?.scaleBy(x: sx, y: sy)
        for s in strokes { drawStroke(s) }
        ctx?.restoreGState()
        NSGraphicsContext.restoreGraphicsState()

        let annotationImage = NSImage(size: size)
        annotationImage.addRepresentation(annotations)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        base.draw(in: NSRect(origin: .zero, size: size))
        annotationImage.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        let out = NSImage(size: size)
        out.addRepresentation(rep)
        return out
    }

    func compositeCGImage() -> CGImage? {
        guard let ns = compositeImage() else { return nil }
        var rect = CGRect(origin: .zero, size: ns.size)
        return ns.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        for s in strokes { drawStroke(s) }
        if let draft { drawStroke(draft) }
        if let activeStroke, textBoxEditor == nil {
            drawActiveSelection(for: activeStroke)
        }
        if let rect = eraserPreviewRect { drawEraserPreview(in: rect) }
    }

    private func drawActiveSelection(for stroke: AnnotationStroke) {
        switch resizeKind(for: stroke) {
        case .none:
            return
        case .line:
            NSColor.white.setStroke()
            let line = NSBezierPath()
            line.move(to: stroke.start)
            line.line(to: stroke.end)
            line.lineWidth = 1
            line.setLineDash([4, 3], count: 2, phase: 0)
            line.stroke()
            drawActiveHandle(at: stroke.start)
            drawActiveHandle(at: stroke.end)
            return
        case .area:
            break
        }

        let rect = activeSelectionRect(for: stroke)
        guard rect.width > 0.5, rect.height > 0.5 else { return }

        NSColor.white.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1
        border.setLineDash([4, 3], count: 2, phase: 0)
        border.stroke()

        for (_, point) in activeHandlePoints(in: rect) {
            drawActiveHandle(at: point)
        }
    }

    private func drawActiveHandle(at point: CGPoint) {
        let handleSize: CGFloat = 6
        let handle = NSRect(
            x: point.x - handleSize / 2,
            y: point.y - handleSize / 2,
            width: handleSize,
            height: handleSize
        )
        NSColor.white.setFill()
        handle.fill()
        NSColor.black.withAlphaComponent(0.85).setStroke()
        let outline = NSBezierPath(rect: handle)
        outline.lineWidth = 1
        outline.stroke()
    }

    /// 返回活动标注的拉伸光标。截图会话由父视图统一提交 cursor rect，避免多个视图抢光标。
    func activeElementResizeCursor(at point: CGPoint) -> (cursor: NSCursor, token: String)? {
        let handle = hitActiveResizeHandle(at: point)
        guard handle != .none else { return nil }
        let position: NSCursor.FrameResizePosition
        switch handle {
        case .start:
            guard let stroke = activeStroke else { return nil }
            position = lineResizePosition(for: stroke, atStart: true)
        case .end:
            guard let stroke = activeStroke else { return nil }
            position = lineResizePosition(for: stroke, atStart: false)
        case .n: position = .top
        case .s: position = .bottom
        case .e: position = .right
        case .w: position = .left
        case .ne: position = .topRight
        case .nw: position = .topLeft
        case .se: position = .bottomRight
        case .sw: position = .bottomLeft
        case .none: return nil
        }
        return (
            cursor: .frameResize(position: position, directions: .all),
            token: "annotation-resize-\(handle.rawValue)"
        )
    }

    private enum ActiveResizeKind {
        case none
        case area
        case line
    }

    private func resizeKind(for stroke: AnnotationStroke) -> ActiveResizeKind {
        switch stroke.tool {
        case .shape, .mosaic:
            return .area
        case .arrow:
            return .line
        case .highlighter:
            return stroke.highlighterMode == .line ? .line : .area
        case .none, .pen, .text, .number, .eraser, .undo, .redo:
            return .none
        }
    }

    private func lineResizePosition(
        for stroke: AnnotationStroke,
        atStart: Bool
    ) -> NSCursor.FrameResizePosition {
        let dx = stroke.end.x - stroke.start.x
        let dy = stroke.end.y - stroke.start.y
        if abs(dx) >= abs(dy) {
            let startOnLeft = dx >= 0
            return atStart
                ? (startOnLeft ? .left : .right)
                : (startOnLeft ? .right : .left)
        }
        let startOnBottom = dy >= 0
        return atStart
            ? (startOnBottom ? .bottom : .top)
            : (startOnBottom ? .top : .bottom)
    }

    private func activeSelectionRect(for stroke: AnnotationStroke) -> CGRect {
        stroke.bounds.insetBy(dx: -5, dy: -5)
    }

    private func activeHandlePoints(in rect: CGRect) -> [(ActiveResizeHandle, CGPoint)] {
        [
            (.sw, CGPoint(x: rect.minX, y: rect.minY)),
            (.s, CGPoint(x: rect.midX, y: rect.minY)),
            (.se, CGPoint(x: rect.maxX, y: rect.minY)),
            (.w, CGPoint(x: rect.minX, y: rect.midY)),
            (.e, CGPoint(x: rect.maxX, y: rect.midY)),
            (.nw, CGPoint(x: rect.minX, y: rect.maxY)),
            (.n, CGPoint(x: rect.midX, y: rect.maxY)),
            (.ne, CGPoint(x: rect.maxX, y: rect.maxY)),
        ]
    }

    private func hitActiveResizeHandle(at point: CGPoint) -> ActiveResizeHandle {
        guard let stroke = activeStroke, resizeKind(for: stroke) != .none else { return .none }
        let hitRadius: CGFloat = 9
        return activeHandlePoints(for: stroke).first {
            hypot($0.1.x - point.x, $0.1.y - point.y) <= hitRadius
        }?.0 ?? .none
    }

    private func activeHandlePoints(for stroke: AnnotationStroke) -> [(ActiveResizeHandle, CGPoint)] {
        switch resizeKind(for: stroke) {
        case .none:
            return []
        case .line:
            return [(.start, stroke.start), (.end, stroke.end)]
        case .area:
            let rect = activeSelectionRect(for: stroke)
            guard rect.width > 0.5, rect.height > 0.5 else { return [] }
            return activeHandlePoints(in: rect)
        }
    }

    private func drawStroke(_ s: AnnotationStroke) {
        s.color.setStroke()
        s.color.setFill()
        switch s.tool {
        case .shape:
            let r = rectOf(s)
            let path: NSBezierPath = s.shapeKind == .ellipse
                ? NSBezierPath(ovalIn: r)
                : NSBezierPath(rect: r)
            path.lineWidth = s.lineWidth
            if s.text == "fill" {
                s.color.withAlphaComponent(0.35).setFill()
                path.fill()
            }
            s.color.setStroke()
            path.stroke()
        case .arrow:
            if s.number == 1 {
                drawPath([s.start, s.end], width: s.lineWidth, color: s.color, alpha: 1)
            } else if s.number == 2 {
                drawArrow(from: s.start, to: s.end, width: s.lineWidth, color: s.color, roundedTail: false)
                drawArrow(from: s.end, to: s.start, width: s.lineWidth, color: s.color, roundedTail: false)
            } else {
                drawArrow(from: s.start, to: s.end, width: s.lineWidth, color: s.color)
            }
        case .pen:
            drawPath(s.points, width: s.lineWidth, color: s.color, alpha: 1)
        case .highlighter:
            let highlightColor = s.color.withAlphaComponent(0.35)
            if s.highlighterMode == .area {
                highlightColor.setFill()
                NSBezierPath(rect: rectOf(s)).fill()
            } else {
                drawPath([s.start, s.end], width: s.lineWidth, color: highlightColor, alpha: 0.35)
            }
        case .mosaic:
            let r = rectOf(s)
            drawMosaic(in: r)
            // 仅拖拽草稿时显示辅助边框
            if draft?.id == s.id {
                NSColor.systemBlue.withAlphaComponent(0.95).setStroke()
                let border = NSBezierPath(rect: r)
                border.lineWidth = 1.5
                border.setLineDash([4, 3], count: 2, phase: 0)
                border.stroke()
            }
        case .text:
            drawWrappedText(s)
        case .number:
            drawNumberBadge(s.number, at: s.start, color: s.color)
        case .eraser:
            if s.eraserMode == .rect {
                let r = rectOf(s)
                drawEraserRect(r)
                // 框选过程/结果外框：在透明擦除区边缘给出可见反馈
                if draft?.id == s.id {
                    NSColor.white.withAlphaComponent(0.9).setStroke()
                    let border = NSBezierPath(rect: r)
                    border.lineWidth = 1
                    border.setLineDash([4, 3], count: 2, phase: 0)
                    border.stroke()
                }
            } else {
                drawEraserPath(s.points, width: s.lineWidth)
            }
        default:
            break
        }
    }

    private func rectOf(_ s: AnnotationStroke) -> CGRect {
        CGRect(
            x: min(s.start.x, s.end.x),
            y: min(s.start.y, s.end.y),
            width: abs(s.end.x - s.start.x),
            height: abs(s.end.y - s.start.y)
        )
    }

    private func drawPath(_ points: [CGPoint], width: CGFloat, color: NSColor, alpha: CGFloat) {
        guard points.count >= 2 else { return }
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: points[0])
        for p in points.dropFirst() { path.line(to: p) }
        color.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }

    private func drawArrow(
        from: CGPoint,
        to: CGPoint,
        width: CGFloat,
        color: NSColor,
        roundedTail: Bool = true
    ) {
        color.setFill()
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = hypot(dx, dy)
        let unitX = length > 0 ? dx / length : 0
        let unitY = length > 0 ? dy / length : 0
        let angle = atan2(dy, dx)
        // 保持箭头头部与箭身线宽的视觉比例：默认线宽 3 对应原有头部长度 12。
        let head = width * 4
        // 箭身直接填充到箭头底边中心，避免粗线在三角箭头变窄处露出。
        let headBaseDistance = head * -cos(.pi * 0.8)
        let shaftEndDistance = min(headBaseDistance, length)
        let shaftEnd = CGPoint(
            x: to.x - unitX * shaftEndDistance,
            y: to.y - unitY * shaftEndDistance
        )
        let normalX = -unitY
        let normalY = unitX
        let halfWidth = width / 2
        let shaftPath = NSBezierPath()
        shaftPath.move(to: CGPoint(
            x: from.x + normalX * halfWidth,
            y: from.y + normalY * halfWidth
        ))
        shaftPath.line(to: CGPoint(
            x: shaftEnd.x + normalX * halfWidth,
            y: shaftEnd.y + normalY * halfWidth
        ))
        shaftPath.line(to: CGPoint(
            x: shaftEnd.x - normalX * halfWidth,
            y: shaftEnd.y - normalY * halfWidth
        ))
        shaftPath.line(to: CGPoint(
            x: from.x - normalX * halfWidth,
            y: from.y - normalY * halfWidth
        ))
        shaftPath.close()
        shaftPath.fill()
        if roundedTail {
            let radius = width / 2
            NSBezierPath(
                ovalIn: NSRect(
                    x: from.x - radius,
                    y: from.y - radius,
                    width: width,
                    height: width
                )
            ).fill()
        }
        let a1 = angle + .pi * 0.8
        let a2 = angle - .pi * 0.8
        let p1 = CGPoint(x: to.x + cos(a1) * head, y: to.y + sin(a1) * head)
        let p2 = CGPoint(x: to.x + cos(a2) * head, y: to.y + sin(a2) * head)
        let headPath = NSBezierPath()
        headPath.move(to: to)
        headPath.line(to: p1)
        headPath.line(to: p2)
        headPath.close()
        headPath.fill()
    }

    private func drawMosaic(in rect: CGRect) {
        guard rect.width > 2, rect.height > 2 else { return }
        if let base = baseImage {
            let sx = base.size.width / max(bounds.width, 1)
            let sy = base.size.height / max(bounds.height, 1)
            let block: CGFloat = 8
            var y = rect.minY
            while y < rect.maxY {
                var x = rect.minX
                while x < rect.maxX {
                    let cell = NSRect(x: x, y: y, width: min(block, rect.maxX - x), height: min(block, rect.maxY - y))
                    let sample = NSRect(
                        x: (x + cell.width / 2) * sx,
                        y: (y + cell.height / 2) * sy,
                        width: max(sx, 1),
                        height: max(sy, 1)
                    )
                    base.draw(in: cell, from: sample, operation: .copy, fraction: 1)
                    x += block
                }
                y += block
            }
        } else {
            NSColor.gray.withAlphaComponent(0.5).setFill()
            rect.fill()
        }
    }

    private func drawEraserPath(_ points: [CGPoint], width: CGFloat) {
        guard points.count >= 2, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setBlendMode(.clear)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.beginPath()
        context.move(to: points[0])
        context.addLines(between: Array(points.dropFirst()))
        context.strokePath()
        context.restoreGState()
    }

    private func drawEraserRect(_ rect: CGRect) {
        guard rect.width > 0.5, rect.height > 0.5,
              let context = NSGraphicsContext.current?.cgContext
        else { return }
        context.saveGState()
        context.setBlendMode(.clear)
        context.fill(rect)
        context.restoreGState()
    }

    private func drawEraserPreview(in rect: NSRect) {
        let path = NSBezierPath(ovalIn: rect)
        NSColor.black.withAlphaComponent(0.75).setStroke()
        path.lineWidth = 3
        path.stroke()
        NSColor.white.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func makeFont() -> NSFont {
        var font = NSFont.systemFont(ofSize: fontSize, weight: fontBold ? .bold : .regular)
        if fontItalic, let f = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: fontSize) {
            font = f
        }
        return font
    }

    private func drawWrappedText(_ s: AnnotationStroke) {
        // 正在编辑的那条不重复画（编辑器内绘制）
        if textBoxEditor?.stroke.id == s.id { return }
        // 已提交文字：不画选中边框（失焦后边框一次消失）；再点中才重新进入编辑器
        let size = max(8, s.lineWidth > 4 ? s.lineWidth : fontSize)
        var font = NSFont.systemFont(ofSize: size, weight: fontBold ? .bold : .regular)
        if fontItalic, let f = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: size) {
            font = f
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: s.color,
        ]
        let width = max(s.textBoxWidth, 36)
        let height = max(s.textBoxHeight, 22)
        let str = s.text as NSString
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: s.start.x, yBy: s.start.y)
        t.rotate(byDegrees: s.rotation)
        t.translateX(by: -width / 2, yBy: -height / 2)
        t.concat()
        let drawOpts: NSString.DrawingOptions = s.textWidthLocked
            ? [.usesLineFragmentOrigin, .usesFontLeading]
            : [.usesLineFragmentOrigin, .usesFontLeading]
        str.draw(
            with: NSRect(x: 0, y: 0, width: width, height: height),
            options: drawOpts,
            attributes: attrs
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawNumberBadge(_ n: Int, at point: CGPoint, color: NSColor) {
        let r: CGFloat = 12
        let circle = NSBezierPath(ovalIn: NSRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
        color.setFill()
        circle.fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 12),
            .foregroundColor: NSColor.white,
        ]
        let str = "\(n)" as NSString
        let size = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), withAttributes: attrs)
    }

    // MARK: - Text editor (Snipaste 变换框)

    private func presentTextEditor(stroke: AnnotationStroke, editing: Bool) {
        textBoxEditor?.removeFromSuperview()
        let editor = TextAnnotationEditor(stroke: stroke)
        editor.onCommit = { [weak self] s in
            guard let self else { return }
            // 空文本不保留
            if s.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.strokes.removeAll { $0.id == s.id }
                self.setSelectedStroke(nil)
            } else if let idx = self.strokes.firstIndex(where: { $0.id == s.id }) {
                self.strokes[idx] = s
                self.setSelectedStroke(s.id)
            } else {
                self.strokes.append(s)
                self.redoStack.removeAll()
                self.setSelectedStroke(s.id)
            }
            // 失焦后取消选中：边框一次消失，无需再点一次
            self.selectedTextId = nil
            self.textBoxEditor = nil
            editor.removeFromSuperview()
            self.needsDisplay = true
        }
        editor.onCancel = { [weak self] in
            guard let self else { return }
            self.strokes.removeAll { $0.id == stroke.id }
            self.selectedTextId = nil
            self.textBoxEditor = nil
            self.setSelectedStroke(nil)
            editor.removeFromSuperview()
            self.needsDisplay = true
        }
        // 拖拽中不要每帧重绘画布笔迹；仅松手/文本变化时刷新
        editor.onLiveChange = { [weak self] in
            self?.needsDisplay = true
        }
        addSubview(editor)
        textBoxEditor = editor
        selectedTextId = stroke.id
        setSelectedStroke(stroke.id)
        // 从 strokes 暂时移除编辑中的，避免双画
        strokes.removeAll { $0.id == stroke.id }
        if editing {
            editor.beginEditing()
        }
        needsDisplay = true
    }

    func commitTextIfNeeded() {
        guard let editor = textBoxEditor else { return }
        editor.endEditing(commit: true)
        // onCommit 会清 textBoxEditor；兜底
        if textBoxEditor === editor {
            textBoxEditor = nil
            selectedTextId = nil
            setSelectedStroke(nil)
            editor.removeFromSuperview()
        }
    }

    func containsAnnotation(at point: CGPoint) -> Bool {
        if let textBoxEditor, textBoxEditor.containsInteraction(at: point) { return true }
        return hitTextStroke(at: point) != nil || hitStrokeIndex(at: point) != nil
    }

    private func setSelectedStroke(_ id: UUID?) {
        guard selectedStrokeId != id else {
            needsDisplay = true
            return
        }
        selectedStrokeId = id
        activeDragStart = nil
        activeDragStroke = nil
        activeResizeHandle = .none
        activeResizeStart = nil
        activeResizeStroke = nil
        onSelectionChanged?()
        needsDisplay = true
    }

    private func hitStrokeIndex(at point: CGPoint) -> Int? {
        for index in strokes.indices.reversed() {
            if strokes[index].bounds.insetBy(dx: -8, dy: -8).contains(point) {
                return index
            }
        }
        return nil
    }

    private func hitTextStroke(at p: CGPoint) -> Int? {
        for (i, s) in strokes.enumerated().reversed() where s.tool == .text {
            if s.bounds.insetBy(dx: -8, dy: -8).contains(p) {
                return i
            }
        }
        return nil
    }

    private func resizedRect(
        from original: CGRect,
        handle: ActiveResizeHandle,
        delta: CGPoint
    ) -> CGRect {
        let minimumDimension: CGFloat = 4
        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY

        // 横向和纵向必须分别计算；角点同时命中两个方向。
        switch handle {
        case .start, .end:
            break
        case .w, .nw, .sw:
            minX = min(original.maxX - minimumDimension, original.minX + delta.x)
        case .e, .ne, .se:
            maxX = max(original.minX + minimumDimension, original.maxX + delta.x)
        case .n, .s, .none:
            break
        }
        switch handle {
        case .start, .end:
            break
        case .n, .nw, .ne:
            maxY = max(original.minY + minimumDimension, original.maxY + delta.y)
        case .s, .sw, .se:
            minY = min(original.maxY - minimumDimension, original.minY + delta.y)
        case .e, .w, .none:
            break
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func resizeActiveStroke(to point: CGPoint) {
        guard let original = activeResizeStroke,
              let start = activeResizeStart,
              activeResizeHandle != .none,
              let id = selectedStrokeId,
              let index = strokes.firstIndex(where: { $0.id == id })
        else { return }

        var resized = original

        switch resizeKind(for: original) {
        case .none:
            return
        case .line:
            switch activeResizeHandle {
            case .start:
                resized.start = point
            case .end:
                resized.end = point
            default:
                return
            }
        case .area:
            let oldRect = original.bounds
            let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
            let newRect = resizedRect(from: oldRect, handle: activeResizeHandle, delta: delta)
            let startOnLeft = original.start.x <= original.end.x
            let startOnBottom = original.start.y <= original.end.y
            resized.start = CGPoint(
                x: startOnLeft ? newRect.minX : newRect.maxX,
                y: startOnBottom ? newRect.minY : newRect.maxY
            )
            resized.end = CGPoint(
                x: startOnLeft ? newRect.maxX : newRect.minX,
                y: startOnBottom ? newRect.maxY : newRect.minY
            )
        }

        strokes[index] = resized
        needsDisplay = true
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        let p = convert(event.locationInWindow, from: nil)
        if tool == .eraser, eraserMode == .smear { eraserHoverPoint = p }
        // 已有编辑器：内部事件由子视图原生处理；点外部一次提交
        if let editor = textBoxEditor {
            if editor.containsInteraction(at: p) {
                return
            }
            commitTextIfNeeded()
            return
        }

        window?.makeFirstResponder(self)

        // 点中已有文字 → 再次唤醒编辑
        if tool == .text || tool == .none, let idx = hitTextStroke(at: p) {
            let s = strokes[idx]
            presentTextEditor(stroke: s, editing: true)
            return
        }

        // 可拉伸活动标注的控制点优先于新建工具，允许二次编辑元素。
        if let active = activeStroke, resizeKind(for: active) != .none {
            let handle = hitActiveResizeHandle(at: p)
            if handle != .none {
                activeResizeHandle = handle
                activeResizeStart = p
                activeResizeStroke = active
                activeDragStart = nil
                activeDragStroke = nil
                return
            }
        }

        if tool == .none, let idx = hitStrokeIndex(at: p) {
            let stroke = strokes[idx]
            setSelectedStroke(stroke.id)
            activeDragStart = p
            activeDragStroke = stroke
            return
        }

        // 点空白：清除可能残留的选中态
        selectedTextId = nil
        setSelectedStroke(nil)

        if tool == .none {
            onIdleMouseEvent?(event)
            return
        }

        switch tool {
        case .undo, .redo:
            return
        case .none:
            return
        case .text:
            let stroke = AnnotationStroke(
                tool: .text,
                points: [p],
                start: p,
                end: p,
                text: "",
                color: strokeColor,
                lineWidth: fontSize,
                textBoxWidth: 40,
                textBoxHeight: max(28, fontSize + 12),
                textWidthLocked: false,
                rotation: 0
            )
            presentTextEditor(stroke: stroke, editing: true)
        case .number:
            let stroke = AnnotationStroke(
                tool: .number,
                points: [p],
                start: p,
                end: p,
                number: nextNumber,
                color: strokeColor
            )
            strokes.append(stroke)
            setSelectedStroke(stroke.id)
            nextNumber += 1
            redoStack.removeAll()
            needsDisplay = true
        case .pen:
            draft = AnnotationStroke(
                tool: .pen,
                points: [p],
                start: p,
                end: p,
                color: strokeColor,
                lineWidth: penWidth
            )
        case .eraser:
            switch eraserMode {
            case .smear:
                draft = AnnotationStroke(
                    tool: .eraser,
                    eraserMode: .smear,
                    points: [p],
                    start: p,
                    end: p,
                    color: .clear,
                    lineWidth: eraserWidth
                )
            case .rect:
                draft = AnnotationStroke(
                    tool: .eraser,
                    eraserMode: .rect,
                    points: [],
                    start: p,
                    end: p,
                    color: .clear,
                    lineWidth: 0
                )
            }
        case .highlighter:
            draft = AnnotationStroke(
                tool: .highlighter,
                highlighterMode: highlighterMode,
                points: [p],
                start: p,
                end: p,
                color: strokeColor,
                lineWidth: highlightWidth
            )
        case .shape, .arrow, .mosaic:
            var stroke = AnnotationStroke(
                tool: tool,
                shapeKind: shapeKind,
                points: [],
                start: p,
                end: p,
                text: (tool == .shape) && filledShapes ? "fill" : "",
                number: tool == .arrow ? arrowStyle : 0,
                color: strokeColor,
                lineWidth: penWidth
            )
            if shift { applyShiftConstraint(to: &stroke) }
            draft = stroke
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if textBoxEditor != nil { return }
        if activeResizeStroke != nil {
            resizeActiveStroke(to: convert(event.locationInWindow, from: nil))
            return
        }
        if tool == .none {
            if let original = activeDragStroke,
               let start = activeDragStart,
               let id = selectedStrokeId,
               let index = strokes.firstIndex(where: { $0.id == id })
            {
                let point = convert(event.locationInWindow, from: nil)
                var moved = original
                translate(
                    &moved,
                    by: CGPoint(x: point.x - start.x, y: point.y - start.y)
                )
                strokes[index] = moved
                needsDisplay = true
                return
            }
            onIdleMouseEvent?(event)
            return
        }

        let p = convert(event.locationInWindow, from: nil)
        if tool == .eraser, eraserMode == .smear { eraserHoverPoint = p }
        let shift = event.modifierFlags.contains(.shift)
        guard var d = draft else { return }
        switch d.tool {
        case .pen:
            d.points.append(p)
            d.end = p
        case .eraser:
            if d.eraserMode == .smear {
                d.points.append(p)
                d.end = p
            } else {
                d.end = p
                if shift { applyShiftConstraint(to: &d) }
            }
        default:
            d.end = p
            if shift { applyShiftConstraint(to: &d) }
        }
        draft = d
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if textBoxEditor != nil { return }
        if activeResizeStroke != nil {
            resizeActiveStroke(to: convert(event.locationInWindow, from: nil))
            activeResizeHandle = .none
            activeResizeStart = nil
            activeResizeStroke = nil
            return
        }
        if tool == .none {
            if activeDragStroke != nil {
                activeDragStart = nil
                activeDragStroke = nil
                return
            }
            onIdleMouseEvent?(event)
            return
        }
        let shift = event.modifierFlags.contains(.shift)
        let p = convert(event.locationInWindow, from: nil)
        guard var d = draft else { return }
        d.end = p
        if d.tool == .pen || (d.tool == .eraser && d.eraserMode == .smear) {
            d.points.append(p)
        } else if shift {
            applyShiftConstraint(to: &d)
        }
        let r = rectOf(d)
        let tooSmall: Bool = {
            switch d.tool {
            case .pen:
                return d.points.count < 2
            case .eraser:
                if d.eraserMode == .smear {
                    return d.points.count < 2
                }
                return r.width < 3 && r.height < 3
            case .number, .text: return false
            default: return r.width < 3 && r.height < 3
            }
        }()
        if !tooSmall {
            strokes.append(d)
            setSelectedStroke(d.id)
            redoStack.removeAll()
        }
        draft = nil
        needsDisplay = true
    }

    private func applyShiftConstraint(to stroke: inout AnnotationStroke) {
        switch stroke.tool {
        case .shape, .mosaic:
            let dx = stroke.end.x - stroke.start.x
            let dy = stroke.end.y - stroke.start.y
            let side = max(abs(dx), abs(dy))
            stroke.end.x = stroke.start.x + (dx >= 0 ? side : -side)
            stroke.end.y = stroke.start.y + (dy >= 0 ? side : -side)
        case .arrow:
            let dx = stroke.end.x - stroke.start.x
            let dy = stroke.end.y - stroke.start.y
            if abs(dx) > abs(dy) {
                stroke.end.y = stroke.start.y
            } else {
                stroke.end.x = stroke.start.x
            }
        default:
            break
        }
    }

    override func scrollWheel(with event: NSEvent) {
        handleScrollWheelEvent(event)
    }

    /// 画布 / 文字编辑器 / 文本视图共用的滚轮入口
    func handleScrollWheelEvent(_ event: NSEvent) {
        let step: CGFloat
        if event.hasPreciseScrollingDeltas {
            scrollWheelAccum += event.scrollingDeltaY
            guard abs(scrollWheelAccum) >= scrollWheelStepThreshold else { return }
            let direction: CGFloat = scrollWheelAccum > 0 ? 1 : -1
            scrollWheelAccum -= direction * scrollWheelStepThreshold
            step = direction
        } else {
            scrollWheelAccum = 0
            let d = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
            guard abs(d) >= 0.2 else { return }
            step = d > 0 ? 1 : -1
        }

        // 文字/序号（含编辑中）走字号；框选橡皮不调粗细；其余走线宽
        let prefersFontSize =
            tool == .text
            || tool == .number
            || textBoxEditor != nil
            || activeStroke?.tool == .text
            || activeStroke?.tool == .number
        if prefersFontSize {
            adjustFontSize(delta: step)
            return
        }
        if tool == .eraser, eraserMode == .rect {
            return
        }
        adjustPenWidth(delta: step)
    }
}
