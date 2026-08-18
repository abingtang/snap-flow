import AppKit

struct ScrollCapturePanelLayout {
    let toolbar: CGRect
    let preview: CGRect

    static func make(region: CGRect, visibleScreen: CGRect) -> Self {
        let toolbarSize = CGSize(width: 150, height: 32)
        let previewSize = CGSize(width: 148, height: min(max(region.height, 180), 420))

        var toolbarOrigin = CGPoint(
            x: region.maxX - toolbarSize.width,
            y: region.minY - toolbarSize.height - 8
        )
        if toolbarOrigin.y < visibleScreen.minY + 6 {
            toolbarOrigin.y = region.maxY + 8
        }
        toolbarOrigin.x = min(
            max(visibleScreen.minX + 6, toolbarOrigin.x),
            visibleScreen.maxX - toolbarSize.width - 6
        )

        var previewOrigin = CGPoint(
            x: region.maxX + 10,
            y: region.maxY - previewSize.height
        )
        if previewOrigin.x + previewSize.width > visibleScreen.maxX - 6 {
            previewOrigin.x = region.minX - previewSize.width - 10
        }
        previewOrigin.x = min(
            max(visibleScreen.minX + 6, previewOrigin.x),
            visibleScreen.maxX - previewSize.width - 6
        )
        previewOrigin.y = min(
            max(visibleScreen.minY + 6, previewOrigin.y),
            visibleScreen.maxY - previewSize.height - 6
        )

        return Self(
            toolbar: CGRect(origin: toolbarOrigin, size: toolbarSize),
            preview: CGRect(origin: previewOrigin, size: previewSize)
        )
    }
}

/// 滚动截屏交互层：底部图标栏与右侧实时缩略图。
@MainActor
final class ScrollCaptureControlPanel {
    private var toolbarPanel: NSPanel?
    private var previewPanel: NSPanel?
    private var previewView: ScrollCapturePreviewView?
    private weak var toolbarView: ScrollCaptureToolbarView?
    private var engine: ScrollCaptureEngine?
    private var currentRegion: CaptureRegion?
    private var actionContinuation: CheckedContinuation<SnipAction?, Never>?
    private var autoScrollTask: Task<Void, Never>?
    private var isAutoScrolling = false
    private(set) var completionAction: SnipAction?
    private(set) var wasCancelled = false
    var captureRegion: CaptureRegion? { currentRegion }

    func present(near region: CaptureRegion, engine: ScrollCaptureEngine) {
        dismissUIOnly()
        self.engine = engine
        currentRegion = region
        completionAction = nil
        wasCancelled = false

        let toolbar = ScrollCaptureToolbarView(frame: CGRect(x: 0, y: 0, width: 150, height: 32))
        toolbar.onAutoScroll = { [weak self] in self?.toggleAutoScroll() }
        toolbar.onSave = { [weak self] in self?.complete(with: .save) }
        toolbar.onPin = { [weak self] in self?.complete(with: .pin) }
        toolbar.onCancel = { [weak self] in self?.cancel() }
        toolbar.onCopy = { [weak self] in self?.complete(with: .copy) }
        let toolbarPanel = makePanel(frame: .zero, interactive: true)
        toolbarPanel.hasShadow = true
        toolbarPanel.contentView = toolbar
        self.toolbarPanel = toolbarPanel
        toolbarView = toolbar

        let preview = ScrollCapturePreviewView()
        preview.setCapturing(true)
        previewView = preview
        let previewPanel = makePanel(frame: .zero, interactive: false)
        previewPanel.hasShadow = true
        previewPanel.contentView = preview
        self.previewPanel = previewPanel

        positionPanels()
        toolbarPanel.orderFrontRegardless()
        previewPanel.orderFrontRegardless()
    }

    func update(_ progress: ScrollCaptureEngine.Progress) {
        previewView?.update(
            image: progress.preview,
            viewportRatio: progress.viewportRatio,
            viewportOffset: progress.viewportOffset,
            matched: progress.matchSucceeded,
            failureMessage: progress.failureMessage
        )
    }

    func markCaptureFinished() {
        stopAutoScroll()
        previewView?.setCapturing(false)
        engine = nil
    }

    func waitForAction() async -> SnipAction? {
        if wasCancelled { return nil }
        if let completionAction { return completionAction }
        return await withCheckedContinuation { actionContinuation = $0 }
    }

    func dismissUIOnly() {
        stopAutoScroll()
        for panel in [toolbarPanel, previewPanel].compactMap({ $0 }) {
            panel.orderOut(nil)
            panel.close()
        }
        toolbarPanel = nil
        previewPanel = nil
        previewView = nil
        toolbarView = nil
    }

    func dismiss() {
        dismissUIOnly()
        engine = nil
        if let actionContinuation {
            actionContinuation.resume(returning: nil)
            self.actionContinuation = nil
        }
    }

    private func complete(with action: SnipAction) {
        guard completionAction == nil, !wasCancelled else { return }
        stopAutoScroll()
        completionAction = action
        engine?.requestStop()
        if let actionContinuation {
            actionContinuation.resume(returning: action)
            self.actionContinuation = nil
        }
    }

    private func cancel() {
        guard completionAction == nil, !wasCancelled else { return }
        stopAutoScroll()
        wasCancelled = true
        engine?.requestCancel()
        if let actionContinuation {
            actionContinuation.resume(returning: nil)
            self.actionContinuation = nil
        }
    }

