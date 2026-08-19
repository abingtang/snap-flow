import AppKit
import Foundation

@MainActor
enum RecordingPanelLayout {
    /// 与框选区域右下角对齐：优先贴在选区下方外侧，工具栏右缘与选区右缘对齐。
    static func hudFrame(
        for region: CGRect,
        screen: NSScreen?,
        size: NSSize
    ) -> NSRect {
        let visible = screen?.visibleFrame ?? region
        let gap: CGFloat = 8

        // 右对齐：HUD 右缘 = 选区右缘
        let rightAlignedX = region.maxX - size.width
        let candidates = [
            // 1. 选区下方（首选）
            NSRect(
                x: rightAlignedX,
                y: region.minY - size.height - gap,
                width: size.width,
                height: size.height
            ),
            // 2. 选区上方（下方放不下时）
            NSRect(
                x: rightAlignedX,
                y: region.maxY + gap,
                width: size.width,
                height: size.height
            ),
            // 3. 选区右下内侧上方一点（上下都越界时的兜底，仍贴右下）
            NSRect(
                x: rightAlignedX,
                y: region.minY + gap,
                width: size.width,
                height: size.height
            ),
        ]

        let preferred = candidates.first { candidate in
            visible.contains(NSPoint(x: candidate.midX, y: candidate.midY))
                || visible.intersects(candidate)
        } ?? candidates[0]

        let maxX = max(visible.minX, visible.maxX - size.width)
        let maxY = max(visible.minY, visible.maxY - size.height)
        return NSRect(
            x: min(max(preferred.minX, visible.minX), maxX),
            y: min(max(preferred.minY, visible.minY), maxY),
            width: size.width,
            height: size.height
        )
    }
}

