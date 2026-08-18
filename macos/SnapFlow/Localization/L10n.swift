import Foundation

/// 类型安全的本地化入口。键名与 `Localizable.xcstrings` 对齐。
///
/// 用法：
/// ```swift
/// Text(L10n.Settings.paneCapture)           // SwiftUI
/// menuItem.title = L10n.Action.captureScreenshot // AppKit
/// ```
///
/// 扩展语言：在 `Localizable.xcstrings` 增加 localization；`AppLanguagePreference.supportedLanguageCodes` 同步追加。
///
/// - Important: 应用内切换语言时**不要**依赖 `String(localized:locale:)`——在开发语言为
///   `zh-Hans` 时它常忽略传入的 `locale`，始终回落到简体。这里按 `*.lproj` 显式取 Bundle。
enum L10n {
    /// 按当前界面语言偏好（或指定语言码）解析目录键。
    static func string(_ key: String, languageCode: String? = nil) -> String {
        let code = languageCode ?? AppLanguage.resolvedLanguageCode()
        return localizationBundle(for: code).localizedString(
            forKey: key,
            value: key,
            table: "Localizable"
        )
    }

    /// 与 `AppLanguagePreference.supportedLanguageCodes` 对应的 `*.lproj` Bundle。
    static func localizationBundle(for languageCode: String) -> Bundle {
        let resource: String
        switch languageCode {
        case "en", "en-US", "en-GB":
            resource = "en"
        case "zh-Hans", "zh-CN", "zh":
            resource = "zh-Hans"
        default:
            // 未知语言回退到已支持集合中的最近匹配
            if languageCode.lowercased().hasPrefix("en") {
                resource = "en"
            } else if languageCode.lowercased().hasPrefix("zh") {
                resource = "zh-Hans"
            } else {
                resource = AppLanguagePreference.bestSupportedLanguageCode(
                    from: Locale.preferredLanguages
                )
            }
        }
        if let path = Bundle.main.path(forResource: resource, ofType: "lproj"),
           let bundle = Bundle(path: path)
        {
            return bundle
        }
        // 最后回退主 Bundle（通常仍是开发语言）
        if let path = Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"),
           let bundle = Bundle(path: path)
        {
            return bundle
        }
        return .main
    }

    // MARK: - Language

    enum Language {
        static var system: String { L10n.string("language.system") }
        static var sectionTitle: String { L10n.string("language.section_title") }
        static var pickerLabel: String { L10n.string("language.picker_label") }
        static var sectionTip: String { L10n.string("language.section_tip") }
    }

    // MARK: - App / Windows

    enum App {
        static var settingsWindowTitle: String { L10n.string("app.settings_window_title") }
        static var onboardingWindowTitle: String { L10n.string("app.onboarding_window_title") }
        static var menuBarTooltip: String { L10n.string("app.menu_bar_tooltip") }
    }

    // MARK: - Menu actions

    enum Action {
        static var captureScreenshot: String { L10n.string("action.capture_screenshot") }
        static var captureScreenshotDelay3: String { L10n.string("action.capture_screenshot_delay3") }
        static var pasteToScreen: String { L10n.string("action.paste_to_screen") }
        static var togglePinnedVisibility: String { L10n.string("action.toggle_pinned_visibility") }
        static var togglePinClickThrough: String { L10n.string("action.toggle_pin_click_through") }
        static var captureOCR: String { L10n.string("action.capture_ocr") }
        static var captureImageOCR: String { L10n.string("action.capture_image_ocr") }
        static var captureTranslate: String { L10n.string("action.capture_translate") }
        static var captureImageTranslate: String { L10n.string("action.capture_image_translate") }
        static var selectionTranslate: String { L10n.string("action.selection_translate") }
        static var openClipboardHistory: String { L10n.string("action.open_clipboard_history") }
        static var openSettings: String { L10n.string("action.open_settings") }
        static var quit: String { L10n.string("action.quit") }
    }

    // MARK: - Settings shell

    enum Settings {
        static var paneCapture: String { L10n.string("settings.pane.capture") }
        static var paneOCRBasic: String { L10n.string("settings.pane.ocr_basic") }
        static var paneTranslateBasic: String { L10n.string("settings.pane.translate_basic") }
        static var paneClipboard: String { L10n.string("settings.pane.clipboard") }
        static var paneRecording: String { L10n.string("settings.pane.recording") }
        static var paneOCRService: String { L10n.string("settings.pane.ocr_service") }
        static var paneTranslateService: String { L10n.string("settings.pane.translate_service") }
        static var paneHistory: String { L10n.string("settings.pane.history") }
        static var paneFavorites: String { L10n.string("settings.pane.favorites") }
        static var paneGeneral: String { L10n.string("settings.pane.general") }
        static var paneAbout: String { L10n.string("settings.pane.about") }

