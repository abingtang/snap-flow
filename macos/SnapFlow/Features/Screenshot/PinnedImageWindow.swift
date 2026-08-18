import AppKit
import UniformTypeIdentifiers

/// Snipaste 风格贴图窗口：
/// - 拖拽移动、置顶
/// - 滚轮缩放 / Ctrl+滚轮透明度
/// - 1/2 旋转、3/4 翻转、中键重置
/// - 右键：复制 / 保存 / OCR / 关闭 / 阴影开关
/// - 外观：无描边，可选蓝色半透明外阴影（AppKit 绘制，避免透明窗 CALayer 阴影失效）
@MainActor
final class PinnedImageWindow: NSPanel {
    enum DragPhase { case began, changed, ended }

    /// 外阴影留白，保证光晕落在窗口内
    private static let glowPadding: CGFloat = 22

    private var sourceImage: NSImage
    private let settings: SettingsStore
    private let onOCR: (() -> Void)?
    private let onTranslate: ((NSImage) -> Void)?
    private let onImageTranslate: ((NSImage) -> Void)?
    private let onFavorite: ((NSImage) -> Void)?
    private var dragStartMouse: NSPoint = .zero
    private var dragStartOrigin: NSPoint = .zero
    private var isDragging = false

    private var baseSize: NSSize
    private var scaleFactor: CGFloat = 1
    private var opacity: CGFloat = 1
    private var rotationQuarter: Int = 0 // 0..3 * 90°
    private var flipH = false
    private var flipV = false
    private(set) var isClickThrough = false
    /// 是否显示蓝色外阴影（默认开；右键菜单可关）
    private(set) var isShadowEnabled = true

    private weak var contentImageView: PinnedImageContentView?
    private var editorCanvas: AnnotationCanvasView?
    private var editorToolbarPanel: NSPanel?
    private var editorActionToolbarPanel: NSPanel?
    private var editorOptionsPanel: NSPanel?
    private var editorOptionsBar: AnnotateOptionsBar?
    private var currentEditorTool: AnnotateTool = .none
    private(set) var isEditingAnnotations = false

    private var currentGlowPadding: CGFloat {
        isShadowEnabled ? Self.glowPadding : 0
    }

    init(
        image: NSImage,
        screenRect: CGRect?,
        settings: SettingsStore,
        onOCR: (() -> Void)? = nil,
        onTranslate: ((NSImage) -> Void)? = nil,
        onImageTranslate: ((NSImage) -> Void)? = nil,
        onFavorite: ((NSImage) -> Void)? = nil
    ) {
        self.sourceImage = image
        self.settings = settings
        self.onOCR = onOCR
        self.onTranslate = onTranslate
        self.onImageTranslate = onImageTranslate
        self.onFavorite = onFavorite
        self.baseSize = Self.displaySize(for: image)

        let pad = Self.glowPadding
        let windowSize = NSSize(
            width: baseSize.width + pad * 2,
            height: baseSize.height + pad * 2
        )
        let contentRect = Self.initialContentRect(
            windowSize: windowSize,
            screenRect: screenRect,
            padding: pad
        )

        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        // 关闭系统灰阴影；蓝色光晕由 contentView 自绘
        hasShadow = false
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = false
        acceptsMouseMovedEvents = true
        alphaValue = 1

        let view = PinnedImageContentView(image: image, glowPadding: pad)
        view.shadowEnabled = true
        view.onRightClick = { [weak self] location in
            self?.showContextMenu(at: location)
        }
        view.onDoubleClick = { [weak self] in
            self?.closePin()
        }
        view.onDrag = { [weak self] phase, screenPoint in
            self?.handleDrag(phase: phase, screenPoint: screenPoint)
        }
        view.onScroll = { [weak self] event in
            self?.handleScroll(event)
        }
        contentView = view
        contentImageView = view

        if screenRect == nil {
            center()
        }
    }