@MainActor
final class RecordingMaskPanel: NSPanel {
    init(region: CGRect, screen: NSScreen) {
        let screenFrame = screen.frame
        super.init(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        ignoresMouseEvents = true

        let localRegion = region
            .offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
            .intersection(NSRect(origin: .zero, size: screenFrame.size))
        contentView = RecordingMaskView(selectionRect: localRegion)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class RecordingMaskView: NSView {
    private let selectionRect: NSRect

    init(selectionRect: NSRect) {
        self.selectionRect = selectionRect
        super.init(frame: .zero)
    }

    override func draw(_ dirtyRect: NSRect) {
        let mask = NSBezierPath(rect: bounds)
        if !selectionRect.isEmpty {
            mask.append(NSBezierPath(rect: selectionRect))
            mask.windingRule = .evenOdd
        }
        SnipStyle.dim.setFill()
        mask.fill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
final class RecordingBorderPanel: NSPanel {
    init(region: CGRect) {
        super.init(
            contentRect: region,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        contentView = RecordingBorderView()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class RecordingBorderView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderColor = SnipStyle.stroke.cgColor
        layer?.borderWidth = SnipStyle.borderWidth
        layer?.cornerRadius = 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
final class RecordingHUDPanel: NSPanel {
    var onPauseToggle: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onSystemAudioToggle: ((Bool) -> Void)?
    var onMicrophoneToggle: ((Bool) -> Void)?
    /// 选择输入设备；`nil` 表示系统默认。
    var onSelectMicrophoneDevice: ((String?) -> Void)?

    private let timeLabel = NSTextField(labelWithString: "00:00")
    private var controlsEnabled = false
    private var systemAudioEnabled = false
    private var microphoneEnabled = false
    private var microphoneDeviceUID: String?
    private lazy var pauseButton = SnipToolButton(symbol: "pause.fill", tooltip: L10n.string("暂停"), size: 26) { [weak self] in
        guard let self, self.controlsEnabled else { return }
        self.onPauseToggle?()
    }
    private lazy var stopButton = SnipToolButton(symbol: "stop.fill", tooltip: L10n.string("停止并保存"), size: 26) { [weak self] in
        guard let self, self.controlsEnabled else { return }
        self.onStop?()
    }
    private lazy var systemAudioButton = SnipToolButton(symbol: "speaker.slash", tooltip: L10n.string("开启系统声音"), size: 26) { [weak self] in
        guard let self, self.controlsEnabled else { return }
        self.onSystemAudioToggle?(!self.systemAudioEnabled)
    }
    private lazy var microphoneButton = SnipToolButton(symbol: "mic.slash", tooltip: L10n.string("开启麦克风"), size: 26) { [weak self] in
        guard let self, self.controlsEnabled else { return }
        self.onMicrophoneToggle?(!self.microphoneEnabled)
    }
    private lazy var cancelButton = SnipToolButton(symbol: "xmark", tooltip: L10n.string("取消录制"), size: 26) { [weak self] in
        guard let self, self.controlsEnabled else { return }
        self.onCancel?()
    }
    private var clockTimer: Timer?
    private var elapsedSeconds = 0
    private var isPaused = false
    private var controlsStack: NSStackView?

    private static let panelHeight: CGFloat = 34
    private static let horizontalPadding: CGFloat = 6
    private static let verticalPadding: CGFloat = 4

    init(region: CGRect, screen: NSScreen?) {
        super.init(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 200, height: Self.panelHeight)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false

        let container = RecordingHUDContainerView()
        container.panel = self
        contentView = container
        setupControls(in: container)
        let fitted = fittedPanelSize()
        setFrame(
            RecordingPanelLayout.hudFrame(
                for: region,
                screen: screen,
                size: fitted
            ),
            display: true
        )
        microphoneButton.contextMenuProvider = { [weak self] in
            self?.makeMicrophoneDeviceMenu() ?? NSMenu()
        }
        setControlsEnabled(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setControlsEnabled(_ enabled: Bool) {
        controlsEnabled = enabled
        [systemAudioButton, microphoneButton, pauseButton, stopButton, cancelButton].forEach {
            $0.alphaValue = enabled ? 1 : 0.45
        }
    }

    func configureSystemAudio(_ enabled: Bool) {
        systemAudioEnabled = enabled
        systemAudioButton.isSelected = enabled
        systemAudioButton.setSymbol(
            enabled ? "speaker.wave.2.fill" : "speaker.slash",
            accessibilityDescription: enabled ? L10n.string("关闭系统声音") : L10n.string("开启系统声音")
        )
        systemAudioButton.toolTip = enabled ? L10n.string("关闭系统声音") : L10n.string("开启系统声音")
    }

    func configureMicrophone(enabled: Bool, deviceUID: String?) {
        microphoneEnabled = enabled
        microphoneDeviceUID = deviceUID
        microphoneButton.isSelected = enabled
        microphoneButton.setSymbol(
            enabled ? "mic.fill" : "mic.slash",
            accessibilityDescription: enabled ? L10n.string("关闭麦克风") : L10n.string("开启麦克风")
        )
        microphoneButton.toolTip = microphoneTooltip(enabled: enabled)
    }

    private func microphoneTooltip(enabled: Bool) -> String {
        let base = enabled ? L10n.string("关闭麦克风") : L10n.string("开启麦克风")
        let deviceName = RecordingAudioInputDevices.displayName(forUID: microphoneDeviceUID)
            ?? L10n.string("系统默认")
        return String(format: L10n.string("%@ · 当前：%@ · 右键选择输入设备"), base, deviceName)
    }

    private func makeMicrophoneDeviceMenu() -> NSMenu {
        let menu = NSMenu()
        let defaultItem = NSMenuItem(
            title: L10n.string("系统默认输入"),
            action: #selector(microphoneDeviceMenuClicked(_:)),
            keyEquivalent: ""
        )
        defaultItem.target = self
        defaultItem.representedObject = NSNull()
        defaultItem.state = microphoneDeviceUID == nil ? .on : .off
        menu.addItem(defaultItem)

        let devices = RecordingAudioInputDevices.available()
        if !devices.isEmpty {
            menu.addItem(.separator())
        }
        for device in devices {
            let item = NSMenuItem(
                title: device.name,
                action: #selector(microphoneDeviceMenuClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = device.uid
            item.state = microphoneDeviceUID == device.uid ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func microphoneDeviceMenuClicked(_ sender: NSMenuItem) {
        let uid: String?
        if sender.representedObject is NSNull {
            uid = nil
        } else {
            uid = sender.representedObject as? String
        }
        microphoneDeviceUID = uid
        microphoneButton.toolTip = microphoneTooltip(enabled: microphoneEnabled)
        onSelectMicrophoneDevice?(uid)
    }

    func startClock() {
        clockTimer?.invalidate()
        elapsedSeconds = 0
        isPaused = false
        updateClock()
        clockTimer = Timer.scheduledTimer(
            timeInterval: 1,
            target: self,
            selector: #selector(clockTick),
            userInfo: nil,
            repeats: true
        )
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        pauseButton.setSymbol(
            paused ? "play.fill" : "pause.fill",
            accessibilityDescription: paused ? L10n.string("继续") : L10n.string("暂停")
        )
        pauseButton.toolTip = paused ? L10n.string("继续") : L10n.string("暂停")
        if !paused, clockTimer == nil {
            startClock()
        }
    }

    func stopClock() {
        clockTimer?.invalidate()
        clockTimer = nil
    }

    override func close() {
        stopClock()
        super.close()
    }

    private func setupControls(in container: NSView) {
        container.wantsLayer = true
        container.layer?.backgroundColor = SnipStyle.toolbarBG.cgColor
        container.layer?.cornerRadius = 7
        container.layer?.borderWidth = 1
        container.layer?.borderColor = AppTheme.nsCaptureBorder.cgColor

        let dot = NSTextField(labelWithString: "●")
        dot.textColor = .systemRed
        dot.font = .systemFont(ofSize: 10, weight: .bold)
        // 禁止时间/圆点被 stack 拉伸，避免右侧空洞。
        dot.setContentHuggingPriority(.required, for: .horizontal)
        dot.setContentCompressionResistancePriority(.required, for: .horizontal)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        timeLabel.textColor = AppTheme.nsCaptureText
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let separator = NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 26))
        separator.wantsLayer = true
        let line = NSView(frame: NSRect(x: 3.5, y: 6, width: 1, height: 14))
        line.wantsLayer = true
        line.layer?.backgroundColor = AppTheme.nsCaptureSeparator.cgColor
        separator.addSubview(line)
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 8).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 26).isActive = true
        separator.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [
            dot,
            timeLabel,
            separator,
            systemAudioButton,
            microphoneButton,
            pauseButton,
            stopButton,
            cancelButton,
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.distribution = .fill
        stack.setHuggingPriority(.required, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        controlsStack = stack
        // 只钉左/上/下，宽度由内容决定，避免固定面板过宽留下右侧空白。
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: Self.horizontalPadding
            ),
            stack.topAnchor.constraint(
                equalTo: container.topAnchor,
                constant: Self.verticalPadding
            ),
            stack.bottomAnchor.constraint(
                equalTo: container.bottomAnchor,
                constant: -Self.verticalPadding
            ),
            stack.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -Self.horizontalPadding
            ),
        ])
    }

    /// 按控件固有宽度收紧面板，去掉尾部空隙。
    private func fittedPanelSize() -> NSSize {
        guard let stack = controlsStack else {
            return NSSize(width: 200, height: Self.panelHeight)
        }
        stack.layoutSubtreeIfNeeded()
        let contentWidth = ceil(stack.fittingSize.width)
        let width = max(contentWidth + Self.horizontalPadding * 2, 160)
        return NSSize(width: width, height: Self.panelHeight)
    }

    private func updateClock() {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        timeLabel.stringValue = String(format: "%02d:%02d", minutes, seconds)
    }

    @objc private func clockTick() {
        guard !isPaused else { return }
        elapsedSeconds += 1
        updateClock()
    }

}

/// 录制保存单一面板：格式选择 → 处理中 → 完成/失败。
/// 视觉对齐偏好设置：surface 卡片、12pt 圆角、AppTheme 边框/文字层级、bordered 按钮。
@MainActor
final class RecordingProcessingPanel: NSWindow, NSWindowDelegate {
    private enum Phase {
        case chooseFormat
        case working
        case completed
        case failed
    }

    private let cardView = RecordingSettingsCardView()
    private let statusIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: L10n.string("保存录制"))
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let progressBar = NSProgressIndicator()
    private let restrictionNotice = RecordingRestrictionNoticeView()
    private let formatRow = NSStackView()
    private let formatTitleLabel = NSTextField(labelWithString: L10n.string("保存格式"))
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cancelButton = NSButton(title: L10n.string("取消"), target: nil, action: nil)
    private let cancelExportButton = NSButton(title: L10n.string("取消导出"), target: nil, action: nil)
    private let saveButton = NSButton(title: L10n.string("保存"), target: nil, action: nil)
    private let finderButton = NSButton(title: L10n.string("在访达中显示"), target: nil, action: nil)
    private let retryGIFButton = NSButton(title: L10n.string("重试导出 GIF"), target: nil, action: nil)
    private let keepMP4Button = NSButton(title: L10n.string("打开 MP4"), target: nil, action: nil)
    private let closeButton = NSButton(title: L10n.string("关闭"), target: nil, action: nil)
    private let chooseActionStack = NSStackView()
    private let resultActionStack = NSStackView()
    private let resultPrimaryActionStack = NSStackView()
    private let resultSecondaryActionStack = NSStackView()
    private let chooseActionSpacer = NSView()
    private let resultPrimarySpacer = NSView()
    private let resultSecondarySpacer = NSView()
    private let contentStack = NSStackView()
    private var outputURL: URL?
    private var temporaryMP4URL: URL?
    private var phase: Phase = .working
    private var isDismissing = false

    /// 用户在格式选择阶段点取消。
    var onCancelFormat: (() -> Void)?
    /// 用户确认格式后开始保存；面板会切到处理中状态。
    var onConfirmFormat: ((ScreenRecordingFormat) -> Void)?
    /// 用户点击窗口红色关闭按钮时取消当前保存/导出。
    var onCancel: (() -> Void)?
    var onCancelExport: (() -> Void)?
    var onClose: (() -> Void)?
    var onRetryGIF: (() -> Void)?
    var onKeepMP4: (() -> Void)?

    init(screen: NSScreen?) {
        let size = NSSize(width: 380, height: 280)
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let frame = NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        super.init(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = L10n.string("保存录制")
        isReleasedWhenClosed = false
        isOpaque = true
        backgroundColor = .windowBackgroundColor
        hasShadow = true
        level = .normal
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        isMovable = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        appearance = NSApp.effectiveAppearance
        delegate = self

        contentView = cardView
        cardView.autoresizingMask = [.width, .height]

        configureTypography()
        configureControls()
        configureLayout()
        applyThemeColors()
        showProcessing()
    }

    /// 展示格式选择；点保存后回调 `onConfirmFormat`，面板切到处理中。
    func showFormatSelection(
        initialFormat: ScreenRecordingFormat,
        errorMessage: String? = nil
    ) {
        phase = .chooseFormat
        outputURL = nil
        temporaryMP4URL = nil
        setWorkingChrome(hidden: true)
        progressBar.isHidden = true
        cancelExportButton.isHidden = true
        setFormatRowHidden(false)
        chooseActionStack.isHidden = false
        resultActionStack.isHidden = true
        statusIcon.isHidden = true
        switch initialFormat {
        case .mp4: formatPopup.selectItem(at: 0)
        case .gif: formatPopup.selectItem(at: 1)
        }
        titleLabel.stringValue = L10n.string("选择保存格式")
        detailLabel.stringValue = L10n.string("请选择要保存的格式")
        restrictionNotice.isHidden = false
        if let errorMessage, !errorMessage.isEmpty {
            hintLabel.stringValue = String(
                format: L10n.string("GIF 导出失败：%@"),
                errorMessage
            )
            hintLabel.isHidden = false
        } else {
            hintLabel.stringValue = ""
            hintLabel.isHidden = true
        }
        applyThemeColors()
        hintLabel.textColor = errorMessage == nil
            ? AppTheme.nsTextTertiary
            : AppTheme.nsWarning
        resizeWindowToContent()
        AppActivation.focus(self)
    }

    func showProcessing() {
        phase = .working
        outputURL = nil
        temporaryMP4URL = nil
        setWorkingChrome(hidden: false)
        progressBar.isHidden = true
        cancelExportButton.isHidden = true
        restrictionNotice.isHidden = true
        setFormatRowHidden(true)
        chooseActionStack.isHidden = true
        resultActionStack.isHidden = false
        setFailureActionsHidden(true)
        finderButton.isEnabled = false
        closeButton.isEnabled = false
        statusIcon.isHidden = true
        titleLabel.stringValue = L10n.string("正在处理录制视频")
        detailLabel.stringValue = L10n.string("正在准备文件…")
        hintLabel.stringValue = ""
        hintLabel.isHidden = true
        applyThemeColors()
        resizeWindowToContent()
    }

    func showExportingGIF() {
        phase = .working
        outputURL = nil
        setWorkingChrome(hidden: false)
        progressBar.isHidden = false
        progressBar.doubleValue = 0
        cancelExportButton.isHidden = false
        cancelExportButton.isEnabled = true
        restrictionNotice.isHidden = true
        setFormatRowHidden(true)
        chooseActionStack.isHidden = true
        resultActionStack.isHidden = false
        setFailureActionsHidden(true)
        finderButton.isEnabled = false
        closeButton.isEnabled = false
        statusIcon.isHidden = true
        titleLabel.stringValue = L10n.string("正在导出 GIF")
        detailLabel.stringValue = L10n.string("整段视频 · 最多 1920×1080 · 8 FPS · 无音频")
        hintLabel.stringValue = L10n.string("导出在后台进行，可取消；临时 MP4 会保留")
        hintLabel.isHidden = false
        applyThemeColors()
        resizeWindowToContent()
    }

    func updateGIFExportProgress(_ progress: RecordingExporter.GIFExportProgress) {
        guard phase == .working else { return }
        progressBar.doubleValue = progress.fractionCompleted
        guard progress.totalFrameCount > 0 else {
            detailLabel.stringValue = L10n.string("正在准备 GIF 帧…")
            return
        }
        detailLabel.stringValue = String(
            format: L10n.string("已处理 %lld/%lld 帧 · %.0f%%"),
            Int64(progress.completedFrameCount),
            Int64(progress.totalFrameCount),
            progress.fractionCompleted * 100
        )
    }

    func showCompleted(fileURL: URL, format: ScreenRecordingFormat = .mp4) {
        phase = .completed
        onCancel = nil
        onCancelExport = nil
        outputURL = fileURL
        temporaryMP4URL = nil
        setWorkingChrome(hidden: true)
        progressBar.isHidden = true
        cancelExportButton.isHidden = true
        restrictionNotice.isHidden = true
        setFormatRowHidden(true)
        chooseActionStack.isHidden = true
        resultActionStack.isHidden = false
        setFailureActionsHidden(true)
        finderButton.isEnabled = true
        closeButton.isEnabled = true
        setStatusIcon(systemName: "checkmark.circle.fill", tint: AppTheme.nsSuccess)
        titleLabel.stringValue = L10n.string("录制处理完成")
        detailLabel.stringValue = String(format: L10n.string("已保存 %@"), fileURL.lastPathComponent)
        switch format {
        case .mp4:
            hintLabel.stringValue = L10n.string("MP4 已可用")
        case .gif:
            hintLabel.stringValue = L10n.string("GIF 已可用（不含音频）")
        }
        hintLabel.isHidden = false
        applyThemeColors()
        resizeWindowToContent()
        // 导出期间允许用户切换到其它应用；完成态出现时重新把结果面板带回前台。
        AppActivation.focus(self)
    }

    func showError(_ message: String) {
        phase = .failed
        onCancel = nil
        onCancelExport = nil
        outputURL = nil
        temporaryMP4URL = nil
        setWorkingChrome(hidden: true)
        progressBar.isHidden = true
        cancelExportButton.isHidden = true
        restrictionNotice.isHidden = true
        setFormatRowHidden(true)
        chooseActionStack.isHidden = true
        resultActionStack.isHidden = false
        setFailureActionsHidden(true)
        finderButton.isEnabled = false
        closeButton.isEnabled = true
        setStatusIcon(systemName: "exclamationmark.triangle.fill", tint: AppTheme.nsDanger)
        titleLabel.stringValue = L10n.string("录制处理失败")
        detailLabel.stringValue = message
        hintLabel.stringValue = L10n.string("临时录制文件未加入历史记录")
        hintLabel.isHidden = false
        applyThemeColors()
        resizeWindowToContent()
        AppActivation.focus(self)
    }

    func showGIFFailure(temporaryMP4URL _: URL, message: String) {
        showFormatSelection(initialFormat: .gif, errorMessage: message)
    }

    // MARK: - Layout & theme

    private func configureTypography() {
        // 对齐 SettingsTypography.cardTitle / rowSubtitle / compact
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.alignment = .left
        detailLabel.font = .systemFont(ofSize: 13, weight: .regular)
        detailLabel.alignment = .left
        detailLabel.maximumNumberOfLines = 4
        detailLabel.preferredMaxLayoutWidth = 320
        detailLabel.lineBreakMode = .byWordWrapping
        hintLabel.font = .systemFont(ofSize: 12, weight: .regular)
        hintLabel.alignment = .left
        hintLabel.maximumNumberOfLines = 2
        hintLabel.preferredMaxLayoutWidth = 320
        hintLabel.lineBreakMode = .byWordWrapping
        formatTitleLabel.font = .systemFont(ofSize: 13, weight: .medium)
    }

    private func configureControls() {
        spinner.style = .spinning
        spinner.controlSize = .regular

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.widthAnchor.constraint(equalToConstant: 320).isActive = true

        statusIcon.imageScaling = .scaleProportionallyUpOrDown
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        statusIcon.heightAnchor.constraint(equalToConstant: 28).isActive = true

        formatPopup.controlSize = .regular
        formatPopup.font = .systemFont(ofSize: 13)
        formatPopup.addItem(withTitle: ScreenRecordingFormat.mp4.displayName)
        formatPopup.lastItem?.representedObject = ScreenRecordingFormat.mp4.rawValue
        formatPopup.addItem(withTitle: String(format: L10n.string("%@（无音频）"), ScreenRecordingFormat.gif.displayName))
        formatPopup.lastItem?.representedObject = ScreenRecordingFormat.gif.rawValue
        formatPopup.translatesAutoresizingMaskIntoConstraints = false
        formatPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        styleSecondaryButton(cancelButton)
        cancelButton.target = self
        cancelButton.action = #selector(cancelFormatClicked)
        cancelButton.keyEquivalent = "\u{1b}"

        styleSecondaryButton(cancelExportButton)
        cancelExportButton.target = self
        cancelExportButton.action = #selector(cancelExportClicked)

        stylePrimaryButton(saveButton)
        saveButton.target = self
        saveButton.action = #selector(confirmFormatClicked)
        saveButton.keyEquivalent = "\r"

        styleSecondaryButton(finderButton)
        finderButton.image = NSImage(
            systemSymbolName: "folder",
            accessibilityDescription: L10n.string("在访达中显示")
        )
        finderButton.imagePosition = .imageLeading
        finderButton.toolTip = L10n.string("在访达中显示录制文件")
        finderButton.target = self
        finderButton.action = #selector(revealInFinderClicked)

        styleSecondaryButton(retryGIFButton)
        retryGIFButton.target = self
        retryGIFButton.action = #selector(retryGIFClicked)

        styleSecondaryButton(keepMP4Button)
        keepMP4Button.target = self
        keepMP4Button.action = #selector(keepMP4Clicked)

        styleSecondaryButton(closeButton)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
    }

    private func configureLayout() {
        formatRow.orientation = .horizontal
        formatRow.alignment = .centerY
        formatRow.distribution = .fill
        formatRow.spacing = 12
        formatRow.addArrangedSubview(formatTitleLabel)
        formatRow.addArrangedSubview(NSView()) // spacer
        formatRow.addArrangedSubview(formatPopup)
        formatRow.translatesAutoresizingMaskIntoConstraints = false
        formatRow.widthAnchor.constraint(equalToConstant: 320).isActive = true

        // 格式行内嵌 muted 底，贴近设置页表单行
        let formatChrome = RecordingFormatRowChrome()
        formatChrome.translatesAutoresizingMaskIntoConstraints = false
        formatChrome.addSubview(formatRow)
        NSLayoutConstraint.activate([
            formatRow.leadingAnchor.constraint(equalTo: formatChrome.leadingAnchor, constant: 12),
            formatRow.trailingAnchor.constraint(equalTo: formatChrome.trailingAnchor, constant: -12),
            formatRow.topAnchor.constraint(equalTo: formatChrome.topAnchor, constant: 10),
            formatRow.bottomAnchor.constraint(equalTo: formatChrome.bottomAnchor, constant: -10),
            formatChrome.widthAnchor.constraint(equalToConstant: 320),
        ])
        // 用 chrome 替代裸 formatRow 加入主栈
        // 保留 formatRow 引用用于 isHidden，同步 chrome
        formatRowChrome = formatChrome

        chooseActionStack.orientation = .horizontal
        chooseActionStack.alignment = .centerY
        chooseActionStack.distribution = .fill
        chooseActionStack.spacing = 10
        chooseActionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        chooseActionSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chooseActionStack.addArrangedSubview(chooseActionSpacer)
        chooseActionStack.addArrangedSubview(cancelButton)
        chooseActionStack.addArrangedSubview(saveButton)
        chooseActionStack.widthAnchor.constraint(equalToConstant: 320).isActive = true

        resultPrimaryActionStack.orientation = .horizontal
        resultPrimaryActionStack.alignment = .centerY
        resultPrimaryActionStack.distribution = .fill
        resultPrimaryActionStack.spacing = 10
        resultPrimarySpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        resultPrimarySpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        resultPrimaryActionStack.addArrangedSubview(resultPrimarySpacer)
        resultPrimaryActionStack.addArrangedSubview(cancelExportButton)
        resultPrimaryActionStack.addArrangedSubview(retryGIFButton)
        resultPrimaryActionStack.addArrangedSubview(keepMP4Button)
        resultPrimaryActionStack.widthAnchor.constraint(equalToConstant: 320).isActive = true

        resultSecondaryActionStack.orientation = .horizontal
        resultSecondaryActionStack.alignment = .centerY
        resultSecondaryActionStack.distribution = .fill
        resultSecondaryActionStack.spacing = 10
        resultSecondaryActionStack.addArrangedSubview(finderButton)
        resultSecondarySpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        resultSecondarySpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        resultSecondaryActionStack.addArrangedSubview(resultSecondarySpacer)
        resultSecondaryActionStack.addArrangedSubview(closeButton)
        resultSecondaryActionStack.widthAnchor.constraint(equalToConstant: 320).isActive = true

        resultActionStack.orientation = .vertical
        resultActionStack.alignment = .centerX
        resultActionStack.spacing = 10
        resultActionStack.addArrangedSubview(resultPrimaryActionStack)
        resultActionStack.addArrangedSubview(resultSecondaryActionStack)

        contentStack.orientation = .vertical
        contentStack.alignment = .centerX
        contentStack.spacing = 10
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(statusIcon)
        contentStack.addArrangedSubview(spinner)
        contentStack.addArrangedSubview(progressBar)
        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(detailLabel)
        contentStack.addArrangedSubview(restrictionNotice)
        contentStack.addArrangedSubview(formatChrome)
        contentStack.addArrangedSubview(hintLabel)
        contentStack.addArrangedSubview(chooseActionStack)
        contentStack.addArrangedSubview(resultActionStack)
        contentStack.setCustomSpacing(14, after: titleLabel)
        contentStack.setCustomSpacing(8, after: detailLabel)
        contentStack.setCustomSpacing(14, after: restrictionNotice)
        contentStack.setCustomSpacing(14, after: formatChrome)
        contentStack.setCustomSpacing(10, after: hintLabel)

        cardView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 28),
            contentStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -28),
            contentStack.topAnchor.constraint(greaterThanOrEqualTo: cardView.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: cardView.bottomAnchor, constant: -24),
            contentStack.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            titleLabel.widthAnchor.constraint(equalToConstant: 320),
            detailLabel.widthAnchor.constraint(equalToConstant: 320),
            restrictionNotice.widthAnchor.constraint(equalToConstant: 320),
            hintLabel.widthAnchor.constraint(equalToConstant: 320),
        ])
    }

    private var formatRowChrome: RecordingFormatRowChrome?

    private func applyThemeColors() {
        cardView.applyTheme()
        formatRowChrome?.applyTheme()
        titleLabel.textColor = AppTheme.nsTextPrimary
        detailLabel.textColor = AppTheme.nsTextSecondary
        restrictionNotice.applyTheme()
        hintLabel.textColor = AppTheme.nsTextTertiary
        formatTitleLabel.textColor = AppTheme.nsTextPrimary
        // 主按钮随强调色
        if #available(macOS 11.0, *) {
            saveButton.bezelColor = AppTheme.nsAccent
        }
    }

    private func styleSecondaryButton(_ button: NSButton) {
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        if #available(macOS 11.0, *) {
            button.controlSize = .regular
        }
    }

    private func stylePrimaryButton(_ button: NSButton) {
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        if #available(macOS 11.0, *) {
            button.controlSize = .regular
            button.contentTintColor = .white
        }
    }

