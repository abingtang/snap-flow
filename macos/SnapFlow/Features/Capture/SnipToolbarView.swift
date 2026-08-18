import AppKit

/// 框选工具栏；截图流程使用编辑工具栏与底部动作工具栏两个显示模式。
/// - 左右 padding、宽度自适应
/// - 按钮可靠接收点击（acceptsFirstMouse + 自身 hitTest）
@MainActor
final class SnipToolbarView: NSView {
    /// `legacy` 保留贴图编辑器的原有布局。
    enum Presentation {
        case legacy
        case captureEditor
        case captureActions
    }

    var onAction: ((SnipAction) -> Void)?
    var onSelectTool: ((AnnotateTool) -> Void)?
    /// 截图 review 用 capture*；贴图二次编辑用 pinnedImage 键（由 bind 决定）
    private weak var settings: SettingsStore?
    private var shortcutScope: LocalShortcutScope = .capture
    private let presentation: Presentation
    private let showsRecordingAction: Bool

    private let stack = NSStackView()
    private let annotationRow = NSStackView()
    private let actionRow = NSStackView()
    private var toolButtons: [AnnotateTool: SnipToolButton] = [:]
    private var allButtons: [SnipToolButton] = []
    private var actionButtons: [SnipAction: SnipToolButton] = [:]
    private var undoButton: SnipToolButton?
    private var redoButton: SnipToolButton?
    private var cursorTrackingArea: NSTrackingArea?
    private var hoveredButton: SnipToolButton?
    /// 截图会话内由 `RegionSelectionView` 统一管光标时设为 false，避免双通道抢 set 闪烁
    var managesCursor: Bool = true
    private(set) var selectedTool: AnnotateTool = .none

