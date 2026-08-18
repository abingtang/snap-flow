import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum CaptureOperationKind: Hashable, Sendable {
    case screenshot
    case service
}

@MainActor
final class CaptureOperationCoordinator {
    struct Token: Equatable, Sendable {
        fileprivate let kind: CaptureOperationKind
        fileprivate let id: UUID
    }

    struct StartedOperation {
        let token: Token
        let task: Task<Void, Never>
    }

    private var currentTokens: [CaptureOperationKind: Token] = [:]
    private var tasks: [CaptureOperationKind: Task<Void, Never>] = [:]

    @discardableResult
    func start(
        kind: CaptureOperationKind,
        operation: @escaping @MainActor (Token) async -> Void
    ) -> StartedOperation {
        tasks[kind]?.cancel()

        let token = Token(kind: kind, id: UUID())
        currentTokens[kind] = token
        let task = Task { @MainActor in
            await operation(token)
        }
        tasks[kind] = task
        return StartedOperation(token: token, task: task)
    }

    func isCurrent(_ token: Token) -> Bool {
        currentTokens[token.kind] == token
    }

    func cancel(_ token: Token) {
        guard isCurrent(token) else { return }
        tasks[token.kind]?.cancel()
        tasks[token.kind] = nil
        currentTokens[token.kind] = nil
    }

    func finish(_ token: Token) {
        guard isCurrent(token) else { return }
        tasks[token.kind] = nil
        currentTokens[token.kind] = nil
    }
}

/// 编排截图 / OCR / 翻译。当前主路径：**Snipaste 风格区域截图**。
@MainActor
final class AppWorkflows {
    private let settings: SettingsStore
    private let permissions: PermissionManager
    private let screenCapture: ScreenCaptureService
    private let ocr: OCRRouter
    private let translation: TranslationService
    private let textSelection: TextSelectionService
    private let panelPresenter: PanelPresenter
    private weak var pasteboardMonitor: PasteboardMonitor?
    private let recordingHistory: RecordingHistoryStore

    private let captureOperations = CaptureOperationCoordinator()
    private var activeSelectionToken: CaptureOperationCoordinator.Token?
    /// 最近一次截图/识别源图；仅在仍有 OCR/截图翻译结果窗时保留，关窗后清空以免台阶式涨内存。
    private var lastCaptureImage: CGImage?
    private var recordingEngine: ScreenRecordingEngine?
    private var recordingHUD: RecordingHUDPanel?
    private var recordingBorder: RecordingBorderPanel?
    private var recordingMask: RecordingMaskPanel?
    private var recordingProcessing: RecordingProcessingPanel?
    private var recordingScreen: NSScreen?
    private var recordingRegion: CaptureRegion?
    private var recordingEscapeMonitor: Any?
    private var recordingLocalEscapeMonitor: Any?
    private var didShowRecordingBlockedFeedback = false

    init(
        settings: SettingsStore,
        permissions: PermissionManager,
        screenCapture: ScreenCaptureService,
        ocr: OCRRouter,
        translation: TranslationService,
        textSelection: TextSelectionService,
        panelPresenter: PanelPresenter,
        pasteboardMonitor: PasteboardMonitor? = nil,
        recordingHistory: RecordingHistoryStore
    ) {
        self.settings = settings
        self.permissions = permissions
        self.screenCapture = screenCapture
        self.ocr = ocr
        self.translation = translation
        self.textSelection = textSelection
        self.panelPresenter = panelPresenter
        self.pasteboardMonitor = pasteboardMonitor
        self.recordingHistory = recordingHistory
    }

    /// 结果窗/叠层全部关闭后释放兜底位图。由 `PanelPresenter` 在关窗路径调用。
    func clearTransientCaptureBuffersIfIdle() {
        guard !panelPresenter.isHoldingCaptureResultBuffers else { return }
        lastCaptureImage = nil
    }

    // MARK: - 功能历史还原

    /// 截图历史：复制图片到剪切板。
    func copySnipHistoryToPasteboard(_ record: SnipHistoryStore.Record) {
        guard let image = SnipHistoryStore.shared.loadImage(for: record) else {
            panelPresenter.flashStatus(L10n.string("历史图片已丢失"), level: .error)
            return
        }
        copyImage(image)
    }

    /// 截图历史：将原图贴到屏幕（尽量回到原选区位置）。
    func pinSnipHistoryToScreen(_ record: SnipHistoryStore.Record) {
        guard let image = SnipHistoryStore.shared.loadImage(for: record) else {
            panelPresenter.flashStatus(L10n.string("历史图片已丢失"), level: .error)
            return
        }
        let rect = record.captureRegion.rectInScreenPoints
        let screenRect: CGRect? = (rect.width > 1 && rect.height > 1) ? rect : nil
        let pinCG = Self.cgImage(from: image)
        if let pinCG {
            lastCaptureImage = pinCG
        }
        let translationHandlers = pinnedTranslationHandlers()
        let pin = panelPresenter.pinScreenshot(
            image: image,
            at: screenRect
        ) { [weak self] in
            Task { await self?.runOCR(on: pinCG, language: .auto) }
        } onRequestTranslate: { image in
            translationHandlers.translate(image)
        } onRequestImageTranslate: { image in
            translationHandlers.imageTranslate(image)
        }
        if pin != nil {
            panelPresenter.flashStatus(L10n.string("已贴到屏幕"), level: .info)
        } else {
            panelPresenter.flashStatus(L10n.string("贴到屏幕失败"), level: .error)
        }
    }

