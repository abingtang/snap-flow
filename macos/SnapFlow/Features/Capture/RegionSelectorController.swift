import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Snipaste 风格截图会话。
///
/// 卡死根因（已修）：
/// 1. 每次 mouseMoved 全屏 `NSImage.draw` + 放大镜裁剪 + 像素取色 → 主线程堵死
/// 2. 冻结屏幕无超时 → ScreenCaptureKit 挂起时永久卡住
/// 3. 工具栏被父视图抢事件
@MainActor
enum RegionSelectorController {
    private static var activeSession: RegionSelectorSession?

    static func forceCancel() {
        // 先停看门狗标记，避免强制退出循环；再拆会话
        MainThreadWatchdog.shared.endCaptureSession()
        activeSession?.cancel()
        activeSession = nil
    }

    /// 滚动截屏时保留选区窗口作为透明遮罩，让滚轮事件穿透到底层页面。
    static func setSnipWindowsPassThroughForScroll(_ enabled: Bool) {
        activeSession?.setWindowsPassThroughForScroll(enabled)
    }

    static var isActive: Bool { activeSession != nil }

    static func snip(
        settings: SettingsStore,
        purpose: SnipPurpose = .annotate
    ) async -> SnipResult? {
        if activeSession != nil {
            forceCancel()
            try? await Task.sleep(for: .milliseconds(80))
        }

        // 会话一开始就开看门狗（含冻屏等待阶段），不要等窗口创建完
        MainThreadWatchdog.shared.beginCaptureSession()

        return await withCheckedContinuation { continuation in
            var resumed = false
            let session = RegionSelectorSession(settings: settings, purpose: purpose) { result in
                guard !resumed else { return }
                resumed = true
                activeSession = nil
                MainThreadWatchdog.shared.endCaptureSession()
                continuation.resume(returning: result)
            }
            activeSession = session
            session.begin()
        }
    }

    static func selectRegion(settings: SettingsStore) async -> CaptureRegion? {
        await snip(settings: settings, purpose: .annotate)?.region
    }
}

// MARK: - Session

@MainActor
private final class RegionSelectorSession: NSObject {
    private let settings: SettingsStore
    private let purpose: SnipPurpose
    private let completion: (SnipResult?) -> Void
    private var windows: [RegionSelectorWindow] = []
    private var finished = false
    private var globalEsc: Any?
    private var localKey: Any?
    private var detectedWindows: [DetectedWindow] = []
    private var beginTask: Task<Void, Never>?

    init(
        settings: SettingsStore,
        purpose: SnipPurpose,
        completion: @escaping (SnipResult?) -> Void
    ) {
        self.settings = settings
        self.purpose = purpose
        self.completion = completion
    }

    func begin() {
        beginTask = Task { @MainActor [weak self] in
            await self?.beginAsync()
        }
    }

    private func beginAsync() async {
        guard !finished else { return }

        // 先刷窗口列表（轻量）
        detectedWindows = WindowHitTester.onScreenWindows()

        // 顺序冻结各屏（避免 Swift 6 TaskGroup 发送 NSScreen 竞态），每屏 4s 超时
        let screens = NSScreen.screens
        var snapshots: [CGDirectDisplayID: CGImage] = [:]
        for screen in screens {
            guard !finished, !Task.isCancelled else { return }
            let id = ScreenGeometry.displayID(for: screen)
            if let img = await Self.captureScreenSnapshot(
                displayID: id,
                widthPoints: screen.frame.width,
                heightPoints: screen.frame.height,
                scale: min(screen.backingScaleFactor, 2)
            ) {
                snapshots[id] = img
            }
        }

        guard !finished, !Task.isCancelled else { return }

        if snapshots.isEmpty {
            NSLog("[SnapFlow] freeze screen failed on all displays — abort snip")
            finish(nil)
            return
        }

        for screen in screens {
            let id = ScreenGeometry.displayID(for: screen)
            let snapshot = snapshots[id]
            let window = RegionSelectorWindow(
                screen: screen,
                snapshot: snapshot,
                settings: settings,
                purpose: purpose,
                windowsProvider: { [weak self] in self?.detectedWindows ?? [] },
                onFinish: { [weak self] result in
                    self?.finish(result)
                }
            )
            windows.append(window)
        }
        // 先完成离屏布局和绘制，再显示窗口，避免黑色背景先于截图图层出现。
        for window in windows {
            window.prepareForPresentation()
        }
        // 所有屏幕窗口准备好后再统一显示，避免 contentView 挂载期间逐个抢焦点造成闪烁。
        // 只激活 App 并前置选区窗，不把偏好设置等普通窗抬到最前
        AppActivation.focus(windows, makeKey: windows.first)
        if let firstWindow = windows.first {
            firstWindow.makeFirstResponder(firstWindow.selectionView)
        }
        // AppKit 在窗口激活时可能重置系统光标，激活完成后再统一设置截图光标。
        for window in windows {
            window.prepareCursorForCapture()
        }
        MainThreadWatchdog.shared.noteMainAlive()

        globalEsc = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainThreadWatchdog.shared.noteMainAlive()
            Task { @MainActor in
                if self?.settings.matches(.captureCancel, event: e) == true {
                    self?.finish(nil)
                }
            }
        }
        localKey = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainThreadWatchdog.shared.noteMainAlive()
            if TextInputSession.isComposing(in: e.window) {
                return e
            }
            if self?.settings.matches(.captureCancel, event: e) == true {
                self?.finish(nil)
                return nil
            }
            if self?.settings.matches(.captureToggleDetection, event: e) == true {
                self?.detectedWindows = WindowHitTester.onScreenWindows()
            }
            return e
        }
    }

    func cancel() { finish(nil) }

    func setWindowsPassThroughForScroll(_ enabled: Bool) {
        for window in windows {
            window.selectionView.setScrollCapturePassThrough(enabled)
            window.alphaValue = 1
            window.isOpaque = !enabled
            window.backgroundColor = enabled ? .clear : .black
            if enabled {
                window.ignoresMouseEvents = true
                window.orderFrontRegardless()
            } else {
                window.ignoresMouseEvents = false
                window.orderFront(nil)
            }
        }
        if !enabled {
            windows.first?.makeKey()
        }
    }

    private func finish(_ result: SnipResult?) {
        guard !finished else { return }
        finished = true
        MainThreadWatchdog.shared.endCaptureSession()
        beginTask?.cancel()
        beginTask = nil
        if let globalEsc { NSEvent.removeMonitor(globalEsc); self.globalEsc = nil }
        if let localKey { NSEvent.removeMonitor(localKey); self.localKey = nil }
        for w in windows {
            // 先停 tracking，避免 orderOut 过程中继续刷新 cursor rect。
            w.selectionView.prepareForTeardown()
            w.selectionView.cancelActiveScrollCapture()
            w.ignoresMouseEvents = true
            w.orderOut(nil)
            w.close()
        }
        windows.removeAll()
        // 强制还原系统箭头；延迟再设一次，压过队列里残留的 cursor 事件
        Self.restoreSystemCursor()
        // 下一 runloop 再 resume，确保窗口已卸下
        DispatchQueue.main.async { [completion] in
            Self.restoreSystemCursor()
            completion(result)
        }
    }

    private static func restoreSystemCursor() {
        NSCursor.unhide()
        NSCursor.setHiddenUntilMouseMoves(false)
        NSCursor.arrow.set()
    }

    private static func captureScreenSnapshot(
        displayID: CGDirectDisplayID,
        widthPoints: CGFloat,
        heightPoints: CGFloat,
        scale: CGFloat
    ) async -> CGImage? {
        // 用 Sendable 原始值，避免把 NSScreen 传入并发上下文
        struct CaptureParams: Sendable {
            let displayID: CGDirectDisplayID
            let width: Int
            let height: Int
        }
        let params = CaptureParams(
            displayID: displayID,
            width: max(Int(widthPoints * scale), 1),
            height: max(Int(heightPoints * scale), 1)
        )

        do {
            return try await withThrowingTaskGroup(of: CGImage?.self) { group in
                group.addTask {
                    let content = try await SCShareableContent.excludingDesktopWindows(
                        false,
                        onScreenWindowsOnly: true
                    )
                    guard let display = content.displays.first(where: { $0.displayID == params.displayID })
                            ?? content.displays.first
                    else { return nil }

                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let config = SCStreamConfiguration()
                    config.width = params.width
                    config.height = params.height
                    config.showsCursor = false
                    config.scalesToFit = false
                    config.captureResolution = .automatic
                    return try await SCScreenshotManager.captureImage(
                        contentFilter: filter,
                        configuration: config
                    )
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(4))
                    throw CancellationError()
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        } catch {
            NSLog("[SnapFlow] freeze screen failed: \(error)")
            return nil
        }
    }
}

// MARK: - Window

@MainActor
private final class RegionSelectorWindow: NSPanel {
    let selectionView: RegionSelectionView