    private func setWorkingChrome(hidden: Bool) {
        if hidden {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
        } else {
            spinner.isHidden = false
            spinner.startAnimation(nil)
        }
    }

    private func setFormatRowHidden(_ hidden: Bool) {
        formatRow.isHidden = hidden
        formatRowChrome?.isHidden = hidden
    }

    private func setStatusIcon(systemName: String, tint: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
        statusIcon.image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        statusIcon.contentTintColor = tint
        statusIcon.isHidden = false
    }

    private func resizeWindowToContent() {
        cardView.layoutSubtreeIfNeeded()
        contentStack.layoutSubtreeIfNeeded()
        let fittingHeight = ceil(contentStack.fittingSize.height)
        guard fittingHeight > 0 else { return }

        let previousFrame = frame
        let contentHeight = min(max(fittingHeight + 44, 180), 320)
        setContentSize(NSSize(width: 380, height: contentHeight))
        setFrameOrigin(NSPoint(
            x: previousFrame.midX - frame.width / 2,
            y: previousFrame.maxY - frame.height
        ))
    }

    private func setFailureActionsHidden(_ hidden: Bool) {
        retryGIFButton.isHidden = hidden
        keepMP4Button.isHidden = hidden
        resultPrimaryActionStack.isHidden = hidden && cancelExportButton.isHidden
    }

