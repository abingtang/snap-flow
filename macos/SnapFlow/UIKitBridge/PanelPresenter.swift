import AppKit
import SwiftUI
import Sauce

/// 统一管理各类非激活浮层 / 结果窗口。
@MainActor
final class PanelPresenter {
    /// Snipaste 风格可贴多张
    private var pinnedWindows: [PinnedImageWindow] = []
    private var hiddenPinnedWindows: [PinnedImageWindow] = []
    /// 当前未钉住的 OCR 结果窗（新一次识别会替换它）
    private var ocrPanel: NSPanel?
    private var ocrSession: OCRResultSession?
    private var ocrKeyMonitor: Any?
    private var ocrWindowDelegates: [ObjectIdentifier: OCRPanelWindowDelegate] = [:]
    /// 已钉住的 OCR 结果窗（新识别不会关掉）
    private var pinnedOCRPanels: [NSPanel] = []
    private var pinnedOCRSessions: [ObjectIdentifier: OCRResultSession] = [:]
    private var pinnedOCRMonitors: [ObjectIdentifier: Any] = [:]

    private var translatePanel: ClipboardPanel?
    private var translateSession: TranslatePopupSession?
    private var translateTasks: [Task<Void, Never>] = []
    private var translateGeneration = UUID()
    private var pendingTranslationServiceIDs: Set<String> = []
    private var overlayPanel: NSPanel?
    private var screenTranslateSession: ScreenTranslateOverlaySession?
    /// 截图翻译结果窗（左图右译，对齐 OCR 窗）
    private var screenTranslateResultPanel: NSPanel?
    private var screenTranslateResultSession: ScreenTranslateResultSession?
    private var screenTranslateResultKeyMonitor: Any?
    private var screenTranslateResultDelegates: [ObjectIdentifier: OCRPanelWindowDelegate] = [:]
    private var pinnedSTRPanels: [NSPanel] = []
    private var pinnedSTRSessions: [ObjectIdentifier: ScreenTranslateResultSession] = [:]
    private var pinnedSTRMonitors: [ObjectIdentifier: Any] = [:]
    private var clipboardPanel: NSPanel?
    private var clipboardVisibleFrame: NSRect?
    private weak var clipboardStatusBarButton: NSStatusBarButton?
    /// 呼出剪切板前的目标 App（必须强引用：`weak` 会在赋值后立刻被释放，导致粘贴时 target 为 nil）。
    private var clipboardTargetApplication: NSRunningApplication?
    private var clipboardTargetPID: pid_t = 0
    private var hasShownClipboardAccessibilityGuide =
        UserDefaults.standard.bool(forKey: "clipboard.hasShownAccessibilityGuide")
    private var onboardingWindow: NSWindow?
    private var settingsWindow: SettingsWindow?
    private weak var container: AppContainer?