    init(
        screen: NSScreen,
        snapshot: CGImage?,
        settings: SettingsStore,
        purpose: SnipPurpose,
        windowsProvider: @escaping () -> [DetectedWindow],
        onFinish: @escaping (SnipResult?) -> Void
    ) {
        let view = RegionSelectionView(
            screen: screen,
            snapshot: snapshot,
            settings: settings,
            purpose: purpose,
            windowsProvider: windowsProvider,
            onFinish: onFinish
        )
        self.selectionView = view

        super.init(
            contentRect: screen.frame,
            // 不用 nonactivating：否则部分系统上子视图收不到可靠点击
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: true)
        isOpaque = true
        backgroundColor = .black
        // 盖住 Dock / 菜单栏：Dock 仍在冻屏快照里可见，但会话中不可点
        // （.floating 低于 Dock，会导致程序坞可操作且「浮」在冻屏之上）
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hasShadow = false
        animationBehavior = .none
        hidesOnDeactivate = false
        // 不把自身排除在截图外；内容已是冻屏位图
        contentView = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// 在窗口显示前完成首帧布局与绘制，避免显示黑色背景后再补上截图图层。
    func prepareForPresentation() {
        contentView?.layoutSubtreeIfNeeded()
        contentView?.displayIfNeeded()
    }

    func prepareCursorForCapture() {
        if !areCursorRectsEnabled {
            enableCursorRects()
        }
        selectionView.refreshCaptureCursor()
        resetCursorRects()
    }
}

// MARK: - Selection view（图层架构，避免每帧全屏 blit）

@MainActor
private final class RegionSelectionView: NSView {
    private enum Mode {
        case detecting
        case pressPending
        case dragging
        case review
        case resizing
    }

    /// Tab 切换：窗口检测 / 界面元素检测
    private enum DetectionMode {
        case window
        case element
    }

    private enum ResizeEdge {
        case none, n, s, e, w, ne, nw, se, sw
    }

    private let dragThreshold: CGFloat = 4
    private let resizeHit: CGFloat = 8
    private let targetScreen: NSScreen
    private let snapshot: CGImage?
    private let imageScale: CGFloat
    private let settings: SettingsStore
    private let purpose: SnipPurpose
    private let windowsProvider: () -> [DetectedWindow]
    private let onFinish: (SnipResult?) -> Void

    private var mode: Mode = .detecting
    private var detectionMode: DetectionMode = .window
    private var mouseLocal: NSPoint = .zero
    private var hoverWindow: DetectedWindow?
    private var hoverElement: ElementHitTester.DetectedElement?
    private var pressedWindow: DetectedWindow?
    private var pressedElement: ElementHitTester.DetectedElement?
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private var lockedRect: NSRect?
    private var croppedCG: CGImage?
    private var croppedNS: NSImage?
    private var tracking: NSTrackingArea?
    private var didFinish = false
    /// 会话结束：禁止再写光标，避免与系统箭头抢
    private var isTornDown = false
    /// 上次已应用的光标状态，避免重复刷新 cursor rect。
    private var appliedCursorToken: String?
    /// 交给 AppKit cursor rect 系统显示的目标光标。
    private var activeCursor: NSCursor = .crosshair
    private var currentAnnotateTool: AnnotateTool = .none
    private var resizeEdge: ResizeEdge = .none
    private var resizeStartRect: NSRect?
    private var resizeStartMouse: NSPoint?
    /// 整体移动选区
    private var isMovingSelection = false
    private var moveStartMouse: NSPoint?
    private var moveStartRect: NSRect?
    private var scrollCaptureTask: Task<Void, Never>?
    private var scrollCaptureEngine: ScrollCaptureEngine?
    private var scrollCapturePanel: ScrollCaptureControlPanel?
    private var scrollCaptureVisibility: (
        magnifier: Bool,
        help: Bool,
        annotate: Bool,
        toolbar: Bool,
        actionToolbar: Bool,
        options: Bool
    )?
    /// 滚动截屏期间隐藏选区内容，但保留镂空遮罩并禁止工具栏重新出现。
    private var isScrollCapturePassThrough = false
    /// 背景：只设置一次
    private let bgLayer = CALayer()
    /// 遮罩 + 描边：轻量重绘
    private let overlayView = SelectionOverlayView()
    private let annotateCanvas = AnnotationCanvasView()
    private let toolbar = SnipToolbarView(presentation: .captureEditor)
    private let actionToolbar = SnipToolbarView(presentation: .captureActions)
    private let optionsBar = AnnotateOptionsBar()
    private let helpHint = SnipHelpHintView()
    /// 仅主屏展示左下角操作提示（副屏不显示，避免多余卡片）
    private let showsHelpHint: Bool

    /// 放大镜节流
    private var lastMagnifierUpdate: CFTimeInterval = 0
    private let magnifierMinInterval: CFTimeInterval = 1.0 / 20.0
    private let magnifierView = MagnifierView()
    /// 用户快捷键关闭放大镜后为 true；再按一次恢复自动显示
    private var magnifierUserSuppressed = false

    init(
        screen: NSScreen,
        snapshot: CGImage?,
        settings: SettingsStore,
        purpose: SnipPurpose,
        windowsProvider: @escaping () -> [DetectedWindow],
        onFinish: @escaping (SnipResult?) -> Void
    ) {
        self.targetScreen = screen
        self.snapshot = snapshot
        if let snapshot {
            self.imageScale = CGFloat(snapshot.width) / max(screen.frame.width, 1)
        } else {
            self.imageScale = screen.backingScaleFactor
        }
        self.settings = settings
        self.purpose = purpose
        self.windowsProvider = windowsProvider
        self.onFinish = onFinish
        self.showsHelpHint = (screen == NSScreen.main)
            || (NSScreen.main == nil && screen == NSScreen.screens.first)
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        autoresizingMask = [.width, .height]

        // 背景图层（GPU，不每帧 CPU draw）
        bgLayer.frame = bounds
        bgLayer.contentsGravity = .resize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bgLayer.contents = snapshot
        CATransaction.commit()
        layer?.addSublayer(bgLayer)

        overlayView.frame = bounds
        overlayView.autoresizingMask = [.width, .height]
        addSubview(overlayView)

        // 默认隐藏；仅当鼠标进入选区时显示（后于工具栏 add，保证层级更高）
        magnifierView.isHidden = true
        magnifierView.frame = NSRect(
            x: 0,
            y: 0,
            width: MagnifierView.preferredSize.width,
            height: MagnifierView.preferredSize.height
        )
        magnifierView.setShortcutHints(
            copyLabel: displayShortcut(settings.shortcut(for: .captureCopyColor), fallback: "C"),
            toggleLabel: displayShortcut(settings.shortcut(for: .captureToggleMagnifier), fallback: "M")
        )

        helpHint.isHidden = !showsHelpHint
        addSubview(helpHint)

        annotateCanvas.isHidden = true
        annotateCanvas.tool = .none
        // 截图会话由本视图统一管光标，避免与画布/工具栏 cursor 通道互抢导致闪烁
        annotateCanvas.managesCursor = false
        annotateCanvas.onSelectionChanged = { [weak self] in
            self?.handleAnnotationSelectionChanged()
        }
        addSubview(annotateCanvas)

        toolbar.isHidden = true
        toolbar.managesCursor = false
        toolbar.onAction = { [weak self] action in
            self?.handleToolbar(action)
        }
        toolbar.onSelectTool = { [weak self] tool in
            self?.handleAnnotateTool(tool)
        }
        toolbar.bindShortcuts(settings: settings, scope: .capture)
        addSubview(toolbar)

        actionToolbar.isHidden = true
        actionToolbar.managesCursor = false
        actionToolbar.onAction = { [weak self] action in
            self?.handleToolbar(action)
        }
        actionToolbar.bindShortcuts(settings: settings, scope: .capture)
        addSubview(actionToolbar)

        optionsBar.isHidden = true
        optionsBar.managesCursor = false
        optionsBar.onChange = { [weak self] style in
            guard let self else { return }
            self.annotateCanvas.apply(options: style)
            // 形状图标随二级切换
            if self.currentAnnotateTool == .shape {
                let symbol = style.shapeKind == .ellipse ? "circle" : "rectangle"
                // 工具栏按钮图由 title/symbol 固定；绘制侧已用 shapeKind
                _ = symbol
            }
        }
        // 颜色选择器锚点：截图框选区域（屏幕坐标）
        optionsBar.colorPanelScreenAnchor = { [weak self] in
            guard let self, let rect = self.lockedRect, let win = self.window else { return nil }
            let winRect = self.convert(rect, to: nil)
            return win.convertToScreen(winRect)
        }
        addSubview(optionsBar)

        // 放大镜最后加入，保证在工具栏 / 选项条之上
        addSubview(magnifierView)

        overlayView.activeRect = nil
        updateHelpText()
    }

    private func updateHelpText() {
        let detect = detectionMode == .window ? L10n.string("窗口检测") : L10n.string("元素检测")
        let toggleKey = displayShortcut(settings.shortcut(for: .captureToggleDetection), fallback: "Tab")
        let cancelKey = displayShortcut(settings.shortcut(for: .captureCancel), fallback: "Esc")
        let copyColorKey = displayShortcut(settings.shortcut(for: .captureCopyColor), fallback: "C")
        let copyColorAltKey = displayShortcut(
            settings.shortcut(for: .captureCopyAlternateColor),
            fallback: "⇧C"
        )
        let magnifierKey = displayShortcut(settings.shortcut(for: .captureToggleMagnifier), fallback: "M")
        let rows: [SnipHelpHintView.Row]
        if purpose == .ocrImmediate {
            rows = [
                .init(key: L10n.string("单击"), detail: L10n.string("选中区域并识别文字")),
                .init(key: L10n.string("拖拽"), detail: L10n.string("自由框选 · 松手后自动 OCR")),
                .init(key: toggleKey, detail: String(format: L10n.string("切换%@"), detect)),
                .init(key: copyColorKey, detail: L10n.string("复制指针颜色（#HEX）")),
                .init(key: copyColorAltKey, detail: L10n.string("复制指针颜色（rgb）")),
                .init(key: magnifierKey, detail: L10n.string("显示/隐藏放大镜")),
                .init(key: cancelKey, detail: L10n.string("取消")),
            ]
        } else {
            rows = [
                .init(key: L10n.string("单击"), detail: L10n.string("选中智能识别区域")),
                .init(key: L10n.string("拖拽"), detail: L10n.string("自由框选 · 松手后可拖边缘拉伸")),
                .init(key: toggleKey, detail: String(format: L10n.string("切换%@"), detect)),
                .init(key: copyColorKey, detail: L10n.string("复制指针颜色（#HEX）")),
                .init(key: copyColorAltKey, detail: L10n.string("复制指针颜色（rgb）")),
                .init(key: magnifierKey, detail: L10n.string("显示/隐藏放大镜")),
                .init(key: cancelKey, detail: L10n.string("取消")),
                // 看门狗强制退出：非用户可配置，固定展示
                .init(key: ShortcutDisplay.label(chord: "cmd+option+shift+escape"), detail: L10n.string("强制退出（卡死时）")),
            ]
        }
        guard showsHelpHint else {
            helpHint.isHidden = true
            return
        }
        helpHint.setRows(rows)
        updateHelpHintPlacement(selectionRect: currentSelectionRect())
    }