    private var selectedFormat: ScreenRecordingFormat {
        let raw = formatPopup.selectedItem?.representedObject as? String
        return ScreenRecordingFormat(rawValue: raw ?? "") ?? .mp4
    }

    @objc private func confirmFormatClicked() {
        guard phase == .chooseFormat else { return }
        let format = selectedFormat
        showProcessing()
        onConfirmFormat?(format)
    }

    @objc private func cancelFormatClicked() {
        guard phase == .chooseFormat else { return }
        let handler = onCancelFormat
        onCancelFormat = nil
        onConfirmFormat = nil
        onCancel = nil
        onCancelExport = nil
        dismissWindow()
        handler?()
    }

    @objc private func cancelExportClicked() {
        guard phase == .working else { return }
        cancelExportButton.isEnabled = false
        let handler = onCancelExport
        onCancelExport = nil
        handler?()
    }

    @objc private func revealInFinderClicked() {
        guard let outputURL else { return }
        _ = FeatureHistoryIO.revealFileInFinder(outputURL)
        closeClicked()
    }

    @objc private func retryGIFClicked() {
        onRetryGIF?()
    }

    @objc private func keepMP4Clicked() {
        onKeepMP4?()
    }

    @objc private func closeClicked() {
        handleWindowCloseRequest()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isDismissing else { return true }
        handleWindowCloseRequest()
        return false
    }