    /// 设置页历史档案：复制文本到系统剪切板（不弹结果窗）。
    func copyHistoryTextToPasteboard(_ text: String, successHint: String = L10n.string("已复制")) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            panelPresenter.flashStatus(L10n.string("没有可复制内容"), level: .warning)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        panelPresenter.flashStatus(successHint, level: .info)
    }

    // MARK: - 主路径：区域截图（识窗 + 工具栏）

    func runRegionScreenshot(delaySeconds: TimeInterval = 0) async {
        await runCaptureOperation(kind: .screenshot) { [weak self] token in
            await self?.performRegionScreenshot(delaySeconds: delaySeconds, token: token)
        }
    }

    private func runCaptureOperation(
        kind: CaptureOperationKind,
        operation: @escaping @MainActor (CaptureOperationCoordinator.Token) async -> Void
    ) async {
        if recordingEngine != nil {
            if !didShowRecordingBlockedFeedback {
                didShowRecordingBlockedFeedback = true
                FeedbackCenter.shared.post(L10n.string("录制进行中，请先停止录制"), level: .info)
            }
            return
        }

        if kind == .service {
            // 系统翻译需要单独失效宿主；云端请求会随下面的 Task 取消。
            translation.cancelInFlight()
        }

        let started = captureOperations.start(kind: kind) { [weak self] token in
            guard let self, self.isCaptureOperationActive(token) else { return }
            await self.cancelActiveSelection()
            guard self.isCaptureOperationActive(token) else { return }
            await operation(token)
        }
        await started.task.value
        guard captureOperations.isCurrent(started.token) else { return }
        if activeSelectionToken == started.token, RegionSelectorController.isActive {
            RegionSelectorController.forceCancel()
        }
        captureOperations.finish(started.token)
    }

    private func runServiceOperation(
        _ operation: @escaping @MainActor (CaptureOperationCoordinator.Token) async -> Void
    ) async {
        await runCaptureOperation(kind: .service, operation: operation)
    }

    private func cancelActiveSelection() async {
        var cancelledSelection = false
        if let token = activeSelectionToken {
            captureOperations.cancel(token)
            activeSelectionToken = nil
            if RegionSelectorController.isActive {
                RegionSelectorController.forceCancel()
                cancelledSelection = true
            }
        } else if RegionSelectorController.isActive {
            // 兼容不由当前协调器创建的遗留选区会话。
            RegionSelectorController.forceCancel()
            cancelledSelection = true
        }
        if cancelledSelection {
            // RegionSelectorSession.finish 会在下一个 run loop 恢复旧 continuation，
            // 留出卸载窗口的时间，避免旧回调清掉新会话的 activeSession。
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func isCaptureOperationActive(
        _ token: CaptureOperationCoordinator.Token
    ) -> Bool {
        !Task.isCancelled && captureOperations.isCurrent(token)
    }

    private func snipForCapture(
        token: CaptureOperationCoordinator.Token,
        purpose: SnipPurpose
    ) async -> SnipResult? {
        activeSelectionToken = token
        defer {
            if activeSelectionToken == token {
                activeSelectionToken = nil
            }
        }

        // 选区会激活 App：锁定设置窗叠放 + 禁止其自动成为 key
        AppActivation.beginOverlayChrome()
        let result = await RegionSelectorController.snip(
            settings: settings,
            purpose: purpose
        )
        guard isCaptureOperationActive(token) else {
            AppActivation.endOverlayChrome()
            return nil
        }
        // 进入录制时保持锁定，直到录制 UI 结束；其它结果立刻解除
        if result == nil || result?.action != .record {
            AppActivation.endOverlayChrome()
        }
        return result
    }

    private func performRegionScreenshot(
        delaySeconds: TimeInterval,
        token: CaptureOperationCoordinator.Token
    ) async {
        guard isCaptureOperationActive(token) else { return }

        guard permissions.ensureScreenRecording() else {
            panelPresenter.showPermissionAlert(for: .screenRecording)
            return
        }

        // 延时截图（Snipaste delayed capture）— 屏幕中央倒计时卡片跳动
        if delaySeconds > 0 {
            for i in stride(from: Int(delaySeconds), through: 1, by: -1) {
                guard isCaptureOperationActive(token) else {
                    FeedbackCenter.shared.dismiss()
                    return
                }
                panelPresenter.flashStatus("\(i)", level: .progress)
                try? await Task.sleep(for: .seconds(1))
            }
            FeedbackCenter.shared.dismiss()
        }

        guard let result = await snipForCapture(token: token, purpose: .annotate) else {
            // 取消 / 冻结屏幕失败
            return
        }

        guard isCaptureOperationActive(token) else { return }
        if result.action != .record {
            lastCaptureImage = result.cgImage
        }
        // 先让出主线程一帧，避免工具栏关闭与贴图同帧卡顿
        await Task.yield()
        guard isCaptureOperationActive(token) else { return }
        await handleSnipResult(result)
    }

    /// Snipaste Paste：将剪贴板内容贴到屏幕
    func pasteClipboardToScreen() {
        let pb = NSPasteboard.general
        if let imgs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let img = imgs.first
        {
            let translationHandlers = pinnedTranslationHandlers()
            let pinCG = Self.cgImage(from: img)
            // 记住该图，便于贴图上 OCR 使用正确源（关结果窗后会清掉）
            if let pinCG {
                lastCaptureImage = pinCG
            }
            let pin = panelPresenter.pinScreenshot(image: img, at: nil) { [weak self] in
                // 显式传入贴图源，避免依赖可能已被清空的 lastCaptureImage
                Task { await self?.runOCR(on: pinCG, language: .auto) }
            } onRequestTranslate: { image in
                translationHandlers.translate(image)
            } onRequestImageTranslate: { image in
                translationHandlers.imageTranslate(image)
            }
            pin?.showStatus(L10n.string("已贴图"))
            return
        }
        // 文本 → 渲染成图片贴出
        if let str = pb.string(forType: .string), !str.isEmpty {
            let img = Self.renderTextImage(str)
            let translationHandlers = pinnedTranslationHandlers()
            let pin = panelPresenter.pinScreenshot(
                image: img,
                at: nil,
                onRequestTranslate: translationHandlers.translate,
                onRequestImageTranslate: translationHandlers.imageTranslate
            )
            pin?.showStatus(L10n.string("已贴图"))
            return
        }
        // 颜色 #RRGGBB
        if let str = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           str.hasPrefix("#"), str.count >= 7
        {
            let img = Self.renderColorCard(hex: str)
            let translationHandlers = pinnedTranslationHandlers()
            let pin = panelPresenter.pinScreenshot(
                image: img,
                at: nil,
                onRequestTranslate: translationHandlers.translate,
                onRequestImageTranslate: translationHandlers.imageTranslate
            )
            pin?.showStatus(L10n.string("已贴图"))
            return
        }
        panelPresenter.flashStatus(L10n.string("剪贴板没有可贴图的内容"), level: .warning)
    }

    private func pinnedTranslationHandlers() -> (
        translate: (NSImage) -> Void,
        imageTranslate: (NSImage) -> Void
    ) {
        let translate: (NSImage) -> Void = { [weak self] image in
            guard let cgImage = Self.cgImage(from: image) else { return }
            Task { await self?.runScreenTranslateFromImage(cgImage) }
        }
        // 无选区坐标的贴图使用同一多服务结果窗，避免伪造屏幕区域。
        return (translate: translate, imageTranslate: translate)
    }

    private func handleSnipResult(_ result: SnipResult) async {
        if result.action != .record {
            lastCaptureImage = result.cgImage
        }
        // 成功截图进历史
        if result.action != .cancelled, result.action != .record {
            SnipHistoryStore.shared.recordSuccess(region: result.region, image: result.image)
        }

        switch result.action {
        case .cancelled:
            return

        case .copy:
            copyImage(result.image)

        case .pin:
            copyImage(result.image)
            let pin = panelPresenter.pinScreenshot(
                image: result.image,
                at: result.region.rectInScreenPoints
            ) { [weak self] in
                Task { await self?.runOCR(on: result.cgImage, language: .auto) }
            } onRequestTranslate: { [weak self] _ in
                Task { await self?.presentScreenTranslateResult(cgImage: result.cgImage, region: result.region) }
            } onRequestImageTranslate: { [weak self] _ in
                Task { await self?.presentImageTranslateOverlay(cgImage: result.cgImage, region: result.region) }
            }
            pin?.showStatus(L10n.string("已复制 · 已钉图"))

        case .confirm:
            copyImage(result.image)
            let pin = panelPresenter.pinScreenshot(
                image: result.image,
                at: result.region.rectInScreenPoints
            ) { [weak self] in
                Task { await self?.runOCR(on: result.cgImage, language: .auto) }
            } onRequestTranslate: { [weak self] _ in
                Task { await self?.presentScreenTranslateResult(cgImage: result.cgImage, region: result.region) }
            } onRequestImageTranslate: { [weak self] _ in
                Task { await self?.presentImageTranslateOverlay(cgImage: result.cgImage, region: result.region) }
            }
            pin?.showStatus(L10n.string("已复制 · 已钉图"))

        case .save:
            copyImage(result.image)
            saveImage(result.image)

        case .quickSave:
            copyImage(result.image)
            quickSave(result.image)

        case .ocr:
            // 截图工具栏 OCR → 识别弹窗
            await runServiceOperation { [weak self] token in
                guard let self, self.isCaptureOperationActive(token) else { return }
                await self.runOCR(on: result.cgImage, language: .auto)
            }

        case .imageOCR:
            // 截图工具栏原图 OCR → 选区叠原文，可一键翻译
            await runServiceOperation { [weak self] token in
                guard let self, self.isCaptureOperationActive(token) else { return }
                await self.presentImageTranslateOverlay(
                    cgImage: result.cgImage,
                    region: result.region,
                    mode: .imageOCR
                )
            }

        case .translate:
            // 截图工具栏截图翻译 → OCR 后打开截图翻译结果窗
            await runServiceOperation { [weak self] token in
                guard let self, self.isCaptureOperationActive(token) else { return }
                await self.presentScreenTranslateResult(
                    cgImage: result.cgImage,
                    region: result.region
                )
            }

        case .imageTranslate:
            // 截图工具栏原图翻译 → OCR 后在截图区域叠加译文
            await runServiceOperation { [weak self] token in
                guard let self, self.isCaptureOperationActive(token) else { return }
                await self.presentImageTranslateOverlay(
                    cgImage: result.cgImage,
                    region: result.region,
                    mode: .imageTranslate
                )
            }

        case .scrollCapture:
            copyImage(result.image)
            let pin = panelPresenter.pinScreenshot(
                image: result.image,
                at: result.region.rectInScreenPoints
            ) { [weak self] in
                Task { await self?.runOCR(on: result.cgImage, language: .auto) }
            } onRequestTranslate: { [weak self] _ in
                Task { await self?.presentScreenTranslateResult(cgImage: result.cgImage, region: result.region) }
            } onRequestImageTranslate: { [weak self] _ in
                Task { await self?.presentImageTranslateOverlay(cgImage: result.cgImage, region: result.region) }
            }
            pin?.showStatus(L10n.string("滚动截屏完成"))

        case .record:
            startScreenRecording(region: result.region)
        }
    }

    private func quickSave(_ image: NSImage) {
        let quality = settings.snipImageQuality
        let url = SnipHistoryStore.quickSaveFileURL(quality: quality)
        do {
            _ = try SnipImageExport.write(image, quality: quality, to: url)
        } catch {
            panelPresenter.flashStatus(L10n.string("快捷保存失败"), level: .error)
        }
    }

    private static func renderTextImage(_ text: String) -> NSImage {
        let font = NSFont.systemFont(ofSize: 16)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
        let str = text as NSString
        let size = str.boundingRect(
            with: NSSize(width: 480, height: 2000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        ).integral.size
        let pad: CGFloat = 16
        let imgSize = NSSize(width: size.width + pad * 2, height: size.height + pad * 2)
        let img = NSImage(size: imgSize)
        img.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: imgSize).fill()
        str.draw(in: NSRect(x: pad, y: pad, width: size.width, height: size.height), withAttributes: attrs)
        img.unlockFocus()
        return img
    }

    private static func renderColorCard(hex: String) -> NSImage {
        var hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = CGFloat((int >> 16) & 0xFF) / 255
        let g = CGFloat((int >> 8) & 0xFF) / 255
        let b = CGFloat(int & 0xFF) / 255
        let size = NSSize(width: 160, height: 100)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor(calibratedRed: r, green: g, blue: b, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let label = "#\(hex.uppercased())" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium),
            .foregroundColor: (r + g + b) / 3 > 0.6 ? NSColor.black : NSColor.white,
        ]
        let ls = label.size(withAttributes: attrs)
        label.draw(
            at: NSPoint(x: (size.width - ls.width) / 2, y: (size.height - ls.height) / 2),
            withAttributes: attrs
        )
        img.unlockFocus()
        return img
    }

    private func copyImage(_ image: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }

    private func saveImage(_ image: NSImage) {
        // runModal 会阻塞主线程；延后一拍，确保选区层已卸下
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let quality = self.settings.snipImageQuality
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png, .jpeg]
            panel.nameFieldStringValue = SnipImageExport.defaultFileName(quality: quality)
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                _ = try SnipImageExport.write(image, quality: quality, to: url)
            } catch {
                self.panelPresenter.flashStatus(L10n.string("保存失败"), level: .error)
            }
        }
    }

    // MARK: - 其它功能（保留）

    func runCaptureOCR() async {
        await runServiceOperation { [weak self] token in
            guard let self, self.isCaptureOperationActive(token) else { return }
            // 再次触发：先关未钉住的 OCR 结果窗再框选
            self.panelPresenter.closeUnpinnedOCRResult()
            await self.performRegionScreenshotThenOCR(token: token)
        }
    }

    /// 截图翻译：框选 → OCR → 左图右多服务译文窗（主路径）
    func runCaptureTranslate() async {
        await runServiceOperation { [weak self] token in
            guard let self, self.isCaptureOperationActive(token) else { return }
            self.panelPresenter.closeUnpinnedScreenTranslateResultWindow()
            await self.performRegionCapture(mode: .translate, token: token)
        }
    }

    /// 从已有图片进入截图翻译（剪切板图片翻译等，不重新框选）
    func runScreenTranslateFromImage(_ cgImage: CGImage) async {
        await runServiceOperation { [weak self] token in
            guard let self, self.isCaptureOperationActive(token) else { return }
            self.panelPresenter.closeUnpinnedScreenTranslateResultWindow()
            self.lastCaptureImage = cgImage
            await self.presentScreenTranslateResult(cgImage: cgImage)
        }
    }

    /// 原图翻译：框选 → 选区叠层译文（次路径）
    func runCaptureImageTranslate() async {
        await runServiceOperation { [weak self] token in
            guard let self, self.isCaptureOperationActive(token) else { return }
            await self.performRegionCapture(mode: .imageTranslate, token: token)
        }
    }

    /// 原图 OCR：框选 → 选区叠原文（复用原图翻译叠层，不自动翻译）
    func runCaptureImageOCR() async {
        await runServiceOperation { [weak self] token in
            guard let self, self.isCaptureOperationActive(token) else { return }
            await self.performRegionCapture(mode: .imageOCR, token: token)
        }
    }

    func runSelectionTranslate() async {
        // 辅助功能：AX 读选区 + 模拟 ⌘C 都需要；未授权时引导去设置
        if !permissions.isAccessibilityGranted() {
            _ = permissions.ensureAccessibility()
            if !permissions.isAccessibilityGranted() {
                panelPresenter.showPermissionAlert(for: .accessibility)
                // 仍尝试出窗：可能用户剪切板里已有内容
            }
        }

        // 立刻出窗，翻译在窗内后台进行（避免「等翻完才弹窗」的明显延迟）
        let text = await resolveSelectionTranslateSource()
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        panelPresenter.showTranslatePopup(
            source: text,
            translated: "",
            statusMessage: hasText
                ? nil
                : L10n.string("未读到选中文本。请先划选文字再试；若仍失败请确认已授予「辅助功能」权限。"),
            autoTranslate: hasText
        )
    }

    /// 原文来源：AX 选区 → ⌘C 取词 → 现有剪切板字符串。
    private func resolveSelectionTranslateSource() async -> String {
        if let selected = await textSelection.accessibilitySelectedText() {
            let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return selected }
        }

        // 只有真正进入模拟 ⌘C 回退时才抑制剪切板监听；结束后立即恢复新的 changeCount 基线。
        pasteboardMonitor?.beginTransientChangeSuppression()
        let selected = await textSelection.pasteboardSelectedText()
        pasteboardMonitor?.endTransientChangeSuppression()
        if let selected {
            let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return selected }
        }

        // 最终兜底：用户可能已手动复制
        if let clip = NSPasteboard.general.string(forType: .string) {
            let trimmed = clip.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return clip }
        }
        return ""
    }

    /// 快捷键：区域截图 → 无论工具栏动作如何，强制进入 OCR 弹窗。
    private func performRegionScreenshotThenOCR(
        token: CaptureOperationCoordinator.Token
    ) async {
        guard isCaptureOperationActive(token) else { return }
        guard permissions.ensureScreenRecording() else {
            panelPresenter.showPermissionAlert(for: .screenRecording)
            return
        }
        // OCR：框选完成即返回，不出现标注工具栏
        guard let result = await snipForCapture(token: token, purpose: .ocrImmediate) else { return }
        guard isCaptureOperationActive(token) else { return }
        lastCaptureImage = result.cgImage
        if result.action == .cancelled { return }
        // 成功截图记入历史（与主路径一致）
        SnipHistoryStore.shared.recordSuccess(region: result.region, image: result.image)
        await runOCR(on: result.cgImage, language: .auto)
    }

    private enum CaptureMode { case ocrOnly, translate, imageTranslate, imageOCR }

    /// 对指定图像（或最近一次截图）做 OCR，并弹出左图右文结果面板。
    /// - Parameter existingSession: 非空时在原窗原地更新（重试 / 换语言 / 换图）。
    /// - Parameter serviceID: 指定引擎；默认用会话选中或全局默认。
    func runOCR(
        on image: CGImage?,
        language: OCRLanguageMode = .auto,
        serviceID: String? = nil,
        existingSession: OCRResultSession? = nil
    ) async {
        guard !Task.isCancelled else { return }
        let target = image ?? existingSession?.cgImage ?? lastCaptureImage
        guard let target else {
            if let existingSession {
                existingSession.applyError(
                    L10n.string("没有可识别的截图"),
                    action: .rescreen
                )
            } else {
                panelPresenter.flashStatus(L10n.string("没有可识别的截图"), level: .warning)
            }
            return
        }
        // 仅在结果窗存活期间保留兜底图；关窗后由 clearTransientCaptureBuffersIfIdle 清空。
        lastCaptureImage = target
        let nsImage = NSImage(
            cgImage: target,
            size: NSSize(width: target.width, height: target.height)
        )

        let resolvedServiceID = serviceID
            ?? existingSession?.selectedServiceID
            ?? settings.resolvedDefaultOCRServiceID()

        let session: OCRResultSession
        if let existingSession {
            session = existingSession
        } else {
            // 先出结果窗，让耗时的 OCR 状态归属于当前结果，而不是菜单栏。
            session = presentOCRWindow(
                image: nsImage,
                cgImage: target,
                text: "",
                lines: [],
                serviceID: resolvedServiceID
            )
        }
        let operation = session.beginOperation()
        session.languageMode = language
        session.selectedServiceID = resolvedServiceID
        session.flash(L10n.string("正在识别…"))

        do {
            let lines = try await ocr.recognize(
                target,
                languages: language.visionLanguages,
                serviceID: resolvedServiceID
            )
            guard !Task.isCancelled else {
                if session.isCurrent(operation) {
                    session.isRecognizing = false
                }
                return
            }
            guard session.isCurrent(operation) else {
                return
            }
            let text = OCRTextLayout.makeText(from: lines)
            recordOCRHistory(
                image: nsImage,
                cgImage: target,
                text: text,
                lines: lines,
                serviceID: resolvedServiceID
            )
            panelPresenter.updateOCRResult(
                image: nsImage,
                cgImage: target,
                lines: lines,
                session: session
            )
        } catch is CancellationError {
            guard session.isCurrent(operation) else { return }
            session.isRecognizing = false
            return
        } catch {
            guard !Task.isCancelled else {
                if session.isCurrent(operation) {
                    session.isRecognizing = false
                }
                return
            }
            guard session.isCurrent(operation) else {
                return
            }
            let message = Self.ocrErrorHint(error)
            session.applyError(message, action: Self.ocrErrorAction(error))
        }
    }

    private static func ocrErrorHint(_ error: Error) -> String {
        let base = error.localizedDescription
        if base.contains(L10n.string("配置")) || base.contains(L10n.string("密钥")) || base.contains(L10n.string("启用")) || base.contains(L10n.string("设置")) {
            return base
        }
        return String(format: L10n.string("%@（可到设置 → OCR → 服务 修改配置）"), base)
    }

    private static func ocrErrorAction(_ error: Error) -> OCRResultErrorAction {
        guard let error = error as? OCRProviderError else { return .retry }
        switch error {
        case .serviceNotFound, .serviceDisabled, .missingCredentials, .notImplemented:
            return .openSettings
        case .invalidImage:
            return .rescreen
        case .network, .api, .invalidResponse:
            return .retry
        }
    }

    private static func translateErrorHint(_ error: Error) -> String {
        let base = error.localizedDescription
        if base.contains(L10n.string("模型")) || base.contains(L10n.string("语言")) || base.contains(L10n.string("系统设置")) {
            return base
        }
        return String(format: L10n.string("%@（可到设置 → 翻译 → 服务 查看状态）"), base)
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

    /// 从本地文件选图并 OCR。
    func runOCRFromOpenPanel(into session: OCRResultSession? = nil) async {
        session?.suppressFocusDismissCount += 1
        defer { session?.suppressFocusDismissCount -= 1 }

        let url: URL? = await withCheckedContinuation { cont in
            DispatchQueue.main.async {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif, .bmp, .webP]
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                panel.message = L10n.string("选择要识别的图片")
                cont.resume(returning: panel.runModal() == .OK ? panel.url : nil)
            }
        }
        guard let url else {
            // 取消选图后把焦点还给 OCR 窗
            if let session, let p = panelPresenter.panelForSession(session) {
                p.makeKeyAndOrderFront(nil)
            }
            return
        }
        guard let nsImage = NSImage(contentsOf: url),
              let cg = Self.cgImage(from: nsImage)
        else {
            if let session {
                session.applyError(
                    L10n.string("无法读取图片"),
                    action: .rescreen
                )
            } else {
                panelPresenter.flashStatus(L10n.string("无法读取图片"), level: .error)
            }
            return
        }
        lastCaptureImage = cg
        await runOCR(
            on: cg,
            language: session?.languageMode ?? .auto,
            existingSession: session
        )
    }

    @discardableResult
    private func presentOCRWindow(
        image: NSImage,
        cgImage: CGImage,
        text: String,
        lines: [OCRLine],
        serviceID: String
    ) -> OCRResultSession {
        return panelPresenter.showOCRResult(
            image: image,
            cgImage: cgImage,
            text: text,
            lines: lines,
            serviceID: serviceID,
            enabledServices: { [weak self] in
                self?.settings.enabledOCRServicesForMenu() ?? [.vision()]
            },
            onSelectService: { [weak self] session, id in
                guard let self else { return }
                self.settings.setDefaultOCRServiceID(id)
                session.selectedServiceID = id
                Task {
                    await self.runOCR(
                        on: session.cgImage,
                        language: session.languageMode,
                        serviceID: id,
                        existingSession: session
                    )
                }
            },
            onRetry: { [weak self] session in
                Task {
                    await self?.runOCR(
                        on: session.cgImage,
                        language: session.languageMode,
                        serviceID: session.selectedServiceID,
                        existingSession: session
                    )
                }
            },
            onRescreen: { [weak self] _ in
                Task { await self?.runCaptureOCR() }
            },
            onOpenFile: { [weak self] session in
                Task { await self?.runOCRFromOpenPanel(into: session) }
            },
            onRerecognize: { [weak self] session, mode in
                session.languageMode = mode
                Task {
                    await self?.runOCR(
                        on: session.cgImage,
                        language: mode,
                        serviceID: session.selectedServiceID,
                        existingSession: session
                    )
                }
            },
            onOpenSettings: { [weak self] in
                self?.panelPresenter.showSettings(pane: .ocrService)
            },
            onTranslate: { [weak self] session in
                guard let self else { return }
                Task { await self.convertOCRSessionToScreenTranslate(session) }
            }
        )
    }

    private func performRegionCapture(
        mode: CaptureMode,
        token: CaptureOperationCoordinator.Token
    ) async {
        guard isCaptureOperationActive(token) else { return }
        guard permissions.ensureScreenRecording() else {
            panelPresenter.showPermissionAlert(for: .screenRecording)
            return
        }
        // 翻译/OCR 专用选区：框选完直接返回，不进标注工具栏
        guard let result = await snipForCapture(token: token, purpose: .ocrImmediate) else { return }
        guard isCaptureOperationActive(token) else { return }
        lastCaptureImage = result.cgImage
        if result.action == .cancelled { return }
        // 框选成功写入截图历史（OCR / 截图翻译 / 原图翻译路径共用）
        SnipHistoryStore.shared.recordSuccess(region: result.region, image: result.image)

        guard isCaptureOperationActive(token) else { return }
        switch mode {
        case .ocrOnly:
            await runOCR(on: result.cgImage, language: .auto)
        case .translate:
            await presentScreenTranslateResult(
                cgImage: result.cgImage,
                region: result.region
            )
        case .imageTranslate:
            await presentImageTranslateOverlay(
                cgImage: result.cgImage,
                region: result.region,
                mode: .imageTranslate
            )
        case .imageOCR:
            await presentImageTranslateOverlay(
                cgImage: result.cgImage,
                region: result.region,
                mode: .imageOCR
            )
        }
    }

    private func recordOCRHistory(
        image: NSImage,
        cgImage: CGImage,
        text: String,
        lines: [OCRLine],
        serviceID: String
    ) {
        OCRHistoryStore.shared.applyPolicy(from: settings)
        let displayName = settings.ocrServices.first(where: { $0.id == serviceID })?.displayName
            ?? serviceID
        OCRHistoryStore.shared.recordSuccess(
            image: image,
            cgImage: cgImage,
            text: text,
            lines: lines,
            serviceID: serviceID,
            serviceDisplayName: displayName
        )
    }

    private func recordScreenTranslateHistory(session: ScreenTranslateResultSession) {
        TranslationHistoryStore.shared.applyPolicy(from: settings)
        let snapshots = session.serviceResults.map {
            TranslationServiceSnapshot(
                serviceID: $0.id,
                displayName: $0.displayName,
                text: $0.text,
                statusMessage: $0.statusMessage
            )
        }
        TranslationHistoryStore.shared.recordScreenTranslate(
            image: session.image,
            cgImage: session.cgImage,
            sourceText: session.ocrText,
            sourceSelection: session.sourceSelection,
            targetSelection: session.targetSelection,
            services: snapshots,
            ocrText: session.ocrText,
            ocrServiceID: session.selectedOCRServiceID,
            lines: session.lines
        )
    }

    /// 截图翻译结果窗：先出窗口显示 OCR 状态，识别完成后自动多服务并发译。
    private func presentScreenTranslateResult(
        cgImage: CGImage,
        region: CaptureRegion? = nil,
        existingSession: ScreenTranslateResultSession? = nil,
        ocrServiceID: String? = nil
    ) async {
        guard !Task.isCancelled else { return }
        // 结果窗存活期间保留；关闭后 clearTransientCaptureBuffersIfIdle 释放。
        lastCaptureImage = cgImage
        let nsImage = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        let resolvedOCR = ocrServiceID
            ?? existingSession?.selectedOCRServiceID
            ?? settings.resolvedDefaultOCRServiceID()

        let services = settings.enabledTranslationServicesForPopup()
        let isNewSession = existingSession == nil
        let session: ScreenTranslateResultSession
        if let existingSession {
            session = existingSession
            session.selectedOCRServiceID = resolvedOCR
            session.configureServices(services)
        } else {
            session = panelPresenter.showScreenTranslateResult(
                image: nsImage,
                cgImage: cgImage,
                lines: [],
                ocrText: "",
                ocrServiceID: resolvedOCR,
                targetSelection: TranslationLanguage.sessionTargetSelection(
                    settingsTarget: settings.targetLanguage,
                    sampleText: "",
                    sourceSetting: settings.sourceLanguage
                ),
                services: services,
                actions: makeScreenTranslateResultActions()
            )
        }

        let operation = session.beginOperation()
        session.isTranslating = false
        session.isRecognizing = true
        session.flash(L10n.string("正在识别…"))

        do {
            let lines = try await ocr.recognize(
                cgImage,
                languages: nil,
                serviceID: resolvedOCR
            )
            guard !Task.isCancelled else {
                if session.isCurrent(operation) {
                    session.isRecognizing = false
                }
                return
            }
            guard session.isCurrent(operation) else { return }
            let text = OCRTextLayout.makeText(from: lines)
            // 截图翻译路径的 OCR 步也写入 OCR 历史（与独立 OCR 模块一致）
            recordOCRHistory(
                image: nsImage,
                cgImage: cgImage,
                text: text,
                lines: lines,
                serviceID: resolvedOCR
            )

            session.applyRecognition(image: nsImage, cgImage: cgImage, lines: lines)
            session.selectedOCRServiceID = resolvedOCR
            session.configureServices(services)
            if isNewSession {
                session.targetSelection = TranslationLanguage.sessionTargetSelection(
                    settingsTarget: settings.targetLanguage,
                    sampleText: text,
                    sourceSetting: settings.sourceLanguage
                )
            }
            guard !lines.isEmpty else { return }
            await translateScreenTranslateResult(session)
            _ = region
        } catch is CancellationError {
            guard session.isCurrent(operation) else { return }
            session.isRecognizing = false
            return
        } catch {
            guard !Task.isCancelled else {
                if session.isCurrent(operation) {
                    session.isRecognizing = false
                }
                return
            }
            guard session.isCurrent(operation) else { return }
            session.applyError(
                Self.ocrErrorHint(error),
                action: Self.screenTranslateOCRErrorAction(error)
            )
        }
    }

    private static func screenTranslateOCRErrorAction(
        _ error: Error
    ) -> ScreenTranslateResultErrorAction {
        guard let error = error as? OCRProviderError else { return .retryOCR }
        switch error {
        case .serviceNotFound, .serviceDisabled, .missingCredentials, .notImplemented:
            return .openOCRSettings
        case .invalidImage:
            return .retryOCR
        case .network, .api, .invalidResponse:
            return .retryOCR
        }
    }

    private func makeScreenTranslateResultActions() -> ScreenTranslateResultActions {
        ScreenTranslateResultActions(
            enabledOCRServices: { [weak self] in
                self?.settings.enabledOCRServicesForMenu() ?? [.vision()]
            },
            onRetryOCR: { [weak self] in
                guard let self,
                      let session = self.panelPresenter.activeScreenTranslateResultSession
                else { return }
                Task {
                    await self.presentScreenTranslateResult(
                        cgImage: session.cgImage,
                        existingSession: session,
                        ocrServiceID: session.selectedOCRServiceID
                    )
                }
            },
            onRescreen: { [weak self] in
                guard let self else { return }
                Task {
                    guard let result = await RegionSelectorController.snip(
                        settings: self.settings,
                        purpose: .ocrImmediate
                    ) else { return }
                    self.lastCaptureImage = result.cgImage
                    if result.action == .cancelled { return }
                    if let session = self.panelPresenter.activeScreenTranslateResultSession {
                        await self.presentScreenTranslateResult(
                            cgImage: result.cgImage,
                            region: result.region,
                            existingSession: session
                        )
                    } else {
                        await self.presentScreenTranslateResult(
                            cgImage: result.cgImage,
                            region: result.region
                        )
                    }
                }
            },
            onOpenFile: { [weak self] in
                guard let self else { return }
                Task { await self.runScreenTranslateFromOpenPanel() }
            },
            onSelectOCRService: { [weak self] id in
                guard let self else { return }
                self.settings.setDefaultOCRServiceID(id)
                guard let session = self.panelPresenter.activeScreenTranslateResultSession else { return }
                Task {
                    await self.presentScreenTranslateResult(
                        cgImage: session.cgImage,
                        existingSession: session,
                        ocrServiceID: id
                    )
                }
            },
            onRetryService: { [weak self] serviceID in
                guard let self,
                      let session = self.panelPresenter.activeScreenTranslateResultSession
                else { return }
                Task { await self.translateScreenTranslateResult(session, serviceID: serviceID) }
            },
            onSourceLanguageChanged: { [weak self] _ in
                guard let self,
                      let session = self.panelPresenter.activeScreenTranslateResultSession
                else { return }
                Task { await self.translateScreenTranslateResult(session) }
            },
            onTargetLanguageChanged: { [weak self] code in
                guard let self else { return }
                self.settings.targetLanguage = code
                guard let session = self.panelPresenter.activeScreenTranslateResultSession
                else { return }
                Task { await self.translateScreenTranslateResult(session) }
            },
            onRetranslate: { [weak self] in
                guard let self,
                      let session = self.panelPresenter.activeScreenTranslateResultSession
                else { return }
                Task { await self.translateScreenTranslateResult(session) }
            },
            onOpenOCRSettings: { [weak self] in
                self?.panelPresenter.showSettings(pane: .ocrService)
            },
            onOpenSettings: { [weak self] in
                self?.panelPresenter.showSettings(pane: .translateService)
            }
        )
    }

    /// OCR 窗「翻译」：关 OCR 窗，用同一图/文打开截图翻译窗并自动译（不重 OCR）
    private func convertOCRSessionToScreenTranslate(_ ocrSession: OCRResultSession) async {
        let image = ocrSession.image
        let cgImage = ocrSession.cgImage
        let lines = ocrSession.lines
        let text = ocrSession.text
        let ocrServiceID = ocrSession.selectedServiceID

        // dismiss 可能先触发 clearTransientCaptureBuffersIfIdle；随后结果窗重建并重新挂住兜底图。
        panelPresenter.dismissOCRSession(ocrSession)

        let services = settings.enabledTranslationServicesForPopup()
        let session = panelPresenter.showScreenTranslateResult(
            image: image,
            cgImage: cgImage,
            lines: lines,
            ocrText: text,
            ocrServiceID: ocrServiceID,
            targetSelection: TranslationLanguage.sessionTargetSelection(
                settingsTarget: settings.targetLanguage,
                sampleText: text,
                sourceSetting: settings.sourceLanguage
            ),
            services: services,
            actions: makeScreenTranslateResultActions()
        )
        lastCaptureImage = cgImage
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            session.emptyMessage = L10n.string("没有可翻译的文字")
            session.errorAction = .retryOCR
            return
        }
        await translateScreenTranslateResult(session)
    }

    private func runScreenTranslateFromOpenPanel() async {
        let session = panelPresenter.activeScreenTranslateResultSession
        session?.beginFocusSuppress()
        defer { session?.endFocusSuppress() }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let nsImage = NSImage(contentsOf: url),
              let cg = Self.cgImage(from: nsImage)
        else {
            if let session {
                session.applyError(
                    L10n.string("无法读取图片"),
                    action: .retryOCR
                )
            } else {
                panelPresenter.flashStatus(L10n.string("无法读取图片"), level: .error)
            }
            return
        }
        lastCaptureImage = cg
        if let session {
            await presentScreenTranslateResult(cgImage: cg, existingSession: session)
        } else {
            await presentScreenTranslateResult(cgImage: cg)
        }
    }

    private func translateScreenTranslateResult(
        _ session: ScreenTranslateResultSession,
        serviceID: String? = nil
    ) async {
        guard !Task.isCancelled else { return }
        let text = session.ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            session.emptyMessage = L10n.string("原文为空")
            session.errorMessage = nil
            session.errorAction = nil
            session.isTranslating = false
            session.setServicesLoading(false)
            return
        }

        let services = settings.enabledTranslationServicesForPopup()
        session.configureServices(services)
        session.refreshDetectedLanguage()
        let targetServices = if let serviceID {
            services.filter { $0.id == serviceID }
        } else {
            services
        }
        let ready = targetServices.filter(\.isReadyToTranslate)
        for entry in targetServices where !entry.isReadyToTranslate {
            session.applyError(
                L10n.string("配置未完成，请到设置中补充密钥"),
                serviceID: entry.id,
                retryable: false,
                openSettings: true
            )
        }
        guard !ready.isEmpty else {
            session.isTranslating = false
            if serviceID == nil {
                session.applyError(
                    L10n.string("没有可用的翻译服务"),
                    action: .openTranslationSettings
                )
            }
            return
        }

        let op = session.beginOperation()
        session.isTranslating = true
        session.setServicesLoading(false)
        for entry in ready {
            session.setServiceLoading(true, serviceID: entry.id)
        }

        let sourceLang = session.sourceSelection
        let targetLang = session.targetSelection
        let chunks = [session.ocrText]

        // 并发各服务（结构化并发，避免 withTaskGroup + MainActor 捕获歧义）
        await withTaskGroup(of: (String, Result<TranslationResult, Error>).self) { group in
            for entry in ready {
                let serviceID = entry.id
                group.addTask {
                    do {
                        let result = try await self.translation.translate(
                            chunks,
                            sourceLanguage: sourceLang,
                            targetLanguage: targetLang,
                            serviceID: serviceID,
                            onPartialText: { partialText in
                                guard !Task.isCancelled, session.isCurrent(op) else { return }
                                session.applyPartialText(partialText, serviceID: serviceID)
                            }
                        )
                        return (serviceID, .success(result))
                    } catch {
                        return (serviceID, .failure(error))
                    }
                }
            }
            for await (serviceID, outcome) in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                guard session.isCurrent(op) else { continue }
                switch outcome {
                case .success(let result):
                    session.applyResult(result, serviceID: serviceID)
                case .failure(let error):
                    if error is CancellationError { continue }
                    let presentation = Self.translationErrorPresentation(error)
                    session.applyError(
                        error.localizedDescription,
                        serviceID: serviceID,
                        retryable: presentation.retryable,
                        openSettings: presentation.openSettings
                    )
                }
            }
        }
        if Task.isCancelled {
            if session.isCurrent(op) {
                session.isTranslating = false
                session.setServicesLoading(false)
            }
            return
        }
        guard session.isCurrent(op) else { return }
        session.isTranslating = false
        session.setServicesLoading(false)
        if !session.serviceResults.contains(where: {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            session.applyError(
                L10n.string("翻译未返回结果，请重试"),
                action: .retranslate
            )
        }
        recordScreenTranslateHistory(session: session)
    }

    /// 原图翻译 / 原图 OCR 叠层（共用 UI；OCR 模式不自动翻译）
    private func presentImageTranslateOverlay(
        cgImage: CGImage,
        region: CaptureRegion,
        mode: ScreenTranslateOverlayMode = .imageTranslate
    ) async {
        guard !Task.isCancelled else { return }

        let ocrServiceID = settings.resolvedDefaultOCRServiceID()
        let translationServiceID = settings.resolvedDefaultTranslationServiceID()
        // 先出叠层，让 OCR 与后续翻译状态都显示在选区内。
        let session = panelPresenter.showScreenTranslateOverlay(
            image: cgImage,
            imageSize: CGSize(width: cgImage.width, height: cgImage.height),
            selection: region,
            lines: [],
            ocrServiceID: ocrServiceID,
            translationServiceID: translationServiceID,
            sourceLanguage: settings.sourceLanguage,
            targetLanguage: settings.targetLanguage,
            mode: mode,
            actions: ScreenTranslateOverlayActions(
                enabledOCRServices: { [weak self] in
                    self?.settings.enabledOCRServicesForMenu() ?? [.vision()]
                },
                enabledTranslationServices: { [weak self] in
                    self?.settings.enabledTranslationServicesForPopup() ?? [.system()]
                },
                onSelectOCR: { [weak self] session, serviceID in
                    guard let self else { return }
                    self.settings.setDefaultOCRServiceID(serviceID)
                    Task { await self.rerunScreenTranslateOCR(session, serviceID: serviceID) }
                },
                onSelectTranslation: { [weak self] session, serviceID in
                    guard let self else { return }
                    self.settings.setDefaultTranslationServiceID(serviceID)
                    // 原图 OCR 未译前：只切换服务，等用户点一键翻译
                    guard session.mode == .imageTranslate || session.hasTranslatedContent else { return }
                    Task { await self.retranslateScreenOverlay(session) }
                },
                onSourceLanguageChanged: { [weak self] session, code in
                    guard let self else { return }
                    // 源语仅会话内
                    session.sourceLanguage = code
                    guard session.mode == .imageTranslate || session.hasTranslatedContent else { return }
                    Task { await self.retranslateScreenOverlay(session) }
                },
                onTargetLanguageChanged: { [weak self] session, code in
                    guard let self else { return }
                    self.settings.targetLanguage = code
                    session.targetLanguage = code
                    guard session.mode == .imageTranslate || session.hasTranslatedContent else { return }
                    Task { await self.retranslateScreenOverlay(session) }
                },
                onRetryOCR: { [weak self] session in
                    guard let self else { return }
                    Task { await self.rerunScreenTranslateOCR(session, serviceID: session.ocrServiceID) }
                },
                onRetranslate: { [weak self] session in
                    guard let self else { return }
                    Task { await self.retranslateScreenOverlay(session) }
                },
                onOpenOCRSettings: { [weak self] in
                    self?.panelPresenter.showSettings(pane: .ocrService)
                },
                onOpenTranslationSettings: { [weak self] in
                    self?.panelPresenter.showSettings(pane: .translateService)
                }
            )
        )
        session.beginOperation(message: L10n.string("识别中…"))

        do {
            let lines = try await ocr.recognize(
                cgImage,
                languages: nil,
                serviceID: ocrServiceID
            )
            guard !Task.isCancelled else {
                session.isProcessing = false
                return
            }
            guard !lines.isEmpty else {
                session.lines = []
                session.isProcessing = false
                session.emptyMessage = L10n.string("未识别到文字")
                session.errorAction = .retryOCR
                return
            }
            let overlayLines = lines.map { line in
                OverlayLine(id: line.id, source: line.text, translated: "", boundingBox: line.boundingBox)
            }
            session.lines = overlayLines
            switch mode {
            case .imageTranslate:
                await retranslateScreenOverlay(session)
            case .imageOCR:
                // 只 OCR：默认叠识别原文，不自动翻译
                session.isShowingOriginal = false
                session.isProcessing = false
                session.emptyMessage = nil
            }
        } catch is CancellationError {
            session.isProcessing = false
            return
        } catch {
            guard !Task.isCancelled else {
                session.isProcessing = false
                return
            }
            session.applyError(
                Self.ocrErrorHint(error),
                action: Self.screenOverlayOCRErrorAction(error)
            )
        }
    }

    private static func screenOverlayOCRErrorAction(
        _ error: Error
    ) -> ScreenTranslateOverlayErrorAction {
        guard let error = error as? OCRProviderError else { return .retryOCR }
        switch error {
        case .serviceNotFound, .serviceDisabled, .missingCredentials, .notImplemented:
            return .openOCRSettings
        case .invalidImage, .network, .api, .invalidResponse:
            return .retryOCR
        }
    }

    private func rerunScreenTranslateOCR(
        _ session: ScreenTranslateOverlaySession,
        serviceID: String
    ) async {
        guard !session.isClosed else { return }
        translation.cancelInFlight()
        // 换 OCR 前先记住是否已译过（更新 lines 后 hasTranslatedContent 会变 false）
        let shouldAutoTranslate = session.mode == .imageTranslate || session.hasTranslatedContent
        let operation = session.beginOperation(message: L10n.string("识别中…"))
        do {
            let lines = try await ocr.recognize(
                session.image,
                languages: nil,
                serviceID: serviceID
            )
            guard session.isCurrent(operation) else { return }
            guard !lines.isEmpty else {
                session.lines = []
                session.isProcessing = false
                session.emptyMessage = L10n.string("未识别到文字")
                session.errorAction = .retryOCR
                return
            }
            session.lines = lines.map {
                OverlayLine(
                    id: $0.id,
                    source: $0.text,
                    translated: "",
                    boundingBox: $0.boundingBox
                )
            }
            // 原图 OCR 且尚未译过：只更新识别结果，不自动翻译
            guard shouldAutoTranslate else {
                session.isProcessing = false
                return
            }
            session.processingMessage = L10n.string("翻译中…")
            try await translateScreenOverlay(session, operation: operation)
        } catch is CancellationError {
            guard session.isCurrent(operation) else { return }
            session.isProcessing = false
        } catch {
            guard session.isCurrent(operation) else { return }
            session.applyError(
                Self.ocrErrorHint(error),
                action: Self.screenOverlayOCRErrorAction(error)
            )
        }
    }

    private func retranslateScreenOverlay(_ session: ScreenTranslateOverlaySession) async {
        guard !session.isClosed, !session.lines.isEmpty else {
            session.emptyMessage = L10n.string("没有可翻译的文字")
            session.errorAction = .retryOCR
            return
        }
        translation.cancelInFlight()
        let operation = session.beginOperation(message: L10n.string("翻译中…"))
        do {
            try await translateScreenOverlay(session, operation: operation)
            // 一键翻译成功后切到叠译文，便于立刻看到结果
            if session.isCurrent(operation) {
                session.isShowingOriginal = false
            }
        } catch is CancellationError {
            guard session.isCurrent(operation) else { return }
            session.isProcessing = false
        } catch {
            guard session.isCurrent(operation) else { return }
            session.applyError(
                Self.translateErrorHint(error),
                action: Self.screenOverlayTranslationErrorAction(error)
            )
        }
    }

    private static func screenOverlayTranslationErrorAction(
        _ error: Error
    ) -> ScreenTranslateOverlayErrorAction {
        guard let error = error as? TranslationServiceError else { return .retranslate }
        switch error {
        case .serviceNotFound, .serviceDisabled, .missingCredentials,
             .cannotDetectLanguage, .modelNotInstalled, .unsupportedPair,
             .authenticationFailed:
            return .openTranslationSettings
        case .emptyInput, .network, .quotaExceeded, .rateLimited,
             .serverUnavailable, .api, .invalidResponse, .failed:
            return .retranslate
        }
    }

    private func translateScreenOverlay(
        _ session: ScreenTranslateOverlaySession,
        operation: UUID
    ) async throws {
        let texts = session.lines.map(\.source)
        let result = try await translation.translate(
            texts,
            sourceLanguage: session.sourceLanguage,
            targetLanguage: session.targetLanguage,
            serviceID: session.translationServiceID
        )
        guard session.isCurrent(operation) else { return }
        session.lines = session.lines.enumerated().map { index, line in
            OverlayLine(
                id: line.id,
                source: line.source,
                translated: result.texts.indices.contains(index) ? result.texts[index] : "",
                boundingBox: line.boundingBox
            )
        }
        session.isProcessing = false
        session.errorMessage = nil
        session.errorAction = nil
        session.emptyMessage = session.hasTranslatedContent
            ? nil
            : L10n.string("暂无译文")
        if let note = result.userFacingNote {
            session.flash(note)
        }
    }

    // MARK: - 录制（视频最小闭环）

    var isRecordingActive: Bool { recordingEngine != nil }

    /// 应用退出或生命周期异常时只取消当前临时录制，不建历史。
    func cancelRecording() {
        guard let engine = recordingEngine else { return }
        Task { @MainActor [weak self, engine] in
            await engine.cancel()
            guard let self, self.recordingEngine === engine else { return }
            self.endScreenRecordingUI()
        }
    }

    private func startScreenRecording(region: CaptureRegion) {
        guard recordingEngine == nil else { return }
        guard let screen = ScreenGeometry.screen(for: region.displayID) else {
            FeedbackCenter.shared.post(L10n.string("录制目标显示器不可用"), level: .error)
            AppActivation.endOverlayChrome()
            return
        }

        // 录制全程：设置窗保持可见但不抢 key / 不抬到其它 App 之上
        AppActivation.beginOverlayChrome()

        // 麦克风默认关闭；仅当用户曾开启且当前已授权时才在启动时采集，避免提前弹权限。
        let microphoneInitiallyOn =
            settings.recordingMicrophoneEnabled && permissions.isMicrophoneGranted()
        let engine = ScreenRecordingEngine(
            configuration: ScreenRecordingConfiguration(
                showsCursor: settings.recordingShowsCursor,
                systemAudioEnabled: settings.recordingSystemAudioEnabled,
                microphoneEnabled: microphoneInitiallyOn,
                microphoneDeviceUID: settings.recordingMicrophoneDeviceUID
            )
        )
        let mask = RecordingMaskPanel(region: region.rectInScreenPoints, screen: screen)
        let border = RecordingBorderPanel(region: region.rectInScreenPoints)
        let hud = RecordingHUDPanel(region: region.rectInScreenPoints, screen: screen)
        recordingEngine = engine
        recordingMask = mask
        recordingBorder = border
        recordingHUD = hud
        recordingScreen = screen
        recordingRegion = region
        didShowRecordingBlockedFeedback = false
        hud.configureSystemAudio(settings.recordingSystemAudioEnabled)
        hud.configureMicrophone(
            enabled: microphoneInitiallyOn,
            deviceUID: settings.recordingMicrophoneDeviceUID
        )

        mask.orderFrontRegardless()
        border.orderFrontRegardless()
        hud.orderFrontRegardless()

        engine.onUnexpectedStop = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.endScreenRecordingUI()
                FeedbackCenter.shared.post(
                    String(format: L10n.string("录制已停止：%@"), error.localizedDescription),
                    level: .error
                )
            }
        }

        hud.onPauseToggle = { [weak engine, weak hud] in
            guard let engine, let hud else { return }
            switch engine.state {
            case .recording:
                engine.pause()
                hud.setPaused(true)
            case .paused:
                engine.resume()
                hud.setPaused(false)
            default:
                break
            }
        }
        hud.onSystemAudioToggle = { [weak self, weak engine, weak hud] enabled in
            guard let self, let engine, let hud else { return }
            self.settings.recordingSystemAudioEnabled = enabled
            hud.configureSystemAudio(enabled)
            engine.setSystemAudioEnabled(enabled)
        }
        hud.onMicrophoneToggle = { [weak self] enabled in
            self?.handleRecordingMicrophoneToggle(enabled: enabled)
        }
        hud.onSelectMicrophoneDevice = { [weak self, weak engine, weak hud] uid in
            guard let self, let engine, let hud else { return }
            self.settings.recordingMicrophoneDeviceUID = uid
            engine.setMicrophoneDeviceUID(uid)
            hud.configureMicrophone(
                enabled: self.settings.recordingMicrophoneEnabled
                    && self.permissions.isMicrophoneGranted(),
                deviceUID: uid
            )
        }
        hud.onStop = { [weak self] in self?.stopScreenRecording() }
        hud.onCancel = { [weak self] in self?.cancelScreenRecording() }

        engine.onSystemAudioConfigurationFailed = { [weak self, weak hud] appliedEnabled in
            Task { @MainActor [weak self, weak hud] in
                guard let self, let hud else { return }
                self.settings.recordingSystemAudioEnabled = appliedEnabled
                hud.configureSystemAudio(appliedEnabled)
                FeedbackCenter.shared.post(
                    appliedEnabled ? L10n.string("系统声音已开启") : L10n.string("系统声音不可用，已保留视频录制"),
                    level: appliedEnabled ? .info : .error
                )
            }
        }
        engine.onMicrophoneCaptureFailed = { [weak self, weak hud] in
            Task { @MainActor [weak self, weak hud] in
                guard let self, let hud else { return }
                self.settings.recordingMicrophoneEnabled = false
                hud.configureMicrophone(
                    enabled: false,
                    deviceUID: self.settings.recordingMicrophoneDeviceUID
                )
                FeedbackCenter.shared.post(
                    L10n.string("麦克风不可用，已保留视频与系统声音录制"),
                    level: .error
                )
            }
        }
        engine.onMicrophoneDeviceFellBackToDefault = { [weak self, weak hud] in
            Task { @MainActor [weak self, weak hud] in
                guard let self, let hud else { return }
                self.settings.recordingMicrophoneDeviceUID = nil
                hud.configureMicrophone(
                    enabled: self.settings.recordingMicrophoneEnabled
                        && self.permissions.isMicrophoneGranted(),
                    deviceUID: nil
                )
                FeedbackCenter.shared.post(
                    L10n.string("原麦克风已移除，已切换为系统默认输入"),
                    level: .info
                )
            }
        }

        recordingEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self] in
                self?.cancelScreenRecording()
            }
        }
        recordingLocalEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.cancelScreenRecording()
            return nil
        }

        var excludedWindowIDs = [mask, border, hud].compactMap { panel -> CGWindowID? in
            guard panel.windowNumber > 0 else { return nil }
            return CGWindowID(panel.windowNumber)
        }
        if let settingsID = panelPresenter.settingsWindowIDForCaptureExclusion {
            excludedWindowIDs.append(settingsID)
        }
        Task { @MainActor [weak self, weak engine, weak hud] in
            guard let self, let engine, let hud else { return }
            do {
                try await engine.start(
                    region: region,
                    excludedWindowIDs: excludedWindowIDs
                )
                guard self.recordingEngine === engine else {
                    await engine.cancel()
                    return
                }
                hud.setControlsEnabled(true)
                hud.startClock()
            } catch {
                guard self.recordingEngine === engine else { return }
                self.endScreenRecordingUI()
                if (error as? ScreenRecordingError) != .cancelled {
                    FeedbackCenter.shared.post(
                        String(format: L10n.string("录制启动失败：%@"), error.localizedDescription),
                        level: .error
                    )
                }
            }
        }
    }

    /// 懒请求麦克风权限后开关采集；拒绝时保留视频/系统音频并恢复按钮。
    private func handleRecordingMicrophoneToggle(enabled: Bool) {
        guard let engine = recordingEngine, let hud = recordingHUD else { return }

        if !enabled {
            settings.recordingMicrophoneEnabled = false
            hud.configureMicrophone(
                enabled: false,
                deviceUID: settings.recordingMicrophoneDeviceUID
            )
            engine.setMicrophoneEnabled(false)
            return
        }

        if permissions.isMicrophoneGranted() {
            settings.recordingMicrophoneEnabled = true
            hud.configureMicrophone(
                enabled: true,
                deviceUID: settings.recordingMicrophoneDeviceUID
            )
            engine.setMicrophoneEnabled(true)
            return
        }

        if permissions.isMicrophoneDenied() {
            settings.recordingMicrophoneEnabled = false
            hud.configureMicrophone(
                enabled: false,
                deviceUID: settings.recordingMicrophoneDeviceUID
            )
            engine.setMicrophoneEnabled(false)
            FeedbackCenter.shared.post(
                L10n.string("麦克风权限已拒绝，仍可录制视频与系统声音"),
                level: .error
            )
            permissions.openSystemSettings(for: .microphone)
            return
        }

        // 首次开启：请求权限期间先保持关闭态，避免未授权时误写。
        hud.configureMicrophone(
            enabled: false,
            deviceUID: settings.recordingMicrophoneDeviceUID
        )
        Task { @MainActor [weak self, weak engine, weak hud] in
            guard let self, let engine, let hud else { return }
            let granted = await self.permissions.requestMicrophonePermission()
            guard self.recordingEngine === engine else { return }
            if granted {
                self.settings.recordingMicrophoneEnabled = true
                hud.configureMicrophone(
                    enabled: true,
                    deviceUID: self.settings.recordingMicrophoneDeviceUID
                )
                engine.setMicrophoneEnabled(true)
            } else {
                self.settings.recordingMicrophoneEnabled = false
                hud.configureMicrophone(
                    enabled: false,
                    deviceUID: self.settings.recordingMicrophoneDeviceUID
                )
                engine.setMicrophoneEnabled(false)
                FeedbackCenter.shared.post(
                    L10n.string("麦克风权限未授予，已保留视频与系统声音录制"),
                    level: .error
                )
            }
        }
    }

    private func stopScreenRecording() {
        guard let engine = recordingEngine else { return }
        recordingHUD?.setControlsEnabled(false)
        Task { @MainActor [weak self, weak engine] in
            guard let self, let engine else { return }
            do {
                guard let output = try await engine.stop() else {
                    self.endScreenRecordingUI()
                    return
                }

                self.closeRecordingChrome()
                let region = self.recordingRegion
                let screen = self.recordingScreen

                let processing = RecordingProcessingPanel(screen: screen)
                self.recordingProcessing = processing
                processing.onClose = { [weak self, weak processing] in
                    guard let self, self.recordingProcessing === processing else { return }
                    self.recordingProcessing = nil
                    AppActivation.endOverlayChrome()
                }
                processing.onCancelFormat = { [weak self, weak processing] in
                    guard let self, self.recordingProcessing === processing else { return }
                    try? FileManager.default.removeItem(at: output.url)
                    self.recordingProcessing = nil
                    self.endScreenRecordingUI()
                    FeedbackCenter.shared.post(L10n.string("已取消保存录制"))
                }

                // 固定策略：同一面板直接进入处理；询问策略：先选格式，保存后原地切换到完成态。
                if let fixed = self.settings.recordingSavePreference.fixedFormat {
                    self.settings.recordingLastSaveFormat = fixed
                    processing.orderFrontRegardless()
                    processing.showProcessing()
                    await self.finalizeRecordingOutput(
                        output,
                        format: fixed,
                        region: region,
                        processing: processing
                    )
                    self.endScreenRecordingUI(keepingProcessingPanel: true)
                } else {
                    processing.onConfirmFormat = { [weak self, weak processing] format in
                        guard let self, let processing, self.recordingProcessing === processing else {
                            return
                        }
                        self.settings.recordingLastSaveFormat = format
                        Task { @MainActor [weak self, weak processing] in
                            guard let self, let processing else { return }
                            await self.finalizeRecordingOutput(
                                output,
                                format: format,
                                region: region,
                                processing: processing
                            )
                            self.endScreenRecordingUI(keepingProcessingPanel: true)
                        }
                    }
                    processing.showFormatSelection(initialFormat: self.settings.recordingLastSaveFormat)
                }
            } catch {
                self.endScreenRecordingUI()
                FeedbackCenter.shared.post(
                    String(format: L10n.string("录制保存失败：%@"), error.localizedDescription),
                    level: .error
                )
            }
        }
    }

    private func finalizeRecordingOutput(
        _ output: ScreenRecordingOutput,
        format: ScreenRecordingFormat,
        region: CaptureRegion?,
        processing: RecordingProcessingPanel
    ) async {
        let counter = settings.nextRecordingFilenameCounter()
        let template = settings.recordingFilenameTemplate

        switch format {
        case .mp4:
            do {
                let url = try ScreenRecordingFileStore.save(
                    temporaryURL: output.url,
                    format: .mp4,
                    template: template,
                    counter: counter
                )
                registerRecordingHistory(
                    fileURL: url,
                    format: .mp4,
                    output: output,
                    region: region
                )
                processing.showCompleted(fileURL: url, format: .mp4)
                FeedbackCenter.shared.post(String(format: L10n.string("录制已保存：%@"), url.lastPathComponent))
                if settings.recordingRevealInFinder {
                    _ = FeatureHistoryIO.revealFileInFinder(url)
                }
            } catch {
                try? FileManager.default.removeItem(at: output.url)
                processing.showError(error.localizedDescription)
                FeedbackCenter.shared.post(
                    String(format: L10n.string("录制保存失败：%@"), error.localizedDescription),
                    level: .error
                )
            }

        case .gif:
            processing.showExportingGIF()
            do {
                let destination = try ScreenRecordingFileStore.uniqueDestination(
                    format: .gif,
                    template: template,
                    counter: counter
                )
                try await RecordingExporter.exportGIF(from: output.url, to: destination)
                try? FileManager.default.removeItem(at: output.url)
                registerRecordingHistory(
                    fileURL: destination,
                    format: .gif,
                    output: output,
                    region: region,
                    forceNoAudio: true
                )
                processing.showCompleted(fileURL: destination, format: .gif)
                FeedbackCenter.shared.post(String(format: L10n.string("GIF 已保存：%@"), destination.lastPathComponent))
                if settings.recordingRevealInFinder {
                    _ = FeatureHistoryIO.revealFileInFinder(destination)
                }
            } catch {
                // GIF 失败：保留临时 MP4，提供重试/打开。
                processing.showGIFFailure(
                    temporaryMP4URL: output.url,
                    message: error.localizedDescription
                )
                processing.onRetryGIF = { [weak self, weak processing] in
                    guard let self, let processing else { return }
                    Task { @MainActor in
                        await self.retryGIFExport(
                            temporaryMP4URL: output.url,
                            output: output,
                            region: region,
                            processing: processing
                        )
                    }
                }
                processing.onKeepMP4 = { [weak self, weak processing] in
                    guard let self, let processing else { return }
                    self.promoteTemporaryMP4(
                        temporaryURL: output.url,
                        output: output,
                        region: region,
                        processing: processing
                    )
                }
                FeedbackCenter.shared.post(
                    L10n.string("GIF 导出失败，已保留临时 MP4"),
                    level: .error
                )
            }
        }
    }

    private func retryGIFExport(
        temporaryMP4URL: URL,
        output: ScreenRecordingOutput,
        region: CaptureRegion?,
        processing: RecordingProcessingPanel
    ) async {
        processing.showExportingGIF()
        let counter = settings.nextRecordingFilenameCounter()
        do {
            let destination = try ScreenRecordingFileStore.uniqueDestination(
                format: .gif,
                template: settings.recordingFilenameTemplate,
                counter: counter
            )
            try await RecordingExporter.exportGIF(from: temporaryMP4URL, to: destination)
            try? FileManager.default.removeItem(at: temporaryMP4URL)
            registerRecordingHistory(
                fileURL: destination,
                format: .gif,
                output: output,
                region: region,
                forceNoAudio: true
            )
            processing.showCompleted(fileURL: destination, format: .gif)
            FeedbackCenter.shared.post(String(format: L10n.string("GIF 已保存：%@"), destination.lastPathComponent))
            if settings.recordingRevealInFinder {
                _ = FeatureHistoryIO.revealFileInFinder(destination)
            }
        } catch {
            processing.showGIFFailure(
                temporaryMP4URL: temporaryMP4URL,
                message: error.localizedDescription
            )
            FeedbackCenter.shared.post(
                String(format: L10n.string("GIF 重试失败：%@"), error.localizedDescription),
                level: .error
            )
        }
    }

    private func promoteTemporaryMP4(
        temporaryURL: URL,
        output: ScreenRecordingOutput,
        region: CaptureRegion?,
        processing: RecordingProcessingPanel
    ) {
        let counter = settings.nextRecordingFilenameCounter()
        do {
            let url = try ScreenRecordingFileStore.save(
                temporaryURL: temporaryURL,
                format: .mp4,
                template: settings.recordingFilenameTemplate,
                counter: counter
            )
            registerRecordingHistory(
                fileURL: url,
                format: .mp4,
                output: output,
                region: region
            )
            processing.showCompleted(fileURL: url, format: .mp4)
            FeedbackCenter.shared.post(String(format: L10n.string("已保存 MP4：%@"), url.lastPathComponent))
            if settings.recordingRevealInFinder {
                _ = FeatureHistoryIO.revealFileInFinder(url)
            }
        } catch {
            processing.showError(error.localizedDescription)
            FeedbackCenter.shared.post(
                String(format: L10n.string("保存 MP4 失败：%@"), error.localizedDescription),
                level: .error
            )
        }
    }

    private func registerRecordingHistory(
        fileURL: URL,
        format: ScreenRecordingFormat,
        output: ScreenRecordingOutput,
        region: CaptureRegion?,
        forceNoAudio: Bool = false
    ) {
        let duration = Self.mediaDurationSeconds(url: fileURL)
        _ = recordingHistory.register(
            fileURL: fileURL,
            format: format,
            durationSeconds: duration,
            pixelWidth: output.pixelWidth,
            pixelHeight: output.pixelHeight,
            displayID: region?.displayID ?? 0,
            containsSystemAudio: forceNoAudio ? false : output.containsSystemAudio,
            containsMicrophone: forceNoAudio ? false : output.containsMicrophone
        )
        recordingHistory.pruneIfNeeded()
    }

    private static func mediaDurationSeconds(url: URL) -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    private func cancelScreenRecording() {
        guard let engine = recordingEngine else { return }
        Task { @MainActor [weak self, weak engine] in
            guard let self, let engine else { return }
            await engine.cancel()
            self.endScreenRecordingUI()
        }
    }

    private func endScreenRecordingUI(keepingProcessingPanel: Bool = false) {
        closeRecordingChrome()
        if !keepingProcessingPanel {
            recordingProcessing?.orderOut(nil)
            recordingProcessing?.close()
            recordingProcessing = nil
            AppActivation.endOverlayChrome()
        }
        // keepingProcessingPanel 时等 processing.onClose 再 endOverlayChrome
        recordingScreen = nil
        recordingRegion = nil
        recordingEngine = nil
        didShowRecordingBlockedFeedback = false
    }

    private func closeRecordingChrome() {
        if let recordingEscapeMonitor {
            NSEvent.removeMonitor(recordingEscapeMonitor)
            self.recordingEscapeMonitor = nil
        }
        if let recordingLocalEscapeMonitor {
            NSEvent.removeMonitor(recordingLocalEscapeMonitor)
            self.recordingLocalEscapeMonitor = nil
        }
        recordingHUD?.orderOut(nil)
        recordingHUD?.close()
        recordingMask?.orderOut(nil)
        recordingMask?.close()
        recordingBorder?.orderOut(nil)
        recordingBorder?.close()
        recordingHUD = nil
        recordingMask = nil
        recordingBorder = nil
    }

    private static func cgImage(from image: NSImage) -> CGImage? {
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
