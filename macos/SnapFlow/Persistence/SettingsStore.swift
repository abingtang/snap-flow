import AppKit
import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class SettingsStore {
    private let defaults: UserDefaults
    private enum Key {
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let targetLanguage = "targetLanguage"
        static let sourceLanguage = "sourceLanguage"
        static let historyLimit = "historyLimit"
        static let clipboardPaused = "clipboard.paused"
        static let clipboardRecordsText = "clipboard.recordsText"
        static let clipboardRecordsImages = "clipboard.recordsImages"
        static let clipboardRecordsFiles = "clipboard.recordsFiles"
        static let clipboardPopupPosition = "clipboard.popupPosition"
        static let clipboardPopupScreen = "clipboard.popupScreen"
        static let clipboardWindowPosition = "clipboard.windowPosition"
        static let translatePopupPosition = "translate.popupPosition"
        static let translatePopupScreen = "translate.popupScreen"
        static let translateWindowPosition = "translate.windowPosition"
        static let snipHistoryLimit = "snipHistoryLimit"
        /// 截图保存图像质量：-1 自动 / 0…100（0 最高压缩，100 无损 PNG）
        static let snipImageQuality = "snip.imageQuality"
        static let snipHistoryEnabled = "history.snipEnabled"
        static let ocrHistoryEnabled = "history.ocrEnabled"
        static let ocrHistoryLimit = "history.ocrLimit"
        static let translationHistoryEnabled = "history.translationEnabled"
        static let translationHistoryLimit = "history.translationLimit"
        /// 全局功能历史保留天数；0 = 永久
        static let historyRetentionDays = "history.retentionDays"
        static let launchAtLogin = "launchAtLogin"
        /// 界面语言偏好（`AppLanguagePreference`）
        static let appLanguagePreference = AppLanguagePreference.defaultsKey
        /// 强调色跟随系统（与 `AppTheme.useSystemAccentDefaultsKey` 同值）
        static let useSystemAccentColor = AppTheme.useSystemAccentDefaultsKey
        /// 贴图首次可发现性提示是否已展示
        static let pinDiscoverabilityHintShown = "pin.discoverabilityHintShown"
        static let hotkeyCaptureScreenshot = "hotkey.captureScreenshot"
        static let hotkeyPasteToScreen = "hotkey.pasteToScreen"
        static let hotkeyTogglePins = "hotkey.togglePins"
        static let hotkeyClickThrough = "hotkey.clickThrough"
        static let hotkeyCaptureOCR = "hotkey.captureOCR"
        static let hotkeyCaptureImageOCR = "hotkey.captureImageOCR"
        static let hotkeyCaptureTranslate = "hotkey.captureTranslate"
        static let hotkeyCaptureImageTranslate = "hotkey.captureImageTranslate"
        static let hotkeySelectionTranslate = "hotkey.selectionTranslate"
        static let hotkeyClipboard = "hotkey.clipboard"
        static let localShortcuts = "localShortcuts"
        static let ocrServices = "ocr.services"
        static let defaultOCRServiceID = "ocr.defaultServiceID"
        static let translationServices = "translation.services"
        static let defaultTranslationServiceID = "translation.defaultServiceID"
        static let recordingSystemAudioEnabled = "recording.systemAudioEnabled"
        static let recordingMicrophoneEnabled = "recording.microphoneEnabled"
        static let recordingMicrophoneDeviceUID = "recording.microphoneDeviceUID"
        static let recordingShowsCursor = "recording.showsCursor"
        static let recordingSavePreference = "recording.savePreference"
        static let recordingLastSaveFormat = "recording.lastSaveFormat"
        static let recordingFilenameTemplate = "recording.filenameTemplate"
        static let recordingFilenameCounter = "recording.filenameCounter"
        static let recordingHistoryEnabled = "recording.historyEnabled"
        static let recordingHistoryLimit = "recording.historyLimit"
        static let recordingHistoryMaxMediaBytes = "recording.historyMaxMediaBytes"
        static let recordingRevealInFinder = "recording.revealInFinder"
        static let recordingIndexCorruptedNotice = "recording.indexCorruptedNotice"
    }

    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }

    /// 目标语言：`system` 跟随本机首选语言，或 BCP-47（如 zh-Hans / en）
    var targetLanguage: String {
        didSet { defaults.set(targetLanguage, forKey: Key.targetLanguage) }
    }

    /// 源语言：`auto` 用 NLLanguageRecognizer，或 BCP-47 强制指定
    var sourceLanguage: String {
        didSet { defaults.set(sourceLanguage, forKey: Key.sourceLanguage) }
    }

    /// 默认翻译服务 ID。
    var defaultTranslationServiceID: String {
        didSet { defaults.set(defaultTranslationServiceID, forKey: Key.defaultTranslationServiceID) }
    }

    /// 已配置的翻译服务列表（固定含系统翻译）。
    var translationServices: [TranslationServiceEntry] {
        didSet {
            let normalized = Self.normalizedTranslationServices(translationServices)
            if normalized != translationServices {
                translationServices = normalized
                return
            }
            Self.persistTranslationServices(normalized, defaults: defaults)
            if !Self.isValidTranslationDefault(defaultTranslationServiceID, in: normalized) {
                defaultTranslationServiceID = TranslationServiceEntry.systemID
            }
        }
    }

    /// 解析后的目标语言 BCP-47。
    var resolvedTargetLanguageCode: String {
        TranslationLanguage.resolvedTargetCode(setting: targetLanguage)
    }

    var historyLimit: Int {
        didSet { defaults.set(historyLimit, forKey: Key.historyLimit) }
    }

    var clipboardPaused: Bool {
        didSet { defaults.set(clipboardPaused, forKey: Key.clipboardPaused) }
    }

    var clipboardRecordsText: Bool {
        didSet { defaults.set(clipboardRecordsText, forKey: Key.clipboardRecordsText) }
    }

    var clipboardRecordsImages: Bool {
        didSet { defaults.set(clipboardRecordsImages, forKey: Key.clipboardRecordsImages) }
    }

    var clipboardRecordsFiles: Bool {
        didSet { defaults.set(clipboardRecordsFiles, forKey: Key.clipboardRecordsFiles) }
    }

    var clipboardPopupPosition: ClipboardPopupPosition {
        didSet { defaults.set(clipboardPopupPosition.rawValue, forKey: Key.clipboardPopupPosition) }
    }

    var clipboardPopupScreen: Int {
        didSet { defaults.set(clipboardPopupScreen, forKey: Key.clipboardPopupScreen) }
    }

    var clipboardWindowPosition: NSPoint {
        didSet { defaults.set(NSStringFromPoint(clipboardWindowPosition), forKey: Key.clipboardWindowPosition) }
    }

    /// 划词翻译浮窗弹出位置（与剪切板同一套模式）。
    var translatePopupPosition: ClipboardPopupPosition {
        didSet { defaults.set(translatePopupPosition.rawValue, forKey: Key.translatePopupPosition) }
    }

    var translatePopupScreen: Int {
        didSet { defaults.set(translatePopupScreen, forKey: Key.translatePopupScreen) }
    }

    /// 「上次位置」模式：相对所选显示器 visibleFrame 的归一化锚点。
    var translateWindowPosition: NSPoint {
        didSet { defaults.set(NSStringFromPoint(translateWindowPosition), forKey: Key.translateWindowPosition) }
    }

    /// 截图历史上限（与设置页、框选 prev/next 共用）。
    var snipHistoryLimit: Int {
        didSet {
            defaults.set(snipHistoryLimit, forKey: Key.snipHistoryLimit)
            SnipHistoryStore.shared.maxCount = snipHistoryLimit
            SnipHistoryStore.shared.prune()
        }
    }

    /// 截图保存到文件时的图像质量：`-1` 自动（PNG），`0…99` JPEG 质量，`100` 无损 PNG。
    /// 不影响复制到剪切板与功能历史（仍为无损）。
    var snipImageQuality: Int {
        didSet {
            let normalized = SnipImageExport.normalizedQuality(snipImageQuality)
            if snipImageQuality != normalized {
                snipImageQuality = normalized
                return
            }
            defaults.set(normalized, forKey: Key.snipImageQuality)
        }
    }

    var snipHistoryEnabled: Bool {
        didSet {
            defaults.set(snipHistoryEnabled, forKey: Key.snipHistoryEnabled)
            SnipHistoryStore.shared.recordingEnabled = snipHistoryEnabled
        }
    }

    var ocrHistoryEnabled: Bool {
        didSet {
            defaults.set(ocrHistoryEnabled, forKey: Key.ocrHistoryEnabled)
            OCRHistoryStore.shared.recordingEnabled = ocrHistoryEnabled
        }
    }

    var ocrHistoryLimit: Int {
        didSet {
            defaults.set(ocrHistoryLimit, forKey: Key.ocrHistoryLimit)
            OCRHistoryStore.shared.maxCount = ocrHistoryLimit
            OCRHistoryStore.shared.prune()
        }
    }

    var translationHistoryEnabled: Bool {
        didSet {
            defaults.set(translationHistoryEnabled, forKey: Key.translationHistoryEnabled)
            TranslationHistoryStore.shared.recordingEnabled = translationHistoryEnabled
        }
    }

    var translationHistoryLimit: Int {
        didSet {
            defaults.set(translationHistoryLimit, forKey: Key.translationHistoryLimit)
            TranslationHistoryStore.shared.maxCount = translationHistoryLimit
            TranslationHistoryStore.shared.prune()
        }
    }

    /// 功能历史（截图 / OCR / 翻译）保留天数；`0` 表示永久。
    var historyRetentionDays: Int {
        didSet {
            defaults.set(historyRetentionDays, forKey: Key.historyRetentionDays)
            SnipHistoryStore.shared.retentionDays = historyRetentionDays
            OCRHistoryStore.shared.retentionDays = historyRetentionDays
            TranslationHistoryStore.shared.retentionDays = historyRetentionDays
            FeatureHistoryMaintenance.pruneAll(settings: self)
        }
    }

    var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }

    var launchAtLoginStatus: SMAppService.Status {
        SMAppService.mainApp.status
    }

    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) throws -> SMAppService.Status {
        let service = SMAppService.mainApp

        switch (enabled, service.status) {
        case (true, .enabled), (true, .requiresApproval), (false, .notRegistered), (false, .notFound):
            break
        default:
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        }

        let status = service.status
        switch status {
        case .enabled, .requiresApproval:
            launchAtLogin = true
        case .notRegistered, .notFound:
            launchAtLogin = false
        @unknown default:
            launchAtLogin = enabled
        }
        return status
    }

    @discardableResult
    func synchronizeLaunchAtLogin() throws -> SMAppService.Status {
        try setLaunchAtLogin(launchAtLogin)
    }

    func refreshLaunchAtLogin() {
        switch launchAtLoginStatus {
        case .enabled, .requiresApproval:
            launchAtLogin = true
        case .notRegistered, .notFound:
            launchAtLogin = false
        @unknown default:
            break
        }
    }

    /// 界面语言：跟随系统 / 简体中文 / 英语（可扩展）。
    var appLanguagePreference: AppLanguagePreference {
        didSet {
            AppLanguagePreference.save(appLanguagePreference, to: defaults)
            NotificationCenter.default.post(name: .snapFlowLanguageDidChange, object: nil)
        }
    }

    /// 当前界面实际使用的 `Locale`。
    var resolvedLocale: Locale {
        appLanguagePreference.resolvedLocale
    }

    /// 使用系统强调色（否则用 SnapFlow 品牌靛蓝）
    var useSystemAccentColor: Bool {
        didSet {
            defaults.set(useSystemAccentColor, forKey: Key.useSystemAccentColor)
            NotificationCenter.default.post(name: .snapFlowAppearanceDidChange, object: nil)
        }
    }

    /// 贴图窗是否已展示过「悬停工具条」提示
    var pinDiscoverabilityHintShown: Bool {
        didSet { defaults.set(pinDiscoverabilityHintShown, forKey: Key.pinDiscoverabilityHintShown) }
    }

    /// 热键序列化字符串，如 "ctrl+option+command+a"
    var hotkeyCaptureScreenshot: String {
        didSet { defaults.set(hotkeyCaptureScreenshot, forKey: Key.hotkeyCaptureScreenshot) }
    }

    /// 贴到屏幕（推荐 ⌃⌥P）
    var hotkeyPasteToScreen: String {
        didSet { defaults.set(hotkeyPasteToScreen, forKey: Key.hotkeyPasteToScreen) }
    }

    var hotkeyTogglePins: String {
        didSet { defaults.set(hotkeyTogglePins, forKey: Key.hotkeyTogglePins) }
    }

    var hotkeyClickThrough: String {
        didSet { defaults.set(hotkeyClickThrough, forKey: Key.hotkeyClickThrough) }
    }

    var hotkeyCaptureOCR: String {
        didSet { defaults.set(hotkeyCaptureOCR, forKey: Key.hotkeyCaptureOCR) }
    }

    /// 原图 OCR（选区叠层识别原文，可一键翻译）
    var hotkeyCaptureImageOCR: String {
        didSet { defaults.set(hotkeyCaptureImageOCR, forKey: Key.hotkeyCaptureImageOCR) }
    }

    var hotkeyCaptureTranslate: String {
        didSet { defaults.set(hotkeyCaptureTranslate, forKey: Key.hotkeyCaptureTranslate) }
    }

    /// 原图翻译（选区叠层）；默认可配置
    var hotkeyCaptureImageTranslate: String {
        didSet { defaults.set(hotkeyCaptureImageTranslate, forKey: Key.hotkeyCaptureImageTranslate) }
    }

    var hotkeySelectionTranslate: String {
        didSet { defaults.set(hotkeySelectionTranslate, forKey: Key.hotkeySelectionTranslate) }
    }

    var hotkeyClipboard: String {
        didSet { defaults.set(hotkeyClipboard, forKey: Key.hotkeyClipboard) }
    }

    var localShortcuts: [String: String] {
        didSet { defaults.set(localShortcuts, forKey: Key.localShortcuts) }
    }

    /// 已添加的 OCR 服务列表（含内置 Vision）。
    var ocrServices: [OCRServiceEntry] {
        didSet { Self.persistOCRServices(ocrServices, defaults: defaults) }
    }

    /// 全局默认 OCR 服务 ID。
    var defaultOCRServiceID: String {
        didSet { defaults.set(defaultOCRServiceID, forKey: Key.defaultOCRServiceID) }
    }

    /// 录制系统音频的下次默认状态；首次安装关闭。
    var recordingSystemAudioEnabled: Bool {
        didSet { defaults.set(recordingSystemAudioEnabled, forKey: Key.recordingSystemAudioEnabled) }
    }

    /// 录制麦克风的下次默认状态；首次安装关闭，首次开启时才懒请求权限。
    var recordingMicrophoneEnabled: Bool {
        didSet { defaults.set(recordingMicrophoneEnabled, forKey: Key.recordingMicrophoneEnabled) }
    }

    /// 上次选择的麦克风设备 UID；`nil` 表示系统默认输入。
    var recordingMicrophoneDeviceUID: String? {
        didSet {
            if let recordingMicrophoneDeviceUID {
                defaults.set(recordingMicrophoneDeviceUID, forKey: Key.recordingMicrophoneDeviceUID)
            } else {
                defaults.removeObject(forKey: Key.recordingMicrophoneDeviceUID)
            }
        }
    }

    /// 是否录制鼠标指针；默认开启。
    var recordingShowsCursor: Bool {
        didSet { defaults.set(recordingShowsCursor, forKey: Key.recordingShowsCursor) }
    }

    /// 停止后的保存策略：每次询问 / 总是 MP4 / 总是 GIF。
    var recordingSavePreference: RecordingSavePreference {
        didSet { defaults.set(recordingSavePreference.rawValue, forKey: Key.recordingSavePreference) }
    }

    /// 上次在询问面板中选择的格式；首次默认 MP4。
    var recordingLastSaveFormat: ScreenRecordingFormat {
        didSet { defaults.set(recordingLastSaveFormat.rawValue, forKey: Key.recordingLastSaveFormat) }
    }

    /// 录制文件名模板，默认 `SnapFlow-rec-{date}-{time}`。
    var recordingFilenameTemplate: String {
        didSet { defaults.set(recordingFilenameTemplate, forKey: Key.recordingFilenameTemplate) }
    }

    /// 是否登记录制历史；关闭时仍保存媒体，不登记、不生成缩略图、不清理。
    var recordingHistoryEnabled: Bool {
        didSet { defaults.set(recordingHistoryEnabled, forKey: Key.recordingHistoryEnabled) }
    }

    /// 录制历史条数上限，默认 20。
    var recordingHistoryLimit: Int {
        didSet { defaults.set(recordingHistoryLimit, forKey: Key.recordingHistoryLimit) }
    }

    /// 录制历史媒体总大小上限（字节），默认 5 GB。
    var recordingHistoryMaxMediaBytes: Int64 {
        didSet { defaults.set(recordingHistoryMaxMediaBytes, forKey: Key.recordingHistoryMaxMediaBytes) }
    }

    /// 保存成功后是否自动在访达中显示；默认关闭。
    var recordingRevealInFinder: Bool {
        didSet { defaults.set(recordingRevealInFinder, forKey: Key.recordingRevealInFinder) }
    }

    /// 录制历史索引曾损坏时在设置中提示。
    var recordingIndexCorruptedNotice: Bool {
        didSet { defaults.set(recordingIndexCorruptedNotice, forKey: Key.recordingIndexCorruptedNotice) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
        // 新装默认跟随系统；已有写入值原样保留（不强制迁移）
        if let storedTarget = defaults.string(forKey: Key.targetLanguage), !storedTarget.isEmpty {
            self.targetLanguage = storedTarget
        } else {
            self.targetLanguage = TranslationLanguage.systemTargetToken
        }
        self.sourceLanguage = defaults.string(forKey: Key.sourceLanguage) ?? TranslationLanguage.autoSourceToken
        self.translationServices = Self.loadTranslationServices(from: defaults)
        self.defaultTranslationServiceID =
            defaults.string(forKey: Key.defaultTranslationServiceID) ?? TranslationServiceEntry.systemID
        let limit = defaults.object(forKey: Key.historyLimit) as? Int
        self.historyLimit = limit ?? 200
        self.clipboardPaused = defaults.bool(forKey: Key.clipboardPaused)
        self.clipboardRecordsText = defaults.object(forKey: Key.clipboardRecordsText) as? Bool ?? true
        self.clipboardRecordsImages = defaults.object(forKey: Key.clipboardRecordsImages) as? Bool ?? true
        self.clipboardRecordsFiles = defaults.object(forKey: Key.clipboardRecordsFiles) as? Bool ?? true
        self.clipboardPopupPosition = ClipboardPopupPosition(
            rawValue: defaults.string(forKey: Key.clipboardPopupPosition) ?? ""
        ) ?? .cursor
        self.clipboardPopupScreen = defaults.integer(forKey: Key.clipboardPopupScreen)
        self.clipboardWindowPosition = defaults.string(forKey: Key.clipboardWindowPosition)
            .map(NSPointFromString) ?? NSPoint(x: 0.5, y: 0.8)
        self.translatePopupPosition = ClipboardPopupPosition(
            rawValue: defaults.string(forKey: Key.translatePopupPosition) ?? ""
        ) ?? .cursor
        self.translatePopupScreen = defaults.integer(forKey: Key.translatePopupScreen)
        self.translateWindowPosition = defaults.string(forKey: Key.translateWindowPosition)
            .map(NSPointFromString) ?? NSPoint(x: 0.5, y: 0.8)
        let snipLimit = defaults.object(forKey: Key.snipHistoryLimit) as? Int
        self.snipHistoryLimit = snipLimit ?? 100
        if defaults.object(forKey: Key.snipImageQuality) != nil {
            self.snipImageQuality = SnipImageExport.normalizedQuality(
                defaults.integer(forKey: Key.snipImageQuality)
            )
        } else {
            self.snipImageQuality = -1
        }
        self.snipHistoryEnabled = defaults.object(forKey: Key.snipHistoryEnabled) as? Bool ?? true
        self.ocrHistoryEnabled = defaults.object(forKey: Key.ocrHistoryEnabled) as? Bool ?? true
        self.ocrHistoryLimit = defaults.object(forKey: Key.ocrHistoryLimit) as? Int ?? 100
        self.translationHistoryEnabled =
            defaults.object(forKey: Key.translationHistoryEnabled) as? Bool ?? true
        self.translationHistoryLimit =
            defaults.object(forKey: Key.translationHistoryLimit) as? Int ?? 100
        let retention = defaults.object(forKey: Key.historyRetentionDays) as? Int
        self.historyRetentionDays = retention ?? 7
        self.launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        self.appLanguagePreference = AppLanguagePreference.load(from: defaults)
        self.useSystemAccentColor = defaults.bool(forKey: Key.useSystemAccentColor)
        self.pinDiscoverabilityHintShown = defaults.bool(forKey: Key.pinDiscoverabilityHintShown)
        // 全局热键：双修饰键分族（⌃⌥ 截图/贴图 · ⌥⌘ OCR/翻译/剪切板），不再使用 F 区
        self.hotkeyCaptureScreenshot = Self.migratedGlobalHotkey(
            defaults.string(forKey: Key.hotkeyCaptureScreenshot),
            previousDefaults: ["ctrl+option+command+a", "f1"],
            recommended: RecommendedHotkey.captureScreenshot
        )
        self.hotkeyPasteToScreen = Self.migratedGlobalHotkey(
            defaults.string(forKey: Key.hotkeyPasteToScreen),
            previousDefaults: ["ctrl+option+command+p", "f3"],
            recommended: RecommendedHotkey.pasteToScreen
        )
        self.hotkeyTogglePins = Self.migratedGlobalHotkey(
            defaults.string(forKey: Key.hotkeyTogglePins),
            previousDefaults: ["shift+f3", ""],
            recommended: RecommendedHotkey.togglePins
        )
        self.hotkeyClickThrough = Self.migratedGlobalHotkey(
            defaults.string(forKey: Key.hotkeyClickThrough),
            previousDefaults: ["ctrl+option+command+x", ""],
            recommended: RecommendedHotkey.clickThrough
        )
        self.hotkeyCaptureOCR = Self.migratedGlobalHotkey(
            defaults.string(forKey: Key.hotkeyCaptureOCR),
            previousDefaults: ["ctrl+option+command+o", ""],
            recommended: RecommendedHotkey.captureOCR
        )
        self.hotkeyCaptureImageOCR = Self.migratedGlobalHotkey(
            defaults.string(forKey: Key.hotkeyCaptureImageOCR),
            previousDefaults: [""],
            recommended: RecommendedHotkey.captureImageOCR
        )
        self.hotkeyCaptureTranslate = Self.migratedGlobalHotkey(
            defaults.string(forKey: Key.hotkeyCaptureTranslate),
            previousDefaults: ["ctrl+option+command+t", ""],
            recommended: RecommendedHotkey.captureTranslate
        )
        self.hotkeyCaptureImageTranslate = Self.migratedGlobalHotkey(
            defaults.string(forKey: Key.hotkeyCaptureImageTranslate),
            previousDefaults: [""],
            recommended: RecommendedHotkey.captureImageTranslate
        )
        self.hotkeySelectionTranslate = Self.migratedGlobalHotkey(
            defaults.string(forKey: Key.hotkeySelectionTranslate),
            previousDefaults: ["ctrl+option+command+s", ""],
            recommended: RecommendedHotkey.selectionTranslate
        )
        self.hotkeyClipboard = Self.migratedGlobalHotkey(
            defaults.string(forKey: Key.hotkeyClipboard),
            previousDefaults: ["ctrl+option+command+v", "cmd+shift+c", ""],
            recommended: RecommendedHotkey.clipboard
        )
        let storedShortcuts = defaults.dictionary(forKey: Key.localShortcuts) as? [String: String] ?? [:]
        self.localShortcuts = Dictionary(
            uniqueKeysWithValues: LocalShortcutAction.allCases.map {
                ($0.rawValue, storedShortcuts[$0.rawValue] ?? $0.defaultChord)
            }
        )
        self.ocrServices = Self.loadOCRServices(from: defaults)
        let storedDefault = defaults.string(forKey: Key.defaultOCRServiceID) ?? OCRServiceEntry.visionID
        self.defaultOCRServiceID = storedDefault
        self.recordingSystemAudioEnabled = defaults.object(forKey: Key.recordingSystemAudioEnabled) as? Bool ?? false
        self.recordingMicrophoneEnabled = defaults.object(forKey: Key.recordingMicrophoneEnabled) as? Bool ?? false
        self.recordingMicrophoneDeviceUID = defaults.string(forKey: Key.recordingMicrophoneDeviceUID)
        self.recordingShowsCursor = defaults.object(forKey: Key.recordingShowsCursor) as? Bool ?? true
        self.recordingSavePreference = RecordingSavePreference(
            rawValue: defaults.string(forKey: Key.recordingSavePreference) ?? ""
        ) ?? .ask
        self.recordingLastSaveFormat = ScreenRecordingFormat(
            rawValue: defaults.string(forKey: Key.recordingLastSaveFormat) ?? ""
        ) ?? .mp4
        let template = defaults.string(forKey: Key.recordingFilenameTemplate)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.recordingFilenameTemplate =
            (template?.isEmpty == false) ? template! : RecordingFilenameTemplate.defaultTemplate
        self.recordingHistoryEnabled = defaults.object(forKey: Key.recordingHistoryEnabled) as? Bool ?? true
        self.recordingHistoryLimit = max(0, defaults.object(forKey: Key.recordingHistoryLimit) as? Int ?? 20)
        if let storedBytes = defaults.object(forKey: Key.recordingHistoryMaxMediaBytes) as? Int64 {
            self.recordingHistoryMaxMediaBytes = max(0, storedBytes)
        } else if let storedInt = defaults.object(forKey: Key.recordingHistoryMaxMediaBytes) as? Int {
            self.recordingHistoryMaxMediaBytes = Int64(max(0, storedInt))
        } else {
            self.recordingHistoryMaxMediaBytes = 5 * 1024 * 1024 * 1024
        }
        self.recordingRevealInFinder = defaults.object(forKey: Key.recordingRevealInFinder) as? Bool ?? false
        self.recordingIndexCorruptedNotice = defaults.bool(forKey: Key.recordingIndexCorruptedNotice)
        // 确保默认指向仍存在的服务
        if !self.ocrServices.contains(where: { $0.id == self.defaultOCRServiceID }) {
            self.defaultOCRServiceID = OCRServiceEntry.visionID
        }
        if !self.translationServices.contains(where: {
            $0.id == self.defaultTranslationServiceID
                && ($0.kind == .system || ($0.isEnabled && $0.isReadyToTranslate))
        }) {
            self.defaultTranslationServiceID = TranslationServiceEntry.systemID
        }
        [
            (Key.hotkeyCaptureScreenshot, hotkeyCaptureScreenshot),
            (Key.hotkeyPasteToScreen, hotkeyPasteToScreen),
            (Key.hotkeyTogglePins, hotkeyTogglePins),
            (Key.hotkeyClickThrough, hotkeyClickThrough),
            (Key.hotkeyCaptureOCR, hotkeyCaptureOCR),
            (Key.hotkeyCaptureImageOCR, hotkeyCaptureImageOCR),
            (Key.hotkeyCaptureTranslate, hotkeyCaptureTranslate),
            (Key.hotkeyCaptureImageTranslate, hotkeyCaptureImageTranslate),
            (Key.hotkeySelectionTranslate, hotkeySelectionTranslate),
            (Key.hotkeyClipboard, hotkeyClipboard),
        ].forEach { defaults.set($0.1, forKey: $0.0) }
        defaults.set(localShortcuts, forKey: Key.localShortcuts)
        defaults.set(defaultOCRServiceID, forKey: Key.defaultOCRServiceID)
        defaults.set(defaultTranslationServiceID, forKey: Key.defaultTranslationServiceID)
        defaults.set(targetLanguage, forKey: Key.targetLanguage)
        Self.persistTranslationServices(translationServices, defaults: defaults)
        Self.persistOCRServices(ocrServices, defaults: defaults)
    }

    // MARK: - Translation services

    func setDefaultTranslationServiceID(_ id: String) {
        guard let entry = translationService(id: id),
              entry.kind == .system || (entry.isEnabled && entry.isReadyToTranslate)
        else { return }
        defaultTranslationServiceID = id
    }

    func resolvedDefaultTranslationServiceID() -> String {
        if let entry = translationService(id: defaultTranslationServiceID),
           entry.kind == .system || (entry.isEnabled && entry.isReadyToTranslate)
        {
            return entry.id
        }
        return TranslationServiceEntry.systemID
    }

    func translationService(id: String) -> TranslationServiceEntry? {
        translationServices.first { $0.id == id }
    }

    /// 划词浮窗：系统翻译始终在，其它服务按启用状态展示；默认服务排在最前。
    func enabledTranslationServicesForPopup() -> [TranslationServiceEntry] {
        let enabled = translationServices.filter { $0.kind == .system || $0.isEnabled }
        let defaultID = resolvedDefaultTranslationServiceID()
        return enabled.sorted {
            if $0.id == defaultID { return true }
            if $1.id == defaultID { return false }
            if $0.kind == .system { return true }
            if $1.kind == .system { return false }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private static func loadTranslationServices(from defaults: UserDefaults) -> [TranslationServiceEntry] {
        guard let data = defaults.data(forKey: Key.translationServices),
              let decoded = try? JSONDecoder().decode([TranslationServiceEntry].self, from: data),
              !decoded.isEmpty
        else {
            return [.system()]
        }
        return normalizedTranslationServices(decoded)
    }

    private static func normalizedTranslationServices(
        _ services: [TranslationServiceEntry]
    ) -> [TranslationServiceEntry] {
        var seenKinds = Set<String>()
        var result = [TranslationServiceEntry.system()]
        seenKinds.insert(TranslationServiceKind.system.rawValue)
        for var entry in services where !seenKinds.contains(entry.kind.rawValue) {
            guard entry.kind != .system else { continue }
            seenKinds.insert(entry.kind.rawValue)
            if !entry.privacyAccepted {
                entry.isEnabled = false
            }
            result.append(entry)
        }
        return result
    }

    private static func isValidTranslationDefault(
        _ id: String,
        in services: [TranslationServiceEntry]
    ) -> Bool {
        guard let entry = services.first(where: { $0.id == id }) else { return false }
        return entry.kind == .system || (entry.isEnabled && entry.isReadyToTranslate)
    }

    private static func persistTranslationServices(
        _ services: [TranslationServiceEntry],
        defaults: UserDefaults
    ) {
        if let data = try? JSONEncoder().encode(services) {
            defaults.set(data, forKey: Key.translationServices)
        }
    }

    // MARK: - OCR services

    func ocrService(id: String) -> OCRServiceEntry? {
        ocrServices.first { $0.id == id }
    }

    /// 菜单中可选：Vision 始终在；其它需 isEnabled。
    func enabledOCRServicesForMenu() -> [OCRServiceEntry] {
        ocrServices.filter { $0.kind == .vision || $0.isEnabled }
    }

    /// 若默认不可用则回落到 Vision。
    func resolvedDefaultOCRServiceID() -> String {
        if let e = ocrService(id: defaultOCRServiceID), e.kind == .vision || e.isEnabled {
            return e.id
        }
        return OCRServiceEntry.visionID
    }

    func setDefaultOCRServiceID(_ id: String) {
        guard ocrServices.contains(where: { $0.id == id }) else { return }
        defaultOCRServiceID = id
    }

    /// 用草稿整体替换（设置页保存）。
    func replaceOCRServices(_ services: [OCRServiceEntry], defaultID: String) {
        var list = services
        if !list.contains(where: { $0.kind == .vision }) {
            list.insert(.vision(), at: 0)
        }
        // Vision 强制启用
        if let idx = list.firstIndex(where: { $0.kind == .vision }) {
            list[idx].isEnabled = true
            list[idx].id = OCRServiceEntry.visionID
            list[idx].displayName = OCRServiceKind.vision.displayName
        }
        ocrServices = list
        if list.contains(where: { $0.id == defaultID }) {
            defaultOCRServiceID = defaultID
        } else {
            defaultOCRServiceID = OCRServiceEntry.visionID
        }
    }

    func updateBaiduToken(serviceID: String, config: BaiduOCRConfig) {
        guard let idx = ocrServices.firstIndex(where: { $0.id == serviceID }) else { return }
        ocrServices[idx].baidu = config
    }

    private static func loadOCRServices(from defaults: UserDefaults) -> [OCRServiceEntry] {
        guard let data = defaults.data(forKey: Key.ocrServices),
              let decoded = try? JSONDecoder().decode([OCRServiceEntry].self, from: data),
              !decoded.isEmpty
        else {
            return [.vision()]
        }
        var list = decoded
        if !list.contains(where: { $0.kind == .vision }) {
            list.insert(.vision(), at: 0)
        }
        if let idx = list.firstIndex(where: { $0.kind == .vision }) {
            list[idx].isEnabled = true
            list[idx].id = OCRServiceEntry.visionID
        }
        return list
    }

    private static func persistOCRServices(_ services: [OCRServiceEntry], defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(services) {
            defaults.set(data, forKey: Key.ocrServices)
        }
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
    }

    /// 恢复 SnapFlow 推荐全局热键（双修饰键分族，无 F 区）。
    func restoreSnipasteHotkeys() {
        applyRecommendedGlobalHotkeys()
    }

    /// 恢复录制相关推荐默认值（不影响当前进行中的录制会话）。
    func restoreRecordingDefaults() {
        recordingShowsCursor = true
        recordingSystemAudioEnabled = false
        recordingMicrophoneEnabled = false
        recordingMicrophoneDeviceUID = nil
        recordingSavePreference = .ask
        recordingLastSaveFormat = .mp4
        recordingFilenameTemplate = RecordingFilenameTemplate.defaultTemplate
        recordingHistoryEnabled = true
        recordingHistoryLimit = 20
        recordingHistoryMaxMediaBytes = 5 * 1024 * 1024 * 1024
        recordingRevealInFinder = false
    }

    /// 递增并返回下一个文件名计数器（用于 `{counter}` 令牌）。
    func nextRecordingFilenameCounter() -> Int {
        let next = max(1, defaults.integer(forKey: Key.recordingFilenameCounter) + 1)
        defaults.set(next, forKey: Key.recordingFilenameCounter)
        return next
    }

    func applyRecommendedGlobalHotkeys() {
        hotkeyCaptureScreenshot = RecommendedHotkey.captureScreenshot
        hotkeyPasteToScreen = RecommendedHotkey.pasteToScreen
        hotkeyTogglePins = RecommendedHotkey.togglePins
        hotkeyClickThrough = RecommendedHotkey.clickThrough
        hotkeyCaptureOCR = RecommendedHotkey.captureOCR
        hotkeyCaptureImageOCR = RecommendedHotkey.captureImageOCR
        hotkeyCaptureTranslate = RecommendedHotkey.captureTranslate
        hotkeyCaptureImageTranslate = RecommendedHotkey.captureImageTranslate
        hotkeySelectionTranslate = RecommendedHotkey.selectionTranslate
        hotkeyClipboard = RecommendedHotkey.clipboard
    }

    func shortcut(for action: LocalShortcutAction) -> String {
        localShortcuts[action.rawValue] ?? action.defaultChord
    }

    func setShortcut(_ chord: String, for action: LocalShortcutAction) {
        // 整表回写，确保 @Observable / didSet 一定触发 UI 刷新
        var next = localShortcuts
        next[action.rawValue] = chord
        localShortcuts = next
    }

    func matches(_ action: LocalShortcutAction, event: NSEvent) -> Bool {
        // 录制屏蔽已在 LocalShortcutMatcher 内统一处理
        return LocalShortcutMatcher.matches(event, chord: shortcut(for: action))
    }

    func restoreLocalShortcuts(scope: LocalShortcutScope) {
        var next = localShortcuts
        for action in LocalShortcutAction.allCases where action.scope == scope {
            next[action.rawValue] = action.defaultChord
        }
        localShortcuts = next
    }

    /// 全局功能热键分组（设置页「恢复本组默认」用）。
    enum GlobalHotkeyGroup: Sendable {
        /// 截图页：区域截图 / 贴图 / 显隐 / 穿透
        case capture
        /// OCR 页：区域 OCR / 原图 OCR
        case ocr
        /// 翻译页：截图翻译 / 原图翻译 / 划词翻译
        case translate
        /// 剪切板页：打开剪切板历史
        case clipboard
    }

    /// 将指定全局功能热键组恢复为推荐方案（不改局部快捷键）。
    func restoreGlobalHotkeys(group: GlobalHotkeyGroup) {
        switch group {
        case .capture:
            hotkeyCaptureScreenshot = RecommendedHotkey.captureScreenshot
            hotkeyPasteToScreen = RecommendedHotkey.pasteToScreen
            hotkeyTogglePins = RecommendedHotkey.togglePins
            hotkeyClickThrough = RecommendedHotkey.clickThrough
        case .ocr:
            hotkeyCaptureOCR = RecommendedHotkey.captureOCR
            hotkeyCaptureImageOCR = RecommendedHotkey.captureImageOCR
        case .translate:
            hotkeyCaptureTranslate = RecommendedHotkey.captureTranslate
            hotkeyCaptureImageTranslate = RecommendedHotkey.captureImageTranslate
            hotkeySelectionTranslate = RecommendedHotkey.selectionTranslate
        case .clipboard:
            hotkeyClipboard = RecommendedHotkey.clipboard
        }
    }

    /// 未写入 / 仍是历史默认值 → 升到推荐方案；用户自定义 chord 保留。
    private static func migratedGlobalHotkey(
        _ stored: String?,
        previousDefaults: [String],
        recommended: String
    ) -> String {
        guard let stored else { return recommended }
        let normalized = stored.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let previous = Set(previousDefaults.map { $0.lowercased() })
        if previous.contains(normalized) {
            return recommended
        }
        return stored
    }

    /// 全局功能热键推荐（双修饰 + 字母，按功能族分前缀）。
    /// - `ctrl+option`：截图 / 贴图
    /// - `option+command`：OCR / 翻译 / 剪切板
    enum RecommendedHotkey {
        static let captureScreenshot = "ctrl+option+s"
        static let pasteToScreen = "ctrl+option+p"
        static let togglePins = "ctrl+option+h"
        static let clickThrough = "ctrl+option+x"
        static let captureOCR = "option+command+o"
        /// 原图 OCR：默认可配置；推荐 ⌥⌘U（避免与 OCR / 翻译键冲突）
        static let captureImageOCR = "option+command+u"
        static let captureTranslate = "option+command+t"
        static let captureImageTranslate = "option+command+i"
        static let selectionTranslate = "option+command+y"
        static let clipboard = "option+command+v"
    }
}