    private let hPad: CGFloat = 6
    private let vPad: CGFloat = 3
    private let btnSize: CGFloat = 26
    private let itemSpacing: CGFloat = 2
    private let rowSpacing: CGFloat = 3

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, presentation: .legacy, showsRecordingAction: false)
    }

    convenience init() {
        self.init(frame: .zero, presentation: .legacy, showsRecordingAction: false)
    }

    convenience init(presentation: Presentation, showsRecordingAction: Bool = true) {
        self.init(
            frame: .zero,
            presentation: presentation,
            showsRecordingAction: showsRecordingAction
        )
    }

    init(
        frame frameRect: NSRect,
        presentation: Presentation,
        showsRecordingAction: Bool = true
    ) {
        self.presentation = presentation
        self.showsRecordingAction = showsRecordingAction
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = SnipStyle.toolbarBG.cgColor
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = AppTheme.nsCaptureBorder.cgColor

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = presentation == .legacy ? rowSpacing : 0
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = true
        addSubview(stack)

        for row in [annotationRow, actionRow] {
            row.orientation = presentation == .captureActions ? .vertical : .horizontal
            row.alignment = presentation == .captureActions ? .centerX : .centerY
            row.spacing = itemSpacing
            row.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            row.translatesAutoresizingMaskIntoConstraints = true
        }

        switch presentation {
        case .legacy:
            stack.addArrangedSubview(annotationRow)
            stack.addArrangedSubview(actionRow)
            buildLegacyLayout()
        case .captureEditor:
            stack.addArrangedSubview(annotationRow)
            buildCaptureEditorLayout()
        case .captureActions:
            stack.addArrangedSubview(actionRow)
            buildCaptureActionsLayout()
        }

        setSelectedTool(.none, notify: false)
        relayout(to: nil)
    }

    private func buildLegacyLayout() {
        appendAnnotateTools(to: annotationRow)
        annotationRow.addArrangedSubview(makeSeparator())
        appendOutputActions(to: annotationRow)
        appendCaptureActions(to: actionRow, includeRecording: false)
        actionRow.addArrangedSubview(makeSeparator())
        appendUndoRedo(to: actionRow)
    }

    private func buildCaptureEditorLayout() {
        appendAnnotateTools(to: annotationRow)
        annotationRow.addArrangedSubview(makeSeparator())
        appendUndoRedo(to: annotationRow)
        annotationRow.addArrangedSubview(makeSeparator())
        appendOutputActions(to: annotationRow)
    }

    private func buildCaptureActionsLayout() {
        appendCaptureActions(to: actionRow, includeRecording: showsRecordingAction)
    }

    private func appendAnnotateTools(to row: NSStackView) {
        // 形状合并为一个按钮；默认不选中任何编辑工具
        let annotateTools: [AnnotateTool] = [
            .shape, .arrow, .pen, .highlighter, .text, .mosaic, .number, .eraser,
        ]
        for tool in annotateTools {
            let button = makeToolButton(tool: tool)
            toolButtons[tool] = button
            allButtons.append(button)
            row.addArrangedSubview(button)
        }
    }

    private func appendOutputActions(to row: NSStackView) {
        let pinButton = makeActionButton(symbol: "pin.fill", tooltip: L10n.string("钉在屏幕上")) { [weak self] in
            self?.fireAction(.pin)
        }
        actionButtons[.pin] = pinButton
        row.addArrangedSubview(pinButton)

        let saveButton = makeActionButton(symbol: "square.and.arrow.down", tooltip: L10n.string("保存")) { [weak self] in
            self?.fireAction(.save)
        }
        actionButtons[.save] = saveButton
        row.addArrangedSubview(saveButton)

        let closeButton = makeActionButton(symbol: "xmark", tooltip: L10n.string("关闭")) { [weak self] in
            self?.fireAction(.cancelled)
        }
        actionButtons[.cancelled] = closeButton
        row.addArrangedSubview(closeButton)

        let copyButton = makeActionButton(symbol: "doc.on.doc", tooltip: L10n.string("复制")) { [weak self] in
            self?.fireAction(.copy)
        }
        actionButtons[.copy] = copyButton
        row.addArrangedSubview(copyButton)
    }

    private func appendCaptureActions(to row: NSStackView, includeRecording: Bool) {
        let separatorIsHorizontal = presentation == .captureActions
        let ocrButton = makeActionButton(symbol: "text.viewfinder", tooltip: L10n.string("OCR 识别")) { [weak self] in
            self?.fireAction(.ocr)
        }
        actionButtons[.ocr] = ocrButton
        row.addArrangedSubview(ocrButton)

        let imageOCRButton = makeActionButton(
            symbol: AppAction.captureImageOCR.menuSymbolName,
            tooltip: L10n.string("原图 OCR")
        ) { [weak self] in
            self?.fireAction(.imageOCR)
        }
        actionButtons[.imageOCR] = imageOCRButton
        row.addArrangedSubview(imageOCRButton)
        row.addArrangedSubview(makeSeparator(isHorizontal: separatorIsHorizontal))

        let translateButton = makeActionButton(
            symbol: AppAction.captureTranslate.menuSymbolName,
            tooltip: L10n.string("截图翻译")
        ) { [weak self] in
            self?.fireAction(.translate)
        }
        actionButtons[.translate] = translateButton
        row.addArrangedSubview(translateButton)

        let imageTranslateButton = makeActionButton(
            symbol: AppAction.captureImageTranslate.menuSymbolName,
            tooltip: L10n.string("原图翻译")
        ) { [weak self] in
            self?.fireAction(.imageTranslate)
        }
        actionButtons[.imageTranslate] = imageTranslateButton
        row.addArrangedSubview(imageTranslateButton)
        row.addArrangedSubview(makeSeparator(isHorizontal: separatorIsHorizontal))

        row.addArrangedSubview(makeActionButton(symbol: "rectangle.stack", tooltip: L10n.string("滚动截屏")) { [weak self] in
            self?.fireAction(.scrollCapture)
        })

        if includeRecording {
            row.addArrangedSubview(makeSeparator(isHorizontal: separatorIsHorizontal))
            let recordingButton = makeActionButton(symbol: "record.circle", tooltip: L10n.string("录制")) { [weak self] in
                self?.fireAction(.record)
            }
            actionButtons[.record] = recordingButton
            row.addArrangedSubview(recordingButton)
        }
    }

    private func appendUndoRedo(to row: NSStackView) {
        let undoButton = makeActionButton(symbol: AnnotateTool.undo.symbolName, tooltip: L10n.string("撤销")) { [weak self] in
            self?.onSelectTool?(.undo)
        }
        self.undoButton = undoButton
        row.addArrangedSubview(undoButton)

        let redoButton = makeActionButton(symbol: AnnotateTool.redo.symbolName, tooltip: L10n.string("重做")) { [weak self] in
            self?.onSelectTool?(.redo)
        }
        self.redoButton = redoButton
        row.addArrangedSubview(redoButton)
    }

    /// 绑定设置以刷新动作按钮 tooltip 中的快捷键展示。
    func bindShortcuts(settings: SettingsStore, scope: LocalShortcutScope = .capture) {
        self.settings = settings
        self.shortcutScope = scope
        refreshShortcutTooltips()
        relayout(to: nil)
    }

    private func refreshShortcutTooltips() {
        guard let settings else { return }
        switch shortcutScope {
        case .capture:
            undoButton?.toolTip = settings.tooltip(L10n.string("撤销"), action: .captureUndo)
            redoButton?.toolTip = settings.tooltip(L10n.string("重做"), action: .captureRedo)
            actionButtons[.pin]?.toolTip = settings.tooltip(L10n.string("钉在屏幕上"), action: .capturePin)
            actionButtons[.save]?.toolTip = settings.tooltip(L10n.string("保存"), action: .captureSave)
            actionButtons[.cancelled]?.toolTip = settings.tooltip(L10n.string("关闭"), action: .captureCancel)
            actionButtons[.copy]?.toolTip = settings.tooltip(L10n.string("复制"), action: .captureCopy)
            actionButtons[.ocr]?.toolTip = L10n.string("OCR 识别")
            actionButtons[.imageOCR]?.toolTip = L10n.string("原图 OCR")
            actionButtons[.translate]?.toolTip = L10n.string("截图翻译")
            actionButtons[.imageTranslate]?.toolTip = L10n.string("原图翻译")
        case .pinnedImage:
            undoButton?.toolTip = settings.tooltip(L10n.string("撤销"), action: .pinUndo)
            redoButton?.toolTip = settings.tooltip(L10n.string("重做"), action: .pinRedo)
            actionButtons[.save]?.toolTip = settings.tooltip(L10n.string("保存"), action: .pinSave)
            actionButtons[.cancelled]?.toolTip = settings.tooltip(L10n.string("关闭"), action: .pinClose)
            actionButtons[.copy]?.toolTip = settings.tooltip(L10n.string("复制"), action: .pinCopy)
            actionButtons[.ocr]?.toolTip = settings.tooltip(L10n.string("OCR 识别"), action: .pinOCR)
            actionButtons[.imageOCR]?.toolTip = L10n.string("原图 OCR")
            actionButtons[.pin]?.toolTip = L10n.string("钉在屏幕上")
            actionButtons[.translate]?.toolTip = L10n.string("截图翻译")
            actionButtons[.imageTranslate]?.toolTip = L10n.string("原图翻译")
        case .ocrResult, .clipboard:
            break
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func fireAction(_ action: SnipAction) {
        NSLog("[SnapFlow] toolbar fire: \(action.rawValue)")
        onAction?(action)
    }

    /// 按内容计算理想尺寸（含左右 padding）
    func preferredSize() -> NSSize {
        let size = computePreferredSize()
        relayout(to: size)
        return size
    }

    func computePreferredSize() -> NSSize {
        let contentWidth: CGFloat
        let contentHeight: CGFloat
        switch presentation {
        case .legacy:
            contentWidth = max(preferredRowWidth(annotationRow), preferredRowWidth(actionRow))
            contentHeight = btnSize * 2 + rowSpacing
        case .captureEditor:
            contentWidth = preferredRowWidth(annotationRow)
            contentHeight = btnSize
        case .captureActions:
            contentWidth = btnSize
            contentHeight = preferredRowHeight(actionRow)
        }
        let width = hPad * 2 + contentWidth
        let height = vPad * 2 + contentHeight
        return NSSize(width: width, height: height)
    }

    private func preferredRowWidth(_ row: NSStackView) -> CGFloat {
        let contentWidth = row.arrangedSubviews.reduce(CGFloat.zero) { result, view in
            result + (view is SnipToolButton ? btnSize : 8)
        }
        return contentWidth + CGFloat(max(row.arrangedSubviews.count - 1, 0)) * itemSpacing
    }

    private func preferredRowHeight(_ row: NSStackView) -> CGFloat {
        let contentHeight = row.arrangedSubviews.reduce(CGFloat.zero) { result, view in
            result + (view is SnipToolButton ? btnSize : 8)
        }
        return contentHeight + CGFloat(max(row.arrangedSubviews.count - 1, 0)) * itemSpacing
    }

    private func relayout(to size: NSSize? = nil) {
        let size = size ?? computePreferredSize()
        setFrameSize(size)
        stack.frame = NSRect(
            x: hPad,
            y: vPad,
            width: max(size.width - hPad * 2, 0),
            height: max(size.height - vPad * 2, 0)
        )
        stack.spacing = rowSpacing
    }

    override func layout() {
        super.layout()
        // frame 被外部设置后，保持内部 stack 左右 padding
        stack.frame = NSRect(
            x: hPad,
            y: vPad,
            width: max(bounds.width - hPad * 2, 0),
            height: max(bounds.height - vPad * 2, btnSize)
        )
        syncHoverAfterLayout()
    }

    override var intrinsicContentSize: NSSize { computePreferredSize() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 把点击分发给具体按钮（不依赖深层 hitTest / imageView）
    override func hitTest(_ point: NSPoint) -> NSView? {
        // point 在 superview 坐标系
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea {
            removeTrackingArea(cursorTrackingArea)
            self.cursorTrackingArea = nil
        }
        // 截图会话里 managesCursor = false，但仍要跟踪移入/移出以立刻显示工具名。
        var options: NSTrackingArea.Options = [
            .activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect,
        ]
        if managesCursor {
            options.insert(.cursorUpdate)
        }
        let area = NSTrackingArea(rect: bounds, options: options, owner: self)
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        if managesCursor {
            updateCursor(with: event)
        }
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard !bounds.contains(local) else { return }
        clearHover()
    }

    override var isHidden: Bool {
        get { super.isHidden }
        set {
            super.isHidden = newValue
            if newValue { clearHover() }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            clearHover()
        }
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
        let overButton = allButtons.contains { button in
            button.bounds.contains(convert(local, to: button))
        }
        return overButton ? .pointingHand : .arrow
    }

    private func button(at local: NSPoint) -> SnipToolButton? {
        allButtons.first { button in
            button.bounds.contains(convert(local, to: button))
        }
    }

    private func updateHover(at local: NSPoint) {
        let hit = button(at: local)
        if hit === hoveredButton {
            hoveredButton?.refreshInstantTooltipPosition()
            return
        }
        hoveredButton?.setHovered(false)
        hoveredButton = hit
        hoveredButton?.setHovered(true)
    }

    private func clearHover() {
        hoveredButton?.setHovered(false)
        hoveredButton = nil
    }

    private func syncHoverAfterLayout() {
        guard let window, !isHidden else {
            clearHover()
            return
        }
        updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        handleClick(event)
    }

    override func mouseUp(with event: NSEvent) {
        // 部分环境下只收到 mouseUp
        // 若 mouseDown 已处理可忽略；为稳妥再试一次命中
    }

    private func handleClick(_ event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        // 转 stack 坐标找按钮
        for btn in allButtons {
            let p = convert(local, to: btn)
            if btn.bounds.contains(p) {
                btn.performClick()
                return
            }
        }
        // 再扫 stack 子视图（含 separator 跳过）
        for case let btn as SnipToolButton in stack.arrangedSubviews {
            let p = convert(local, to: btn)
            if btn.bounds.contains(p) {
                btn.performClick()
                return
            }
        }
        NSLog("[SnapFlow] toolbar click missed at \(local)")
    }

    func setSelectedTool(_ tool: AnnotateTool, notify: Bool = true) {
        // 再点已选中的编辑工具 → 取消，回到拖/拉选区
        if notify, tool != .none, tool != .undo, tool != .redo, selectedTool == tool {
            selectedTool = .none
            for (_, btn) in toolButtons { btn.isSelected = false }
            onSelectTool?(.none)
            return
        }
        selectedTool = tool
        for (t, btn) in toolButtons {
            btn.isSelected = (t == tool && tool != .none)
        }
        if notify {
            onSelectTool?(tool)
        }
    }

    private func makeToolButton(tool: AnnotateTool) -> SnipToolButton {
        // 文字工具用字母「T」样式，其余用 SF Symbol
        if tool == .text {
            return SnipToolButton(titleGlyph: "T", tooltip: tool.title, size: btnSize) { [weak self] in
                self?.setSelectedTool(tool, notify: true)
            }
        }
        return SnipToolButton(symbol: tool.symbolName, tooltip: tool.title, size: btnSize) { [weak self] in
            self?.setSelectedTool(tool, notify: true)
        }
    }

    private func makeActionButton(symbol: String, tooltip: String, action: @escaping () -> Void) -> SnipToolButton {
        let btn = SnipToolButton(symbol: symbol, tooltip: tooltip, size: btnSize, action: action)
        allButtons.append(btn)
        return btn
    }

    private func makeSeparator(isHorizontal: Bool = false) -> NSView {
        let wrapSize = isHorizontal
            ? NSSize(width: btnSize, height: 8)
            : NSSize(width: 8, height: btnSize)
        let wrap = NSView(frame: NSRect(origin: .zero, size: wrapSize))
        wrap.wantsLayer = true
        let lineFrame = isHorizontal
            ? NSRect(x: (btnSize - 14) / 2, y: 3.5, width: 14, height: 1)
            : NSRect(x: 3.5, y: (btnSize - 14) / 2, width: 1, height: 14)
        let line = NSView(frame: lineFrame)
        line.wantsLayer = true
        line.layer?.backgroundColor = AppTheme.nsCaptureSeparator.cgColor
        wrap.addSubview(line)
        wrap.setContentHuggingPriority(.required, for: .horizontal)
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.widthAnchor.constraint(equalToConstant: wrapSize.width).isActive = true
        wrap.heightAnchor.constraint(equalToConstant: wrapSize.height).isActive = true
        return wrap
    }
}

// MARK: - Button

@MainActor
final class SnipToolButton: NSView {
    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let actionBlock: () -> Void
    private var tracking: NSTrackingArea?
    private var isHovered = false
    private var isPressed = false
    private let usesTitleGlyph: Bool
    private var instantTooltipText = ""
    var isSelected = false {
        didSet { updateAppearance() }
    }
    /// 可选右键菜单（例如麦克风输入设备选择）。
    var contextMenuProvider: (() -> NSMenu)?

    init(symbol: String, tooltip: String, size: CGFloat = 32, action: @escaping () -> Void) {
        self.actionBlock = action
        self.usesTitleGlyph = false
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        commonInit(size: size, tooltip: tooltip)

        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config)
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.translatesAutoresizingMaskIntoConstraints = false
        let icon: CGFloat = 16
        imageView.isHidden = false
        titleLabel.isHidden = true
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            // SF Symbol 的字形包围盒视觉上略偏上，向下 1pt 才与按钮中心对齐。
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            imageView.widthAnchor.constraint(equalToConstant: icon),
            imageView.heightAnchor.constraint(equalToConstant: icon),
        ])
        updateAppearance()
    }

    private var titleGlyph: String = ""

    /// 字母图标（如文字工具「T」）—— 自行绘制以垂直居中
    init(titleGlyph: String, tooltip: String, size: CGFloat = 32, action: @escaping () -> Void) {
        self.actionBlock = action
        self.usesTitleGlyph = true
        self.titleGlyph = titleGlyph
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        commonInit(size: size, tooltip: tooltip)
        imageView.isHidden = true
        titleLabel.isHidden = true
        updateAppearance()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard usesTitleGlyph, !titleGlyph.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: 16, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: glyphColor,
        ]
        let str = titleGlyph as NSString
        let sz = str.size(withAttributes: attrs)
        // 视觉垂直居中：系统字体 bounding box 偏上，略向下修正
        let origin = NSPoint(
            x: (bounds.width - sz.width) / 2,
            y: (bounds.height - sz.height) / 2 - 0.5
        )
        str.draw(at: origin, withAttributes: attrs)
    }

    private var glyphColor: NSColor = AppTheme.nsCaptureText

    private func commonInit(size: CGFloat, tooltip: String) {
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.masksToBounds = true
        toolTip = tooltip
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 整颗按钮自己吃掉命中，避免点到 imageView
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    func performClick() {
        isPressed = true
        updateAppearance()
        actionBlock()
        DispatchQueue.main.async { [weak self] in
            self?.isPressed = false
            self?.updateAppearance()
        }
    }

    func setSymbol(_ symbol: String, accessibilityDescription: String? = nil) {
        guard !usesTitleGlyph else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        imageView.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: accessibilityDescription
        )?.withSymbolConfiguration(config)
        updateAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override var toolTip: String? {
        get { nil }
        set {
            instantTooltipText = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            super.toolTip = nil
            setAccessibilityLabel(instantTooltipText)
            if isHovered {
                InstantToolbarTooltip.show(instantTooltipText, from: self)
            }
        }
    }

    func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else {
            if hovered {
                InstantToolbarTooltip.reposition(from: self)
            }
            return
        }
        isHovered = hovered
        if !hovered {
            isPressed = false
        }
        updateAppearance()
        if hovered {
            InstantToolbarTooltip.show(instantTooltipText, from: self)
        } else {
            InstantToolbarTooltip.hide(from: self)
        }
    }

    func refreshInstantTooltipPosition() {
        guard isHovered else { return }
        InstantToolbarTooltip.reposition(from: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            setHovered(false)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        // 嵌在 SnipToolbarView 里时由父视图统一驱动，避免与吞掉 hitTest 的跟踪区打架。
        guard enclosingToolbar == nil else { return }
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard enclosingToolbar == nil else { return }
        setHovered(false)
    }

    private var enclosingToolbar: SnipToolbarView? {
        var current = superview
        while let view = current {
            if let toolbar = view as? SnipToolbarView {
                return toolbar
            }
            current = view.superview
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        updateAppearance()
        performClick()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenuProvider?() else {
            super.rightMouseDown(with: event)
            return
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height), in: self)
    }

    private func updateAppearance() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let fg: NSColor
        if isPressed {
            layer?.backgroundColor = AppTheme.nsCapturePressed.cgColor
            fg = .white
        } else if isSelected {
            layer?.backgroundColor = NSColor(calibratedRed: 0.35, green: 0.62, blue: 1.0, alpha: 0.45).cgColor
            fg = .white
        } else if isHovered {
            layer?.backgroundColor = AppTheme.nsCaptureHover.cgColor
            fg = .white
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            fg = AppTheme.nsCaptureText
        }
        glyphColor = fg
        if usesTitleGlyph {
            needsDisplay = true
        } else {
            imageView.contentTintColor = fg
        }
        CATransaction.commit()
    }
}

