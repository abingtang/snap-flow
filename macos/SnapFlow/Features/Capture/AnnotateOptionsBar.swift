import AppKit

/// 二级扩展条：色板 / 线宽 / 形状切换（方框↔圆）等
@MainActor
final class AnnotateOptionsBar: NSView {
    struct Style: Equatable {
        /// 各工具初始默认红色
        var color: NSColor = .systemRed
        var lineWidth: CGFloat = 3
        var filled: Bool = false
        var arrowStyle: Int = 0
        var shapeKind: ShapeKind = .rectangle
        var highlighterMode: HighlighterMode = .line
        var eraserMode: EraserMode = .smear
        var fontSize: CGFloat = 14
        var bold: Bool = false
        var italic: Bool = false

        /// 按工具给出独立初始默认（颜色统一红色，粗细/字号可按工具区分）
        static func `default`(for tool: AnnotateTool) -> Style {
            var style = Style()
            style.color = .systemRed
            switch tool {
            case .pen:
                style.lineWidth = 3
            case .shape, .arrow:
                style.lineWidth = 3
            case .highlighter:
                style.lineWidth = 12
            case .eraser:
                style.lineWidth = 16
                style.eraserMode = .smear
            case .text, .number:
                style.fontSize = 14
                style.lineWidth = 3
            default:
                break
            }
            return style
        }
    }

    var style = Style() {
        didSet {
            if activeTool.isDrawable {
                stylesByTool[activeTool] = style
            }
            onChange?(style)
        }
    }
    var onChange: ((Style) -> Void)?
    /// 屏幕坐标系锚点：颜色选择器出现在截图框选区域附近（由 RegionSelector 注入）
    var colorPanelScreenAnchor: (() -> NSRect?)?

    /// 当前二级条绑定的标注工具（用于按工具记忆样式）
    private(set) var activeTool: AnnotateTool = .none
    /// 各绘制工具独立的颜色 / 粗细 / 字号等
    private var stylesByTool: [AnnotateTool: Style] = [:]

    private let hPad: CGFloat = 6
    private let vPad: CGFloat = 3
    /// 控件岛 / 图标行高度（整体压矮）
    private let itemH: CGFloat = 22
    private let iconItemW: CGFloat = 26
    /// 线宽控件岛宽度：圆点预览 + 数字框（无进度条）
    private let sliderWidth: CGFloat = 58
    /// 字号控件岛宽度
    private let numericWidth: CGFloat = 68
    /// 组内图标间距
    private let itemGap: CGFloat = 2
    /// 分组之间（分隔符）占位宽度
    private let groupGap: CGFloat = 8
    /// 控件岛与色板之间的间距
    private let islandTrailingGap: CGFloat = 6
    /// 色板两行：色块 14，间隙尽量贴紧
    private let paletteCell: CGFloat = 14
    private let paletteCellGap: CGFloat = 1
    private var paletteBlockH: CGFloat { paletteCell * 2 + paletteCellGap }
    private var items: [OptionsItem] = []
    private var hasPalette = false
    private var cursorTrackingArea: NSTrackingArea?
    /// 截图会话内由父视图统一管光标时设为 false
    var managesCursor: Bool = true
    /// 滚轮累计：触控板精密滚动需积够阈值才变 1 档，避免过灵敏
    private var scrollWheelAccum: CGFloat = 0
    /// 精密滚动约需累计这么多 pt 才步进 1（越大越钝）
    private let scrollWheelStepThreshold: CGFloat = 32

