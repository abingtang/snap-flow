import Foundation
import Observation

/// 应用级依赖装配。UI 通过 environment 访问。
@MainActor
@Observable
final class AppContainer {
    let settings: SettingsStore
    let permissions: PermissionManager
    let screenCapture: ScreenCaptureService
    let ocr: OCRRouter
    let translation: TranslationService
    let textSelection: TextSelectionService
    let historyStore: HistoryStore
    let recordingHistory: RecordingHistoryStore
    let pasteboardMonitor: PasteboardMonitor
    let hotKeyManager: HotKeyManager
    let panelPresenter: PanelPresenter
    let workflows: AppWorkflows

    init() {
        let settings = SettingsStore()
        FeatureHistoryMaintenance.pruneAll(settings: settings)
        let permissions = PermissionManager()
        let historyStore = HistoryStore(settings: settings)
        let recordingHistory = RecordingHistoryStore(settings: settings)
        let panelPresenter = PanelPresenter()

        let screenCapture = ScreenCaptureService()
        let ocr = OCRRouter(settings: settings)
        let translation = TranslationService(settings: settings)
        let textSelection = TextSelectionService()
        let pasteboardMonitor = PasteboardMonitor(historyStore: historyStore, settings: settings)
        let hotKeyManager = HotKeyManager(settings: settings)

        self.settings = settings
        self.permissions = permissions
        self.screenCapture = screenCapture
        self.ocr = ocr
        self.translation = translation
        self.textSelection = textSelection
        self.historyStore = historyStore
        self.recordingHistory = recordingHistory
        self.pasteboardMonitor = pasteboardMonitor
        self.hotKeyManager = hotKeyManager
        self.panelPresenter = panelPresenter

        self.workflows = AppWorkflows(
            settings: settings,
            permissions: permissions,
            screenCapture: screenCapture,
            ocr: ocr,
            translation: translation,
            textSelection: textSelection,
            panelPresenter: panelPresenter,
            pasteboardMonitor: pasteboardMonitor,
            recordingHistory: recordingHistory
        )

        // 空闲时预热系统翻译宿主，避免首次划词翻译再挂 panel
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            translation.warmupHost()
        }
    }
}