    private func displayShortcut(_ chord: String, fallback: String) -> String {
        let trimmed = chord.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return fallback }
        let display = HotKeyChord.displayString(from: trimmed)
        return display.isEmpty ? fallback : display
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        bgLayer.frame = bounds
        overlayView.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !isTornDown else { return }
        window?.makeFirstResponder(self)
        window?.acceptsMouseMovedEvents = true
        updateTracking()
        window?.invalidateCursorRects(for: self)
    }

    func refreshCaptureCursor() {
        guard !isTornDown else { return }
        appliedCursorToken = nil
        applyCursor(.crosshair, token: "crosshair")
    }

    /// 结束截图前调用：撤 tracking，禁止再改光标
    func prepareForTeardown() {
        isTornDown = true
        if let tracking {
            removeTrackingArea(tracking)
            self.tracking = nil
        }
        appliedCursorToken = nil
    }

    override var acceptsFirstResponder: Bool { true }

    func setScrollCapturePassThrough(_ enabled: Bool) {
        isScrollCapturePassThrough = enabled
        if enabled {
            if scrollCaptureVisibility == nil {
                scrollCaptureVisibility = (
                    magnifierView.isHidden,
                    helpHint.isHidden,
                    annotateCanvas.isHidden,
                    toolbar.isHidden,
                    actionToolbar.isHidden,
                    optionsBar.isHidden
                )
            }
            bgLayer.isHidden = true
            layer?.backgroundColor = NSColor.clear.cgColor
            magnifierView.isHidden = true
            helpHint.isHidden = true
            annotateCanvas.isHidden = true
            toolbar.isHidden = true
            actionToolbar.isHidden = true
            optionsBar.isHidden = true
            return
        }

        bgLayer.isHidden = false
        layer?.backgroundColor = NSColor.black.cgColor
        if let visibility = scrollCaptureVisibility {
            magnifierView.isHidden = visibility.magnifier
            helpHint.isHidden = visibility.help || !showsHelpHint
            annotateCanvas.isHidden = visibility.annotate
            toolbar.isHidden = visibility.toolbar
            actionToolbar.isHidden = visibility.actionToolbar
            optionsBar.isHidden = visibility.options
            scrollCaptureVisibility = nil
        }
    }