    /// 保留 API，贴图上不再显示就地状态条（复制/钉图反馈改由右键菜单与系统行为体现）
    func showStatus(_ message: String, duration: TimeInterval = 1.6) {
        // intentionally empty
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func present() {
        AppActivation.focus(self)
    }

    // MARK: - Transform

    private func applyTransform() {
        var img = sourceImage
        // flip
        if flipH || flipV {
            img = Self.flipped(img, horizontal: flipH, vertical: flipV)
        }
        // rotation
        if rotationQuarter % 4 != 0 {
            img = Self.rotated(img, quarters: rotationQuarter % 4)
        }
        contentImageView?.setImage(img)

        let aspect = img.size
        let w = max(baseSize.width * scaleFactor, 24)
        let h = w * (aspect.height / max(aspect.width, 1))
        applyWindowFrame(imageWidth: w, imageHeight: h)
        alphaValue = opacity
        positionEditorPanels()
    }

    /// 按图片逻辑尺寸 + 当前阴影留白同步窗口与内容布局
    private func applyWindowFrame(imageWidth: CGFloat, imageHeight: CGFloat) {
        let pad = currentGlowPadding
        contentImageView?.glowPadding = pad
        contentImageView?.shadowEnabled = isShadowEnabled
        let winW = imageWidth + pad * 2
        let winH = imageHeight + pad * 2
        var f = frame
        let cx = f.midX
        let cy = f.midY
        f.size = NSSize(width: winW, height: winH)
        f.origin = NSPoint(x: cx - winW / 2, y: cy - winH / 2)
        setFrame(f, display: true)
        contentImageView?.needsDisplay = true
    }

    private func currentImageDisplaySize() -> NSSize {
        var img = sourceImage
        if flipH || flipV {
            img = Self.flipped(img, horizontal: flipH, vertical: flipV)
        }
        if rotationQuarter % 4 != 0 {
            img = Self.rotated(img, quarters: rotationQuarter % 4)
        }
        let aspect = img.size
        let w = max(baseSize.width * scaleFactor, 24)
        let h = w * (aspect.height / max(aspect.width, 1))
        return NSSize(width: w, height: h)
    }

    private func handleScroll(_ event: NSEvent) {
        let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
        guard abs(delta) > 0.01 else { return }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            // 透明度：按滚动量微调，避免一格跳太大
            let step: CGFloat
            if event.hasPreciseScrollingDeltas {
                step = delta * 0.002
            } else {
                step = (delta > 0 ? 1 : -1) * 0.03
            }
            opacity = min(1, max(0.15, opacity + step))
            alphaValue = opacity
        } else {
            // 缩放：按滚动量比例调整。
            // 原先每次事件固定 ×1.08，触控板/高精度滚轮一次滑动会连发多次 → 幅度过大。
            let unit: CGFloat
            if event.hasPreciseScrollingDeltas {
                // 约 50 像素 ≈ 一档；单事件封顶 ±2 档，防止甩一下暴冲
                unit = max(-2, min(2, delta / 50))
            } else {
                // 经典滚轮：通常每格 ±1，限制最大步数
                unit = max(-2, min(2, delta))
            }
            // 每档约 3%（pow(1.03, unit)）
            let factor = pow(1.03 as CGFloat, unit)
            scaleFactor = min(8, max(0.15, scaleFactor * factor))
            applyTransform()
        }
    }