// MARK: - Instant tooltip

/// 移入立刻显示、移出立刻消失。不用系统 `toolTip`：系统提示有延迟，且父视图吞掉 hitTest 后不会出现。
@MainActor
enum InstantToolbarTooltip {
    private static let tip = InstantToolbarTooltipView()
    private static weak var owner: NSView?

    static func show(_ text: String, from source: NSView) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            hide(from: source)
            return
        }
        owner = source
        tip.show(trimmed, from: source)
    }

    static func hide(from source: NSView) {
        guard owner == nil || owner === source else { return }
        owner = nil
        tip.hide()
    }

    static func reposition(from source: NSView) {
        guard owner === source else { return }
        tip.reposition(from: source)
    }
}

@MainActor
private final class InstantToolbarTooltipView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let padH: CGFloat = 7
    private let padV: CGFloat = 4
    private let gap: CGFloat = 6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.masksToBounds = true
        layer?.backgroundColor = SnipStyle.helpBG.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ text: String, from source: NSView) {
        label.stringValue = text
        label.sizeToFit()
        let size = NSSize(
            width: ceil(label.bounds.width) + padH * 2,
            height: ceil(label.bounds.height) + padV * 2
        )
        label.frame = NSRect(
            x: padH,
            y: padV,
            width: size.width - padH * 2,
            height: size.height - padV * 2
        )
        setFrameSize(size)
        reposition(from: source)
        isHidden = false
    }

    func hide() {
        isHidden = true
        removeFromSuperview()
    }

    func reposition(from source: NSView) {
        guard let host = source.window?.contentView else {
            hide()
            return
        }
        if superview !== host {
            host.addSubview(self, positioned: .above, relativeTo: nil)
        }

        let sourceInHost = convertSourceFrame(source, to: host)
        let preferSide = (source.superview as? NSStackView)?.orientation == .vertical
        var origin: NSPoint
        if preferSide {
            origin = NSPoint(
                x: sourceInHost.minX - gap - bounds.width,
                y: sourceInHost.midY - bounds.height / 2
            )
            if origin.x < host.bounds.minX + 2 {
                origin.x = sourceInHost.maxX + gap
            }
        } else {
            origin = NSPoint(
                x: sourceInHost.midX - bounds.width / 2,
                y: sourceInHost.minY - gap - bounds.height
            )
            if origin.y < host.bounds.minY + 2 {
                origin.y = sourceInHost.maxY + gap
            }
        }
        origin.x = min(max(origin.x, host.bounds.minX + 2), max(host.bounds.maxX - bounds.width - 2, host.bounds.minX + 2))
        origin.y = min(max(origin.y, host.bounds.minY + 2), max(host.bounds.maxY - bounds.height - 2, host.bounds.minY + 2))
        setFrameOrigin(origin)
        host.addSubview(self, positioned: .above, relativeTo: nil)
    }

    private func convertSourceFrame(_ source: NSView, to host: NSView) -> NSRect {
        let sourceInWindow = source.convert(source.bounds, to: nil)
        guard let sourceWindow = source.window, let hostWindow = host.window else {
            return host.convert(sourceInWindow, from: nil)
        }
        if sourceWindow === hostWindow {
            return host.convert(sourceInWindow, from: nil)
        }
        let screenRect = sourceWindow.convertToScreen(sourceInWindow)
        let hostWindowRect = hostWindow.convertFromScreen(screenRect)
        return host.convert(hostWindowRect, from: nil)
    }
}