    /// 非 key 窗口也接受第一下点击（截图层关键）
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 工具栏 > 选项条 > 选区边缘/移动 > 标注画布（放大镜不参与命中，事件穿透）
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }

        if mode == .review || mode == .resizing {
            if !toolbar.isHidden, toolbar.frame.contains(local) {
                return toolbar
            }
            if !actionToolbar.isHidden, actionToolbar.frame.contains(local) {
                return actionToolbar
            }
            if !optionsBar.isHidden, optionsBar.frame.contains(local) {
                return optionsBar.hitTest(local) ?? optionsBar
            }
            // 未选编辑工具：边缘拉伸 / 内部移动 全由本视图处理
            if currentAnnotateTool == .none || !currentAnnotateTool.isDrawable {
                if !annotateCanvas.isHidden,
                   annotateCanvas.frame.contains(local),
                   annotateCanvas.containsAnnotation(at: annotateCanvas.convert(local, from: self))
                {
                    return annotateCanvas.hitTest(annotateCanvas.convert(local, from: self)) ?? annotateCanvas
                }
                return self
            }
            // 已选编辑工具：边缘仍可拉伸；内部给画布（含文字编辑器子视图）
            // 文字编辑中优先给画布/编辑器，避免边缘把手抢事件
            if !annotateCanvas.isTextEditing,
               let rect = lockedRect,
               hitResizeEdge(local, rect: rect) != .none
            {
                return self
            }
            if !annotateCanvas.isHidden, annotateCanvas.frame.contains(local) {
                // 必须用画布坐标系命中子视图（文字变换框）
                return annotateCanvas.hitTest(local) ?? annotateCanvas
            }
            return self
        }
        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTracking()
    }

    private func updateTracking() {
        if isTornDown {
            if let tracking {
                removeTrackingArea(tracking)
                self.tracking = nil
            }
            return
        }
        if let tracking { removeTrackingArea(tracking) }
        // mouseMoved 只更新目标光标，实际显示由 AppKit cursor rect 系统统一处理。
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        discardCursorRects()
        guard !isTornDown else { return }
        addCursorRect(bounds, cursor: activeCursor)
    }

    /// 统一更新 cursor rect；工具栏由父视图统一管理时立即应用，避免继续显示截图光标。
    private func applyCursor(_ cursor: NSCursor, token: String, immediately: Bool = false) {
        guard !isTornDown else { return }
        if appliedCursorToken != token {
            appliedCursorToken = token
            activeCursor = cursor
            window?.invalidateCursorRects(for: self)
        }
        if immediately {
            cursor.set()
        }
    }

    private func updateCursor(at p: NSPoint) {
        guard !isTornDown else { return }
        if !toolbar.isHidden, toolbar.frame.contains(p) {
            let c = toolbar.cursor(at: convert(p, to: toolbar))
            applyCursor(c, token: c === NSCursor.pointingHand ? "hand" : "arrow", immediately: true)
            return
        }
        if !actionToolbar.isHidden, actionToolbar.frame.contains(p) {
            let c = actionToolbar.cursor(at: convert(p, to: actionToolbar))
            applyCursor(c, token: c === NSCursor.pointingHand ? "action-hand" : "action-arrow", immediately: true)
            return
        }
        if !optionsBar.isHidden, optionsBar.frame.contains(p) {
            let c = optionsBar.cursor(at: convert(p, to: optionsBar))
            let token: String
            if c === NSCursor.pointingHand { token = "opt-hand" }
            else if c === NSCursor.iBeam { token = "opt-ibeam" }
            else if c === NSCursor.resizeUpDown { token = "opt-resize" }
            else if c === NSCursor.columnResize { token = "opt-col" }
            else { token = "opt-arrow" }
            applyCursor(c, token: token, immediately: true)
            return
        }
        if annotateCanvas.isTextEditing,
           annotateCanvas.frame.contains(p),
           let cursor = annotateCanvas.textInteractionCursor(at: convert(p, to: annotateCanvas))
        {
            applyCursor(cursor, token: "text-\(ObjectIdentifier(cursor))")
            return
        }
        if mode == .detecting || mode == .pressPending || mode == .dragging {
            applyCursor(.crosshair, token: "crosshair")
            return
        }
        // review / resizing：按边缘/内部/编辑工具换光标
        guard let rect = lockedRect else {
            applyCursor(.arrow, token: "arrow")
            return
        }
        if !annotateCanvas.isTextEditing {
            let edge = hitResizeEdge(p, rect: rect)
            if edge != .none, let cursor = resizeCursor(for: edge) {
                applyCursor(cursor, token: "resize-\(edge)")
                return
            }
        }
        if !annotateCanvas.isHidden,
           annotateCanvas.frame.contains(p),
           let annotationCursor = annotateCanvas.activeElementResizeCursor(
               at: convert(p, to: annotateCanvas)
           )
        {
            applyCursor(annotationCursor.cursor, token: annotationCursor.token)
            return
        }
        if currentAnnotateTool != .none && currentAnnotateTool.isDrawable {
            if currentAnnotateTool == .text {
                applyCursor(.iBeam, token: "ibeam")
            } else {
                applyCursor(.crosshair, token: "draw-crosshair")
            }
            return
        }
        if isMovingSelection {
            applyCursor(.closedHand, token: "closedHand")
        } else if rect.contains(p) {
            applyCursor(.openHand, token: "openHand")
        } else {
            applyCursor(.arrow, token: "arrow")
        }
    }

    private func resizeCursor(for edge: ResizeEdge) -> NSCursor? {
        let position: NSCursor.FrameResizePosition
        switch edge {
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
        return .frameResize(position: position, directions: .all)
    }

    func refreshHover() {
        updateHoverWindow(at: mouseLocal)
        applyOverlay()
    }

    // MARK: - Overlay state

    private func applyOverlay() {
        let rect = currentSelectionRect()
        overlayView.activeRect = rect
        overlayView.needsDisplay = true
        layoutToolbar(under: rect)

        // 放大镜：鼠标进入框选区域（含边框/把手）时显示；仅本屏，避免副屏残留
        updateMagnifierVisibility(selectionRect: rect)
        // 帮助卡：默认左下；与选区/光标重叠时换角，四角皆挡则隐藏
        updateHelpHintPlacement(selectionRect: rect)
    }

    /// 操作提示避让：优先左下 → 右下 → 左上 → 右上；仍与选区或光标冲突则隐藏。
    private func updateHelpHintPlacement(selectionRect: NSRect?) {
        guard showsHelpHint, !isScrollCapturePassThrough else {
            helpHint.isHidden = true
            return
        }
        // 标注/拉伸阶段不需要操作提示
        if mode == .review || mode == .resizing {
            helpHint.isHidden = true
            return
        }

        // 拖拽中更激进：有有效选区时直接隐藏，避免挡框选内容
        if mode == .dragging,
           let rect = selectionRect,
           rect.width > 0.5,
           rect.height > 0.5
        {
            helpHint.isHidden = true
            return
        }

        let selectionPad: CGFloat = 8
        let mousePad: CGFloat = 28
        let anchors = SnipHelpHintView.Anchor.allCases

        for anchor in anchors {
            let candidate = helpHint.frame(for: anchor, in: bounds)
            if isHelpHintBlocked(
                frame: candidate,
                selectionRect: selectionRect,
                selectionPad: selectionPad,
                mousePad: mousePad
            ) {
                continue
            }
            helpHint.place(in: bounds, anchor: anchor)
            helpHint.isHidden = false
            return
        }

        helpHint.isHidden = true
    }

    private func isHelpHintBlocked(
        frame: NSRect,
        selectionRect: NSRect?,
        selectionPad: CGFloat,
        mousePad: CGFloat
    ) -> Bool {
        if let rect = selectionRect, rect.width > 0.5, rect.height > 0.5 {
            let expanded = frame.insetBy(dx: -selectionPad, dy: -selectionPad)
            if expanded.intersects(rect) {
                return true
            }
        }
        let mouseZone = frame.insetBy(dx: -mousePad, dy: -mousePad)
        if mouseZone.contains(mouseLocal) {
            return true
        }
        return false
    }

    private var optionsTool: AnnotateTool? {
        if currentAnnotateTool.isDrawable { return currentAnnotateTool }
        return annotateCanvas.activeStrokeTool
    }

    private func handleAnnotationSelectionChanged() {
        guard !didFinish, mode == .review || mode == .resizing else { return }
        if let tool = annotateCanvas.activeStrokeTool,
           tool.isDrawable,
           let style = annotateCanvas.activeOptionsStyle
        {
            optionsBar.setStyle(style, notify: false)
        } else if currentAnnotateTool.isDrawable {
            // 无选中笔画时（如画布滚轮改粗细/字号）写回当前工具独立样式
            let merged = annotateCanvas.mergeCanvasBrush(
                into: optionsBar.style,
                for: currentAnnotateTool
            )
            optionsBar.setStyle(merged, notify: false)
        }
        layoutToolbar(under: lockedRect)
        updateCursor(at: mouseLocal)
        keepCaptureWindowFocused(
            preferredResponder: annotateCanvas.activeStrokeTool == nil ? self : annotateCanvas
        )
    }

    private func keepCaptureWindowFocused(preferredResponder: NSResponder? = nil) {
        guard !didFinish else { return }
        // 勿用 activate(ignoringOtherApps:)：会反复把偏好设置抬到最前
        if let window {
            AppActivation.focus(window)
        }
        if let preferredResponder {
            window?.makeFirstResponder(preferredResponder)
        }
    }

    /// 是否因标注工具激活而应隐藏放大镜
    private var isAnnotateToolActive: Bool {
        (currentAnnotateTool != .none && currentAnnotateTool.isDrawable)
            || annotateCanvas.activeStrokeTool?.isDrawable == true
    }

    /// 鼠标落在选区内（含边框）且未激活标注工具、用户未关闭时显示放大镜
    private func updateMagnifierVisibility(selectionRect: NSRect?) {
        // 滚动截屏穿透 / 用户关闭 / 标注工具激活 → 一律隐藏
        if isScrollCapturePassThrough || magnifierUserSuppressed || isAnnotateToolActive {
            magnifierView.isHidden = true
            return
        }
        let mouseOnThisScreen = targetScreen.frame.contains(NSEvent.mouseLocation)
        // 外扩：描边 + 把手半径，保证「边框上」也算进入选区
        let pad = max(SnipStyle.borderWidth, SnipStyle.handleSize / 2)
        let show: Bool
        if mouseOnThisScreen,
           let rect = selectionRect,
           rect.width > 0.5,
           rect.height > 0.5
        {
            let hit = rect.insetBy(dx: -pad, dy: -pad)
            show = hit.contains(mouseLocal)
        } else {
            show = false
        }
        let wasHidden = magnifierView.isHidden
        magnifierView.isHidden = !show
        if show {
            bringMagnifierToFront()
            // 刚从隐藏变为显示时立刻刷新，不吃节流
            if wasHidden { lastMagnifierUpdate = 0 }
            updateMagnifierThrottled()
        }
    }

    /// 保证放大镜叠在工具栏之上
    private func bringMagnifierToFront() {
        guard magnifierView.superview === self else { return }
        addSubview(magnifierView, positioned: .above, relativeTo: nil)
    }

    private func toggleMagnifierByShortcut() {
        magnifierUserSuppressed.toggle()
        updateMagnifierVisibility(selectionRect: currentSelectionRect())
    }

    private func currentSelectionRect() -> NSRect? {
        switch mode {
        case .detecting, .pressPending:
            if mode == .pressPending, let s = dragStart, let c = dragCurrent {
                let moved = hypot(c.x - s.x, c.y - s.y)
                if moved >= dragThreshold {
                    return normalized(s, c)
                }
            }
            if detectionMode == .element {
                if let el = hoverElement,
                   let local = localFrame(global: el.frame)
                {
                    return local
                }
            } else if let hoverWindow,
                      let local = WindowHitTester.localFrame(of: hoverWindow, on: targetScreen)
            {
                return local
            }
            if mode == .pressPending, let s = dragStart, let c = dragCurrent {
                return normalized(s, c)
            }
            return nil
        case .dragging:
            guard let s = dragStart, let c = dragCurrent else { return nil }
            return normalized(s, c)
        case .review, .resizing:
            return lockedRect
        }
    }

    private func localFrame(global: CGRect) -> NSRect? {
        let inter = global.intersection(targetScreen.frame)
        guard inter.width > 2, inter.height > 2 else { return nil }
        return NSRect(
            x: inter.minX - targetScreen.frame.minX,
            y: inter.minY - targetScreen.frame.minY,
            width: inter.width,
            height: inter.height
        )
    }

    private func layoutToolbar(under rect: NSRect?) {
        guard !isScrollCapturePassThrough,
              mode == .review || mode == .resizing,
              let rect
        else {
            toolbar.isHidden = true
            actionToolbar.isHidden = true
            optionsBar.isHidden = true
            annotateCanvas.isHidden = true
            return
        }

        let edgeInset: CGFloat = 8
        let gap: CGFloat = 6
        let editorSize = toolbar.computePreferredSize()
        let actionSize = actionToolbar.computePreferredSize()
        let displayedOptionsTool = optionsTool
        let showsOptions = displayedOptionsTool?.isDrawable == true
        let optionsSize: NSSize
        if showsOptions {
            optionsBar.isHidden = false
            let preferred: AnnotateOptionsBar.Style? = {
                if let activeTool = annotateCanvas.activeStrokeTool,
                   activeTool == displayedOptionsTool,
                   let style = annotateCanvas.activeOptionsStyle
                {
                    return style
                }
                return nil
            }()
            optionsBar.show(for: displayedOptionsTool!, preferredStyle: preferred)
            optionsSize = optionsBar.preferredSize()
        } else {
            optionsBar.isHidden = true
            optionsBar.frame = .zero
            optionsSize = .zero
        }

        let placed = CaptureToolbarLayout.frames(
            for: CaptureToolbarLayout.Request(
                bounds: bounds,
                selection: rect,
                editorSize: editorSize,
                actionSize: actionSize,
                optionsSize: optionsSize,
                showsOptions: showsOptions,
                edgeInset: edgeInset,
                gap: gap
            )
        )
        let editorFrame = placed.editor
        let actionFrame = placed.action
        let optionsFrame = placed.options

        toolbar.isHidden = false
        toolbar.frame = editorFrame
        toolbar.needsLayout = true
        toolbar.layoutSubtreeIfNeeded()

        actionToolbar.isHidden = false
        actionToolbar.frame = actionFrame
        actionToolbar.needsLayout = true
        actionToolbar.layoutSubtreeIfNeeded()

        if showsOptions {
            optionsBar.frame = optionsFrame
        }

        annotateCanvas.isHidden = false
        annotateCanvas.setSelectionFrame(rect)
        annotateCanvas.baseImage = croppedNS
        annotateCanvas.tool = currentAnnotateTool
        annotateCanvas.apply(options: optionsBar.style, updatingActiveStroke: false)
    }

    private func handleAnnotateTool(_ tool: AnnotateTool) {
        switch tool {
        case .undo:
            annotateCanvas.undo()
            return
        case .redo:
            annotateCanvas.redo()
            return
        default:
            break
        }
        annotateCanvas.commitTextIfNeeded()
        currentAnnotateTool = tool
        annotateCanvas.tool = tool
        toolbar.setSelectedTool(tool, notify: false)
        if tool != .none {
            // 选中同工具活动笔画时用笔画样式；否则用该工具独立记忆样式（默认红）
            let preferred: AnnotateOptionsBar.Style? =
                (annotateCanvas.activeStrokeTool == tool)
                ? annotateCanvas.activeOptionsStyle
                : nil
            optionsBar.show(for: tool, preferredStyle: preferred)
            annotateCanvas.apply(options: optionsBar.style, updatingActiveStroke: false)
            annotateCanvas.isHidden = false
            if let rect = lockedRect {
                annotateCanvas.setSelectionFrame(rect)
            }
        } else {
            optionsBar.isHidden = true
            annotateCanvas.isHidden = false
        }
        if let rect = lockedRect {
            layoutToolbar(under: rect)
        }
        // 选中任意绘制工具时隐藏放大镜；回到选择态后按规则恢复
        updateMagnifierVisibility(selectionRect: lockedRect)
        updateCursor(at: mouseLocal)
        bringMagnifierToFront()
        keepCaptureWindowFocused(preferredResponder: tool == .none ? self : annotateCanvas)
    }

    // MARK: - Resize handles

    private func hitResizeEdge(_ p: NSPoint, rect: NSRect) -> ResizeEdge {
        let m = resizeHit
        let nearL = abs(p.x - rect.minX) <= m
        let nearR = abs(p.x - rect.maxX) <= m
        let nearB = abs(p.y - rect.minY) <= m
        let nearT = abs(p.y - rect.maxY) <= m
        let inX = p.x >= rect.minX - m && p.x <= rect.maxX + m
        let inY = p.y >= rect.minY - m && p.y <= rect.maxY + m
        if nearT && nearL { return .nw }
        if nearT && nearR { return .ne }
        if nearB && nearL { return .sw }
        if nearB && nearR { return .se }
        if nearT && inX { return .n }
        if nearB && inX { return .s }
        if nearL && inY { return .w }
        if nearR && inY { return .e }
        return .none
    }

    private func applyResize(to point: NSPoint) {
        guard var rect = resizeStartRect, let start = resizeStartMouse else { return }
        let dx = point.x - start.x
        let dy = point.y - start.y
        switch resizeEdge {
        case .n:
            rect.size.height += dy
        case .s:
            rect.origin.y += dy
            rect.size.height -= dy
        case .e:
            rect.size.width += dx
        case .w:
            rect.origin.x += dx
            rect.size.width -= dx
        case .ne:
            rect.size.width += dx
            rect.size.height += dy
        case .nw:
            rect.origin.x += dx
            rect.size.width -= dx
            rect.size.height += dy
        case .se:
            rect.size.width += dx
            rect.origin.y += dy
            rect.size.height -= dy
        case .sw:
            rect.origin.x += dx
            rect.size.width -= dx
            rect.origin.y += dy
            rect.size.height -= dy
        case .none:
            return
        }
        if rect.width < 8 { rect.size.width = 8 }
        if rect.height < 8 { rect.size.height = 8 }
        rect.origin.x = min(max(0, rect.origin.x), bounds.width - rect.width)
        rect.origin.y = min(max(0, rect.origin.y), bounds.height - rect.height)
        lockedRect = rect
        applyOverlay()
    }

    private func applyMove(to point: NSPoint) {
        guard let startR = moveStartRect, let startM = moveStartMouse else { return }
        let dx = point.x - startM.x
        let dy = point.y - startM.y
        var rect = startR
        rect.origin.x += dx
        rect.origin.y += dy
        rect.origin.x = min(max(0, rect.origin.x), bounds.width - rect.width)
        rect.origin.y = min(max(0, rect.origin.y), bounds.height - rect.height)
        lockedRect = rect
        applyOverlay()
    }

    private func finishResize() {
        guard let rect = lockedRect else {
            mode = .review
            return
        }
        mode = .review
        resizeEdge = .none
        // 重裁剪；标注保持屏幕坐标，区域外内容仍保留在历史中
        if let cropped = cropSnapshot(rect) {
            croppedCG = cropped
            croppedNS = NSImage(
                cgImage: cropped,
                size: NSSize(
                    width: CGFloat(cropped.width) / max(imageScale, 1),
                    height: CGFloat(cropped.height) / max(imageScale, 1)
                )
            )
            annotateCanvas.baseImage = croppedNS
        }
        applyOverlay()
    }

    private func updateMagnifierThrottled() {
        let now = CACurrentMediaTime()
        guard now - lastMagnifierUpdate >= magnifierMinInterval else { return }
        lastMagnifierUpdate = now
        magnifierView.update(
            snapshot: snapshot,
            imageScale: imageScale,
            pointInView: mouseLocal,
            viewBounds: bounds,
            screenOrigin: targetScreen.frame.origin
        )
        // 位置：光标右下
        let size = magnifierView.bounds.size
        var origin = NSPoint(x: mouseLocal.x + 16, y: mouseLocal.y - size.height - 16)
        if origin.x + size.width > bounds.maxX { origin.x = mouseLocal.x - size.width - 16 }
        if origin.y < 0 { origin.y = mouseLocal.y + 16 }
        magnifierView.setFrameOrigin(origin)
        bringMagnifierToFront()
    }

    private func normalized(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }

    // MARK: - Commit

    private func commitSelection(_ localRect: NSRect) {
        guard localRect.width >= 4, localRect.height >= 4 else { return }
        lockedRect = localRect
        helpHint.isHidden = true

        if let cropped = cropSnapshot(localRect) {
            croppedCG = cropped
            croppedNS = NSImage(
                cgImage: cropped,
                size: NSSize(
                    width: CGFloat(cropped.width) / max(imageScale, 1),
                    height: CGFloat(cropped.height) / max(imageScale, 1)
                )
            )
            annotateCanvas.baseImage = croppedNS
        } else {
            NSLog("[SnapFlow] crop failed")
        }

        // OCR 专用：框选完直接出结果，不进标注工具栏
        if purpose == .ocrImmediate {
            guard !didFinish else { return }
            applyOverlay()
            guard let result = makeResult(action: .ocr) else {
                didFinish = true
                onFinish(nil)
                return
            }
            didFinish = true
            onFinish(result)
            return
        }

        mode = .review
        annotateCanvas.clearAll()
        // 默认不选编辑工具：可自由拖/拉截图框
        currentAnnotateTool = .none
        annotateCanvas.tool = .none
        toolbar.setSelectedTool(.none, notify: false)
        optionsBar.isHidden = true
        annotateCanvas.isHidden = true
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)

        applyOverlay()
        updateCursor(at: mouseLocal)
        addSubview(annotateCanvas, positioned: .above, relativeTo: nil)
        addSubview(optionsBar, positioned: .above, relativeTo: nil)
        addSubview(toolbar, positioned: .above, relativeTo: nil)
        addSubview(actionToolbar, positioned: .above, relativeTo: nil)
        // 框选完成后仍停留在截图会话，后续可直接选择标注工具进行二次编辑。
        keepCaptureWindowFocused(preferredResponder: self)
    }

    private func cropSnapshot(_ localRect: NSRect) -> CGImage? {
        guard let snapshot else { return nil }
        let s = imageScale
        let px = localRect.minX * s
        let py = (bounds.height - localRect.maxY) * s
        let pw = localRect.width * s
        let ph = localRect.height * s
        let rect = CGRect(x: px, y: py, width: pw, height: ph).integral
        let full = CGRect(x: 0, y: 0, width: snapshot.width, height: snapshot.height)
        return snapshot.cropping(to: rect.intersection(full))
    }

    private func makeResult(action: SnipAction) -> SnipResult? {
        guard let local = lockedRect else { return nil }

        // 合成标注后的图；无标注则用原裁剪图
        let finalNS: NSImage
        let finalCG: CGImage
        if let composed = annotateCanvas.compositeImage(),
           let cg = annotateCanvas.compositeCGImage()
        {
            finalNS = composed
            finalCG = cg
        } else if let ns = croppedNS, let cg = croppedCG {
            finalNS = ns
            finalCG = cg
        } else {
            return nil
        }

        let origin = targetScreen.frame.origin
        let global = CGRect(
            x: origin.x + local.minX,
            y: origin.y + local.minY,
            width: local.width,
            height: local.height
        )
        let region = CaptureRegion(
            rectInScreenPoints: global,
            displayID: ScreenGeometry.displayID(for: targetScreen),
            scaleFactor: imageScale
        )
        return SnipResult(region: region, image: finalNS, cgImage: finalCG, action: action)
    }

    private func handleToolbar(_ action: SnipAction) {
        guard !didFinish else { return }
        NSLog("[SnapFlow] toolbar action: \(action.rawValue)")
        if action == .cancelled {
            didFinish = true
            onFinish(nil)
            return
        }
        if action == .scrollCapture {
            guard scrollCaptureTask == nil else { return }
            scrollCaptureTask = Task { @MainActor in
                await self.runScrollCapture()
            }
            return
        }
        guard let result = makeResult(action: action) else {
            NSLog("[SnapFlow] makeResult failed — no image")
            didFinish = true
            onFinish(nil)
            return
        }
        didFinish = true
        onFinish(result)
    }

    // MARK: - 滚动截屏

    private func runScrollCapture() async {
        guard !didFinish, let local = lockedRect else { return }
        guard local.width >= 8, local.height >= 8 else { return }

        let origin = targetScreen.frame.origin
        let global = CGRect(
            x: origin.x + local.minX,
            y: origin.y + local.minY,
            width: local.width,
            height: local.height
        )
        let region = CaptureRegion(
            rectInScreenPoints: global,
            displayID: ScreenGeometry.displayID(for: targetScreen),
            scaleFactor: targetScreen.backingScaleFactor
        )

        RegionSelectorController.setSnipWindowsPassThroughForScroll(true)

        let engine = ScrollCaptureEngine(region: region)
        let hud = ScrollCaptureControlPanel()
        scrollCaptureEngine = engine
        scrollCapturePanel = hud
        hud.present(near: region, engine: engine)

        do {
            let cg = try await engine.run { progress in
                hud.update(progress)
            }
            hud.markCaptureFinished()
            guard let action = await hud.waitForAction(), !hud.wasCancelled else {
                cancelScrollCaptureSession(hud: hud)
                return
            }
            let finalRegion = hud.captureRegion ?? region

            let ns = NSImage(
                cgImage: cg,
                size: NSSize(
                    width: CGFloat(cg.width) / finalRegion.scaleFactor,
                    height: CGFloat(cg.height) / finalRegion.scaleFactor
                )
            )
            // 区域高度改为整张长图对应的逻辑高度（贴图用）。
            let tallRegion = CaptureRegion(
                rectInScreenPoints: CGRect(
                    x: finalRegion.rectInScreenPoints.minX,
                    y: finalRegion.rectInScreenPoints.maxY - CGFloat(cg.height) / finalRegion.scaleFactor,
                    width: finalRegion.rectInScreenPoints.width,
                    height: CGFloat(cg.height) / finalRegion.scaleFactor
                ),
                displayID: finalRegion.displayID,
                scaleFactor: finalRegion.scaleFactor
            )
            guard !didFinish else { return }
            cleanupScrollCapture(hud: hud, restoreSelection: false)
            didFinish = true
            onFinish(SnipResult(region: tallRegion, image: ns, cgImage: cg, action: action))
        } catch is CancellationError {
            cancelScrollCaptureSession(hud: hud)
        } catch let error as ScrollCaptureError where error == .cancelled {
            cancelScrollCaptureSession(hud: hud)
        } catch {
            NSLog("[SnapFlow] scroll capture failed: \(error)")
            FeedbackCenter.shared.post(
                scrollCaptureFailureMessage(for: error),
                level: .error,
                duration: 3
            )
            cleanupScrollCapture(hud: hud, restoreSelection: true)
        }
    }

    private func scrollCaptureFailureMessage(for error: Error) -> String {
        if let error = error as? ScreenCaptureError {
            switch error {
            case .noDisplay:
                return L10n.string("滚动截图失败：未找到可用显示器。请确认目标窗口仍在当前屏幕上。")
            case .invalidRegion:
                return L10n.string("滚动截图失败：采集区域无效。请重新框选区域后再试。")
            case .timeout:
                return L10n.string("滚动截图失败：屏幕采集超时。请检查屏幕录制权限，并稍后重试。")
            case .captureFailed:
                return L10n.string("滚动截图失败：无法读取屏幕画面。请开启屏幕录制权限，并保持窗口和选区大小不变。")
            }
        }
        if let error = error as? ScrollCaptureError {
            switch error {
            case .captureFailed:
                return L10n.string("滚动截图失败：无法继续拼接。请保持窗口和选区大小不变，并放慢滚动速度后重试。")
            case .empty:
                return L10n.string("滚动截图失败：没有采集到有效画面。请重新选择区域后重试。")
            case .cancelled:
                return L10n.string("滚动截图已取消。")
            }
        }
        return L10n.string("滚动截图失败：当前画面无法继续处理。请保持窗口稳定、放慢滚动速度并重试。")
    }

    func cancelActiveScrollCapture() {
        scrollCaptureEngine?.requestCancel()
        scrollCaptureTask?.cancel()
        scrollCapturePanel?.dismiss()
        scrollCaptureEngine = nil
        scrollCaptureTask = nil
        scrollCapturePanel = nil
    }

    private func cleanupScrollCapture(
        hud: ScrollCaptureControlPanel,
        restoreSelection: Bool
    ) {
        hud.dismiss()
        if scrollCapturePanel === hud {
            scrollCapturePanel = nil
            scrollCaptureEngine = nil
            scrollCaptureTask = nil
        }
        if restoreSelection {
            RegionSelectorController.setSnipWindowsPassThroughForScroll(false)
        }
    }

    private func cancelScrollCaptureSession(hud: ScrollCaptureControlPanel) {
        cleanupScrollCapture(hud: hud, restoreSelection: false)
        guard !didFinish else { return }
        didFinish = true
        onFinish(nil)
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        MainThreadWatchdog.shared.noteMainAlive()
        mouseLocal = convert(event.locationInWindow, from: nil)
        updateCursor(at: mouseLocal)
        switch mode {
        case .detecting:
            updateHoverWindow(at: mouseLocal)
            applyOverlay()
        case .pressPending, .dragging, .review, .resizing:
            // review 时也要随鼠标进出选区切换放大镜
            applyOverlay()
        }
    }

    private func updateHoverWindow(at local: NSPoint) {
        let global = NSPoint(
            x: targetScreen.frame.minX + local.x,
            y: targetScreen.frame.minY + local.y
        )
        if detectionMode == .element {
            hoverElement = ElementHitTester.hitTest(point: global)
            hoverWindow = nil
        } else {
            hoverWindow = WindowHitTester.hitTest(point: global, windows: windowsProvider())
            hoverElement = nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        mouseLocal = loc

        // review：边缘拉伸 / 内部移动（无编辑工具时）/ 或交给 canvas
        if mode == .review, let rect = lockedRect {
            let edge = hitResizeEdge(loc, rect: rect)
            if edge != .none {
                mode = .resizing
                resizeEdge = edge
                resizeStartRect = rect
                resizeStartMouse = loc
                isMovingSelection = false
                updateCursor(at: loc)
                return
            }
            // 无编辑工具：拖动内部移动整框
            if (currentAnnotateTool == .none || !currentAnnotateTool.isDrawable), rect.contains(loc) {
                isMovingSelection = true
                moveStartMouse = loc
                moveStartRect = rect
                applyCursor(.closedHand, token: "closedHand")
                return
            }
            return
        }
        if mode == .resizing { return }

        guard mode == .detecting else { return }

        updateHoverWindow(at: loc)
        pressedWindow = hoverWindow
        pressedElement = hoverElement
        dragStart = loc
        dragCurrent = loc
        mode = .pressPending
        applyOverlay()
    }

    override func mouseDragged(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        mouseLocal = loc
        dragCurrent = loc

        if mode == .resizing {
            applyResize(to: loc)
            updateCursor(at: loc)
            return
        }
        if isMovingSelection {
            applyMove(to: loc)
            return
        }

        if mode == .pressPending, let s = dragStart {
            if hypot(loc.x - s.x, loc.y - s.y) >= dragThreshold {
                mode = .dragging
                pressedWindow = nil
                pressedElement = nil
                hoverWindow = nil
                hoverElement = nil
            }
            applyOverlay()
            return
        }
        if mode == .dragging {
            applyOverlay()
        }
    }

    private func resetToDetecting() {
        mode = .detecting
        dragStart = nil
        dragCurrent = nil
        pressedWindow = nil
        updateHoverWindow(at: mouseLocal)
        applyOverlay()
    }

    override func keyDown(with event: NSEvent) {
        if settings.matches(.captureCancel, event: event) {
            didFinish = true
            onFinish(nil)
            return
        }

        // Snipaste 成功输出快捷键（review）
        if mode == .review {
            if settings.matches(.captureQuickSave, event: event) {
                handleToolbar(.quickSave)
                return
            }
            if settings.matches(.captureCopy, event: event) { handleToolbar(.copy); return }
            if settings.matches(.captureSave, event: event) { handleToolbar(.save); return }
            if settings.matches(.capturePin, event: event) { handleToolbar(.pin); return }
            if settings.matches(.captureClearAnnotations, event: event) { annotateCanvas.clearAll(); return }
            if settings.matches(.captureUndo, event: event) { annotateCanvas.undo(); return }
            if settings.matches(.captureRedo, event: event) { annotateCanvas.redo(); return }
            if settings.matches(.captureConfirm, event: event) {
                if TextInputSession.isComposing(in: window) || TextInputSession.isEditing(in: window) {
                    super.keyDown(with: event)
                    return
                }
                handleToolbar(.copy)
                return
            }
            if settings.matches(.captureToggleToolbar, event: event) {
                toolbar.isHidden.toggle()
                actionToolbar.isHidden = toolbar.isHidden
                optionsBar.isHidden = toolbar.isHidden || currentAnnotateTool == .none
                return
            }
            if settings.matches(.captureToggleMagnifier, event: event) {
                toggleMagnifierByShortcut()
                return
            }
            if settings.matches(.captureCopyAlternateColor, event: event) {
                copyColorUnderCursor(shift: true)
                return
            }
            if settings.matches(.captureCopyColor, event: event) {
                copyColorUnderCursor(shift: false)
                return
            }
            if adjustLockedSelection(with: event) { return }
            super.keyDown(with: event)
            return
        }

        // Tab 切换窗口检测 / 元素检测
        if settings.matches(.captureToggleDetection, event: event) {
            detectionMode = detectionMode == .window ? .element : .window
            if detectionMode == .element, !AXIsProcessTrusted() {
                // 提示一次
                NSLog(L10n.string("[SnapFlow] 元素检测需要辅助功能权限"))
            }
            updateHelpText()
            updateHoverWindow(at: mouseLocal)
            applyOverlay()
            return
        }

        // —— 选区阶段 ——
        // Ctrl+A 全屏
        if settings.matches(.captureSelectAll, event: event) {
            commitSelection(bounds.insetBy(dx: 0, dy: 0))
            return
        }
        // R 上次成功区域
        if settings.matches(.captureRestoreRegion, event: event),
           let last = SnipHistoryStore.shared.lastSuccessfulRegion
        {
            if let local = intersectRegion(last) {
                commitSelection(local)
            }
            return
        }
        // , . 历史回放（贴回历史图为预览选区）
        if settings.matches(.capturePreviousHistory, event: event) {
            if let rec = SnipHistoryStore.shared.previous() {
                applyHistoryRecord(rec)
            }
            return
        }
        if settings.matches(.captureNextHistory, event: event) {
            if let rec = SnipHistoryStore.shared.next() {
                applyHistoryRecord(rec)
            } else {
                // 回到实时
                hoverWindow = nil
                applyOverlay()
            }
            return
        }
        // WASD 移动光标 1px
        var dx: CGFloat = 0, dy: CGFloat = 0
        if settings.matches(.captureCursorLeft, event: event) { dx = -1 }
        if settings.matches(.captureCursorRight, event: event) { dx = 1 }
        if settings.matches(.captureCursorDown, event: event) { dy = -1 }
        if settings.matches(.captureCursorUp, event: event) { dy = 1 }
        if dx != 0 || dy != 0 {
            mouseLocal.x = min(max(0, mouseLocal.x + dx), bounds.width)
            mouseLocal.y = min(max(0, mouseLocal.y + dy), bounds.height)
            // 同步系统光标（近似）
            if let win = window {
                let screenPt = win.convertPoint(toScreen: NSPoint(x: mouseLocal.x, y: mouseLocal.y))
                CGWarpMouseCursorPosition(CGPoint(x: screenPt.x, y: NSHeight(NSScreen.screens[0].frame) - screenPt.y))
            }
            updateHoverWindow(at: mouseLocal)
            applyOverlay()
            return
        }
        // 方向键微调选区（在 pressPending/dragging 时）
        if dragStart != nil, let c = dragCurrent, mode == .dragging || mode == .pressPending {
            var nc = c
            let step: CGFloat = 1
            if settings.matches(.captureExpandUp, event: event) {
                nc.y += step
            } else if settings.matches(.captureExpandDown, event: event) {
                nc.y -= step
            } else if settings.matches(.captureExpandLeft, event: event) {
                nc.x -= step
            } else if settings.matches(.captureExpandRight, event: event) {
                nc.x += step
            } else if settings.matches(.captureShrinkUp, event: event) {
                nc.y -= step
            } else if settings.matches(.captureShrinkDown, event: event) {
                nc.y += step
            } else if settings.matches(.captureShrinkLeft, event: event) {
                nc.x += step
            } else if settings.matches(.captureShrinkRight, event: event) {
                nc.x -= step
            } else {
                // 扩大
                if settings.matches(.captureMoveUp, event: event) { nc.y += step; dragStart?.y += step }
                else if settings.matches(.captureMoveDown, event: event) { nc.y -= step; dragStart?.y -= step }
                else if settings.matches(.captureMoveLeft, event: event) { nc.x -= step; dragStart?.x -= step }
                else if settings.matches(.captureMoveRight, event: event) { nc.x += step; dragStart?.x += step }
                else { super.keyDown(with: event); return }
            }
            dragCurrent = nc
            applyOverlay()
            return
        }
        // 放大镜显隐
        if settings.matches(.captureToggleMagnifier, event: event) {
            toggleMagnifierByShortcut()
            return
        }
        // C 取色（快捷键复制，非鼠标点击）
        if settings.matches(.captureCopyAlternateColor, event: event) {
            copyColorUnderCursor(shift: true)
            return
        }
        if settings.matches(.captureCopyColor, event: event) {
            copyColorUnderCursor(shift: false)
            return
        }
        super.keyDown(with: event)
    }

    private func adjustLockedSelection(with event: NSEvent) -> Bool {
        guard var rect = lockedRect else { return false }
        let step: CGFloat = 1

        if settings.matches(.captureMoveUp, event: event) { rect.origin.y += step }
        else if settings.matches(.captureMoveDown, event: event) { rect.origin.y -= step }
        else if settings.matches(.captureMoveLeft, event: event) { rect.origin.x -= step }
        else if settings.matches(.captureMoveRight, event: event) { rect.origin.x += step }
        else if settings.matches(.captureExpandUp, event: event) { rect.size.height += step }
        else if settings.matches(.captureExpandDown, event: event) {
            rect.origin.y -= step
            rect.size.height += step
        } else if settings.matches(.captureExpandLeft, event: event) {
            rect.origin.x -= step
            rect.size.width += step
        } else if settings.matches(.captureExpandRight, event: event) {
            rect.size.width += step
        } else if settings.matches(.captureShrinkUp, event: event), rect.height > 8 {
            rect.size.height -= step
        } else if settings.matches(.captureShrinkDown, event: event), rect.height > 8 {
            rect.origin.y += step
            rect.size.height -= step
        } else if settings.matches(.captureShrinkLeft, event: event), rect.width > 8 {
            rect.origin.x += step
            rect.size.width -= step
        } else if settings.matches(.captureShrinkRight, event: event), rect.width > 8 {
            rect.size.width -= step
        } else {
            return false
        }

        rect.size.width = min(rect.width, bounds.width)
        rect.size.height = min(rect.height, bounds.height)
        rect.origin.x = min(max(bounds.minX, rect.origin.x), bounds.maxX - rect.width)
        rect.origin.y = min(max(bounds.minY, rect.origin.y), bounds.maxY - rect.height)
        lockedRect = rect
        finishResize()
        return true
    }

    override func mouseUp(with event: NSEvent) {
        let end = convert(event.locationInWindow, from: nil)
        mouseLocal = end
        dragCurrent = end

        if mode == .resizing {
            finishResize()
            updateCursor(at: end)
            return
        }
        if isMovingSelection {
            isMovingSelection = false
            moveStartMouse = nil
            moveStartRect = nil
            // 移动后重裁剪
            finishResize()
            updateCursor(at: end)
            return
        }

        // 双击选区 → 复制（review）
        if mode == .review, event.clickCount >= 2, let rect = lockedRect {
            if rect.contains(end) {
                handleToolbar(.copy)
                return
            }
        }

        switch mode {
        case .pressPending:
            if detectionMode == .element,
               let el = pressedElement,
               let local = localFrame(global: el.frame)
            {
                commitSelection(local)
            } else if let win = pressedWindow,
                      let local = WindowHitTester.localFrame(of: win, on: targetScreen)
            {
                commitSelection(local)
            } else {
                resetToDetecting()
            }
        case .dragging:
            guard let s = dragStart else {
                resetToDetecting()
                return
            }
            let rect = normalized(s, end)
            if rect.width >= 4, rect.height >= 4 {
                commitSelection(rect)
            } else {
                resetToDetecting()
            }
        default:
            break
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        // 非编辑：右键取消；review 且无绘制：取消
        if mode == .review {
            // 右键结束当前绘制手感 → 这里取消会话
            didFinish = true
            onFinish(nil)
            return
        }
        didFinish = true
        onFinish(nil)
    }

    override func otherMouseDown(with event: NSEvent) {
        // 中键：直接钉图（需已有选区）
        if event.buttonNumber == 2 {
            if mode == .review {
                handleToolbar(.pin)
            }
        }
    }

    private func intersectRegion(_ region: CaptureRegion) -> NSRect? {
        let global = region.rectInScreenPoints
        let inter = global.intersection(targetScreen.frame)
        guard inter.width > 4, inter.height > 4 else { return nil }
        return NSRect(
            x: inter.minX - targetScreen.frame.minX,
            y: inter.minY - targetScreen.frame.minY,
            width: inter.width,
            height: inter.height
        )
    }

    private func applyHistoryRecord(_ rec: SnipHistoryStore.Record) {
        if let local = intersectRegion(rec.captureRegion) {
            // 用历史图替换背景局部不强制，直接 commit 历史区域
            commitSelection(local)
            if let img = SnipHistoryStore.shared.loadImage(for: rec) {
                croppedNS = img
                annotateCanvas.baseImage = img
                var rect = CGRect(origin: .zero, size: img.size)
                if let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                    croppedCG = cg
                }
            }
        }
    }

    private func copyColorUnderCursor(shift: Bool) {
        guard let rgb = MagnifierView.sampleRGB(
            snapshot: snapshot,
            imageScale: imageScale,
            pointInView: mouseLocal,
            viewBounds: bounds
        ) else { return }
        let text = shift
            ? "rgb(\(rgb.r), \(rgb.g), \(rgb.b))"
            : String(format: "#%02X%02X%02X", rgb.r, rgb.g, rgb.b)
        copyColorString(text)
        // 与放大镜展示同步反馈
        if !magnifierView.isHidden {
            magnifierView.flashCopied()
        }
    }

    private func copyColorString(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    override func cancelOperation(_ sender: Any?) {
        didFinish = true
        onFinish(nil)
    }
}

// MARK: - Overlay（仅画遮罩与描边，极轻）

@MainActor
private final class SelectionOverlayView: NSView {
    var activeRect: NSRect? {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
        // 透明背景，只画叠加
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // 不 clear 成不透明，用 dim 镂空
        if let rect = activeRect, rect.width > 0.5, rect.height > 0.5 {
            let path = NSBezierPath(rect: bounds)
            path.append(NSBezierPath(rect: rect))
            path.windingRule = .evenOdd
            SnipStyle.dim.setFill()
            path.fill()

            SnipStyle.stroke.setStroke()
            let border = NSBezierPath(rect: rect)
            border.lineWidth = SnipStyle.borderWidth
            border.stroke()

            // 把手
            let hs = SnipStyle.handleSize
            let pts: [NSPoint] = [
                .init(x: rect.minX, y: rect.minY),
                .init(x: rect.midX, y: rect.minY),
                .init(x: rect.maxX, y: rect.minY),
                .init(x: rect.minX, y: rect.midY),
                .init(x: rect.maxX, y: rect.midY),
                .init(x: rect.minX, y: rect.maxY),
                .init(x: rect.midX, y: rect.maxY),
                .init(x: rect.maxX, y: rect.maxY),
            ]
            for p in pts {
                let r = NSRect(x: p.x - hs / 2, y: p.y - hs / 2, width: hs, height: hs)
                let circle = NSBezierPath(ovalIn: r)
                SnipStyle.handleFill.setFill()
                circle.fill()
                SnipStyle.stroke.setStroke()
                circle.lineWidth = 1.2
                circle.stroke()
            }

            // 尺寸
            let text = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded())) pt"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: SnipStyle.labelFG,
            ]
            let size = (text as NSString).size(withAttributes: attrs)
            let pad: CGFloat = 5
            var ox = rect.minX
            var oy = rect.maxY + 4
            if oy + size.height + pad > bounds.maxY {
                oy = rect.maxY - size.height - pad - 2
            }
            let bg = NSRect(x: ox, y: oy, width: size.width + pad * 2, height: size.height + pad)
            SnipStyle.labelBG.setFill()
            NSBezierPath(roundedRect: bg, xRadius: 3, yRadius: 3).fill()
            (text as NSString).draw(at: NSPoint(x: ox + pad, y: oy + pad / 2), withAttributes: attrs)
        } else {
            SnipStyle.dim.setFill()
            bounds.fill()
        }
    }
}