    private func handleDrag(phase: DragPhase, screenPoint: NSPoint) {
        switch phase {
        case .began:
            isDragging = true
            dragStartMouse = screenPoint
            dragStartOrigin = frame.origin
        case .changed:
            guard isDragging else { return }
            let dx = screenPoint.x - dragStartMouse.x
            let dy = screenPoint.y - dragStartMouse.y
            setFrameOrigin(NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy))
            positionEditorPanels()
        case .ended:
            isDragging = false
        }
    }

    private func resetVisual() {
        scaleFactor = 1
        opacity = 1
        rotationQuarter = 0
        flipH = false
        flipV = false
        applyTransform()
    }

    // MARK: - Menu

    private func showContextMenu(at locationInWindow: NSPoint) {
        let menu = NSMenu()
        menu.addItem(
            withTitle: isEditingAnnotations ? L10n.string("完成标注") : L10n.string("打开标注工具栏"),
            action: #selector(toggleEditor),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.string("复制"), action: #selector(copyImage), keyEquivalent: "")
        menu.addItem(withTitle: L10n.string("保存…"), action: #selector(saveImage), keyEquivalent: "")
        if onFavorite != nil {
            menu.addItem(withTitle: L10n.string("添加到收藏"), action: #selector(addToFavorites), keyEquivalent: "")
        }
        if onOCR != nil {
            menu.addItem(withTitle: L10n.string("识别文字"), action: #selector(runOCR), keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.string("旋转 90°"), action: #selector(rotateCW), keyEquivalent: "")
        menu.addItem(withTitle: L10n.string("水平翻转"), action: #selector(flipHorizontal), keyEquivalent: "")
        menu.addItem(withTitle: L10n.string("重置大小/透明度"), action: #selector(resetAll), keyEquivalent: "")
        let shadowItem = NSMenuItem(
            title: isShadowEnabled ? L10n.string("隐藏阴影") : L10n.string("显示阴影"),
            action: #selector(toggleShadow),
            keyEquivalent: ""
        )
        menu.addItem(shadowItem)
        let through = NSMenuItem(
            title: isClickThrough ? L10n.string("关闭鼠标穿透") : L10n.string("开启鼠标穿透"),
            action: #selector(toggleClickThrough),
            keyEquivalent: ""
        )
        menu.addItem(through)
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.string("关闭"), action: #selector(closePin), keyEquivalent: "")
        for item in menu.items { item.target = self }
        menu.popUp(positioning: nil, at: locationInWindow, in: contentView)
    }

    @objc private func copyImage() {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let img = contentImageView?.currentImage {
            pb.writeObjects([img])
        } else {
            pb.writeObjects([sourceImage])
        }
    }

    @objc private func saveImage() {
        let quality = settings.snipImageQuality
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = SnipImageExport.defaultFileName(quality: quality)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let img = contentImageView?.currentImage ?? sourceImage
        do {
            _ = try SnipImageExport.write(img, quality: quality, to: url)
        } catch {
            // 保存失败：静默（贴图上已去掉状态条；右键仍可重试）
        }
    }

    @objc private func runOCR() { onOCR?() }

    @objc private func addToFavorites() {
        let img = contentImageView?.currentImage ?? sourceImage
        onFavorite?(img)
        // 无 Toast：收藏列表与菜单再次打开即可确认
    }

    @objc private func closePin() {
        closeEditorPanels()
        orderOut(nil)
        close()
    }
    @objc private func rotateCW() { rotationQuarter = (rotationQuarter + 1) % 4; applyTransform() }
    @objc private func flipHorizontal() { flipH.toggle(); applyTransform() }
    @objc func resetAll() { resetVisual() }
    @objc private func toggleClickThrough() {
        setClickThrough(!isClickThrough)
    }
    @objc private func toggleShadow() {
        setShadowEnabled(!isShadowEnabled)
    }
    @objc private func toggleEditor() {
        isEditingAnnotations ? finishEditing(commit: true) : beginEditing()
    }

    /// 鼠标穿透：点击落到下层窗口
    func setClickThrough(_ on: Bool) {
        isClickThrough = on
        ignoresMouseEvents = on
        // 穿透时略降透明度作提示
        alphaValue = on ? min(opacity, 0.65) : opacity
    }

    /// 开关蓝色外阴影；开关时按当前图片尺寸重算窗口留白
    func setShadowEnabled(_ on: Bool) {
        guard isShadowEnabled != on else { return }
        isShadowEnabled = on
        let size = currentImageDisplaySize()
        applyWindowFrame(imageWidth: size.width, imageHeight: size.height)
        positionEditorPanels()
    }

    override func keyDown(with event: NSEvent) {
        if settings.matches(.pinToggleEditor, event: event) { toggleEditor(); return }
        if settings.matches(.pinClose, event: event) {
            if editorCanvas == nil { closePin() } else { finishEditing(commit: true) }
            return
        }
        if settings.matches(.pinCopy, event: event) {
            if editorCanvas != nil { finishEditing(commit: true) }
            copyImage()
            return
        }
        if settings.matches(.pinSave, event: event) {
            if editorCanvas != nil { finishEditing(commit: true) }
            saveImage()
            return
        }
        if settings.matches(.pinOCR, event: event) {
            if editorCanvas != nil { finishEditing(commit: true) }
            runOCR()
            return
        }
        if let editorCanvas {
            if settings.matches(.pinUndo, event: event) { editorCanvas.undo(); return }
            if settings.matches(.pinRedo, event: event) { editorCanvas.redo(); return }
            if settings.matches(.pinClearAnnotations, event: event) { editorCanvas.clearAll(); return }
            super.keyDown(with: event)
            return
        }
        if settings.matches(.pinOpacityUp, event: event) {
            opacity = min(1, opacity + 0.05)
            alphaValue = opacity
            return
        }
        if settings.matches(.pinOpacityDown, event: event) {
            opacity = max(0.15, opacity - 0.05)
            alphaValue = opacity
            return
        }
        if settings.matches(.pinRotateClockwise, event: event) {
            rotationQuarter = (rotationQuarter + 1) % 4
            applyTransform()
            return
        }
        if settings.matches(.pinRotateCounterclockwise, event: event) {
            rotationQuarter = (rotationQuarter + 3) % 4
            applyTransform()
            return
        }
        if settings.matches(.pinFlipHorizontal, event: event) {
            flipH.toggle()
            applyTransform()
            return
        }
        if settings.matches(.pinFlipVertical, event: event) {
            flipV.toggle()
            applyTransform()
            return
        }
        if settings.matches(.pinZoomIn, event: event) {
            scaleFactor = min(8, scaleFactor * 1.1)
            applyTransform()
            return
        }
        if settings.matches(.pinZoomOut, event: event) {
            scaleFactor = max(0.15, scaleFactor / 1.1)
            applyTransform()
            return
        }
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard editorCanvas == nil else { return }
        handleScroll(event)
    }

    // MARK: - Secondary annotation

    private func beginEditing() {
        guard editorCanvas == nil,
              let contentImageView,
              let image = contentImageView.currentImage
        else { return }

        if isClickThrough { setClickThrough(false) }

        // 标注画布仅覆盖图片区域，不含外阴影留白
        let canvas = AnnotationCanvasView(frame: contentImageView.imageContentFrame)
        canvas.baseImage = image
        canvas.autoresizingMask = [.width, .height]
        canvas.tool = .none
        canvas.onIdleMouseEvent = { [weak contentImageView] event in
            switch event.type {
            case .leftMouseDown:
                contentImageView?.mouseDown(with: event)
            case .leftMouseDragged:
                contentImageView?.mouseDragged(with: event)
            case .leftMouseUp:
                contentImageView?.mouseUp(with: event)
            default:
                break
            }
        }
        contentImageView.editorActive = true
        contentImageView.addSubview(canvas)
        editorCanvas = canvas
        isEditingAnnotations = true

        let toolbar = SnipToolbarView(presentation: .captureEditor)
        toolbar.onSelectTool = { [weak self] tool in self?.selectEditorTool(tool) }
        toolbar.onAction = { [weak self] action in self?.handleEditorAction(action) }
        toolbar.bindShortcuts(settings: settings, scope: .pinnedImage)
        let toolbarSize = toolbar.preferredSize()
        editorToolbarPanel = makeEditorPanel(size: toolbarSize, content: toolbar)

        let actionToolbar = SnipToolbarView(
            presentation: .captureActions,
            showsRecordingAction: false
        )
        actionToolbar.onAction = { [weak self] action in self?.handleEditorAction(action) }
        actionToolbar.bindShortcuts(settings: settings, scope: .pinnedImage)
        let actionToolbarSize = actionToolbar.preferredSize()
        editorActionToolbarPanel = makeEditorPanel(size: actionToolbarSize, content: actionToolbar)

        let options = AnnotateOptionsBar()
        options.isHidden = true
        options.onChange = { [weak canvas] style in canvas?.apply(options: style) }
        options.colorPanelScreenAnchor = { [weak self] in self?.frame }
        editorOptionsBar = options
        editorOptionsPanel = makeEditorPanel(size: NSSize(width: 1, height: 1), content: options)
        editorOptionsPanel?.orderOut(nil)

        positionEditorPanels()
        editorToolbarPanel?.orderFrontRegardless()
        editorActionToolbarPanel?.orderFrontRegardless()
        makeKey()
        makeFirstResponder(canvas)
    }

    private func selectEditorTool(_ tool: AnnotateTool) {
        guard let editorCanvas, let editorOptionsBar else { return }
        switch tool {
        case .undo:
            editorCanvas.undo()
            return
        case .redo:
            editorCanvas.redo()
            return
        default:
            break
        }

        currentEditorTool = tool
        editorCanvas.tool = tool
        guard tool != .none, tool.isDrawable else {
            editorOptionsPanel?.orderOut(nil)
            return
        }
        editorOptionsBar.show(for: tool)
        editorCanvas.apply(options: editorOptionsBar.style)
        let size = editorOptionsBar.preferredSize()
        editorOptionsPanel?.setContentSize(size)
        positionEditorPanels()
        editorOptionsPanel?.orderFrontRegardless()
        makeKey()
        makeFirstResponder(editorCanvas)
    }

    private func handleEditorAction(_ action: SnipAction) {
        switch action {
        case .cancelled:
            finishEditing(commit: true)
        case .copy:
            finishEditing(commit: true)
            copyImage()
        case .save:
            finishEditing(commit: true)
            saveImage()
        case .ocr:
            finishEditing(commit: true)
            runOCR()
        case .imageOCR:
            // 贴图无稳定选区叠层时：回退到结果窗 OCR
            finishEditing(commit: true)
            runOCR()
        case .translate:
            finishEditing(commit: true)
            onTranslate?(sourceImage)
        case .imageTranslate:
            finishEditing(commit: true)
            onImageTranslate?(sourceImage)
        case .pin, .confirm, .record, .quickSave, .scrollCapture:
            finishEditing(commit: true)
        }
    }

    private func finishEditing(commit: Bool) {
        if commit, let composed = editorCanvas?.compositeImage() {
            sourceImage = composed
            // baseSize 为图片逻辑尺寸，不含外阴影留白
            let pad = currentGlowPadding
            baseSize = NSSize(
                width: max(frame.width - pad * 2, 24),
                height: max(frame.height - pad * 2, 24)
            )
            scaleFactor = 1
            rotationQuarter = 0
            flipH = false
            flipV = false
            contentImageView?.setImage(composed)
        }
        editorCanvas?.removeFromSuperview()
        editorCanvas = nil
        isEditingAnnotations = false
        contentImageView?.editorActive = false
        currentEditorTool = .none
        closeEditorPanels()
        makeKey()
        makeFirstResponder(contentImageView)
    }

    private func makeEditorPanel(size: NSSize, content: NSView) -> NSPanel {
        let panel = PinnedEditorPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.contentView = content
        addChildWindow(panel, ordered: .above)
        return panel
    }

    private func positionEditorPanels() {
        guard let toolbarPanel = editorToolbarPanel else { return }
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
        // 相对「图片内容区」定位：底部工具栏右下角对齐（扣掉阴影留白）
        let pad = currentGlowPadding
        let imageMaxX = frame.maxX - pad
        let imageMinY = frame.minY + pad
        let gap: CGFloat = 4

        let toolbarFitsBelow = imageMinY - toolbarPanel.frame.height - gap >= visible.minY
        // 右下角：右缘贴图片内容右缘
        var toolbarOrigin = NSPoint(
            x: imageMaxX - toolbarPanel.frame.width,
            y: imageMinY - toolbarPanel.frame.height - gap
        )
        if !toolbarFitsBelow {
            // 贴在图片内容底边内侧
            toolbarOrigin.y = imageMinY + gap
        }
        toolbarOrigin.x = min(
            max(visible.minX + 8, toolbarOrigin.x),
            visible.maxX - toolbarPanel.frame.width - 8
        )
        toolbarPanel.setFrameOrigin(toolbarOrigin)

        if let actionPanel = editorActionToolbarPanel {
            let actionOutsideX = imageMaxX + gap
            let actionFitsOutside = actionOutsideX + actionPanel.frame.width <= visible.maxX - 8
            var actionOrigin = NSPoint(
                x: actionFitsOutside
                    ? actionOutsideX
                    : imageMaxX - actionPanel.frame.width - gap,
                y: imageMinY
            )
            if !toolbarFitsBelow {
                // 贴近屏幕底部时，横向编辑栏在下，竖向动作栏置于其上。
                toolbarOrigin.y = imageMinY + gap
                toolbarPanel.setFrameOrigin(toolbarOrigin)
                actionOrigin.y = toolbarPanel.frame.maxY + 4
            }
            actionOrigin.x = min(
                max(visible.minX + 8, actionOrigin.x),
                visible.maxX - actionPanel.frame.width - 8
            )
            actionOrigin.y = min(
                max(visible.minY + 8, actionOrigin.y),
                visible.maxY - actionPanel.frame.height - 8
            )
            actionPanel.setFrameOrigin(actionOrigin)
        }

        if let optionsPanel = editorOptionsPanel, currentEditorTool != .none {
            // 选项条与底部工具栏同右缘对齐
            var optionsOrigin = NSPoint(
                x: toolbarOrigin.x + toolbarPanel.frame.width - optionsPanel.frame.width,
                y: toolbarOrigin.y - optionsPanel.frame.height - 4
            )
            if optionsOrigin.y < visible.minY {
                optionsOrigin.y = toolbarPanel.frame.maxY + 4
            }
            optionsOrigin.x = min(
                max(visible.minX + 8, optionsOrigin.x),
                visible.maxX - optionsPanel.frame.width - 8
            )
            optionsPanel.setFrameOrigin(optionsOrigin)

            if !toolbarFitsBelow, let actionPanel = editorActionToolbarPanel {
                var actionOrigin = actionPanel.frame.origin
                actionOrigin.y = optionsPanel.frame.maxY + 4
                actionOrigin.y = min(
                    max(visible.minY + 8, actionOrigin.y),
                    visible.maxY - actionPanel.frame.height - 8
                )
                actionPanel.setFrameOrigin(actionOrigin)
            }
        }
    }

    private func closeEditorPanels() {
        for panel in [editorToolbarPanel, editorActionToolbarPanel, editorOptionsPanel].compactMap({ $0 }) {
            removeChildWindow(panel)
            panel.orderOut(nil)
            panel.close()
        }
        editorToolbarPanel = nil
        editorActionToolbarPanel = nil
        editorOptionsPanel = nil
        editorOptionsBar = nil
    }

    // MARK: - Image ops

    /// 以原选区所在显示器为目标，将贴图初始位置限制在可见区域内。
    ///
    /// 滚动截图的 `screenRect` 代表整张长图，底部坐标可能已经落到屏幕之外；
    /// 它仍然需要保留给 OCR / 翻译等区域元数据，但不能直接作为窗口原点。
    private static func initialContentRect(
        windowSize: NSSize,
        screenRect: CGRect?,
        padding: CGFloat
    ) -> NSRect {
        guard let screenRect, screenRect.width > 2, screenRect.height > 2 else {
            return NSRect(origin: .zero, size: windowSize)
        }

        var rect = NSRect(
            x: screenRect.origin.x - padding,
            y: screenRect.origin.y - padding,
            width: windowSize.width,
            height: windowSize.height
        )

        // 长图的底部可能在屏幕外，用长图顶部附近的点找回原始显示器。
        let anchor = NSPoint(x: screenRect.midX, y: screenRect.maxY - 1)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) })
            ?? NSScreen.screens.first(where: { $0.frame.intersects(screenRect) })
            ?? NSScreen.main
        guard let screen else { return rect }

        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        if rect.width <= visible.width {
            rect.origin.x = min(
                max(rect.origin.x, visible.minX),
                visible.maxX - rect.width
            )
        } else {
            rect.origin.x = visible.minX
        }
        if rect.height <= visible.height {
            rect.origin.y = min(
                max(rect.origin.y, visible.minY),
                visible.maxY - rect.height
            )
        } else {
            // 窗口可能比可见区域高，至少保证长图底部可见、可拖拽。
            rect.origin.y = visible.minY
        }
        return rect
    }

    private static func displaySize(for image: NSImage) -> NSSize {
        let s = image.size
        let maxSide: CGFloat = 900
        if s.width <= maxSide, s.height <= maxSide { return s }
        let scale = min(maxSide / max(s.width, 1), maxSide / max(s.height, 1))
        return NSSize(width: s.width * scale, height: s.height * scale)
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private static func rotated(_ image: NSImage, quarters: Int) -> NSImage {
        let q = ((quarters % 4) + 4) % 4
        if q == 0 { return image }
        let size = image.size
        let newSize = (q % 2 == 0) ? size : NSSize(width: size.height, height: size.width)
        let out = NSImage(size: newSize)
        out.lockFocus()
        let transform = NSAffineTransform()
        transform.translateX(by: newSize.width / 2, yBy: newSize.height / 2)
        transform.rotate(byDegrees: CGFloat(q) * -90)
        transform.translateX(by: -size.width / 2, yBy: -size.height / 2)
        transform.concat()
        image.draw(at: .zero, from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }

    private static func flipped(_ image: NSImage, horizontal: Bool, vertical: Bool) -> NSImage {
        let size = image.size
        let out = NSImage(size: size)
        out.lockFocus()
        let t = NSAffineTransform()
        t.translateX(by: horizontal ? size.width : 0, yBy: vertical ? size.height : 0)
        t.scaleX(by: horizontal ? -1 : 1, yBy: vertical ? -1 : 1)
        t.concat()
        image.draw(at: .zero, from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }
}

// MARK: - Content

@MainActor
private final class PinnedEditorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class PinnedImageContentView: NSView {
    var onRightClick: ((NSPoint) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onDrag: ((PinnedImageWindow.DragPhase, NSPoint) -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    var editorActive = false

    /// 阴影留白（与窗口同步；关阴影时为 0）
    var glowPadding: CGFloat {
        didSet {
            if oldValue != glowPadding {
                needsLayout = true
                needsDisplay = true
            }
        }
    }

    var shadowEnabled = true {
        didSet {
            if oldValue != shadowEnabled {
                needsDisplay = true
            }
        }
    }

    private let imageView = NSImageView()
    private(set) var currentImage: NSImage?

    /// 图片内容区（相对本视图，已扣除外阴影留白）
    var imageContentFrame: NSRect {
        let pad = max(glowPadding, 0)
        return bounds.insetBy(dx: pad, dy: pad)
    }

    init(image: NSImage, glowPadding: CGFloat) {
        self.glowPadding = glowPadding
        super.init(frame: .zero)
        currentImage = image
        // 关闭 layer-backed：在透明 NSPanel 上用 draw + NSShadow 更稳定
        wantsLayer = false

        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = false
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ image: NSImage) {
        currentImage = image
        imageView.image = image
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // 先画外阴影光晕，再由 imageView 盖住中间
        guard shadowEnabled, glowPadding > 0.5 else { return }
        let content = imageContentFrame
        guard content.width > 1, content.height > 1 else { return }

        let glowColor = NSColor(calibratedRed: 0.22, green: 0.52, blue: 1.0, alpha: 1)

        // 1) NSShadow：主光晕（透明窗上比 CALayer shadow 可靠）
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = glowColor.withAlphaComponent(0.72)
        shadow.shadowBlurRadius = min(glowPadding * 0.85, 18)
        shadow.shadowOffset = .zero
        shadow.set()
        // 投射体：略带蓝色的半透明填充，会被图片盖住，只露出外围模糊
        glowColor.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: content, xRadius: 1.5, yRadius: 1.5).fill()
        NSGraphicsContext.restoreGraphicsState()

        // 2) 多层外扩柔环：补足阴影在浅色背景上的可见度
        let rings = 8
        for i in 1...rings {
            let t = CGFloat(i) / CGFloat(rings)
            let expand = glowPadding * t
            let alpha = 0.16 * (1 - t) * (1 - t)
            let rect = content.insetBy(dx: -expand, dy: -expand)
            glowColor.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2 + expand * 0.08, yRadius: 2 + expand * 0.08).fill()
        }
    }

    override func layout() {
        super.layout()
        imageView.frame = imageContentFrame
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if editorActive {
            return super.hitTest(point)
        }
        let local = convert(point, from: superview)
        // 仅图片区域可交互；外阴影留白穿透到下层
        guard imageContentFrame.contains(local) else { return nil }
        return self
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?()
            return
        }
        let screen = event.window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
        onDrag?(.began, screen)
    }

    override func mouseDragged(with event: NSEvent) {
        let screen = event.window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
        onDrag?(.changed, screen)
    }

    override func mouseUp(with event: NSEvent) {
        let screen = event.window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
        onDrag?(.ended, screen)
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            (window as? PinnedImageWindow)?.resetAll()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
    }
}
