import AppKit

@MainActor
private final class AnnotationTextView: NSTextView {
    var onEscape: (() -> Void)?
    var onScrollWheel: ((NSEvent) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if let onScrollWheel {
            onScrollWheel(event)
            return
        }
        super.scrollWheel(with: event)
    }
}

/// 文字正文完全交给 NSTextView；本视图只处理边框变换。
@MainActor
final class TextAnnotationEditor: NSView, NSTextViewDelegate {
    var onCommit: ((AnnotationStroke) -> Void)?
    var onCancel: (() -> Void)?
    var onLiveChange: (() -> Void)?

    private(set) var stroke: AnnotationStroke

    private let textView = AnnotationTextView()
    private var cursorTrackingArea: NSTrackingArea?
    private var isEditing = true
    private var widthLocked: Bool
    private var fontSize: CGFloat
    private var isBold = false
    private var isItalic = false

    private enum Edge {
        case left, right, top, bottom
        case topLeft, bottomLeft, bottomRight

        var changesWidth: Bool {
            switch self {
            case .left, .right, .topLeft, .bottomLeft, .bottomRight: true
            case .top, .bottom: false
            }
        }
    }

    private enum Hit {
        case body
        case move
        case resize(Edge)
        case rotate
        case close
        case outside
    }

    private enum DragMode {
        case none
        case move
        case resize(Edge)
        case rotate
    }

    private var dragMode: DragMode = .none
    private var dragStart: CGPoint = .zero
    private var startCenter: CGPoint = .zero
    private var startSize: CGSize = .zero
    private var startRotation: CGFloat = 0

    private let minWidth: CGFloat = 36
    private let minHeight: CGFloat = 22
    private let maxWidth: CGFloat = 800
    private let maxHeight: CGFloat = 600
    private let inset: CGFloat = 6
    private let handleRadius: CGFloat = 9
    private let controlRadius: CGFloat = 7
    private let edgeHitWidth: CGFloat = 7
    private let rotateDistance: CGFloat = 24
    private let chromeColor: NSColor = .systemRed