// MARK: - Magnifier（独立视图，节流更新）

@MainActor
private final class MagnifierView: NSView {
    static let preferredSize = NSSize(width: 108, height: 148)

    private let imageSide: CGFloat = 96
    private let imageView = NSImageView()
    private let crosshairView = MagnifierCrosshairView()
    private let coordLabel = NSTextField(labelWithString: "")
    private let colorSwatch = NSView()
    private let colorLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: L10n.string("C 复制"))
    private var currentHex: String = ""
    private var flashTask: Task<Void, Never>?
    private var copyHintText = L10n.string("C 复制")
    private var idleHintText = L10n.string("C 复制 · M 显隐")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.88).cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = SnipStyle.stroke.cgColor
        // 不拦截鼠标，事件穿透到下层选区/工具栏
        layer?.zPosition = 50

        let pad: CGFloat = 6
        let imageFrame = NSRect(x: pad, y: 44, width: imageSide, height: imageSide)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.frame = imageFrame
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 3
        imageView.layer?.masksToBounds = true
        addSubview(imageView)

        // 十字线叠在放大图上：中心 = 鼠标像素
        crosshairView.frame = imageFrame
        crosshairView.wantsLayer = false
        addSubview(crosshairView)

        coordLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        coordLabel.textColor = NSColor.white.withAlphaComponent(0.9)
        coordLabel.alignment = .center
        coordLabel.isBordered = false
        coordLabel.drawsBackground = false
        coordLabel.frame = NSRect(x: pad, y: 28, width: imageSide, height: 14)
        addSubview(coordLabel)

        // 颜色行：色块 + HEX（复制走快捷键 C，不可点击）
        let swatchSize: CGFloat = 12
        colorSwatch.wantsLayer = true
        colorSwatch.layer?.cornerRadius = 2
        colorSwatch.layer?.borderWidth = 1
        colorSwatch.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        colorSwatch.frame = NSRect(x: pad + 4, y: 10, width: swatchSize, height: swatchSize)
        addSubview(colorSwatch)

        colorLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        colorLabel.textColor = .white
        colorLabel.alignment = .left
        colorLabel.isBordered = false
        colorLabel.drawsBackground = false
        colorLabel.frame = NSRect(x: pad + 4 + swatchSize + 6, y: 8, width: 58, height: 16)
        addSubview(colorLabel)

        hintLabel.font = .systemFont(ofSize: 8, weight: .medium)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.45)
        hintLabel.alignment = .right
        hintLabel.isBordered = false
        hintLabel.drawsBackground = false
        hintLabel.frame = NSRect(x: pad, y: 2, width: imageSide, height: 10)
        addSubview(hintLabel)

        toolTip = L10n.string("C 复制颜色 · M 显示/隐藏放大镜")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 事件穿透，不挡住下方工具栏/选区
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setShortcutHints(copyLabel: String, toggleLabel: String) {
        let copy = copyLabel.isEmpty ? "C" : copyLabel
        let toggle = toggleLabel.isEmpty ? "M" : toggleLabel
        copyHintText = String(format: L10n.string("%@ 复制"), copy)
        idleHintText = String(format: L10n.string("%@ 复制 · %@ 显隐"), copy, toggle)
        hintLabel.stringValue = idleHintText
        toolTip = String(format: L10n.string("%@ 复制颜色 · %@ 显示/隐藏放大镜"), copy, toggle)
    }

    func flashCopied() {
        flashTask?.cancel()
        hintLabel.stringValue = L10n.string("已复制")
        hintLabel.textColor = SnipStyle.stroke
        flashTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self.hintLabel.stringValue = self.idleHintText
            self.hintLabel.textColor = NSColor.white.withAlphaComponent(0.45)
        }
    }

    func update(
        snapshot: CGImage?,
        imageScale: CGFloat,
        pointInView: NSPoint,
        viewBounds: NSRect,
        screenOrigin: CGPoint
    ) {
        guard let snapshot else {
            imageView.image = nil
            coordLabel.stringValue = "—"
            colorLabel.stringValue = "—"
            currentHex = ""
            colorSwatch.layer?.backgroundColor = NSColor.darkGray.cgColor
            return
        }
        let srcSide: CGFloat = 12
        let s = imageScale
        let px = pointInView.x * s
        let py = (viewBounds.height - pointInView.y) * s
        let half = srcSide * s / 2
        let src = CGRect(x: px - half, y: py - half, width: srcSide * s, height: srcSide * s).integral
        let full = CGRect(x: 0, y: 0, width: snapshot.width, height: snapshot.height)
        guard let cropped = snapshot.cropping(to: src.intersection(full)) else { return }
        imageView.image = NSImage(cgImage: cropped, size: NSSize(width: imageSide, height: imageSide))

        let gx = screenOrigin.x + pointInView.x
        let gy = screenOrigin.y + pointInView.y
        coordLabel.stringValue = String(format: "%.0f, %.0f", gx, gy)

        if let rgb = Self.sampleRGB(
            snapshot: snapshot,
            imageScale: imageScale,
            pointInView: pointInView,
            viewBounds: viewBounds
        ) {
            let hex = String(format: "#%02X%02X%02X", rgb.r, rgb.g, rgb.b)
            currentHex = hex
            colorLabel.stringValue = hex
            colorSwatch.layer?.backgroundColor = NSColor(
                srgbRed: CGFloat(rgb.r) / 255,
                green: CGFloat(rgb.g) / 255,
                blue: CGFloat(rgb.b) / 255,
                alpha: 1
            ).cgColor
        } else {
            currentHex = ""
            colorLabel.stringValue = "—"
            colorSwatch.layer?.backgroundColor = NSColor.darkGray.cgColor
        }
        crosshairView.needsDisplay = true
    }

    /// 从冻屏位图采样指针处 RGB（sRGB 近似）
    static func sampleRGB(
        snapshot: CGImage?,
        imageScale: CGFloat,
        pointInView: NSPoint,
        viewBounds: NSRect
    ) -> (r: Int, g: Int, b: Int)? {
        guard let snapshot else { return nil }
        let s = max(imageScale, 0.001)
        let x = Int((pointInView.x * s).rounded(.down))
        let y = Int(((viewBounds.height - pointInView.y) * s).rounded(.down))
        guard x >= 0, y >= 0, x < snapshot.width, y < snapshot.height else { return nil }
        // 1×1 裁剪 + BitmapRep，避免手算 BGRA/RGBA 字节序
        guard let pixel = snapshot.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        let rep = NSBitmapImageRep(cgImage: pixel)
        guard let color = rep.colorAt(x: 0, y: 0) else { return nil }
        let converted = color.usingColorSpace(.sRGB) ?? color.usingColorSpace(.deviceRGB) ?? color
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        converted.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (
            r: min(255, max(0, Int((r * 255).rounded()))),
            g: min(255, max(0, Int((g * 255).rounded()))),
            b: min(255, max(0, Int((b * 255).rounded())))
        )
    }
}

/// 放大镜预览区十字准星：水平/垂直中线各一条半透明蓝线，交点为鼠标位置（预览中心）
@MainActor
private final class MagnifierCrosshairView: NSView {
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        // 半透明蓝色十字；交点即放大中心 = 鼠标下像素
        let color = SnipStyle.stroke.withAlphaComponent(0.55)
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: NSPoint(x: bounds.midX, y: 0))
        path.line(to: NSPoint(x: bounds.midX, y: bounds.maxY))
        path.move(to: NSPoint(x: 0, y: bounds.midY))
        path.line(to: NSPoint(x: bounds.maxX, y: bounds.midY))
        path.stroke()

        // 中心小点，方便对准
        let dotR: CGFloat = 1.5
        let dot = NSRect(
            x: bounds.midX - dotR,
            y: bounds.midY - dotR,
            width: dotR * 2,
            height: dotR * 2
        )
        SnipStyle.stroke.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: dot).fill()
    }
}