    override func close() {
        isDismissing = true
        super.close()
        isDismissing = false
    }

    private func handleWindowCloseRequest() {
        switch phase {
        case .chooseFormat:
            cancelFormatClicked()
        case .working:
            let handler = onCancel ?? onCancelExport
            onCancel = nil
            onCancelExport = nil
            dismissWindow()
            handler?()
        case .completed, .failed:
            let closeHandler = onClose
            clearCallbacks()
            dismissWindow()
            closeHandler?()
        }
    }

    private func dismissWindow() {
        orderOut(nil)
        close()
    }

    private func clearCallbacks() {
        onCancelFormat = nil
        onConfirmFormat = nil
        onCancel = nil
        onCancelExport = nil
        onRetryGIF = nil
        onKeepMP4 = nil
    }
}

/// 录制保存内容面：使用单一 surface，避免普通窗口内再套一层卡片边框。
@MainActor
private final class RecordingSettingsCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.masksToBounds = true
        layer?.borderWidth = 0
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    func applyTheme() {
        layer?.backgroundColor = AppTheme.nsSurface.cgColor
        layer?.borderColor = AppTheme.nsBorder.cgColor
    }
}

/// GIF 导出限制提醒：与普通说明分层，避免限制文本挤在标题下方。
@MainActor
private final class RecordingRestrictionNoticeView: NSView {
    private let iconView = NSImageView()
    private let messageLabel = NSTextField(
        wrappingLabelWithString: L10n.string("GIF 无音频 · 最大 1920×1080 · 8 FPS")
    )
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1