    private func toggleAutoScroll() {
        if isAutoScrolling {
            stopAutoScroll()
            return
        }

        isAutoScrolling = true
        toolbarView?.setAutoScrolling(true)
        autoScrollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self, self.isAutoScrolling {
                Self.postScrollDown()
                do {
                    try await Task.sleep(for: .milliseconds(240))
                } catch {
                    return
                }
            }
        }
    }

    private func stopAutoScroll() {
        autoScrollTask?.cancel()
        autoScrollTask = nil
        guard isAutoScrolling else { return }
        isAutoScrolling = false
        toolbarView?.setAutoScrolling(false)
    }

    private static func postScrollDown() {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .line,
            wheelCount: 1,
            wheel1: -3,
            wheel2: 0,
            wheel3: 0
        ) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func positionPanels() {
        guard let currentRegion else { return }
        let screen = screenContaining(currentRegion.rectInScreenPoints) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? currentRegion.rectInScreenPoints
        let layout = ScrollCapturePanelLayout.make(
            region: currentRegion.rectInScreenPoints,
            visibleScreen: visible
        )
        toolbarPanel?.setFrame(layout.toolbar, display: true)
        previewPanel?.setFrame(layout.preview, display: true)
    }

    private func screenContaining(_ rect: CGRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(rect) }
    }

    private func makePanel(frame: CGRect, interactive: Bool) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 选区遮罩使用 .screenSaver；控制面板必须位于其上方才能可见。
        // ScrollCaptureSession 会排除当前应用窗口，不会把面板采集进滚动截图。
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = !interactive
        return panel
    }
}

@MainActor
private final class ScrollCaptureToolbarView: NSView {
    var onAutoScroll: (() -> Void)?
    var onSave: (() -> Void)?
    var onPin: (() -> Void)?
    var onCancel: (() -> Void)?
    var onCopy: (() -> Void)?
    private var autoScrollButton: SnipToolButton?
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = SnipStyle.toolbarBG.cgColor
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = AppTheme.nsCaptureBorder.cgColor

        stack.frame = bounds.insetBy(dx: 6, dy: 3)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.autoresizingMask = [.width, .height]
        addSubview(stack)

        let autoScrollButton = SnipToolButton(
            symbol: "arrow.down",
            tooltip: L10n.string("自动向下滚动"),
            size: 26
        ) { [weak self] in
            self?.onAutoScroll?()
        }
        self.autoScrollButton = autoScrollButton
        stack.addArrangedSubview(autoScrollButton)

        stack.addArrangedSubview(
            SnipToolButton(symbol: "square.and.arrow.down", tooltip: L10n.string("保存"), size: 26) { [weak self] in
                self?.onSave?()
            }
        )
        stack.addArrangedSubview(
            SnipToolButton(symbol: "pin.fill", tooltip: L10n.string("钉在屏幕上"), size: 26) { [weak self] in
                self?.onPin?()
            }
        )
        stack.addArrangedSubview(
            SnipToolButton(symbol: "xmark", tooltip: L10n.string("关闭"), size: 26) { [weak self] in
                self?.onCancel?()
            }
        )
        stack.addArrangedSubview(
            SnipToolButton(symbol: "doc.on.doc", tooltip: L10n.string("复制"), size: 26) { [weak self] in
                self?.onCopy?()
            }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setAutoScrolling(_ enabled: Bool) {
        autoScrollButton?.isSelected = enabled
        autoScrollButton?.toolTip = enabled ? L10n.string("停止自动滚动") : L10n.string("自动向下滚动")
    }

    override func layout() {
        super.layout()
        stack.frame = bounds.insetBy(dx: 6, dy: 3)
    }
}

@MainActor
private final class ScrollCapturePreviewView: NSView {
    private let directionHint = L10n.string("提示：只能向下滚动")
    private var image: CGImage?
    private var viewportRatio: Double = 1
    private var viewportOffset: Double = 0
    private var matched = true
    private var isCapturing = false
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.cornerRadius = 6

        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.isBordered = false
        statusLabel.drawsBackground = true
        statusLabel.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92)
        statusLabel.wantsLayer = true
        statusLabel.layer?.cornerRadius = 5
        statusLabel.stringValue = directionHint
        statusLabel.isHidden = false
        addSubview(statusLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setCapturing(_ capturing: Bool) {
        guard isCapturing != capturing else { return }
        isCapturing = capturing
        needsDisplay = true
    }

    func update(
        image: CGImage,
        viewportRatio: Double,
        viewportOffset: Double,
        matched: Bool,
        failureMessage: String?
    ) {
        self.image = image
        self.viewportRatio = min(max(viewportRatio, 0), 1)
        self.viewportOffset = min(max(viewportOffset, 0), 1)
        self.matched = matched
        statusLabel.stringValue = failureMessage ?? directionHint
        statusLabel.isHidden = false
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        statusLabel.frame = NSRect(
            x: 6,
            y: 6,
            width: max(bounds.width - 12, 0),
            height: statusLabel.isHidden ? 0 : 38
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if let image {
            let available = bounds.insetBy(dx: 7, dy: 7)
            let scale = min(
                available.width / CGFloat(image.width),
                available.height / CGFloat(image.height)
            )
            let imageRect = CGRect(
                x: bounds.midX - CGFloat(image.width) * scale / 2,
                y: bounds.midY - CGFloat(image.height) * scale / 2,
                width: CGFloat(image.width) * scale,
                height: CGFloat(image.height) * scale
            )
            context.interpolationQuality = .medium
            context.draw(image, in: imageRect)

        }

        let borderWidth: CGFloat = isCapturing ? 2.5 : 1
        let borderColor = isCapturing
            ? SnipStyle.stroke.withAlphaComponent(0.95)
            : NSColor.separatorColor.withAlphaComponent(0.55)
        context.setStrokeColor(borderColor.cgColor)
        context.setLineWidth(borderWidth)
        context.addPath(
            CGPath(
                roundedRect: bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2),
                cornerWidth: 6,
                cornerHeight: 6,
                transform: nil
            )
        )
        context.strokePath()
    }
}