    /// Snipaste 风格：两行候选色（上排偏深/主色，下排偏浅）
    private let palette: [NSColor] = [
        // 上排
        .black, .darkGray, NSColor(calibratedRed: 0.75, green: 0.2, blue: 0.15, alpha: 1),
        NSColor(calibratedRed: 0.9, green: 0.45, blue: 0.1, alpha: 1),
        NSColor(calibratedRed: 0.95, green: 0.8, blue: 0.15, alpha: 1),
        NSColor(calibratedRed: 0.25, green: 0.7, blue: 0.3, alpha: 1),
        NSColor(calibratedRed: 0.15, green: 0.7, blue: 0.75, alpha: 1),
        NSColor(calibratedRed: 0.2, green: 0.45, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.55, green: 0.3, blue: 0.85, alpha: 1),
        NSColor(calibratedRed: 0.9, green: 0.35, blue: 0.65, alpha: 1),
        // 下排
        .white, .lightGray,
        NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.5, alpha: 1),
        NSColor(calibratedRed: 0.95, green: 0.7, blue: 0.4, alpha: 1),
        NSColor(calibratedRed: 1.0, green: 0.95, blue: 0.55, alpha: 1),
        NSColor(calibratedRed: 0.55, green: 0.9, blue: 0.55, alpha: 1),
        NSColor(calibratedRed: 0.55, green: 0.9, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.55, green: 0.75, blue: 1.0, alpha: 1),
        NSColor(calibratedRed: 0.75, green: 0.6, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.95, green: 0.7, blue: 0.85, alpha: 1),
    ]
    private let paletteColumns = 10

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = SnipStyle.toolbarBG.cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = AppTheme.nsCaptureBorder.cgColor
        rebuild(for: .none)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        for item in items {
            if let numericInput = item.numericHitTest(at: local, from: self) {
                return numericInput
            }
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        // 数字框由 hitTest 直接返回，不会进入这里；进入这里说明用户点的是其他功能，先提交并结束数字编辑。
        _ = window?.makeFirstResponder(self)
        let local = convert(event.locationInWindow, from: nil)
        for item in items where item.frame.contains(local) {
            if item.kind == .slider {
                // 圆点区域：上下拖动调节线宽；数字框走 hitTest
                item.isTracking = true
                item.thicknessDragStartY = local.y
                item.thicknessDragStartWidth = style.lineWidth
                return
            }
            item.isPressed = true
            item.needsDisplay = true
            item.action()
            DispatchQueue.main.async {
                item.isPressed = false
                item.needsDisplay = true
            }
            return
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if let item = items.first(where: { $0.kind == .slider && $0.isTracking }) {
            handleThicknessDrag(at: local, item: item)
        }
    }

    override func mouseUp(with event: NSEvent) {
        items.forEach {
            $0.isTracking = false
            $0.thicknessDragStartY = nil
        }
    }

    override func scrollWheel(with event: NSEvent) {
        handleScrollWheel(event)
    }

    /// 供子数字框转发滚轮（命中 NSTextField 时事件不会到本视图）
    fileprivate func handleScrollWheel(_ event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let overSlider = items.contains { $0.kind == .slider && $0.frame.contains(local) }
        let overFontSize = items.contains { $0.kind == .numeric && $0.frame.contains(local) }
        guard overSlider || overFontSize else {
            scrollWheelAccum = 0
            super.scrollWheel(with: event)
            return
        }

        let step = consumeScrollWheelStep(from: event)
        guard step != 0 else { return }

        if let item = items.first(where: { $0.kind == .slider && $0.frame.contains(local) }) {
            applyLineWidth(style.lineWidth + step, on: item)
            return
        }
        if let item = items.first(where: { $0.kind == .numeric && $0.frame.contains(local) }) {
            applyFontSize(style.fontSize + step, on: item)
            return
        }
    }

    /// 将滚轮/触控板事件折算为 -1 / 0 / +1 步进。
    private func consumeScrollWheelStep(from event: NSEvent) -> CGFloat {
        if event.hasPreciseScrollingDeltas {
            scrollWheelAccum += event.scrollingDeltaY
            guard abs(scrollWheelAccum) >= scrollWheelStepThreshold else { return 0 }
            let direction: CGFloat = scrollWheelAccum > 0 ? 1 : -1
            // 只扣一档阈值，快速连滑可连续进档但仍明显比「每事件 +1」钝
            scrollWheelAccum -= direction * scrollWheelStepThreshold
            return direction
        }
        // 传统鼠标滚轮：一格一档，忽略过小噪声
        scrollWheelAccum = 0
        let d = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
        guard abs(d) >= 0.2 else { return 0 }
        return d > 0 ? 1 : -1
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea {
            removeTrackingArea(cursorTrackingArea)
            self.cursorTrackingArea = nil
        }
        guard managesCursor else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .cursorUpdate, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard managesCursor else { return }
        updateCursor(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        guard managesCursor else { return }
        updateCursor(with: event)
    }

    private func updateCursor(with event: NSEvent) {
        guard managesCursor else { return }
        let local = convert(event.locationInWindow, from: nil)
        cursor(at: local).set()
    }

    func cursor(at local: NSPoint) -> NSCursor {
        guard let item = items.first(where: { $0.frame.contains(local) }) else {
            return .arrow
        }
        switch item.kind {
        case .slider:
            if item.numericHitTest(at: local, from: self) != nil {
                return .iBeam
            }
            return .resizeUpDown
        case .numeric:
            // 数字框区域由 hitTest 交给 NSTextField（I-beam）；岛其余区域用上下光标提示可滚轮调节
            if item.numericHitTest(at: local, from: self) != nil {
                return .iBeam
            }
            return .resizeUpDown
        case .separator:
            return .arrow
        case .colorMain, .color, .icon, .text:
            return .pointingHand
        }
    }

    /// 在圆点区域上下拖动调节线宽（上增下减）
    private func handleThicknessDrag(at local: NSPoint, item: OptionsItem) {
        guard let startY = item.thicknessDragStartY else { return }
        let dy = local.y - startY
        // 约 4pt 对应 1 档线宽
        let delta = (dy / 4).rounded()
        applyLineWidth(item.thicknessDragStartWidth + delta, on: item)
    }

    private func applyLineWidth(_ value: CGFloat, on item: OptionsItem) {
        let clamped = min(max(value.rounded(), 1), 24)
        item.label = "\(Int(clamped))"
        item.setNumericValue(clamped)
        item.needsDisplay = true
        // style.didSet 会触发 onChange，此处不再重复回调
        if style.lineWidth != clamped {
            style.lineWidth = clamped
        }
    }

    private func applyFontSize(_ value: CGFloat, on item: OptionsItem) {
        let clamped = min(max(value.rounded(), 8), 120)
        item.label = "\(Int(clamped))"
        item.setNumericValue(clamped)
        item.needsDisplay = true
        if style.fontSize != clamped {
            style.fontSize = clamped
        }
    }

    func preferredSize() -> NSSize {
        layoutItems()
        let w = items.map(\.frame.maxX).max().map { $0 + hPad } ?? 120
        let h = hasPalette ? (paletteBlockH + vPad * 2) : (itemH + vPad * 2)
        return NSSize(width: max(w, 120), height: h)
    }

    /// 切换工具：加载该工具独立样式（或 preferredStyle / 默认红色）
    func show(for tool: AnnotateTool, preferredStyle: Style? = nil) {
        let previousTool = activeTool
        let nextStyle: Style? = tool.isDrawable
            ? (preferredStyle ?? stylesByTool[tool] ?? Style.default(for: tool))
            : nil
        let styleChanged = nextStyle.map { style != $0 } ?? false
        let hasWidthInput = items.contains { $0.id == "width" }
        let shouldShowWidthInput = nextStyle?.eraserMode == .smear
        let needsRebuild = previousTool != tool
            || (tool == .eraser && hasWidthInput != shouldShowWidthInput)

        activeTool = tool
        if let nextStyle {
            let callback = onChange
            onChange = nil
            style = nextStyle
            stylesByTool[tool] = nextStyle
            onChange = callback
        }
        if needsRebuild {
            rebuild(for: tool)
        } else if styleChanged {
            // layoutToolbar 会在鼠标移动时重复调用 show；同工具同结构下只同步显示，不替换输入框。
            let callback = onChange
            onChange = nil
            refreshSelectionChrome()
            onChange = callback
        }
    }

    /// 更新当前样式。同步活动元素时不触发回调，避免把画布当前状态再次写回元素。
    func setStyle(_ newStyle: Style, notify: Bool = true) {
        guard !notify else {
            style = newStyle
            return
        }

        let callback = onChange
        onChange = nil
        style = newStyle
        if activeTool.isDrawable {
            stylesByTool[activeTool] = newStyle
        }
        refreshSelectionChrome()
        onChange = callback
    }

    /// 读取某工具当前记忆的样式（无则默认）
    func storedStyle(for tool: AnnotateTool) -> Style {
        stylesByTool[tool] ?? Style.default(for: tool)
    }

    // MARK: - Build

    private func rebuild(for tool: AnnotateTool) {
        items.forEach { $0.removeFromSuperview() }
        items.removeAll()
        hasPalette = false

        switch tool {
        case .none:
            // 无编辑工具：不显示二级条
            isHidden = true
            setFrameSize(.zero)
            return
        case .shape:
            isHidden = false
            addIcon("rectangle", L10n.string("方框"), selected: style.shapeKind == .rectangle) { [weak self] in
                self?.style.shapeKind = .rectangle
                self?.refreshSelectionChrome()
            }
            addIcon("circle", L10n.string("圆形"), selected: style.shapeKind == .ellipse) { [weak self] in
                self?.style.shapeKind = .ellipse
                self?.refreshSelectionChrome()
            }
            addSep()
            addIcon("square", L10n.string("描边"), selected: !style.filled) { [weak self] in
                self?.style.filled = false
                self?.refreshSelectionChrome()
            }
            addIcon("square.fill", L10n.string("填充"), selected: style.filled) { [weak self] in
                self?.style.filled = true
                self?.refreshSelectionChrome()
            }
            addSep()
            addSlider()
            addSep()
            addPalette()
        case .arrow:
            isHidden = false
            // 直线 / 单箭头 / 双向：与主工具语义对齐的轮廓图标
            addIcon("line.diagonal", L10n.string("直线"), selected: style.arrowStyle == 1) { [weak self] in
                self?.style.arrowStyle = 1
                self?.refreshSelectionChrome()
            }
            addIcon("arrow.up.right", L10n.string("箭头"), selected: style.arrowStyle == 0) { [weak self] in
                self?.style.arrowStyle = 0
                self?.refreshSelectionChrome()
            }
            addIcon("arrow.left.and.right", L10n.string("双向"), selected: style.arrowStyle == 2) { [weak self] in
                self?.style.arrowStyle = 2
                self?.refreshSelectionChrome()
            }
            addSep()
            addSlider()
            addSep()
            addPalette()
        case .pen:
            isHidden = false
            addSlider()
            addSep()
            addPalette()
        case .highlighter:
            isHidden = false
            addIcon(
                "line.diagonal",
                L10n.string("直线"),
                id: "highlighter_line",
                selected: style.highlighterMode == .line
            ) { [weak self] in
                self?.style.highlighterMode = .line
                self?.refreshSelectionChrome()
            }
            addIcon(
                "rectangle",
                L10n.string("区域"),
                id: "highlighter_area",
                selected: style.highlighterMode == .area
            ) { [weak self] in
                self?.style.highlighterMode = .area
                self?.refreshSelectionChrome()
            }
            addSep()
            addSlider()
            addSep()
            addPalette()
        case .mosaic:
            // 马赛克无需二级选项条（粗细/色板）
            isHidden = true
            setFrameSize(.zero)
            return
        case .eraser:
            isHidden = false
            addIcon(
                "scribble.variable",
                L10n.string("涂抹"),
                id: "eraser_smear",
                selected: style.eraserMode == .smear
            ) { [weak self] in
                guard let self, self.style.eraserMode != .smear else { return }
                self.style.eraserMode = .smear
                // 涂抹才显示粗细：切换模式后重建二级条
                self.rebuild(for: .eraser)
            }
            addIcon(
                "rectangle.dashed",
                L10n.string("框选"),
                id: "eraser_rect",
                selected: style.eraserMode == .rect
            ) { [weak self] in
                guard let self, self.style.eraserMode != .rect else { return }
                self.style.eraserMode = .rect
                self.rebuild(for: .eraser)
            }
            // 粗细仅对涂抹生效
            if style.eraserMode == .smear {
                addSep()
                addSlider()
            }
        case .text:
            isHidden = false
            // 粗体 / 斜体用系统字形图标，比字母 B/I 更清晰、更统一
            addIcon("bold", L10n.string("粗体"), id: "bold", selected: style.bold) { [weak self] in
                self?.style.bold.toggle()
                self?.refreshSelectionChrome()
            }
            addIcon("italic", L10n.string("斜体"), id: "italic", selected: style.italic) { [weak self] in
                self?.style.italic.toggle()
                self?.refreshSelectionChrome()
            }
            addFontSize()
            addSep()
            addPalette()
        case .number:
            isHidden = false
            addFontSize()
            addSep()
            addPalette()
        default:
            isHidden = true
            setFrameSize(.zero)
            return
        }

        let size = preferredSize()
        setFrameSize(size)
        needsDisplay = true
        onChange?(style)
    }

    private func refreshSelectionChrome() {
        // 按 id 刷新选中态
        for item in items {
            switch item.id {
            case "shape_rect": item.isSelected = style.shapeKind == .rectangle
            case "shape_ell": item.isSelected = style.shapeKind == .ellipse
            case "stroke": item.isSelected = !style.filled
            case "fill": item.isSelected = style.filled
            case "line": item.isSelected = style.arrowStyle == 1
            case "arrow": item.isSelected = style.arrowStyle == 0
            case "bi": item.isSelected = style.arrowStyle == 2
            case "highlighter_line": item.isSelected = style.highlighterMode == .line
            case "highlighter_area": item.isSelected = style.highlighterMode == .area
            case "eraser_smear": item.isSelected = style.eraserMode == .smear
            case "eraser_rect": item.isSelected = style.eraserMode == .rect
            case "bold": item.isSelected = style.bold
            case "italic": item.isSelected = style.italic
            case "width":
                item.label = "\(Int(style.lineWidth))"
                item.setNumericValue(style.lineWidth)
            case "fontSize":
                item.label = "\(Int(style.fontSize))"
                item.setNumericValue(style.fontSize)
            case "color_main":
                item.color = style.color
                item.isSelected = true
            default:
                if item.id.hasPrefix("color_"), item.id != "color_main" {
                    let idx = Int(item.id.dropFirst(6)) ?? -1
                    if idx >= 0, idx < palette.count {
                        item.isSelected = colorsEqual(palette[idx], style.color)
                    }
                }
            }
            item.needsDisplay = true
        }
        onChange?(style)
    }

    private func addPalette() {
        hasPalette = true
        // 大色块：当前色，点击打开系统颜色选择器
        let main = OptionsItem(id: "color_main", kind: .colorMain, color: style.color) { [weak self] in
            self?.openSystemColorPanel()
        }
        main.toolTip = L10n.string("点击打开颜色选择器")
        main.isSelected = true
        items.append(main)
        addSubview(main)

        // 小色板（两行布局，layoutItems 中按列排布）
        for (idx, c) in palette.enumerated() {
            let item = OptionsItem(id: "color_\(idx)", kind: .color, color: c) { [weak self] in
                self?.style.color = c
                self?.refreshSelectionChrome()
            }
            item.toolTip = colorTip(c)
            item.isSelected = colorsEqual(c, style.color)
            items.append(item)
            addSubview(item)
        }
    }

    private func openSystemColorPanel() {
        let panel = NSColorPanel.shared
        panel.color = style.color
        panel.showsAlpha = true
        panel.isContinuous = true
        panel.setTarget(self)
        panel.setAction(#selector(systemColorChanged(_:)))
        panel.orderFront(nil)
        AppActivation.activateWithoutRaisingAllWindows()

        // 定位到截图框选区域附近（优先），否则靠近本色块
        positionColorPanel(panel)
    }

    private func positionColorPanel(_ panel: NSColorPanel) {
        let panelSize = panel.frame.size
        var origin: NSPoint?

        if let anchor = colorPanelScreenAnchor?(), anchor.width > 0, anchor.height > 0 {
            // 优先放在选区左侧，紧贴选区；放不下则右侧，再不行贴选区下方
            let gap: CGFloat = 12
            if let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main {
                let vis = screen.visibleFrame
                // 左侧
                var o = NSPoint(x: anchor.minX - panelSize.width - gap, y: anchor.midY - panelSize.height / 2)
                if o.x < vis.minX {
                    // 右侧
                    o.x = anchor.maxX + gap
                }
                if o.x + panelSize.width > vis.maxX {
                    // 贴选区下沿水平居中
                    o.x = max(vis.minX, min(anchor.midX - panelSize.width / 2, vis.maxX - panelSize.width))
                    o.y = anchor.minY - panelSize.height - gap
                }
                o.y = max(vis.minY, min(o.y, vis.maxY - panelSize.height))
                o.x = max(vis.minX, min(o.x, vis.maxX - panelSize.width))
                origin = o
            }
        }

        if origin == nil, let win = window, let mainItem = items.first(where: { $0.id == "color_main" }) {
            let local = mainItem.frame
            let winRect = convert(local, to: nil)
            let screenRect = win.convertToScreen(winRect)
            origin = NSPoint(x: screenRect.minX, y: screenRect.maxY + 8)
        }

        if let o = origin {
            panel.setFrameOrigin(o)
        }
    }

    @objc private func systemColorChanged(_ sender: NSColorPanel) {
        style.color = sender.color
        refreshSelectionChrome()
        // 更新大色块显示
        if let main = items.first(where: { $0.id == "color_main" }) {
            main.color = sender.color
            main.needsDisplay = true
        }
    }

    private func colorTip(_ c: NSColor) -> String {
        guard let rgb = c.usingColorSpace(.sRGB) else { return L10n.string("颜色") }
        return String(
            format: "#%02X%02X%02X",
            Int(rgb.redComponent * 255),
            Int(rgb.greenComponent * 255),
            Int(rgb.blueComponent * 255)
        )
    }

    private func addIcon(
        _ symbol: String,
        _ tip: String,
        id explicitID: String? = nil,
        selected: Bool = false,
        _ action: @escaping () -> Void
    ) {
        let id: String = explicitID ?? {
            switch tip {
            case L10n.string("方框"): return "shape_rect"
            case L10n.string("圆形"): return "shape_ell"
            case L10n.string("描边"): return "stroke"
            case L10n.string("填充"): return "fill"
            case L10n.string("直线"): return "line"
            case L10n.string("箭头"): return "arrow"
            case L10n.string("双向"): return "bi"
            default: return "icon_\(items.count)"
            }
        }()
        let item = OptionsItem(id: id, kind: .icon, symbol: symbol, action: action)
        item.toolTip = tip
        item.isSelected = selected
        items.append(item)
        addSubview(item)
    }

    private func addText(_ title: String, _ tip: String, selected: Bool, _ action: @escaping () -> Void) {
        let id = tip == L10n.string("粗体") ? "bold" : (tip == L10n.string("斜体") ? "italic" : "t_\(items.count)")
        let item = OptionsItem(id: id, kind: .text, title: title, action: action)
        item.toolTip = tip
        item.isSelected = selected
        items.append(item)
        addSubview(item)
    }

    private func addSlider() {
        let item = OptionsItem(id: "width", kind: .slider, label: "\(Int(style.lineWidth))", action: {})
        item.toolTip = L10n.string("线宽")
        item.configureNumericInput(value: style.lineWidth, range: 1...24) { [weak self, weak item] value in
            guard let self else { return }
            self.style.lineWidth = value
            item?.label = "\(Int(value))"
            item?.needsDisplay = true
        }
        items.append(item)
        addSubview(item)
    }

    private func addFontSize() {
        let item = OptionsItem(id: "fontSize", kind: .numeric, action: {})
        item.label = "\(Int(style.fontSize))"
        item.configureNumericInput(value: style.fontSize, range: 8...120) { [weak self, weak item] value in
            self?.style.fontSize = value
            item?.label = "\(Int(value))"
            item?.needsDisplay = true
        }
        item.toolTip = L10n.string("字号")
        items.append(item)
        addSubview(item)
    }

    private func addSep() {
        let item = OptionsItem(id: "sep_\(items.count)", kind: .separator, action: {})
        items.append(item)
        addSubview(item)
    }

    private func layoutItems() {
        let barH = hasPalette ? paletteBlockH : itemH
        let contentH = bounds.height > 1 ? bounds.height - vPad * 2 : barH
        let midY = vPad + (hasPalette ? (paletteBlockH - itemH) / 2 : 0)
        var x = hPad

        // 非色板项先水平排布；色板项单独两行
        var colorItems: [OptionsItem] = []
        var mainColor: OptionsItem?

        for item in items {
            switch item.kind {
            case .colorMain:
                mainColor = item
            case .color:
                colorItems.append(item)
            default:
                let w: CGFloat
                switch item.kind {
                case .icon, .text: w = iconItemW
                case .slider: w = sliderWidth
                case .numeric: w = numericWidth
                case .separator: w = groupGap
                default: w = iconItemW
                }
                let y = hasPalette ? midY : vPad
                item.frame = NSRect(x: x, y: y, width: w, height: itemH)
                item.needsDisplay = true
                let gapAfter: CGFloat
                switch item.kind {
                case .separator:
                    gapAfter = 0
                case .icon, .text:
                    gapAfter = itemGap
                case .slider, .numeric:
                    gapAfter = islandTrailingGap
                default:
                    gapAfter = itemGap
                }
                x += w + gapAfter
            }
        }

        if let main = mainColor {
            let mainSize: CGFloat = hasPalette ? paletteBlockH - 2 : itemH - 2
            let y = vPad + (hasPalette ? (paletteBlockH - mainSize) / 2 : (itemH - mainSize) / 2)
            main.frame = NSRect(x: x, y: y, width: mainSize, height: mainSize)
            main.needsDisplay = true
            // 大色块与小色板紧贴
            x += mainSize + 3
        }

        if !colorItems.isEmpty {
            let cell = paletteCell
            let gap = paletteCellGap
            let cols = paletteColumns
            for (idx, item) in colorItems.enumerated() {
                let row = idx / cols
                let col = idx % cols
                // 色块紧凑排布：仅 1pt 缝
                let ix = x + CGFloat(col) * (cell + gap)
                // 上排 row0 在上：AppKit y 向上，上排 y 更大
                let iy = vPad + (row == 0 ? cell + gap : 0)
                item.frame = NSRect(x: ix, y: iy, width: cell, height: cell)
                item.needsDisplay = true
            }
            let usedCols = min(cols, colorItems.count)
            x += CGFloat(usedCols) * (cell + gap)
            _ = contentH
        }
    }

    override func layout() {
        super.layout()
        layoutItems()
    }

    private func colorsEqual(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let ar = a.usingColorSpace(.sRGB), let br = b.usingColorSpace(.sRGB) else { return a == b }
        return abs(ar.redComponent - br.redComponent) < 0.02
            && abs(ar.greenComponent - br.greenComponent) < 0.02
            && abs(ar.blueComponent - br.blueComponent) < 0.02
    }
}

@MainActor
private final class OptionsItem: NSView, NSTextFieldDelegate {
    enum Kind { case colorMain, color, icon, text, slider, numeric, separator }

    let id: String
    let kind: Kind
    var action: () -> Void
    var color: NSColor?
    var symbol: String?
    var title: String?
    var label: String = ""
    var isSelected = false
    var isPressed = false
    var isTracking = false
    private var numericField: NSTextField?
    private var numericRange: ClosedRange<CGFloat>?
    private var onNumericChange: ((CGFloat) -> Void)?
    /// 线宽圆点拖动起点（父视图坐标系 y）
    var thicknessDragStartY: CGFloat?
    var thicknessDragStartWidth: CGFloat = 3

    /// 控件岛内边距
    private var islandInset: CGFloat { 4 }

    init(
        id: String,
        kind: Kind,
        color: NSColor? = nil,
        symbol: String? = nil,
        title: String? = nil,
        label: String = "",
        action: @escaping () -> Void
    ) {
        self.id = id
        self.kind = kind
        self.color = color
        self.symbol = symbol
        self.title = title
        self.label = label
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        guard let numericField else { return }
        let chipW: CGFloat = kind == .slider ? 26 : 32
        let chipH: CGFloat = 16
        numericField.frame = NSRect(
            x: bounds.maxX - chipW - islandInset,
            y: ((bounds.height - chipH) / 2).rounded(),
            width: chipW,
            height: chipH
        )
        applyChipChrome(to: numericField)
    }

    func configureNumericInput(
        value: CGFloat,
        range: ClosedRange<CGFloat>,
        onChange: @escaping (CGFloat) -> Void
    ) {
        numericRange = range
        onNumericChange = onChange

        let field = ChipNumericTextField(string: "\(Int(value))")
        // 使用自定义 cell，保证数字在胶囊内水平+垂直居中
        let cell = CenteredChipTextFieldCell(textCell: "\(Int(value))")
        cell.isEditable = true
        cell.isSelectable = true
        cell.isBordered = false
        cell.isBezeled = false
        cell.drawsBackground = false
        cell.alignment = .center
        cell.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        cell.textColor = AppTheme.nsCaptureText
        cell.lineBreakMode = .byClipping
        field.cell = cell
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .center
        field.font = cell.font
        field.textColor = AppTheme.nsCaptureText
        field.delegate = self
        field.target = self
        field.action = #selector(commitNumericInput)
        field.wantsLayer = true
        // 数字框吃掉滚轮时转发给选项条（字号 / 线宽）
        field.onScrollWheel = { [weak self] event in
            guard let bar = self?.enclosingAnnotateOptionsBar else { return }
            bar.handleScrollWheel(event)
        }
        applyChipChrome(to: field)
        addSubview(field)
        numericField = field
        needsLayout = true
    }

    private var enclosingAnnotateOptionsBar: AnnotateOptionsBar? {
        var view: NSView? = self
        while let current = view {
            if let bar = current as? AnnotateOptionsBar { return bar }
            view = current.superview
        }
        return nil
    }

    /// 线宽 / 字号共用的胶囊数字框样式
    private func applyChipChrome(to field: NSTextField) {
        field.wantsLayer = true
        field.layer?.cornerRadius = 4
        field.layer?.masksToBounds = true
        field.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        field.layer?.borderWidth = 1
        field.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
    }

    func setNumericValue(_ value: CGFloat) {
        numericField?.stringValue = "\(Int(value))"
    }

    func numericHitTest(at point: NSPoint, from parent: NSView) -> NSView? {
        guard let numericField else { return nil }
        let fieldPoint = parent.convert(point, to: numericField)
        return numericField.bounds.contains(fieldPoint) ? numericField : nil
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitNumericInput()
    }

    @objc private func commitNumericInput() {
        guard let numericField, let numericRange else { return }
        guard let entered = Double(numericField.stringValue) else {
            setNumericValue(CGFloat(Int(label) ?? Int(numericRange.lowerBound)))
            return
        }
        let value = min(max(CGFloat(entered).rounded(), numericRange.lowerBound), numericRange.upperBound)
        setNumericValue(value)
        needsDisplay = true
        onNumericChange?(value)
    }

    override func draw(_ dirtyRect: NSRect) {
        switch kind {
        case .separator:
            // 分组分隔：更细、上下留白，强化「图标组 / 控件岛 / 色板」层次
            AppTheme.nsCaptureSeparator.withAlphaComponent(0.35).setFill()
            let lineH = max(bounds.height - 10, 8)
            NSRect(x: bounds.midX - 0.5, y: bounds.midY - lineH / 2, width: 1, height: lineH).fill()
        case .colorMain:
            // 大色块 + 右下角彩虹小三角（Snipaste）
            let inset = bounds.insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: inset, xRadius: 4, yRadius: 4)
            (color ?? .systemRed).setFill()
            path.fill()
            NSColor.white.setStroke()
            path.lineWidth = isPressed ? 2.5 : 1.5
            path.stroke()
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: inset.maxX - 11, y: inset.minY + 1))
            tri.line(to: NSPoint(x: inset.maxX - 1, y: inset.minY + 1))
            tri.line(to: NSPoint(x: inset.maxX - 1, y: inset.minY + 11))
            tri.close()
            // 简易彩虹角
            if let grad = NSGradient(colors: [
                .systemRed, .systemYellow, .systemGreen, .systemBlue, .systemPurple,
            ]) {
                grad.draw(in: tri, angle: 45)
            } else {
                NSColor.systemRed.setFill()
                tri.fill()
            }
        case .color:
            // 两行小色块：填满 cell，仅留极小圆角，视觉上紧凑贴合
            let side = min(bounds.width, bounds.height)
            let origin = NSPoint(
                x: bounds.midX - side / 2,
                y: bounds.midY - side / 2
            )
            let rect = NSRect(origin: origin, size: NSSize(width: side, height: side))
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            (color ?? .gray).setFill()
            path.fill()
            if isSelected || isPressed {
                NSColor.white.setStroke()
                path.lineWidth = 1.5
                path.stroke()
            } else {
                // 浅描边避免同色相邻时完全糊成一片，仍保持贴紧
                AppTheme.nsCaptureOutline.withAlphaComponent(0.35).setStroke()
                path.lineWidth = 0.5
                path.stroke()
            }
        case .icon:
            if isSelected {
                SnipStyle.stroke.withAlphaComponent(0.55).setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
            } else if isPressed {
                AppTheme.nsCaptureHoverStrong.setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
            }
            let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
                .applying(.init(paletteColors: [.white]))
            if let symbol,
               let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(symbolConfiguration)
            {
                let size = NSSize(width: 14, height: 14)
                let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
                img.draw(in: NSRect(origin: origin, size: size), from: .zero, operation: .sourceOver, fraction: 1)
            }
        case .text:
            if isSelected {
                SnipStyle.stroke.withAlphaComponent(0.55).setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
            } else if isPressed {
                AppTheme.nsCaptureHoverStrong.setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
            }
            let t = (title ?? "") as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: AppTheme.nsCaptureText,
            ]
            let size = t.size(withAttributes: attrs)
            t.draw(
                at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                withAttributes: attrs
            )
        case .numeric:
            drawControlIsland()
            // 字号示意：经典「A」字形，比 textformat.size 更易辨认
            let glyph = "A" as NSString
            let fontSizeValue = CGFloat(Int(numericField?.stringValue ?? label) ?? 14)
            // 将 8…120 映射到岛内可读字号 8…13
            let t = max(0, min(1, (fontSizeValue - 8) / 112))
            let previewPointSize = 8 + t * 5
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: previewPointSize, weight: .bold),
                .foregroundColor: AppTheme.nsCaptureText,
            ]
            let glyphSize = glyph.size(withAttributes: attrs)
            let chipMinX = numericField?.frame.minX ?? (bounds.maxX - islandInset - 32)
            let areaWidth = max(chipMinX - islandInset, glyphSize.width)
            let origin = NSPoint(
                x: islandInset + (areaWidth - glyphSize.width) / 2,
                y: bounds.midY - glyphSize.height / 2
            )
            glyph.draw(at: origin, withAttributes: attrs)
        case .slider:
            drawControlIsland()
            // 圆点半径随线宽变化，直观表示粗细（无进度条）
            let lineW = CGFloat(Int(label) ?? 3)
            let maxDiameter = min(bounds.height - 6, 14)
            let diameter = min(max(lineW, 2), maxDiameter)
            let chipMinX = numericField?.frame.minX ?? (bounds.maxX - islandInset - 26)
            let previewCenterX = islandInset + (chipMinX - islandInset) / 2
            let dot = NSRect(
                x: previewCenterX - diameter / 2,
                y: bounds.midY - diameter / 2,
                width: diameter,
                height: diameter
            )
            NSColor.black.withAlphaComponent(0.22).setFill()
            NSBezierPath(ovalIn: dot.insetBy(dx: -0.5, dy: -0.5)).fill()
            NSColor.white.withAlphaComponent(0.95).setFill()
            NSBezierPath(ovalIn: dot).fill()
            NSColor.white.withAlphaComponent(0.35).setStroke()
            let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            ring.stroke()
        }
    }

    /// 线宽 / 字号共用的浅底圆角「控件岛」
    private func drawControlIsland() {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        NSColor.white.withAlphaComponent(0.07).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.10).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// 胶囊数字框：把滚轮交给选项条，避免悬停数字时字号/线宽无法调节
@MainActor
private final class ChipNumericTextField: NSTextField {
    var onScrollWheel: ((NSEvent) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        if let onScrollWheel {
            onScrollWheel(event)
            return
        }
        super.scrollWheel(with: event)
    }
}

/// 胶囊数字框专用 cell：在固定高度内把文字水平+垂直居中
@MainActor
private final class CenteredChipTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let textSize = cellSize(forBounds: rect)
        var draw = rect
        draw.size.height = min(textSize.height, rect.height)
        draw.origin.y = rect.origin.y + ((rect.height - draw.size.height) / 2).rounded(.toNearestOrAwayFromZero)
        // 水平居中交给 alignment = .center，保留完整宽度
        return draw
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(
            withFrame: drawingRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }
}