    init(stroke: AnnotationStroke) {
        self.stroke = stroke
        widthLocked = stroke.textWidthLocked
        fontSize = max(8, min(120, stroke.lineWidth > 4 ? stroke.lineWidth : 14))
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        configureTextView()
        addSubview(textView)

        if !widthLocked {
            fitToContent()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let superview else { return }
        frame = superview.bounds
        autoresizingMask = [.width, .height]
        updateTextViewLayout()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshCursorTrackingArea()
    }

    override var acceptsFirstResponder: Bool { false }

    private func configureTextView() {
        textView.delegate = self
        textView.string = stroke.text
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = stroke.color
        textView.insertionPointColor = stroke.color
        textView.alignment = .left
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.textContainer?.lineFragmentPadding = 2
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = true
        textView.font = currentFont()
        textView.onEscape = { [weak self] in
            guard let self else { return }
            self.endEditing(
                commit: !self.textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        textView.onScrollWheel = { [weak self] event in
            self?.forwardScrollWheel(event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        forwardScrollWheel(event)
    }

    private func forwardScrollWheel(_ event: NSEvent) {
        if let canvas = superview as? AnnotationCanvasView {
            canvas.handleScrollWheelEvent(event)
            return
        }
        super.scrollWheel(with: event)
    }

    func beginEditing() {
        isEditing = true
        textView.isEditable = true
        textView.isSelectable = true
        updateTextViewLayout()
        window?.makeFirstResponder(textView)
        needsDisplay = true
    }

    func endEditing(commit: Bool) {
        guard isEditing else { return }
        finishGeometryDrag()
        isEditing = false
        stroke.text = textView.string
        stroke.textWidthLocked = widthLocked
        stroke.lineWidth = fontSize
        textView.isEditable = false

        if commit {
            onCommit?(stroke)
        } else {
            onCancel?()
        }
    }

    func applyStyle(color: NSColor, fontSize: CGFloat, bold: Bool, italic: Bool) {
        stroke.color = color
        self.fontSize = max(8, min(120, fontSize))
        isBold = bold
        isItalic = italic
        stroke.lineWidth = self.fontSize

        textView.textColor = color
        textView.insertionPointColor = color
        textView.font = currentFont()
        if !widthLocked {
            fitToContent()
        }
        updateTextViewLayout()
        needsDisplay = true
    }

    private func currentFont() -> NSFont {
        var font = NSFont.systemFont(ofSize: fontSize, weight: isBold ? .bold : .regular)
        if isItalic,
           let italicFont = NSFont(
               descriptor: font.fontDescriptor.withSymbolicTraits(.italic),
               size: fontSize
           )
        {
            font = italicFont
        }
        return font
    }

    private func textAttributes() -> [NSAttributedString.Key: Any] {
        [.font: currentFont(), .foregroundColor: stroke.color]
    }

    private func measuredTextSize(for text: String, width: CGFloat?) -> CGSize {
        if text.isEmpty {
            return CGSize(width: minWidth, height: max(minHeight, ceil(fontSize + inset * 2)))
        }

        let drawingWidth = width.map { max(16, $0 - inset * 2) } ?? 2_000
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: drawingWidth, height: 2_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: textAttributes()
        )
        let measuredWidth = width ?? ceil(rect.width) + inset * 2 + 4
        return CGSize(
            width: min(max(measuredWidth, minWidth), maxWidth),
            height: min(max(ceil(rect.height) + inset * 2, minHeight), maxHeight)
        )
    }

    private func fitToContent() {
        stroke.text = textView.string
        let size = measuredTextSize(for: textView.string, width: widthLocked ? stroke.textBoxWidth : nil)
        if widthLocked {
            stroke.textBoxHeight = max(stroke.textBoxHeight, size.height)
        } else {
            stroke.textBoxWidth = size.width
            stroke.textBoxHeight = size.height
        }
        clampStrokeSize()
    }

    private func clampStrokeSize() {
        stroke.textBoxWidth = min(max(stroke.textBoxWidth, minWidth), maxWidth)
        stroke.textBoxHeight = min(max(stroke.textBoxHeight, minHeight), maxHeight)
    }

    private func updateTextViewLayout() {
        clampStrokeSize()
        textView.frameCenterRotation = 0
        textView.frame = NSRect(
            x: stroke.start.x - stroke.textBoxWidth / 2,
            y: stroke.start.y - stroke.textBoxHeight / 2,
            width: stroke.textBoxWidth,
            height: stroke.textBoxHeight
        )
        textView.textContainer?.containerSize = NSSize(
            width: max(16, stroke.textBoxWidth - 4),
            height: maxHeight
        )
        textView.frameCenterRotation = stroke.rotation
        refreshCursorTrackingArea()
    }

    private func refreshCursorTrackingArea() {
        if let cursorTrackingArea {
            removeTrackingArea(cursorTrackingArea)
        }
        guard superview != nil else {
            cursorTrackingArea = nil
            return
        }

        let padding = rotateDistance + 12
        let area = NSTrackingArea(
            rect: stroke.bounds.insetBy(dx: -padding, dy: -padding),
            options: [.activeAlways, .mouseMoved, .cursorUpdate, .enabledDuringMouseDrag],
            owner: self
        )
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    // MARK: - Hit testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHiddenOrHasHiddenAncestor, bounds.contains(point) else { return nil }
        switch hit(at: point) {
        case .body:
            guard isEditing else { return self }
            return textView.hitTest(convert(point, to: textView)) ?? textView
        case .move, .resize, .rotate, .close:
            return self
        case .outside:
            return nil
        }
    }

    func containsInteraction(at pointInSuperview: CGPoint) -> Bool {
        let local = convert(pointInSuperview, from: superview)
        if case .outside = hit(at: local) { return false }
        return true
    }

    func interactionCursor(at pointInSuperview: CGPoint) -> NSCursor? {
        let local = convert(pointInSuperview, from: superview)
        let target = hit(at: local)
        if case .outside = target { return nil }
        return cursor(for: target)
    }

    private func pointInBox(_ point: CGPoint) -> CGPoint {
        let dx = point.x - stroke.start.x
        let dy = point.y - stroke.start.y
        let radians = -stroke.rotation * .pi / 180
        return CGPoint(
            x: dx * cos(radians) - dy * sin(radians) + stroke.textBoxWidth / 2,
            y: dx * sin(radians) + dy * cos(radians) + stroke.textBoxHeight / 2
        )
    }

    private func hit(at point: CGPoint) -> Hit {
        let local = pointInBox(point)
        let width = stroke.textBoxWidth
        let height = stroke.textBoxHeight

        let close = CGPoint(x: width, y: height)
        if hypot(local.x - close.x, local.y - close.y) <= 11 {
            return .close
        }

        let rotate = CGPoint(x: width / 2, y: height + rotateDistance)
        if hypot(local.x - rotate.x, local.y - rotate.y) <= 11 {
            return .rotate
        }

        let handles: [(Edge, CGPoint)] = [
            (.bottomLeft, CGPoint(x: 0, y: 0)),
            (.bottomRight, CGPoint(x: width, y: 0)),
            (.topLeft, CGPoint(x: 0, y: height)),
        ]
        for (edge, center) in handles
        where hypot(local.x - center.x, local.y - center.y) <= handleRadius {
            return .resize(edge)
        }

        if local.y >= -edgeHitWidth, local.y <= height + edgeHitWidth {
            if abs(local.x) <= edgeHitWidth { return .resize(.left) }
            if abs(local.x - width) <= edgeHitWidth { return .resize(.right) }
        }
        if local.x >= -edgeHitWidth, local.x <= width + edgeHitWidth {
            if abs(local.y) <= edgeHitWidth { return .resize(.bottom) }
            if abs(local.y - height) <= edgeHitWidth { return .resize(.top) }
        }

        if local.x > edgeHitWidth,
           local.x < width - edgeHitWidth,
           local.y > edgeHitWidth,
           local.y < height - edgeHitWidth
        {
            return .body
        }

        let moveRect = CGRect(x: -12, y: -12, width: width + 24, height: height + 24)
        return moveRect.contains(local) ? .move : .outside
    }

    override func mouseMoved(with event: NSEvent) {
        cursor(for: hit(at: convert(event.locationInWindow, from: nil))).set()
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor(for: hit(at: convert(event.locationInWindow, from: nil))).set()
    }

    private func cursor(for hit: Hit) -> NSCursor {
        switch hit {
        case .body:
            return .iBeam
        case .move:
            return .openHand
        case .rotate, .close:
            return .pointingHand
        case .resize(let edge):
            let position: NSCursor.FrameResizePosition = switch edge {
            case .left: .left
            case .right: .right
            case .top: .top
            case .bottom: .bottom
            case .topLeft: .topLeft
            case .bottomLeft: .bottomLeft
            case .bottomRight: .bottomRight
            }
            return .frameResize(position: position, directions: .all)
        case .outside:
            return .arrow
        }
    }

    // MARK: - Mouse geometry

    override func mouseDown(with event: NSEvent) {
        MainThreadWatchdog.shared.noteMainAlive()
        let point = convert(event.locationInWindow, from: nil)
        captureDragStart(at: point)

        switch hit(at: point) {
        case .resize(let edge):
            if edge.changesWidth {
                widthLocked = true
                stroke.textWidthLocked = true
            }
            beginGeometryDrag(.resize(edge))
        case .move:
            beginGeometryDrag(.move)
        case .rotate:
            beginGeometryDrag(.rotate)
        case .close:
            endEditing(commit: false)
            removeFromSuperview()
        case .body:
            window?.makeFirstResponder(textView)
        case .outside:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        MainThreadWatchdog.shared.noteMainAlive()
        let point = convert(event.locationInWindow, from: nil)
        let delta = CGPoint(x: point.x - dragStart.x, y: point.y - dragStart.y)

        switch dragMode {
        case .move:
            stroke.start = CGPoint(x: startCenter.x + delta.x, y: startCenter.y + delta.y)
        case .resize(let edge):
            resize(edge: edge, delta: delta)
        case .rotate:
            let startAngle = atan2(dragStart.y - startCenter.y, dragStart.x - startCenter.x)
            let angle = atan2(point.y - startCenter.y, point.x - startCenter.x)
            stroke.rotation = startRotation + (angle - startAngle) * 180 / .pi
        case .none:
            return
        }

        updateTextViewLayout()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        MainThreadWatchdog.shared.noteMainAlive()
        finishGeometryDrag()
    }

    private func captureDragStart(at point: CGPoint) {
        dragStart = point
        startCenter = stroke.start
        startSize = CGSize(width: stroke.textBoxWidth, height: stroke.textBoxHeight)
        startRotation = stroke.rotation
    }

    private func beginGeometryDrag(_ mode: DragMode) {
        dragMode = mode
        stroke.text = textView.string
        MainThreadWatchdog.shared.noteGeometryDrag(true)
    }

    private func finishGeometryDrag() {
        guard !isNone(dragMode) else { return }
        dragMode = .none
        MainThreadWatchdog.shared.noteGeometryDrag(false)
        stroke.text = textView.string
        stroke.textWidthLocked = widthLocked
        updateTextViewLayout()
        onLiveChange?()
        needsDisplay = true
    }

    private func isNone(_ mode: DragMode) -> Bool {
        if case .none = mode { return true }
        return false
    }

    private func resize(edge: Edge, delta: CGPoint) {
        let radians = startRotation * .pi / 180
        let cosAngle = cos(radians)
        let sinAngle = sin(radians)
        let localDelta = CGPoint(
            x: delta.x * cosAngle + delta.y * sinAngle,
            y: -delta.x * sinAngle + delta.y * cosAngle
        )

        var minX = -startSize.width / 2
        var maxX = startSize.width / 2
        var minY = -startSize.height / 2
        var maxY = startSize.height / 2

        switch edge {
        case .left, .topLeft, .bottomLeft: minX += localDelta.x
        default: break
        }
        switch edge {
        case .right, .bottomRight: maxX += localDelta.x
        default: break
        }
        switch edge {
        case .bottom, .bottomLeft, .bottomRight: minY += localDelta.y
        default: break
        }
        switch edge {
        case .top, .topLeft: maxY += localDelta.y
        default: break
        }

        if maxX - minX < minWidth {
            switch edge {
            case .left, .topLeft, .bottomLeft: minX = maxX - minWidth
            default: maxX = minX + minWidth
            }
        }
        if maxY - minY < minHeight {
            switch edge {
            case .bottom, .bottomLeft, .bottomRight: minY = maxY - minHeight
            default: maxY = minY + minHeight
            }
        }

        let width = min(max(maxX - minX, minWidth), maxWidth)
        let height = min(max(maxY - minY, minHeight), maxHeight)
        let localCenter = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        stroke.start = CGPoint(
            x: startCenter.x + localCenter.x * cosAngle - localCenter.y * sinAngle,
            y: startCenter.y + localCenter.x * sinAngle + localCenter.y * cosAngle
        )
        stroke.textBoxWidth = width
        stroke.textBoxHeight = height
    }

    // MARK: - Text

    func textDidChange(_ notification: Notification) {
        stroke.text = textView.string
        fitToContent()
        updateTextViewLayout()
        onLiveChange?()
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard isEditing else { return }

        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: stroke.start.x, yBy: stroke.start.y)
        transform.rotate(byDegrees: stroke.rotation)
        transform.translateX(by: -stroke.textBoxWidth / 2, yBy: -stroke.textBoxHeight / 2)
        transform.concat()

        chromeColor.setStroke()
        let border = NSBezierPath(
            rect: NSRect(x: 0, y: 0, width: stroke.textBoxWidth, height: stroke.textBoxHeight)
        )
        border.lineWidth = 1
        border.stroke()

        drawIconButton(
            symbol: "arrow.up.left.and.arrow.down.right",
            at: CGPoint(x: 0, y: stroke.textBoxHeight)
        )
        drawIconButton(
            symbol: "arrow.up.right.and.arrow.down.left",
            at: CGPoint(x: 0, y: 0)
        )
        drawIconButton(
            symbol: "arrow.up.left.and.arrow.down.right",
            at: CGPoint(x: stroke.textBoxWidth, y: 0)
        )

        let rotate = CGPoint(x: stroke.textBoxWidth / 2, y: stroke.textBoxHeight + rotateDistance)
        let line = NSBezierPath()
        line.move(to: CGPoint(x: stroke.textBoxWidth / 2, y: stroke.textBoxHeight))
        line.line(to: rotate)
        line.lineWidth = 1
        line.stroke()
        drawIconButton(symbol: "arrow.clockwise", at: rotate)

        drawIconButton(
            symbol: "xmark",
            at: CGPoint(x: stroke.textBoxWidth, y: stroke.textBoxHeight)
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawIconButton(symbol: String, at point: CGPoint) {
        let radius = controlRadius
        let rect = NSRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        NSColor.white.setFill()
        chromeColor.setStroke()
        let path = NSBezierPath(ovalIn: rect)
        path.fill()
        path.stroke()

        let configuration = NSImage.SymbolConfiguration(paletteColors: [chromeColor])
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)?
            .draw(in: rect.insetBy(dx: 3, dy: 3))
    }

    var isTransforming: Bool {
        !isNone(dragMode)
    }
}