        static var sectionFeatures: String { L10n.string("settings.section.features") }
        static var sectionServices: String { L10n.string("settings.section.services") }
        static var sectionData: String { L10n.string("settings.section.data") }
        static var sectionSystem: String { L10n.string("settings.section.system") }

        static var historyClipboard: String { L10n.string("settings.history.clipboard") }
        static var historyCapture: String { L10n.string("settings.history.capture") }
        static var historyRecording: String { L10n.string("settings.history.recording") }
        static var historyOCR: String { L10n.string("settings.history.ocr") }
        static var historyTranslate: String { L10n.string("settings.history.translate") }

        static var generalPermissions: String { L10n.string("settings.general.permissions") }
        static var generalScreenRecording: String { L10n.string("settings.general.screen_recording") }
        static var generalScreenRecordingHint: String { L10n.string("settings.general.screen_recording_hint") }
        static var generalAccessibility: String { L10n.string("settings.general.accessibility") }
        static var generalAccessibilityHint: String { L10n.string("settings.general.accessibility_hint") }
        static var generalMicrophone: String { L10n.string("settings.general.microphone") }
        static var generalMicrophoneHint: String { L10n.string("settings.general.microphone_hint") }
        static var generalAppearance: String { L10n.string("settings.general.appearance") }
        static var generalAppearanceTip: String { L10n.string("settings.general.appearance_tip") }
        static var generalFollowSystemAccent: String { L10n.string("settings.general.follow_system_accent") }
        static var generalFollowSystemAccentHint: String { L10n.string("settings.general.follow_system_accent_hint") }
        static var generalLaunch: String { L10n.string("settings.general.launch") }
        static var generalLaunchAtLogin: String { L10n.string("settings.general.launch_at_login") }
        static var generalLaunchAtLoginHint: String { L10n.string("settings.general.launch_at_login_hint") }
        static var generalFeatureHistory: String { L10n.string("settings.general.feature_history") }
        static var generalRetention: String { L10n.string("settings.general.retention") }
        static var generalRetentionHint: String { L10n.string("settings.general.retention_hint") }
    }

    // MARK: - Onboarding

    enum Onboarding {
        static var welcome: String { L10n.string("onboarding.welcome") }
        static var pageCaptureTitle: String { L10n.string("onboarding.page_capture_title") }
        static var pageCaptureBullet1: String { L10n.string("onboarding.page_capture_bullet1") }
        static var pageCaptureBullet2: String { L10n.string("onboarding.page_capture_bullet2") }
        static var pageCaptureBullet3: String { L10n.string("onboarding.page_capture_bullet3") }
        static func pageCaptureBullet4(shortcut: String) -> String {
            String(format: L10n.string("onboarding.page_capture_bullet4_format"), shortcut)
        }

        static var pageOCRTitle: String { L10n.string("onboarding.page_ocr_title") }
        static var pageOCRBullet1: String { L10n.string("onboarding.page_ocr_bullet1") }
        static var pageOCRBullet2: String { L10n.string("onboarding.page_ocr_bullet2") }
        static var pageOCRBullet3: String { L10n.string("onboarding.page_ocr_bullet3") }
        static var pageOCRBullet4: String { L10n.string("onboarding.page_ocr_bullet4") }

        static var permissionsTitle: String { L10n.string("onboarding.permissions_title") }
        static var permissionsSubtitle: String { L10n.string("onboarding.permissions_subtitle") }
        static var screenRecordingTitle: String { L10n.string("onboarding.screen_recording_title") }
        static var screenRecordingDetail: String { L10n.string("onboarding.screen_recording_detail") }
        static var accessibilityTitle: String { L10n.string("onboarding.accessibility_title") }
        static var accessibilityDetail: String { L10n.string("onboarding.accessibility_detail") }
        static var granted: String { L10n.string("onboarding.granted") }
        static var needsPermission: String { L10n.string("onboarding.needs_permission") }
        static var requestOrOpenSettings: String { L10n.string("onboarding.request_or_open_settings") }
        static var refreshHint: String { L10n.string("onboarding.refresh_hint") }
        static var back: String { L10n.string("onboarding.back") }
        static var continueButton: String { L10n.string("onboarding.continue") }
        static var getStarted: String { L10n.string("onboarding.get_started") }
        static func pageIndicator(page: Int, total: Int) -> String {
            String(format: L10n.string("onboarding.page_indicator_format"), page, total)
        }
    }
}