        iconView.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: L10n.string("提醒")
        )
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 17),
            iconView.heightAnchor.constraint(equalToConstant: 17),
        ])

        messageLabel.font = .systemFont(ofSize: 12, weight: .medium)
        messageLabel.maximumNumberOfLines = 1
        messageLabel.preferredMaxLayoutWidth = 270
        messageLabel.lineBreakMode = .byTruncatingTail

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(messageLabel)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    func applyTheme() {
        let warning = AppTheme.nsWarning
        layer?.backgroundColor = warning.withAlphaComponent(0.12).cgColor
        layer?.borderColor = warning.withAlphaComponent(0.28).cgColor
        iconView.contentTintColor = warning
        messageLabel.textColor = AppTheme.nsTextSecondary
    }
}

/// 设置页表单行底：muted surface + 轻边框。
@MainActor
private final class RecordingFormatRowChrome: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    func applyTheme() {
        layer?.backgroundColor = AppTheme.nsSurfaceMuted.cgColor
        layer?.borderColor = AppTheme.nsBorder.withAlphaComponent(0.85).cgColor
    }
}

@MainActor
private final class RecordingHUDContainerView: NSView {
    weak var panel: RecordingHUDPanel?
    private var dragOffset = NSPoint.zero
    private var isDragging = false

    override func mouseDown(with event: NSEvent) {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        dragOffset = NSPoint(
            x: mouse.x - panel.frame.minX,
            y: mouse.y - panel.frame.minY
        )
        isDragging = true
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let panel else { return }
        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(
            NSPoint(x: mouse.x - dragOffset.x, y: mouse.y - dragOffset.y)
        )
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        NSCursor.arrow.set()
    }
}