    func attach(container: AppContainer) {
        self.container = container
        NotificationCenter.default.addObserver(
            forName: .snapFlowLanguageDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshLocalizedWindowTitles()
            }
        }
    }

    private func refreshLocalizedWindowTitles() {
        if let settingsWindow {
            settingsWindow.title = L10n.string("SnapFlow 设置")
        }
        if let onboardingWindow {
            onboardingWindow.title = L10n.string("欢迎使用 SnapFlow")
        }
    }

    /// 录制排除列表：设置窗若打开则排除，避免被录进画面（窗本身保持原位显示）。
    var settingsWindowIDForCaptureExclusion: CGWindowID? {
        guard let window = settingsWindow, window.isVisible, window.windowNumber > 0 else { return nil }
        return CGWindowID(window.windowNumber)
    }

    func attach(statusBarButton: NSStatusBarButton) {
        clipboardStatusBarButton = statusBarButton
    }

    /// 为 SwiftUI 浮层根注入强调色 observation；设置页切换后各窗 tint 即时更新。
    @ViewBuilder
    private func themed<Content: View>(_ content: Content) -> some View {
        content.snapFlowAppearance(settings: container?.settings)
    }

    // MARK: - 就地状态

    /// 全局反馈：`progress`（倒计时）走屏幕中央卡片，其余走系统通知
    func flashStatus(
        _ message: String,
        level: FeedbackLevel = .info,
        duration: TimeInterval? = nil
    ) {
        FeedbackCenter.shared.post(message, level: level, duration: duration)
    }

    /// 优先 OCR 顶栏；否则贴图；再否则全局反馈（系统通知 / 中央倒计时）
    func flashContextStatus(
        _ message: String,
        level: FeedbackLevel = .info,
        on pin: PinnedImageWindow? = nil
    ) {
        if let session = ocrSession ?? pinnedOCRSessions.values.first {
            session.flash(message)
            return
        }
        if let pin {
            pin.showStatus(message)
            return
        }
        // 光标下贴图
        discardClosedPins()
        let mouse = NSEvent.mouseLocation
        if let hit = pinnedWindows.first(where: { $0.frame.contains(mouse) }) {
            hit.showStatus(message)
            return
        }
        flashStatus(message, level: level)
    }

    // MARK: - Screenshot (Snipaste 贴图)

    /// 将截图钉到屏幕上（贴图）。默认贴在原选区位置。
    @discardableResult
    func pinScreenshot(
        image: NSImage,
        at screenRect: CGRect?,
        onRequestOCR: (() -> Void)? = nil,
        onRequestTranslate: ((NSImage) -> Void)? = nil,
        onRequestImageTranslate: ((NSImage) -> Void)? = nil
    ) -> PinnedImageWindow? {
        // 清理已关闭的引用
        discardClosedPins()

        guard let settings = container?.settings else { return nil }
        let pin = PinnedImageWindow(
            image: image,
            screenRect: screenRect,
            settings: settings,
            onOCR: onRequestOCR,
            onTranslate: onRequestTranslate,
            onImageTranslate: onRequestImageTranslate,
            onFavorite: { [weak self] img in
                self?.favoritePinnedImage(img)
            }
        )
        pinnedWindows.append(pin)
        pin.present()
        return pin
    }

    /// Snipaste：切换光标下贴图的鼠标穿透；若无则关闭全部穿透
    func toggleClickThroughUnderCursor() {
        discardClosedPins()
        let mouse = NSEvent.mouseLocation
        if let hit = pinnedWindows.first(where: { $0.frame.contains(mouse) }) {
            hit.setClickThrough(!hit.isClickThrough)
            return
        }
        // 无命中：全部取消穿透
        var any = false
        for w in pinnedWindows where w.isClickThrough {
            w.setClickThrough(false)
            any = true
        }
        flashStatus(
            any ? L10n.string("已取消全部穿透") : L10n.string("光标下没有贴图"),
            level: any ? .info : .warning
        )
    }

    /// 不关闭贴图，只切换全部贴图的可见性。
    func togglePinnedVisibility() {
        if hiddenPinnedWindows.isEmpty {
            discardClosedPins()
            hiddenPinnedWindows = pinnedWindows.filter(\.isVisible)
            hiddenPinnedWindows.forEach { $0.orderOut(nil) }
        } else {
            hiddenPinnedWindows.forEach { $0.orderFrontRegardless() }
            hiddenPinnedWindows.removeAll()
        }
    }

    /// 兼容旧调用：贴图到鼠标附近
    func showScreenshotPreview(image: NSImage, onRequestOCR: (() -> Void)? = nil) {
        pinScreenshot(image: image, at: nil, onRequestOCR: onRequestOCR)
    }

    // MARK: - OCR

    /// 展示左图右文 OCR 结果窗。若当前窗未钉住则替换；已钉住的窗保留。
    /// 回调均带上对应 `OCRResultSession`，钉住后仍能正确重试/选图。
    @discardableResult
    func showOCRResult(
        image: NSImage,
        cgImage: CGImage,
        text: String,
        lines: [OCRLine],
        serviceID: String = OCRServiceEntry.visionID,
        enabledServices: @escaping () -> [OCRServiceEntry] = { [.vision()] },
        onSelectService: @escaping (OCRResultSession, String) -> Void = { _, _ in },
        onRetry: @escaping (OCRResultSession) -> Void,
        onRescreen: @escaping (OCRResultSession) -> Void,
        onOpenFile: @escaping (OCRResultSession) -> Void,
        onRerecognize: @escaping (OCRResultSession, OCRLanguageMode) -> Void,
        onOpenSettings: @escaping () -> Void = {},
        onTranslate: @escaping (OCRResultSession) -> Void = { _ in }
    ) -> OCRResultSession {
        // 未钉住的旧窗关掉；钉住的保留
        closeUnpinnedOCR()

        let session = OCRResultSession(
            image: image,
            cgImage: cgImage,
            lines: lines,
            text: text,
            selectedServiceID: serviceID
        )
        session.isContentFavorited = container?.historyStore.isFavorited(
            text: session.text,
            image: session.image
        ) ?? false
        let actions = OCRResultActions(
            onClose: { [weak self, weak session] in
                guard let self, let session else { return }
                self.closeOCRSession(session)
            },
            onTogglePin: { [weak self, weak session] in
                guard let self, let session else { return }
                self.toggleOCRPin(session)
            },
            onRetry: { [weak session] in
                guard let session else { return }
                onRetry(session)
            },
            onRescreen: { [weak session] in
                guard let session else { return }
                onRescreen(session)
            },
            onOpenFile: { [weak session] in
                guard let session else { return }
                onOpenFile(session)
            },
            onRerecognize: { [weak session] mode in
                guard let session else { return }
                onRerecognize(session, mode)
            },
            onSelectService: { [weak session] id in
                guard let session else { return }
                onSelectService(session, id)
            },
            enabledServices: enabledServices,
            onOpenSettings: { [weak session] in
                guard let session else { return }
                session.suppressFocusDismissCount += 1
                onOpenSettings()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    session.suppressFocusDismissCount = max(0, session.suppressFocusDismissCount - 1)
                }
            },
            onTranslate: { [weak session] in
                guard let session else { return }
                onTranslate(session)
            },
            onFavorite: { [weak self, weak session] in
                guard let self, let session else { return }
                self.toggleFavoriteOCRSession(session)
            },
            isFavorited: { [weak self, weak session] in
                guard let self, let session else { return false }
                return self.container?.historyStore.isFavorited(
                    text: session.text,
                    image: session.image
                ) ?? false
            }
        )
        let view = OCRResultView(
            session: session,
            actions: actions,
            settings: container?.settings
        )
        let panel = makeOCRResultPanel(
            size: NSSize(width: 860, height: 520),
            rootView: view
        )
        ocrPanel = panel
        ocrSession = session
        attachOCRWindowDelegate(panel: panel, session: session)
        installOCRKeyMonitor(for: panel, session: session, actions: actions, pinned: false)
        positionOCRPanelTopCenter(panel)
        AppActivation.focus(panel)
        // 确保右侧文本可编辑：成为 key 后再聚焦
        panel.makeFirstResponder(panel.contentView)
        return session
    }

    /// 原地更新当前（或指定）OCR 会话内容，用于重试/换语言后不重开窗。
    func updateOCRResult(
        image: NSImage,
        cgImage: CGImage,
        lines: [OCRLine],
        session: OCRResultSession? = nil
    ) {
        let target = session ?? ocrSession
        guard let target else {
            // 无会话时退回新开窗（由调用方应避免）
            return
        }
        target.applyRecognition(image: image, cgImage: cgImage, lines: lines)
        if lines.isEmpty {
            target.flash(L10n.string("未识别到文字"))
        }
    }

    var activeOCRSession: OCRResultSession? { ocrSession }
    var activeTranslateSession: TranslatePopupSession? { translateSession }

    /// 是否仍持有 OCR / 截图翻译 / 原图叠层结果（含钉住窗）。
    /// 为 false 时 `AppWorkflows` 可释放 `lastCaptureImage`。
    var isHoldingCaptureResultBuffers: Bool {
        ocrSession != nil
            || !pinnedOCRSessions.isEmpty
            || screenTranslateResultSession != nil
            || !pinnedSTRSessions.isEmpty
            || screenTranslateSession != nil
    }

    private func notifyCaptureResultWindowsDidChange() {
        container?.workflows.clearTransientCaptureBuffersIfIdle()
    }

    private func toggleOCRPin(_ session: OCRResultSession) {
        if session.isPinned {
            // 取消钉住：若不是当前活动窗，移回活动位或保持独立可关
            session.isPinned = false
            applyOCRPanelLevel(for: session, pinned: false)
            session.flash(L10n.string("已取消钉住"))
            // 从 pinned 列表移出；若当前无活动窗则设为活动窗
            if let panel = panel(for: session) {
                let id = ObjectIdentifier(panel)
                pinnedOCRPanels.removeAll { ObjectIdentifier($0) == id }
                pinnedOCRSessions.removeValue(forKey: id)
                if ocrPanel == nil {
                    ocrPanel = panel
                    ocrSession = session
                    // 迁移 monitor 引用
                    if let mon = pinnedOCRMonitors.removeValue(forKey: id) {
                        removeOCRKeyMonitor(pinned: false)
                        ocrKeyMonitor = mon
                    }
                }
            }
            return
        }

        session.isPinned = true
        applyOCRPanelLevel(for: session, pinned: true)
        session.flash(L10n.string("已钉住窗口"))

        guard let panel = ocrPanel, ocrSession === session else {
            // 已在 pinned 列表中再次钉住
            return
        }
        // 活动窗 → 钉住列表，避免下次识别关掉
        let id = ObjectIdentifier(panel)
        pinnedOCRPanels.append(panel)
        pinnedOCRSessions[id] = session
        if let mon = ocrKeyMonitor {
            pinnedOCRMonitors[id] = mon
            ocrKeyMonitor = nil
        }
        ocrPanel = nil
        ocrSession = nil
    }

    private func applyOCRPanelLevel(for session: OCRResultSession, pinned: Bool) {
        guard let panel = panel(for: session) else { return }
        panel.level = pinned ? .statusBar : .floating
        // 钉住后允许失焦仍保留；未钉住时靠 delegate 失焦关闭
        panel.hidesOnDeactivate = false
    }

    private func attachOCRWindowDelegate(panel: NSPanel, session: OCRResultSession) {
        let id = ObjectIdentifier(panel)
        let delegate = OCRPanelWindowDelegate { [weak self, weak session, weak panel] in
            guard let self, let session, let panel else { return }
            // 钉住：失焦不关
            guard !session.isPinned else { return }
            guard session.suppressFocusDismissCount == 0 else { return }
            // 打开文件面板等模态时不关
            if NSApp.modalWindow != nil { return }
            // 延迟判定：避免点菜单/按钮瞬间 resign 误关
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                guard !session.isPinned else { return }
                guard session.suppressFocusDismissCount == 0 else { return }
                guard NSApp.modalWindow == nil else { return }
                // 仍未重新成为 key，则视为失去焦点
                guard panel === self.panel(for: session), !panel.isKeyWindow else { return }
                self.closeOCRSession(session)
            }
        }
        panel.delegate = delegate
        ocrWindowDelegates[id] = delegate
    }

    func panelForSession(_ session: OCRResultSession) -> NSPanel? {
        if ocrSession === session { return ocrPanel }
        for (id, s) in pinnedOCRSessions where s === session {
            return pinnedOCRPanels.first { ObjectIdentifier($0) == id }
        }
        return nil
    }

    private func panel(for session: OCRResultSession) -> NSPanel? {
        panelForSession(session)
    }

    private func closeOCRSession(_ session: OCRResultSession) {
        if ocrSession === session {
            closeUnpinnedOCR()
            return
        }
        if let panel = panel(for: session) {
            let id = ObjectIdentifier(panel)
            if let mon = pinnedOCRMonitors.removeValue(forKey: id) {
                NSEvent.removeMonitor(mon)
            }
            pinnedOCRSessions.removeValue(forKey: id)
            pinnedOCRPanels.removeAll { ObjectIdentifier($0) == id }
            ocrWindowDelegates.removeValue(forKey: id)
            panel.delegate = nil
            // 先卸 hosting，避免 orderOut 后仍持有 NSImage/CGImage。
            panel.contentView = nil
            panel.orderOut(nil)
            notifyCaptureResultWindowsDidChange()
        }
    }

    private func closeUnpinnedOCR() {
        removeOCRKeyMonitor(pinned: false)
        if let panel = ocrPanel {
            let id = ObjectIdentifier(panel)
            ocrWindowDelegates.removeValue(forKey: id)
            panel.delegate = nil
            panel.contentView = nil
            panel.orderOut(nil)
        }
        ocrPanel = nil
        ocrSession = nil
        notifyCaptureResultWindowsDidChange()
    }

    private func installOCRKeyMonitor(
        for panel: NSPanel,
        session: OCRResultSession,
        actions: OCRResultActions,
        pinned: Bool
    ) {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel, weak session] event in
            guard let self, let panel, let session else { return event }
            // 仅当事件窗口是本 OCR 窗时拦截
            guard event.window === panel || panel.isKeyWindow else { return event }
            if TextInputSession.isComposing(in: event.window) {
                return event
            }
            guard let settings = self.container?.settings else { return event }

            if settings.matches(.ocrRetry, event: event) {
                actions.onRetry()
                return nil
            }
            if settings.matches(.ocrClose, event: event) || settings.matches(.ocrCloseCommandW, event: event) {
                actions.onClose()
                return nil
            }
            if settings.matches(.ocrTogglePin, event: event) {
                actions.onTogglePin()
                return nil
            }
            if settings.matches(.ocrFontLarger, event: event) {
                session.fontSize = min(session.fontSize + 1, 36)
                return nil
            }
            if settings.matches(.ocrFontSmaller, event: event) {
                session.fontSize = max(session.fontSize - 1, 10)
                return nil
            }
            return event
        }
        if pinned {
            pinnedOCRMonitors[ObjectIdentifier(panel)] = monitor as Any
        } else {
            removeOCRKeyMonitor(pinned: false)
            ocrKeyMonitor = monitor
        }
    }

    private func removeOCRKeyMonitor(pinned: Bool) {
        if !pinned, let ocrKeyMonitor {
            NSEvent.removeMonitor(ocrKeyMonitor)
            self.ocrKeyMonitor = nil
        }
    }

    /// OCR 专用浮窗：无系统红绿灯，自绘标题栏；可拖拽移动；可成为 key 以便编辑文本。
    private func makeOCRResultPanel<Content: View>(
        size: NSSize,
        rootView: Content
    ) -> OCRResultPanel {
        let panel = OCRResultPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.string("离线文本识别")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 360, height: 320)
        // 无红绿灯；内容自带圆角卡片
        let host = NSHostingView(rootView: themed(rootView.padding(6)))
        panel.contentView = host
        return panel
    }

    /// 默认出现在当前鼠标所在屏的顶部水平居中。
    private func positionOCRPanelTopCenter(_ panel: NSPanel?) {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        // 使用当前 content size（已由 Auto Layout / 初始 size 决定）
        if frame.width < 10 || frame.height < 10 {
            frame.size = panel.minSize
        }
        let topMargin: CGFloat = 28
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = visible.maxY - frame.height - topMargin
        // 夹紧在可见区域内
        if frame.minX < visible.minX + 8 {
            frame.origin.x = visible.minX + 8
        }
        if frame.maxX > visible.maxX - 8 {
            frame.origin.x = visible.maxX - frame.width - 8
        }
        if frame.minY < visible.minY + 8 {
            frame.origin.y = visible.minY + 8
        }
        panel.setFrame(frame, display: true)
    }

    // MARK: - Translate popup

    /// 划词翻译：borderless 顶层；原文 + 方向条 + 多服务译文卡。
    /// - Parameter autoTranslate: 为 true 时窗体**先显示**，再后台翻译（不阻塞出窗）。
    func showTranslatePopup(
        source: String,
        translated: String,
        statusMessage: String? = nil,
        autoTranslate: Bool = false
    ) {
        closeTranslate()

        // 预热系统翻译宿主，与出窗并行，缩短首次翻译等待
        container?.translation.warmupHost()

        let settingsTarget = container?.settings.targetLanguage
            ?? TranslationLanguage.systemTargetToken
        let sourceSetting = container?.settings.sourceLanguage
            ?? TranslationLanguage.autoSourceToken
        let target = TranslationLanguage.sessionTargetSelection(
            settingsTarget: settingsTarget,
            sampleText: source,
            sourceSetting: sourceSetting
        )
        let services = container?.settings.enabledTranslationServicesForPopup() ?? [.system()]
        let session = TranslatePopupSession(
            sourceText: source,
            translatedText: translated,
            statusMessage: statusMessage,
            targetSelection: target,
            services: services
        )
        if autoTranslate, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            session.isTranslating = true
            session.setServicesLoading(true)
        }
        translateSession = session

        // 整窗 max = 屏可用高度；实际高度按内容估算（不超过 max），禁止 HostingView 自动改窗尺寸
        let panelMaxHeight = translatePopupMaxHeight()
        let panelHeight = TranslatePopupView.preferredPanelHeight(
            sourceText: source,
            serviceResults: session.serviceResults,
            panelMaxHeight: panelMaxHeight,
            sourceStatusMessage: session.sourceStatusMessage
        )
        let size = NSSize(width: TranslatePopupView.panelWidth, height: panelHeight)
        let view = makeTranslatePopupView(
            session: session,
            panelMaxHeight: panelMaxHeight,
            panelHeight: panelHeight
        )

        let popupPosition = container?.settings.translatePopupPosition ?? .cursor
        let origin = translatePopupOrigin(size: size, position: popupPosition)
        var targetFrame = NSRect(origin: origin, size: size)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(targetFrame) })
            ?? NSScreen.screens.first(where: {
                NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
            })
            ?? NSScreen.main
        {
            targetFrame = Self.clampedTranslateFrame(
                targetFrame,
                requestedHeight: panelHeight,
                visibleFrame: screen.visibleFrame
            )
        }

        let panel = ClipboardPanel(
            contentRect: targetFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.onResignKey = { [weak self] in
            self?.scheduleTranslateFocusDismiss(for: panel)
        }
        panel.onEndLiveMove = { [weak panel, settings = container?.settings] in
            guard let panel, let settings, let visible = panel.screen?.visibleFrame else { return }
            // 与剪切板一致：锚点取窗顶边水平中心，相对 visibleFrame 归一化
            let anchorX = panel.frame.midX - visible.minX
            let anchorY = panel.frame.maxY - visible.minY
            settings.translateWindowPosition = NSPoint(
                x: anchorX / max(visible.width, 1),
                y: anchorY / max(visible.height, 1)
            )
        }
        panel.delegate = panel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isMovable = popupPosition != .statusItem
        panel.isMovableByWindowBackground = popupPosition != .statusItem

        let hosting = NSHostingView(rootView: themed(view))
        // 禁止 SwiftUI 根据内容不断更新窗口 min/max，打断约束死循环
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.setContentSize(size)
        panel.setFrame(targetFrame, display: true)
        translatePanel = panel

        panel.orderFrontRegardless()
        if popupPosition == .statusItem {
            DispatchQueue.main.async { [weak self] in
                self?.clipboardStatusBarButton?.isHighlighted = true
            }
        }
        panel.makeKey()

        if autoTranslate, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            retranslatePopup(session: session, alreadyMarkedLoading: true)
        }
    }

    private func makeTranslatePopupView(
        session: TranslatePopupSession,
        panelMaxHeight: CGFloat,
        panelHeight: CGFloat
    ) -> TranslatePopupView {
        TranslatePopupView(
            session: session,
            onTargetSelectionChanged: { [weak self] code in
                self?.container?.settings.targetLanguage = code
            },
            onRetranslate: { [weak self] in
                self?.retranslatePopup(session: session)
            },
            onRetryService: { [weak self] serviceID in
                self?.retranslatePopup(session: session, serviceID: serviceID)
            },
            onClose: { [weak self] in
                self?.closeTranslate()
            },
            // 划词窗关闭目前固定 Esc（与 LocalShortcut 无独立 scope）
            closeChord: "escape",
            onOpenSettings: { [weak self] in
                // 打开设置时短暂 suppress 失焦关窗
                session.beginFocusSuppress()
                self?.showSettings(pane: .translateService)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    session.endFocusSuppress()
                }
            },
            isTextFavorited: { [weak self] text in
                self?.container?.historyStore.isTextFavorited(text) ?? false
            },
            onToggleFavoriteText: { [weak self] text in
                self?.container?.historyStore.toggleFavorite(
                    text: text,
                    application: "com.snapflow.selection-translate"
                ) ?? false
            },
            onLayoutNeeded: { [weak self] in
                self?.relayoutTranslatePanel(for: session)
            },
            panelMaxHeight: panelMaxHeight,
            panelHeight: panelHeight
        )
    }

    /// 按会话内容重算面板高度。
    /// - 高度变高：优先保持底边，**向上撑开**；顶到屏顶后再限高。
    /// - 折叠/展开即使总高不变也要刷新 rootView（各卡 max-height 会变）。
    private func relayoutTranslatePanel(for session: TranslatePopupSession) {
        guard let panel = translatePanel, translateSession === session else { return }
        let maxH = translatePopupMaxHeight()
        let newH = TranslatePopupView.preferredPanelHeight(
            sourceText: session.sourceText,
            serviceResults: session.serviceResults,
            panelMaxHeight: maxH,
            sourceStatusMessage: session.sourceStatusMessage
        )
        let size = NSSize(width: TranslatePopupView.panelWidth, height: newH)
        let view = makeTranslatePopupView(
            session: session,
            panelMaxHeight: maxH,
            panelHeight: newH
        )
        let hosting = NSHostingView(rootView: themed(view))
        hosting.sizingOptions = []
        panel.contentView = hosting

        var frame = panel.frame
        let previousBottom = frame.minY
        let previousTop = frame.maxY
        frame.size = size

        // 变高：尽量保持底边向上长；变矮：保持顶边
        if newH > panel.frame.height + 1 {
            frame.origin.y = previousBottom
        } else {
            frame.origin.y = previousTop - newH
        }

        if let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            frame = Self.clampedTranslateFrame(frame, requestedHeight: newH, visibleFrame: visible)
        }
        // 即使高度几乎不变，也要 apply frame（max 分配可能已变，hosting 已换）
        DispatchQueue.main.async {
            panel.setFrame(frame, display: true)
        }
    }

    /// 临时菜单或系统模态结束后继续检查，避免首次 resign 被抑制后再也不关窗。
    /// 系统「下载语言包」常在翻译进行中抢 key，且不一定能出现在 `NSApp.windows` 标题扫描里；
    /// 若此时立刻 `closeTranslate`，会 cancelInFlight 并把系统提示一并拆掉（用户看到双窗闪退）。
    private func scheduleTranslateFocusDismiss(for panel: NSPanel) {
        Task { @MainActor [weak self, weak panel] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, let panel, self.translatePanel === panel else { return }

            // 翻译进行中且仍在本 App 内失焦：给系统 sheet / 错误 suppress 一点就绪时间
            let graceSeconds: TimeInterval = self.shouldApplyTranslatingFocusGrace() ? 3.5 : 0
            let graceDeadline = Date().addingTimeInterval(graceSeconds)

            while !panel.isKeyWindow {
                guard self.translatePanel === panel else { return }
                if self.shouldKeepTranslatePopupOpen(panel: panel) {
                    try? await Task.sleep(for: .milliseconds(180))
                    continue
                }
                if Date() < graceDeadline {
                    try? await Task.sleep(for: .milliseconds(180))
                    continue
                }
                break
            }

            guard !panel.isKeyWindow, self.translatePanel === panel else { return }
            self.closeTranslate()
        }
    }

    /// 点到其它 App 视为用户离开；本 App 内失焦更可能是系统语言包 / sheet。
    private func shouldApplyTranslatingFocusGrace() -> Bool {
        guard translateSession?.isTranslating == true else { return false }
        let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let selfID = Bundle.main.bundleIdentifier
        if let frontID, let selfID, frontID != selfID {
            return false
        }
        return true
    }

    /// 目标屏 visibleFrame 高度 − 上下边距（接近全可用高度）。
    private func translatePopupMaxHeight() -> CGFloat {
        let screen = translatePopupPreferredScreen()
        let visibleH = screen?.visibleFrame.height ?? 800
        let margin: CGFloat = 24 // 上下合计边距
        return max(1, floor(visibleH - margin))
    }

    /// 划词浮窗优先落在哪块屏（跟随弹出位置设置）。
    private func translatePopupPreferredScreen() -> NSScreen? {
        let settings = container?.settings
        let position = settings?.translatePopupPosition ?? .cursor
        switch position {
        case .center, .lastPosition:
            return ClipboardPopupPosition.resolvedScreen(index: settings?.translatePopupScreen ?? 0)
        case .statusItem:
            return clipboardStatusBarButton?.window?.screen ?? NSScreen.main
        case .window:
            if let frame = NSWorkspace.shared.frontmostApplication?.clipboardWindowFrame {
                return NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main
            }
            return NSScreen.main
        case .cursor:
            let mouse = NSEvent.mouseLocation
            return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
                ?? NSScreen.main
        }
    }

    /// 夹紧到 visibleFrame：高度 ≤ 可用高；若底边越界则整体上移（向上撑开效果）。
    static func clampedTranslateFrame(
        _ currentFrame: NSRect,
        requestedHeight: CGFloat,
        visibleFrame: NSRect
    ) -> NSRect {
        let margin: CGFloat = 8
        let availableHeight = max(1, visibleFrame.height - margin * 2)
        let minimumHeight = min(220, availableHeight)
        var frame = currentFrame
        frame.size.height = min(max(requestedHeight, minimumHeight), availableHeight)

        let minX = visibleFrame.minX + margin
        let maxX = max(minX, visibleFrame.maxX - margin - frame.width)
        let minY = visibleFrame.minY + margin
        let maxOriginY = visibleFrame.maxY - margin - frame.size.height

        // 优先保留调用方给出的 origin.y（变高时已按底边锚定）；越界再夹
        frame.origin.x = min(max(frame.origin.x, minX), maxX)
        frame.origin.y = min(max(frame.origin.y, minY), max(minY, maxOriginY))
        return frame
    }

    /// 按会话内源语选择 + 目标语（已写入设置）再译所有可用服务。
    private func retranslatePopup(
        session: TranslatePopupSession,
        serviceID: String? = nil,
        alreadyMarkedLoading: Bool = false
    ) {
        guard let translation = container?.translation,
              let settings = container?.settings
        else { return }
        let text = session.sourceText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            session.flash(L10n.string("原文为空"))
            session.isTranslating = false
            session.setServicesLoading(false)
            return
        }

        // 新一轮翻译先取消旧 Task；网络请求和系统 translationTask 都会收到取消。
        translateTasks.forEach { $0.cancel() }
        translateTasks.removeAll()
        translation.cancelInFlight()
        translateGeneration = UUID()
        let generation = translateGeneration

        let services = settings.enabledTranslationServicesForPopup()
        session.configureServices(services)
        session.setServicesLoading(false)
        session.refreshDetectedLanguage()

        let targetServices = if let serviceID {
            services.filter { $0.id == serviceID }
        } else {
            services
        }
        let readyServices = targetServices.filter(\.isReadyToTranslate)
        for item in targetServices where !item.isReadyToTranslate {
            session.applyError(
                L10n.string("配置未完成，请到设置中补充密钥"),
                serviceID: item.id,
                retryable: false,
                openSettings: true
            )
        }
        guard !readyServices.isEmpty else {
            session.isTranslating = false
            relayoutTranslatePanel(for: session)
            return
        }

        session.isTranslating = true
        pendingTranslationServiceIDs = Set(readyServices.map(\.id))
        for item in readyServices {
            session.setServiceLoading(true, serviceID: item.id)
        }
        // loading 占位高度与原文变化后同步一次
        relayoutTranslatePanel(for: session)
        let sourceLang = session.sourceSelection
        let targetLang = session.targetSelection

        translateTasks = readyServices.map { service in
            Task { @MainActor [weak self, weak session] in
                guard let self, let session else { return }
                defer {
                    self.finishTranslationService(
                        serviceID: service.id,
                        generation: generation,
                        session: session
                    )
                }
                do {
                    let result = try await translation.translate(
                        [text],
                        sourceLanguage: sourceLang,
                        targetLanguage: targetLang,
                        serviceID: service.id,
                        onPartialText: { [weak self, weak session] partialText in
                            guard let self, let session,
                                  !Task.isCancelled,
                                  generation == self.translateGeneration,
                                  self.translateSession === session
                            else { return }
                            session.applyPartialText(partialText, serviceID: service.id)
                        }
                    )
                    guard !Task.isCancelled,
                          generation == self.translateGeneration,
                          self.translateSession === session
                    else { return }
                    session.applyResult(result, serviceID: service.id)
                    if result.isSameLanguage {
                        session.flash(result.userFacingNote ?? L10n.string("已是目标语言"))
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled,
                          generation == self.translateGeneration,
                          self.translateSession === session
                    else { return }
                    let message = error.localizedDescription
                    let presentation = Self.translationErrorPresentation(error)
                    session.applyError(
                        message,
                        serviceID: service.id,
                        retryable: presentation.retryable,
                        openSettings: presentation.openSettings
                    )
                    if service.kind == .system {
                        self.handleSystemTranslationFailure(message, session: session)
                    }
                }
            }
        }
    }

    private static func translationErrorPresentation(_ error: Error) -> (
        retryable: Bool,
        openSettings: Bool
    ) {
        guard let error = error as? TranslationServiceError else {
            return (retryable: true, openSettings: false)
        }
        switch error {
        case .serviceNotFound, .serviceDisabled, .missingCredentials,
             .cannotDetectLanguage, .modelNotInstalled, .unsupportedPair,
             .authenticationFailed:
            return (retryable: false, openSettings: true)
        case .emptyInput:
            return (retryable: false, openSettings: false)
        case .network, .quotaExceeded, .rateLimited, .serverUnavailable,
             .api, .invalidResponse, .failed:
            return (retryable: true, openSettings: false)
        }
    }

    private func finishTranslationService(
        serviceID: String,
        generation: UUID,
        session: TranslatePopupSession
    ) {
        guard generation == translateGeneration, translateSession === session else { return }
        pendingTranslationServiceIDs.remove(serviceID)
        // 单卡结果到位即可重算高度（不必等全部完成），避免长文/短文仍卡在初始估算
        relayoutTranslatePanel(for: session)
        guard pendingTranslationServiceIDs.isEmpty else { return }
        session.isTranslating = false
        session.setServicesLoading(false)
        translateTasks.removeAll()
        relayoutTranslatePanel(for: session)
        recordSelectionTranslateHistory(session: session)
    }

    /// 划词翻译一轮全部结束后写入历史（至少一条成功译文）。
    private func recordSelectionTranslateHistory(session: TranslatePopupSession) {
        guard let settings = container?.settings else { return }
        TranslationHistoryStore.shared.applyPolicy(from: settings)
        let snapshots = session.serviceResults.map {
            TranslationServiceSnapshot(
                serviceID: $0.id,
                displayName: $0.displayName,
                text: $0.text,
                statusMessage: $0.statusMessage
            )
        }
        TranslationHistoryStore.shared.recordSelection(
            sourceText: session.sourceText,
            sourceSelection: session.sourceSelection,
            targetSelection: session.targetSelection,
            services: snapshots
        )
    }

    private func handleSystemTranslationFailure(
        _ message: String,
        session: TranslatePopupSession
    ) {
        let hasDownloadUI = looksLikeSystemTranslationDownloadUIPresent()
        guard Self.shouldSuppressFocusDismissAfterSystemFailure(
            message: message,
            hasDownloadUI: hasDownloadUI
        ) else { return }

        // 缺语言包：保活到用户重新聚焦弹窗或显式关闭（系统下载 UI 常检测不到）
        session.beginFocusSuppress()
        Task { @MainActor [weak self, weak session] in
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, let session, self.translateSession === session else { return }
                if self.translatePanel?.isKeyWindow == true {
                    break
                }
            }
            guard let self, let session, self.translateSession === session else { return }
            session.endFocusSuppress()
            // 不强制 makeKey，避免打断用户正在操作的系统设置/下载窗
            self.translatePanel?.orderFrontRegardless()
        }
    }

    /// 缺语言包文案，或已检测到系统下载 UI 时，应抑制失焦关闭。
    static func shouldSuppressFocusDismissAfterSystemFailure(
        message: String = "",
        hasDownloadUI: Bool
    ) -> Bool {
        if hasDownloadUI { return true }
        return isMissingLanguagePackMessage(message)
    }

    static func isMissingLanguagePackMessage(_ message: String) -> Bool {
        let m = message.lowercased()
        if m.contains(L10n.string("语言包")) || m.contains(L10n.string("翻译模型")) || m.contains(L10n.string("未安装")) {
            return true
        }
        if m.contains("not installed") || m.contains("language pack") {
            return true
        }
        // TranslationServiceError.modelNotInstalled 当前文案
        if message.contains(L10n.string("系统需要")) && message.contains(L10n.string("才能翻译")) {
            return true
        }
        if message.contains(L10n.string("下载")) && (message.contains(L10n.string("语言")) || message.contains(L10n.string("翻译"))) {
            return true
        }
        return false
    }

    /// 失焦时是否应保留划词翻译窗。
    /// 点外部关窗：正常允许；系统下载语言 / 模态 / 缺包 suppress 时保留。
    private func shouldKeepTranslatePopupOpen(panel: NSPanel) -> Bool {
        if let session = translateSession, session.shouldSuppressFocusDismiss {
            return true
        }
        if NSApp.modalWindow != nil { return true }
        if panel.attachedSheet != nil { return true }
        if looksLikeSystemTranslationDownloadUIPresent() { return true }
        return false
    }

    /// 粗判：进程内是否出现系统「下载语言以翻译」一类窗口 / sheet。
    private func looksLikeSystemTranslationDownloadUIPresent() -> Bool {
        for window in NSApp.windows {
            if window === translatePanel { continue }
            if window === clipboardPanel { continue }
            if window === ocrPanel { continue }
            if window === overlayPanel { continue }
            if window === screenTranslateResultPanel { continue }
            if pinnedSTRPanels.contains(where: { $0 === window }) { continue }
            if pinnedOCRPanels.contains(where: { $0 === window }) { continue }
            if window === settingsWindow { continue }
            if window === onboardingWindow { continue }

            // sheet 可能挂在宿主小窗上（TranslationSessionHost 的 1% 透明度 panel）
            if window.attachedSheet != nil { return true }
            if window.isSheet { return true }

            guard window.isVisible || window.isSheet else { continue }

            let title = window.title
            if title.contains(L10n.string("下载语言"))
                || title.contains("Download")
                || title.contains("Language")
                || (title.contains(L10n.string("翻译")) && title.contains(L10n.string("下载")))
            {
                return true
            }

            let className = NSStringFromClass(type(of: window))
            if className.localizedCaseInsensitiveContains("Translation")
                || className.localizedCaseInsensitiveContains("RemoteView")
                || className.localizedCaseInsensitiveContains("LanguageDownload")
            {
                return true
            }
        }
        return false
    }

    /// 按设置的弹出模式计算原点（与剪切板历史共用 `ClipboardPopupPosition`）。
    private func translatePopupOrigin(
        size: NSSize,
        position: ClipboardPopupPosition
    ) -> NSPoint {
        let settings = container?.settings
        return position.origin(
            size: size,
            statusBarButton: clipboardStatusBarButton,
            popupScreen: settings?.translatePopupScreen ?? 0,
            lastPosition: settings?.translateWindowPosition ?? NSPoint(x: 0.5, y: 0.8)
        )
    }

    // MARK: - Screen translate result window（截图翻译）

    /// 左图 + OCR 原文 / 右多服务译文。未钉住时新开替换；钉住的保留。
    @discardableResult
    func showScreenTranslateResult(
        image: NSImage,
        cgImage: CGImage,
        lines: [OCRLine],
        ocrText: String,
        ocrServiceID: String,
        targetSelection: String,
        services: [TranslationServiceEntry],
        actions: ScreenTranslateResultActions
    ) -> ScreenTranslateResultSession {
        closeUnpinnedScreenTranslateResult()

        let session = ScreenTranslateResultSession(
            image: image,
            cgImage: cgImage,
            lines: lines,
            ocrText: ocrText,
            selectedOCRServiceID: ocrServiceID,
            targetSelection: targetSelection,
            services: services
        )
        session.isContentFavorited = isScreenTranslateFavorited(session)
        let viewActions = ScreenTranslateResultActions(
            enabledOCRServices: actions.enabledOCRServices,
            onClose: { [weak self, weak session] in
                guard let self, let session else { return }
                self.closeScreenTranslateResult(session)
            },
            onTogglePin: { [weak self, weak session] in
                guard let self, let session else { return }
                self.toggleScreenTranslateResultPin(session)
            },
            onRetryOCR: actions.onRetryOCR,
            onRescreen: actions.onRescreen,
            onOpenFile: actions.onOpenFile,
            onSelectOCRService: { [weak session] id in
                guard let session else { return }
                session.selectedOCRServiceID = id
                actions.onSelectOCRService(id)
            },
            onSourceLanguageChanged: { [weak session] code in
                guard let session else { return }
                session.sourceSelection = code
                actions.onSourceLanguageChanged(code)
            },
            onTargetLanguageChanged: { [weak session] code in
                guard let session else { return }
                session.targetSelection = code
                actions.onTargetLanguageChanged(code)
            },
            onRetranslate: actions.onRetranslate,
            onOpenSettings: { [weak session] in
                session?.beginFocusSuppress()
                actions.onOpenSettings()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    session?.endFocusSuppress()
                }
            },
            onFavorite: { [weak self, weak session] in
                guard let self, let session else { return }
                self.toggleFavoriteScreenTranslateSession(session)
            },
            isFavorited: { [weak self, weak session] in
                guard let self, let session else { return false }
                return self.isScreenTranslateFavorited(session)
            }
        )

        let view = ScreenTranslateResultView(
            session: session,
            actions: viewActions,
            settings: container?.settings
        )
        let panel = makeOCRResultPanel(size: NSSize(width: 960, height: 580), rootView: view)
        panel.title = L10n.string("截图翻译")
        panel.minSize = NSSize(width: 420, height: 360)
        screenTranslateResultPanel = panel
        screenTranslateResultSession = session
        attachScreenTranslateResultDelegate(panel: panel, session: session)
        installScreenTranslateResultKeyMonitor(for: panel, session: session, actions: viewActions)
        positionOCRPanelTopCenter(panel)
        AppActivation.focus(panel)
        panel.makeFirstResponder(panel.contentView)
        return session
    }

    var activeScreenTranslateResultSession: ScreenTranslateResultSession? {
        screenTranslateResultSession
    }

    private func toggleScreenTranslateResultPin(_ session: ScreenTranslateResultSession) {
        if session.isPinned {
            session.isPinned = false
            applySTRPanelLevel(for: session, pinned: false)
            session.flash(L10n.string("已取消钉住"))
            if let panel = panel(for: session) {
                let id = ObjectIdentifier(panel)
                pinnedSTRPanels.removeAll { ObjectIdentifier($0) == id }
                pinnedSTRSessions.removeValue(forKey: id)
                if screenTranslateResultPanel == nil {
                    screenTranslateResultPanel = panel
                    screenTranslateResultSession = session
                    if let mon = pinnedSTRMonitors.removeValue(forKey: id) {
                        removeSTRKeyMonitor()
                        screenTranslateResultKeyMonitor = mon
                    }
                }
            }
            return
        }
        session.isPinned = true
        applySTRPanelLevel(for: session, pinned: true)
        session.flash(L10n.string("已钉住窗口"))
        guard let panel = screenTranslateResultPanel, screenTranslateResultSession === session else { return }
        let id = ObjectIdentifier(panel)
        pinnedSTRPanels.append(panel)
        pinnedSTRSessions[id] = session
        if let mon = screenTranslateResultKeyMonitor {
            pinnedSTRMonitors[id] = mon
            screenTranslateResultKeyMonitor = nil
        }
        screenTranslateResultPanel = nil
        screenTranslateResultSession = nil
    }

    private func applySTRPanelLevel(for session: ScreenTranslateResultSession, pinned: Bool) {
        guard let panel = panel(for: session) else { return }
        panel.level = pinned ? .statusBar : .floating
        panel.hidesOnDeactivate = false
    }

    private func panel(for session: ScreenTranslateResultSession) -> NSPanel? {
        if screenTranslateResultSession === session { return screenTranslateResultPanel }
        for (id, s) in pinnedSTRSessions where s === session {
            return pinnedSTRPanels.first { ObjectIdentifier($0) == id }
        }
        return nil
    }

    private func attachScreenTranslateResultDelegate(
        panel: NSPanel,
        session: ScreenTranslateResultSession
    ) {
        let id = ObjectIdentifier(panel)
        let delegate = OCRPanelWindowDelegate { [weak self, weak session, weak panel] in
            guard let self, let session, let panel else { return }
            guard !session.isPinned else { return }
            // 与划词一致：系统装语言包 / 模态 / 会话 suppress 时保留窗口
            Task { @MainActor [weak self, weak session, weak panel] in
                try? await Task.sleep(for: .milliseconds(120))
                guard let self, let session, let panel else { return }
                while !panel.isKeyWindow, self.shouldKeepScreenTranslateResultOpen(session: session, panel: panel) {
                    try? await Task.sleep(for: .milliseconds(180))
                    guard self.panel(for: session) === panel else { return }
                }
                guard !session.isPinned else { return }
                guard !panel.isKeyWindow, self.panel(for: session) === panel else { return }
                guard !self.shouldKeepScreenTranslateResultOpen(session: session, panel: panel) else { return }
                self.closeScreenTranslateResult(session)
            }
        }
        panel.delegate = delegate
        screenTranslateResultDelegates[id] = delegate
    }

    /// 截图翻译窗失焦是否应保留（系统下载语言包 / 模态 / 会话 suppress）。
    private func shouldKeepScreenTranslateResultOpen(
        session: ScreenTranslateResultSession,
        panel: NSPanel
    ) -> Bool {
        if session.shouldSuppressFocusDismiss { return true }
        if NSApp.modalWindow != nil { return true }
        if panel.attachedSheet != nil { return true }
        if looksLikeSystemTranslationDownloadUIPresent() { return true }
        return false
    }

    private func closeScreenTranslateResult(_ session: ScreenTranslateResultSession) {
        if screenTranslateResultSession === session {
            closeUnpinnedScreenTranslateResult()
            return
        }
        if let panel = panel(for: session) {
            let id = ObjectIdentifier(panel)
            if let mon = pinnedSTRMonitors.removeValue(forKey: id) {
                NSEvent.removeMonitor(mon)
            }
            pinnedSTRSessions.removeValue(forKey: id)
            pinnedSTRPanels.removeAll { ObjectIdentifier($0) == id }
            screenTranslateResultDelegates.removeValue(forKey: id)
            panel.delegate = nil
            panel.contentView = nil
            panel.orderOut(nil)
            notifyCaptureResultWindowsDidChange()
        }
    }

    private func closeUnpinnedScreenTranslateResult() {
        removeSTRKeyMonitor()
        if let panel = screenTranslateResultPanel {
            let id = ObjectIdentifier(panel)
            screenTranslateResultDelegates.removeValue(forKey: id)
            panel.delegate = nil
            panel.contentView = nil
            panel.orderOut(nil)
        }
        screenTranslateResultPanel = nil
        screenTranslateResultSession = nil
        notifyCaptureResultWindowsDidChange()
    }

    private func installScreenTranslateResultKeyMonitor(
        for panel: NSPanel,
        session: ScreenTranslateResultSession,
        actions: ScreenTranslateResultActions
    ) {
        removeSTRKeyMonitor()
        screenTranslateResultKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self, weak panel, weak session] event in
            guard let self, let panel, let session else { return event }
            guard event.window === panel || panel.isKeyWindow else { return event }
            if TextInputSession.isComposing(in: event.window) {
                return event
            }
            guard let settings = self.container?.settings else { return event }
            if settings.matches(.ocrClose, event: event)
                || settings.matches(.ocrCloseCommandW, event: event)
            {
                actions.onClose()
                return nil
            }
            if settings.matches(.ocrTogglePin, event: event) {
                actions.onTogglePin()
                return nil
            }
            if settings.matches(.ocrRetry, event: event) {
                actions.onRetryOCR()
                return nil
            }
            return event
        }
    }

    private func removeSTRKeyMonitor() {
        if let screenTranslateResultKeyMonitor {
            NSEvent.removeMonitor(screenTranslateResultKeyMonitor)
            self.screenTranslateResultKeyMonitor = nil
        }
    }

    // MARK: - Screen translate overlay（原图翻译）

    @discardableResult
    func showScreenTranslateOverlay(
        image: CGImage,
        imageSize: CGSize,
        selection: CaptureRegion,
        lines: [OverlayLine],
        ocrServiceID: String,
        translationServiceID: String,
        sourceLanguage: String,
        targetLanguage: String,
        mode: ScreenTranslateOverlayMode = .imageTranslate,
        actions: ScreenTranslateOverlayActions
    ) -> ScreenTranslateOverlaySession {
        closeOverlay()
        let session = ScreenTranslateOverlaySession(
            image: image,
            imageSize: imageSize,
            selection: selection,
            lines: lines,
            ocrServiceID: ocrServiceID,
            translationServiceID: translationServiceID,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            mode: mode
        )

        let visibleFrame = NSScreen.screens
            .first(where: { $0.frame.intersects(selection.rectInScreenPoints) })?
            .visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? selection.rectInScreenPoints
        let toolbarWidth = ScreenTranslateOverlayView.toolbarWidth(for: visibleFrame.width)
        let toolbarHeight = ScreenTranslateOverlayView.toolbarHeight(for: toolbarWidth)
        let placement = Self.screenTranslateOverlayPlacement(
            selection: selection.rectInScreenPoints,
            visibleFrame: visibleFrame,
            requestedToolbarWidth: toolbarWidth,
            requestedToolbarHeight: toolbarHeight
        )
        let view = ScreenTranslateOverlayView(
            session: session,
            actions: ScreenTranslateOverlayActions(
                enabledOCRServices: actions.enabledOCRServices,
                enabledTranslationServices: actions.enabledTranslationServices,
                onSelectOCR: actions.onSelectOCR,
                onSelectTranslation: actions.onSelectTranslation,
                onSourceLanguageChanged: actions.onSourceLanguageChanged,
                onTargetLanguageChanged: actions.onTargetLanguageChanged,
                onRetranslate: actions.onRetranslate,
                onClose: { [weak self] in self?.closeOverlay() }
            ),
            toolbarAbove: placement.toolbarAbove,
            toolbarWidth: toolbarWidth,
            toolbarHeight: toolbarHeight
        )

        // 需 canBecomeKey，否则译文无法选中；不用 nonactivating，便于文本选择/复制
        let panel = ClipboardPanel(
            contentRect: placement.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        let hosting = NSHostingView(rootView: themed(view))
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.setFrame(placement.frame, display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        overlayPanel = panel
        screenTranslateSession = session
        return session
    }

    /// 选区外下方放置工具栏，并让工具栏右边缘与选区右边缘对齐。
    /// 屏幕底部空间不足时自动切换到选区上方，避免工具栏被 Dock 或屏幕边缘裁掉。
    static func screenTranslateOverlayPlacement(
        selection: CGRect,
        visibleFrame: CGRect,
        requestedToolbarWidth: CGFloat? = nil,
        requestedToolbarHeight: CGFloat? = nil
    ) -> (frame: NSRect, toolbarAbove: Bool) {
        let toolbarWidth = requestedToolbarWidth
            ?? ScreenTranslateOverlayView.toolbarWidth(for: visibleFrame.width)
        let toolbarHeight = requestedToolbarHeight
            ?? ScreenTranslateOverlayView.toolbarHeight(for: toolbarWidth)
        let gap = ScreenTranslateOverlayView.toolbarGap
        let panelWidth = max(selection.width, toolbarWidth)
        let panelHeight = selection.height + toolbarHeight + gap
        let margin: CGFloat = 8

        var originX = selection.maxX - panelWidth
        let minX = visibleFrame.minX + margin
        let maxX = max(minX, visibleFrame.maxX - panelWidth - margin)
        originX = min(max(originX, minX), maxX)

        let belowY = selection.minY - toolbarHeight - gap
        let aboveY = selection.maxY + gap
        let minY = visibleFrame.minY + margin
        let maxY = max(minY, visibleFrame.maxY - panelHeight - margin)
        let fitsBelow = belowY >= minY
            && belowY + panelHeight <= visibleFrame.maxY - margin
        let toolbarAbove = !fitsBelow
        let originY = min(max(toolbarAbove ? aboveY : belowY, minY), maxY)

        return (
            NSRect(x: originX, y: originY, width: panelWidth, height: panelHeight),
            toolbarAbove
        )
    }

    // MARK: - Clipboard

    func showClipboardHistory() {
        guard let container else { return }
        if clipboardPanel?.isVisible == true {
            closeClipboard()
            return
        }

        // 在创建窗口前锁定原前台 App，自动粘贴仍需回到这里。
        rememberClipboardPasteTarget()
        let position = container.settings.clipboardPopupPosition
        let size = NSSize(width: 360, height: 560)
        let origin = position.origin(
            size: size,
            statusBarButton: clipboardStatusBarButton,
            popupScreen: container.settings.clipboardPopupScreen,
            lastPosition: container.settings.clipboardWindowPosition
        )
        let targetFrame = NSRect(origin: origin, size: size)
        clipboardVisibleFrame = NSScreen.screens
            .first(where: { $0.frame.intersects(targetFrame) })?
            .visibleFrame

        let view = ClipboardHistoryView(
            container: container,
            onPaste: { [weak self] item, plainText in
                self?.pasteClipboardItem(item, plainText: plainText)
            },
            onClose: { [weak self] in
                self?.closeClipboard()
            },
            onPreviewChanged: { [weak self] isOpen in
                self?.resizeClipboardPreview(isOpen: isOpen)
            },
            onTranslate: { [weak self] item in
                self?.translateClipboardItem(item)
            }
        )
        // contentRect 直接用目标屏幕坐标创建，避免先落在 (0,0) 再挪。
        // 不用 nonactivatingPanel：否则前台仍是外部输入框，↑↓/回车先被外部 App 吃掉，
        // local monitor 收不到键（accessory 菜单栏 App 尤甚）。粘贴目标已在上面锁定。
        let panel = ClipboardPanel(
            contentRect: targetFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.onResignKey = { [weak self] in self?.closeClipboard() }
        panel.onEndLiveMove = { [weak panel, settings = container.settings] in
            guard let panel, let visible = panel.screen?.visibleFrame else { return }
            let anchorX = panel.frame.minX + 180 - visible.minX
            let anchorY = panel.frame.maxY - visible.minY
            settings.clipboardWindowPosition = NSPoint(
                x: anchorX / visible.width,
                y: anchorY / visible.height
            )
        }
        panel.delegate = panel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isMovable = position != .statusItem
        panel.isMovableByWindowBackground = position != .statusItem
        panel.contentView = NSHostingView(rootView: themed(view))
        panel.setFrame(targetFrame, display: false)
        clipboardPanel = panel

        // 抢激活 + key，否则方向键仍进「刚才的输入框」。
        // 不要 makeFirstResponder(contentView)：大块 hosting 成为焦点时，
        // 系统可能把指针移到该视图几何中心（多屏/居中面板时像「飞到屏幕中央」）。
        // 也不要 CGWarp 回移：坐标换算易错，反而把鼠标弄到错误位置。
        // 只前置剪切板浮层，不抬起偏好设置等其它窗。
        AppActivation.focus(panel)
        if position == .statusItem {
            DispatchQueue.main.async { [weak self] in
                self?.clipboardStatusBarButton?.isHighlighted = true
            }
        }
        panel.setFrame(targetFrame, display: true)
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, self.clipboardPanel === panel else { return }
            panel.setFrame(targetFrame, display: true)
            if !panel.isKeyWindow {
                panel.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// 剪切板卡片翻译：文本 → 划词窗；图片 → 截图翻译结果窗（OCR + 多服务）
    private func translateClipboardItem(_ item: HistoryItem) {
        closeClipboard()

        // 优先纯文本
        if let text = item.string {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                showTranslatePopup(
                    source: text,
                    translated: "",
                    statusMessage: nil,
                    autoTranslate: true
                )
                return
            }
        }

        // 图片：走截图翻译（OCR 后多服务译）
        if let image = item.image {
            var rect = NSRect(origin: .zero, size: image.size)
            guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
                flashStatus(L10n.string("无法读取图片"), level: .error)
                return
            }
            guard let workflows = container?.workflows else {
                flashStatus(L10n.string("无法启动图片翻译"), level: .error)
                return
            }
            Task { await workflows.runScreenTranslateFromImage(cg) }
            return
        }

        flashStatus(L10n.string("该条目无法翻译"), level: .error)
    }

    /// 设置页内嵌历史：只写回系统剪切板，不模拟粘贴、不关窗。
    func copyClipboardItemToPasteboard(_ item: HistoryItem, plainText: Bool) {
        guard let container else {
            flashStatus(L10n.string("复制失败"), level: .error)
            return
        }
        // 先提升为最新，再写回系统剪切板（忽略写回触发的监听）
        _ = container.historyStore.markAsLatestCopy(id: item.id)
        guard container.pasteboardMonitor.writeToPasteboard(item, plainText: plainText) else {
            flashStatus(L10n.string("复制失败"), level: .error)
            return
        }
    }

    /// 设置页 / 其它入口：剪切板条目翻译（文本 → 划词；图片 → 截图翻译）。
    func translateClipboardHistoryItem(_ item: HistoryItem) {
        translateClipboardItem(item)
    }

    // MARK: - Favorites（无 Toast；UI 用实心星反馈）

    private func toggleFavoriteOCRSession(_ session: OCRResultSession) {
        guard let store = container?.historyStore else { return }
        session.isContentFavorited = store.toggleFavorite(
            text: session.text,
            image: session.image,
            application: "com.snapflow.ocr"
        )
    }

    private func toggleFavoriteScreenTranslateSession(_ session: ScreenTranslateResultSession) {
        guard let store = container?.historyStore else { return }
        let text = screenTranslateFavoriteText(session)
        session.isContentFavorited = store.toggleFavorite(
            text: text,
            image: session.image,
            application: "com.snapflow.translate"
        )
    }

    private func isScreenTranslateFavorited(_ session: ScreenTranslateResultSession) -> Bool {
        container?.historyStore.isFavorited(
            text: screenTranslateFavoriteText(session),
            image: session.image
        ) ?? false
    }

    private func screenTranslateFavoriteText(_ session: ScreenTranslateResultSession) -> String? {
        let primary = session.serviceResults
            .first(where: {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })?
            .text
        if let primary, !primary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return primary
        }
        let ocr = session.ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        return ocr.isEmpty ? nil : session.ocrText
    }

    func favoritePinnedImage(_ image: NSImage) {
        _ = container?.historyStore.toggleFavorite(image: image, application: "com.snapflow.snip")
    }

    /// 记录粘贴回填目标：优先当前前台普通 App；否则用最近一次有效目标 / 其它 .regular App。
    private func rememberClipboardPasteTarget() {
        let ownPID = ProcessInfo.processInfo.processIdentifier

        func adopt(_ app: NSRunningApplication?) -> Bool {
            guard let app,
                  app.processIdentifier != ownPID,
                  !app.isTerminated,
                  app.activationPolicy == .regular
            else { return false }
            clipboardTargetApplication = app
            clipboardTargetPID = app.processIdentifier
            return true
        }

        // 1) Workspace 前台
        if adopt(NSWorkspace.shared.frontmostApplication) { return }

        // 2) Accessibility 焦点 App（菜单栏 App 激活后 frontmost 常变成自己）
        if let axPID = focusedApplicationPID(),
           axPID != ownPID,
           adopt(NSRunningApplication(processIdentifier: axPID))
        {
            return
        }

        // 3) 保留此前目标
        if let existing = clipboardTargetApplication,
           !existing.isTerminated,
           existing.processIdentifier != ownPID
        {
            clipboardTargetPID = existing.processIdentifier
            return
        }
        if clipboardTargetPID != 0,
           adopt(NSRunningApplication(processIdentifier: clipboardTargetPID))
        {
            return
        }

        // 4) 回退：任意已启动的普通 GUI App（非自己）—— 最后手段
        _ = adopt(
            NSWorkspace.shared.runningApplications.first(where: {
                $0.activationPolicy == .regular
                    && $0.processIdentifier != ownPID
                    && !$0.isTerminated
                    && $0.bundleIdentifier != nil
            })
        )
    }

    /// 当前系统焦点所在 App 的 PID（需辅助功能；失败返回 nil）。
    private func focusedApplicationPID() -> pid_t? {
        let system = AXUIElementCreateSystemWide()
        var ref: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            system,
            kAXFocusedApplicationAttribute as CFString,
            &ref
        )
        guard status == .success, let ref else { return nil }
        let element = unsafeBitCast(ref, to: AXUIElement.self)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid != 0 else { return nil }
        return pid
    }

    private func resolvedClipboardPasteTarget() -> NSRunningApplication? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let app = clipboardTargetApplication,
           !app.isTerminated,
           app.processIdentifier != ownPID
        {
            return app
        }
        if clipboardTargetPID != 0,
           let app = NSRunningApplication(processIdentifier: clipboardTargetPID),
           !app.isTerminated,
           app.processIdentifier != ownPID
        {
            return app
        }
        return nil
    }

    private func pasteClipboardItem(_ item: HistoryItem, plainText: Bool) {
        guard let container else { return }
        // 选中/粘贴该条 = 视为最新复制：更新时间并排到置顶项之后
        _ = container.historyStore.markAsLatestCopy(id: item.id)
        let monitor = container.pasteboardMonitor
        let mixedGroups = plainText
            ? []
            : monitor.pasteboardContentGroups(for: item, includeFileContents: false)
        let accessibilityGranted = container.permissions.isAccessibilityGranted()
        let shouldPasteGroups = accessibilityGranted && mixedGroups.count > 1

        if shouldPasteGroups {
            guard let firstGroup = mixedGroups.first,
                  monitor.writeToPasteboard(contents: firstGroup)
            else { return }
        } else {
            guard monitor.writeToPasteboard(item, plainText: plainText) else { return }
        }

        // 解析目标（强引用 + PID 双保险），再关窗
        let target = resolvedClipboardPasteTarget()
        closeClipboard()

        guard accessibilityGranted else {
            // 已写入剪切板，用户可手动 ⌘V；提示一次辅助功能
            if !hasShownClipboardAccessibilityGuide {
                hasShownClipboardAccessibilityGuide = true
                UserDefaults.standard.set(true, forKey: "clipboard.hasShownAccessibilityGuide")
                DispatchQueue.main.async { [weak self] in
                    self?.showPermissionAlert(for: .accessibility)
                }
            }
            return
        }

        // 必须等目标 App 真正成为前台后再发 ⌘V，否则会贴回 SnapFlow 或丢焦点
        activatePreviousAppAndPaste(target)
        if shouldPasteGroups {
            pasteClipboardGroups(Array(mixedGroups.dropFirst()), monitor: monitor, target: target)
        }
    }

    /// 回到呼出剪切板前的 App，确认前台后再模拟 ⌘V。
    private func activatePreviousAppAndPaste(_ target: NSRunningApplication?) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let target,
              target.processIdentifier != ownPID,
              !target.isTerminated
        else {
            // 无可靠目标：仅保证剪切板已写好
            return
        }

        let targetPID = target.processIdentifier
        yieldActivationAndActivate(target)

        var attempts = 0
        func attemptPaste() {
            attempts += 1
            let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if frontPID == targetPID || attempts >= 12 {
                // 再给焦点恢复一帧，避免窗口在前但输入焦点未回
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.postClipboardPasteShortcut()
                }
                return
            }
            // 前台尚未切回：再激活并重试
            if attempts == 4 || attempts == 8 {
                yieldActivationAndActivate(target)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: attemptPaste)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: attemptPaste)
    }

    /// macOS 14+ 必须先 `yieldActivation` 再 `activate(from:)`；
    /// 旧系统继续用 `activateIgnoringOtherApps`。
    private func yieldActivationAndActivate(_ target: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: target)
            _ = target.activate(from: .current, options: [.activateAllWindows])
        } else {
            _ = target.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
    }

    private func pasteClipboardGroups(
        _ groups: [[HistoryItemContent]],
        monitor: PasteboardMonitor,
        target: NSRunningApplication?
    ) {
        guard let nextGroup = groups.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
            guard let self,
                  monitor.writeToPasteboard(contents: nextGroup)
            else { return }
            // 多段粘贴：确保仍在目标 App
            if let target, !target.isTerminated {
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                if front != target.processIdentifier {
                    yieldActivationAndActivate(target)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.postClipboardPasteShortcut()
                        self?.pasteClipboardGroups(Array(groups.dropFirst()), monitor: monitor, target: target)
                    }
                    return
                }
            }
            self.postClipboardPasteShortcut()
            self.pasteClipboardGroups(Array(groups.dropFirst()), monitor: monitor, target: target)
        }
    }

    private func postClipboardPasteShortcut() {
        let source = CGEventSource(stateID: .combinedSessionState)
        // hidSystemState 对跨 App 模拟按键更稳
        source?.localEventsSuppressionInterval = 0
        let keyCode = Sauce.shared.keyCode(for: .v)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // hid 层投递，减少被 session 路由回本 App 的概率
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func resizeClipboardPreview(isOpen: Bool) {
        guard let panel = clipboardPanel else { return }
        var frame = panel.frame
        // 主栏 360 + 预览 320 = 680，与 ClipboardHistoryView 一致
        let visible = clipboardVisibleFrame ?? panel.screen?.visibleFrame
        frame.size.width = min(isOpen ? 680 : 360, visible?.width ?? 680)
        if let visible {
            // 左上角锚点固定：加宽时向右扩展，收窄时右边收回
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        }
        panel.setFrame(frame, display: true, animate: true)
    }

    // MARK: - Settings / Onboarding

    /// 打开设置窗口；可选跳到指定侧栏页（OCR 服务 / 翻译服务等）。
    /// - Parameter openAddCustomFavorite: 为 true 时进入「收藏」并弹出「添加自定义收藏」。
    /// 菜单栏 App（`.accessory`）统一用这一扇窗，避免与 SwiftUI `Settings` 场景双开。
    /// 关闭后卸掉 `NSHostingView`（保留空壳窗），只清缩略图内存缓存；**不**换 HistoryStore
    /// 的 `ModelContext`（设置页与剪切板共享，关窗时 recycle 会 `EXC_BAD_ACCESS`）。
    func showSettings(pane: SettingsPane = .capture, openAddCustomFavorite: Bool = false) {
        guard let container else { return }
        // 用户主动打开设置：允许成为 key，并正常前置本窗
        AppActivation.noteProtectedWindowUserInteraction()
        AppActivation.endOverlayChrome()

        let resolvedPane = openAddCustomFavorite ? SettingsPane.favorites : pane
        let view = SettingsView(
            initialPane: resolvedPane,
            openAddCustomFavorite: openAddCustomFavorite
        )
            .environment(container)
            .snapFlowAppearance(settings: container.settings)
            .frame(minWidth: 720, minHeight: 480)
        let host = NSHostingView(rootView: view)

        // 已有实例：菜单栏再次点「偏好设置」时只需抬到最前；deep link / 空壳再换 content
        if let settingsWindow {
            AppActivation.stackingProtectedWindow = settingsWindow
            let hasHosting = settingsWindow.contentView.map {
                NSStringFromClass(type(of: $0)).contains("HostingView")
            } ?? false
            let shouldRebuildContent =
                !hasHosting
                || !settingsWindow.isVisible
                || openAddCustomFavorite
                || pane != .capture
            if shouldRebuildContent {
                settingsWindow.contentView = host
            }
            presentTopLevelWindow(settingsWindow, recenterIfHidden: true, keepAboveOtherApps: false)
            return
        }

        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("snapflow.settings")
        window.title = L10n.string("SnapFlow 设置")
        window.contentView = host
        window.setContentSize(NSSize(width: 860, height: 680))
        window.minSize = NSSize(width: 720, height: 480)
        // 保持 false：关窗只隐藏；由我们卸 content，避免 isReleasedWhenClosed + 自代理拆窗崩溃。
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // 普通窗口层级：打开时提到前台即可，之后可被其它 App 盖住
        window.level = .normal
        window.delegate = window
        window.onWillClose = { [weak self] in
            self?.handleSettingsWindowWillClose()
        }
        window.center()
        settingsWindow = window
        AppActivation.stackingProtectedWindow = window
        presentTopLevelWindow(window, recenterIfHidden: false, keepAboveOtherApps: false)
    }

    /// 设置窗关闭后：卸掉 SwiftUI 宿主，保留空壳窗口供下次复用。
    private func handleSettingsWindowWillClose() {
        if AppActivation.stackingProtectedWindow === settingsWindow {
            AppActivation.stackingProtectedWindow = nil
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.settingsWindow else { return }
            // 已再次打开则不要卸
            guard !window.isVisible else { return }
            window.makeFirstResponder(nil)
            // 空 NSView 替换 hosting，释放设置页视图树；勿 contentView=nil（AppKit 边界更稳）
            window.contentView = NSView(frame: window.contentLayoutRect)
            // 仅清缩略图 NSCache；HistoryStore 留给剪切板面板自己的 close 路径回收
            ClipboardImageThumbnailCache.removeAllMemory()
        }
    }

    /// 关掉未钉住的 OCR 结果窗（再次截图 OCR / 转翻译前调用）
    func closeUnpinnedOCRResult() {
        closeUnpinnedOCR()
    }

    /// 关掉指定 OCR 会话（含钉住）
    func dismissOCRSession(_ session: OCRResultSession) {
        closeOCRSession(session)
    }

    /// 关掉未钉住的截图翻译结果窗
    func closeUnpinnedScreenTranslateResultWindow() {
        closeUnpinnedScreenTranslateResult()
    }

    func showOnboarding() {
        guard let container else { return }
        let view = OnboardingView(container: container) { [weak self] in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
        }
        .snapFlowAppearance(settings: container.settings)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.string("欢迎使用 SnapFlow")
        window.contentView = NSHostingView(rootView: view)
        window.setContentSize(NSSize(width: 520, height: 460))
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()
        onboardingWindow = window
        presentTopLevelWindow(window, recenterIfHidden: false)
    }

    /// 在 **保持 `.accessory`（不出现程序坞图标）** 的前提下把窗提到最前。
    /// 不切换为 `.regular`，否则 Dock 会闪出应用图标。
    /// - Parameter keepAboveOtherApps: `true` 使用 floating 层级（始终压在其它 App 上）；
    ///   `false`（偏好设置）使用 normal 层级——打开时提到前台，之后可被其它应用盖住。
    private func presentTopLevelWindow(
        _ window: NSWindow,
        recenterIfHidden: Bool,
        keepAboveOtherApps: Bool = true
    ) {
        // 始终保持菜单栏形态
        if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        if recenterIfHidden, !window.isVisible {
            window.center()
        }

        window.collectionBehavior.insert(.moveToActiveSpace)
        // floating：始终压在其它 App 上；normal：打开瞬间抬到顶层，之后仍可被其它 App 盖住
        window.level = keepAboveOtherApps ? .floating : .normal

        // 用户主动打开：允许 key，并强制抬到最前（含「设置已开、菜单栏再点一次」）
        AppActivation.noteProtectedWindowUserInteraction()
        _ = NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        window.makeKeyAndOrderFront(nil)
        // accessory 下仅 makeKeyAndOrderFront 常压不过其它 App；无论 normal/floating 都 orderFrontRegardless 一次
        window.orderFrontRegardless()

        // 状态栏菜单收起瞬间可能抢走焦点，下一拍再提一次
        DispatchQueue.main.async {
            if NSApp.activationPolicy() != .accessory {
                NSApp.setActivationPolicy(.accessory)
            }
            _ = NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    func showPermissionAlert(for permission: AppPermission) {
        let alert = NSAlert()
        alert.messageText = String(format: L10n.string("需要%@权限"), permission.title)
        alert.informativeText = permission.message
        alert.addButton(withTitle: L10n.string("打开系统设置"))
        alert.addButton(withTitle: L10n.string("取消"))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            container?.permissions.openSystemSettings(for: permission)
        }
    }

    // MARK: - Helpers

    private func discardClosedPins() {
        pinnedWindows.removeAll { window in
            !window.isVisible && !hiddenPinnedWindows.contains { $0 === window }
        }
    }

    private func closeOCR() {
        closeUnpinnedOCR()
        // 钉住的窗不随全局 close 清除，除非调用方明确关闭单窗
    }

    private func closeTranslate() {
        // 关窗即取消进行中的翻译（含 loading 时点外部 / Esc）
        translateTasks.forEach { $0.cancel() }
        translateTasks.removeAll()
        pendingTranslationServiceIDs.removeAll()
        translateGeneration = UUID()
        if let session = translateSession, session.isTranslating {
            container?.translation.cancelInFlight()
            session.isTranslating = false
            session.setServicesLoading(false)
        } else {
            container?.translation.cancelInFlight()
        }
        if let panel = translatePanel {
            panel.onResignKey = nil
            panel.onEndLiveMove = nil
            panel.delegate = nil
            panel.orderOut(nil)
        }
        translatePanel = nil
        translateSession = nil
        // 菜单栏高亮仅在剪切板未开时收回
        if clipboardPanel == nil {
            clipboardStatusBarButton?.isHighlighted = false
        }
    }

    private func closeOverlay() {
        screenTranslateSession?.isClosed = true
        container?.translation.cancelInFlight()
        overlayPanel?.contentView = nil
        overlayPanel?.orderOut(nil)
        overlayPanel = nil
        screenTranslateSession = nil
        notifyCaptureResultWindowsDidChange()
    }

    private func closeClipboard() {
        clipboardStatusBarButton?.isHighlighted = false
        clipboardPanel?.orderOut(nil)
        clipboardPanel = nil
        clipboardVisibleFrame = nil
        // 1) 清缩略图内存缓存 2) 换新 ModelContext，丢掉滚动时 fault 进来的全图 Data。
        ClipboardImageThumbnailCache.removeAll()
        container?.historyStore.releaseFaultedImagePayloads()
        // 保留 clipboardTargetApplication / PID 到下次呼出覆盖，避免粘贴竞态清空；
        // 仅在明确无会话时由 remember 覆盖。这里仍清空 App 引用以免悬挂，PID 可保留一周期。
        clipboardTargetApplication = nil
        // clipboardTargetPID 保留：下次 remember 可作回退；粘贴已在 close 前 resolved
    }

}

// MARK: - 设置窗口输入焦点

/// 设置页内的 SwiftUI 文本输入控件使用 AppKit field editor。
/// macOS 点击按钮、Picker 或空白区域时不一定会自动让 field editor 失焦，
/// 因此在设置窗口范围内统一处理鼠标按下事件。
/// 同时作为 `NSWindowDelegate`：关闭后由 presenter 卸掉 hosting 视图。
private final class SettingsWindow: NSWindow, NSWindowDelegate {
    var onWillClose: (() -> Void)?

    /// 截图/录制会话中由 `AppActivation` 禁止自动成为 key，避免关选区后设置窗抢前台。
    override var canBecomeKey: Bool {
        AppActivation.protectedWindowCanBecomeKey
    }

    override var canBecomeMain: Bool {
        AppActivation.protectedWindowCanBecomeKey
    }

    override func sendEvent(_ event: NSEvent) {
        // 用户主动点设置窗：允许聚焦，并视为交互
        if event.type == .leftMouseDown {
            AppActivation.noteProtectedWindowUserInteraction()
        }
        if event.type == .leftMouseDown,
           isEditingText,
           !isEditableTextInput(at: event.locationInWindow)
        {
            makeFirstResponder(nil)
        }

        super.sendEvent(event)
    }

    func windowWillClose(_ notification: Notification) {
        if AppActivation.stackingProtectedWindow === self {
            AppActivation.stackingProtectedWindow = nil
        }
        onWillClose?()
    }

    private var isEditingText: Bool {
        if let textField = firstResponder as? NSTextField {
            return textField.isEditable
        }
        if let textView = firstResponder as? NSTextView {
            return textView.isEditable || textView.isFieldEditor
        }
        return false
    }

    private func isEditableTextInput(at windowPoint: NSPoint) -> Bool {
        guard let contentView else { return false }
        let contentPoint = contentView.convert(windowPoint, from: nil)
        var view = contentView.hitTest(contentPoint)

        while let current = view {
            if let textField = current as? NSTextField, textField.isEditable {
                return true
            }
            if let textView = current as? NSTextView, textView.isEditable || textView.isFieldEditor {
                return true
            }
            view = current.superview
        }
        return false
    }
}

// MARK: - OCR 浮窗

/// borderless 默认 `canBecomeKey == false`，会导致右侧 TextEditor 无法编辑。
final class OCRResultPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class ClipboardPanel: NSPanel, NSWindowDelegate {
    var onResignKey: (() -> Void)?
    var onEndLiveMove: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    /// 拖动结束/位置变化时记「上次位置」。
    /// （`windowDidEndLiveMove` 不是正式 delegate API，此前几乎不会触发。）
    func windowDidMove(_ notification: Notification) {
        onEndLiveMove?()
    }
}

// MARK: - OCR 浮窗失焦关闭

/// 未钉住时 `resignKey` → 关闭（模态/短暂失焦有延迟保护）。
@MainActor
private final class OCRPanelWindowDelegate: NSObject, NSWindowDelegate {
    private let onResignKey: () -> Void

    init(onResignKey: @escaping () -> Void) {
        self.onResignKey = onResignKey
    }

    func windowDidResignKey(_ notification: Notification) {
        onResignKey()
    }
}
