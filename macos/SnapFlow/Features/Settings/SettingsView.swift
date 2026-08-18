import AppKit
import ServiceManagement
import SwiftUI

// MARK: - 导航

/// 偏好设置侧栏页（结果窗「设置」按钮可 deep link）
/// 侧栏顺序：功能 → 服务 → 数据 → 系统（`allCases` 顺序即展示顺序）。
enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case capture
    case ocrBasic
    case translateBasic
    case clipboard
    case recording
    case ocrService
    case translateService
    case history
    case favorites
    case general
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .capture: L10n.string("截图")
        case .ocrBasic: L10n.string("OCR 设置")
        case .translateBasic: L10n.string("翻译设置")
        case .clipboard: L10n.string("剪切板")
        case .recording: L10n.string("录制")
        case .ocrService: L10n.string("OCR 服务")
        case .translateService: L10n.string("翻译服务")
        case .history: L10n.string("历史")
        case .favorites: L10n.string("收藏")
        case .general: L10n.string("通用设置")
        case .about: L10n.string("关于")
        }
    }

    /// 设置内搜索：标题 + 同义词 / 能力关键词（含服务商名）。
    var searchKeywords: [String] {
        switch self {
        case .capture:
            [L10n.string("截图"), L10n.string("区域截图"), L10n.string("贴图"), L10n.string("钉图"), L10n.string("图像质量"), "PNG", "JPEG", L10n.string("快捷键"), L10n.string("穿透"), L10n.string("标注")]
        case .ocrBasic:
            ["OCR", L10n.string("文字识别"), L10n.string("识字"), L10n.string("识别"), L10n.string("快捷键"), L10n.string("语言")]
        case .translateBasic:
            [L10n.string("翻译"), L10n.string("划词"), L10n.string("目标语言"), L10n.string("源语言"), L10n.string("快捷键"), L10n.string("弹出位置")]
        case .clipboard:
            [L10n.string("剪切板"), L10n.string("剪贴板"), L10n.string("固定"), L10n.string("快捷键"), L10n.string("粘贴"), L10n.string("记录类型")]
        case .recording:
            [
                L10n.string("录制"), L10n.string("屏幕录制"), L10n.string("麦克风"), L10n.string("系统声音"), "MP4", "GIF",
                L10n.string("文件名"), L10n.string("保存"), L10n.string("指针"), "Movies",
            ]
        case .ocrService:
            [
                "OCR", L10n.string("服务"), "Vision", L10n.string("百度"), L10n.string("腾讯"), L10n.string("火山"), L10n.string("有道"), "Google",
                "API", L10n.string("密钥"), L10n.string("云服务"), L10n.string("文字识别服务"),
            ]
        case .translateService:
            [
                L10n.string("翻译服务"), "DeepL", L10n.string("百度"), L10n.string("有道"), "Google", L10n.string("火山"), L10n.string("腾讯"),
                "OpenAI", "API", L10n.string("密钥"), L10n.string("系统翻译"), L10n.string("服务"),
            ]
        case .history:
            [
                L10n.string("历史"), L10n.string("历史记录"), L10n.string("剪切板历史"), L10n.string("剪贴板历史"), L10n.string("截图历史"),
                L10n.string("OCR 历史"), L10n.string("识别历史"), L10n.string("翻译历史"), L10n.string("截图记录"),
                L10n.string("录制历史"), L10n.string("视频历史"), L10n.string("GIF 历史"), L10n.string("收藏录制"),
            ]
        case .favorites:
            [L10n.string("收藏"), L10n.string("星标"), L10n.string("自定义收藏")]
        case .general:
            [
                L10n.string("通用"), L10n.string("权限"), L10n.string("屏幕录制"), L10n.string("辅助功能"), L10n.string("麦克风"), L10n.string("登录启动"), L10n.string("历史保留"),
                L10n.string("快捷键"), L10n.string("恢复热键"), L10n.string("强调色"), L10n.string("外观"), L10n.string("系统强调色"), L10n.string("主题"),
            ]
        case .about:
            [
                L10n.string("关于"), L10n.string("版本"), "SnapFlow", L10n.string("功能"), L10n.string("截图"), L10n.string("贴图"), "OCR", L10n.string("翻译"),
                L10n.string("划词"), L10n.string("录制"), L10n.string("剪切板"), L10n.string("历史"), L10n.string("收藏"), L10n.string("大模型"), L10n.string("流式"),
            ]
        }
    }

    func matchesSearch(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        if title.localizedCaseInsensitiveContains(q) { return true }
        if let header = sectionHeader, header.localizedCaseInsensitiveContains(q) { return true }
        return searchKeywords.contains { $0.localizedCaseInsensitiveContains(q) }
    }

    var symbol: String {
        switch self {
        case .capture: "camera.viewfinder"
        case .ocrBasic: "text.viewfinder"
        case .translateBasic: "globe"
        case .clipboard: "clipboard"
        case .recording: "record.circle"
        case .ocrService: "shippingbox"
        case .translateService: "shippingbox"
        case .history: "clock.arrow.circlepath"
        case .favorites: "star.fill"
        case .general: "gearshape"
        case .about: "info.circle"
        }
    }

    /// 侧栏分组：功能 / 服务 / 数据 / 系统。
    var sectionHeader: String? {
        switch self {
        case .capture: L10n.string("功能")
        case .ocrService: L10n.string("服务")
        case .history: L10n.string("数据")
        case .general: L10n.string("系统")
        default: nil
        }
    }

    /// 是否在侧栏显示 sectionHeader（组内第一项）
    var showsSectionHeader: Bool {
        switch self {
        case .capture, .ocrService, .history, .general: true
        default: false
        }
    }
}

/// 统一历史页的内容 Tab；首项同时作为历史页的默认内容。
enum SettingsHistoryTab: String, CaseIterable, Identifiable, Hashable {
    case clipboard
    case capture
    case recording
    case ocr
    case translate

    static let initial: Self = .clipboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clipboard: L10n.string("剪切板历史")
        case .capture: L10n.string("截图历史")
        case .recording: L10n.string("录制历史")
        case .ocr: L10n.string("OCR 历史")
        case .translate: L10n.string("翻译历史")
        }
    }

    var symbol: String {
        switch self {
        case .clipboard: "clipboard"
        case .capture: "camera.viewfinder"
        case .recording: "record.circle"
        case .ocr: "text.viewfinder"
        case .translate: "globe"
        }
    }
}

// MARK: - Root

struct SettingsView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.snapFlowAccent) private var accent
    @State private var selection: SettingsPane
    @State private var historyTab: SettingsHistoryTab = .initial
    /// 历史页内容延后一帧挂载，避免与窗体切换抢主线程。
    @State private var historyContentReady = false
    @State private var confirmClearAllFeatureHistory = false
    /// 侧栏行 hover（未选中时显示 surfaceHover）
    @State private var sidebarHoverPane: SettingsPane?
    /// 侧栏搜索（匹配标题 / 关键词，点选即跳转 pane）
    @State private var sidebarSearch = ""
    /// 从剪切板浮层 deep link：进入收藏并自动打开「添加自定义」
    private let openAddCustomFavorite: Bool

    init(
        initialPane: SettingsPane = .capture,
        initialHistoryTab: SettingsHistoryTab = .initial,
        openAddCustomFavorite: Bool = false
    ) {
        _selection = State(initialValue: initialPane)
        _historyTab = State(initialValue: initialHistoryTab)
        self.openAddCustomFavorite = openAddCustomFavorite
    }

    private var isSidebarFiltering: Bool {
        !sidebarSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredSidebarPanes: [SettingsPane] {
        SettingsPane.allCases.filter { $0.matchesSearch(sidebarSearch) }
    }

    var body: some View {
        @Bindable var settings = container.settings
        // 订阅强调色 / 界面语言，确保侧栏与页面文案即时刷新
        let _ = settings.useSystemAccentColor
        let _ = settings.appLanguagePreference

        HStack(spacing: 0) {
            sidebar
                .frame(width: 200)
                .background(AppTheme.surfaceMuted)

            Rectangle()
                .fill(AppTheme.separator)
                .frame(width: 1)

            detail(settings: settings)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppTheme.windowBackground)
        }
        .frame(minWidth: 720, minHeight: 480)
        .foregroundStyle(AppTheme.textPrimary)
        .snapFlowAppearance(settings: container.settings)
        .confirmationDialog(
            L10n.string("清除全部功能历史？"),
            isPresented: $confirmClearAllFeatureHistory
        ) {
            Button(L10n.string("清除全部"), role: .destructive) {
                FeatureHistoryMaintenance.clearAllFeatureHistory(settings: container.settings)
            }
            Button(L10n.string("取消"), role: .cancel) {}
        } message: {
            Text(L10n.string("将删除截图、OCR 与翻译历史的本地文件，不可撤销。剪切板历史不受影响。"))
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarSearchField
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if isSidebarFiltering {
                        if filteredSidebarPanes.isEmpty {
                            Text(L10n.string("无匹配设置项"))
                                .font(SettingsTypography.compact)
                                .dynamicTypeSize(SettingsTypography.contentTypeRange)
                                .foregroundStyle(AppTheme.textTertiary)
                                .padding(.horizontal, 14)
                                .padding(.top, 12)
                        } else {
                            ForEach(filteredSidebarPanes) { pane in
                                sidebarRow(pane)
                            }
                        }
                    } else {
                        ForEach(SettingsPane.allCases) { pane in
                            if pane.showsSectionHeader, let header = pane.sectionHeader {
                                Text(header)
                                    .font(SettingsTypography.sectionHeader)
                                    .dynamicTypeSize(SettingsTypography.contentTypeRange)
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .padding(.horizontal, 14)
                                    .padding(.top, pane == .capture ? 4 : 12)
                                    .padding(.bottom, 3)
                            }
                            sidebarRow(pane)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
        }
    }

    private var sidebarSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(SettingsTypography.compact.weight(.medium))
                .dynamicTypeSize(SettingsTypography.contentTypeRange)
                .foregroundStyle(AppTheme.textTertiary)
            TextField(L10n.string("搜索设置…"), text: $sidebarSearch)
                .textFieldStyle(.plain)
                .font(SettingsTypography.compact)
                .dynamicTypeSize(SettingsTypography.contentTypeRange)
            if isSidebarFiltering {
                Button {
                    sidebarSearch = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(SettingsTypography.compact)
                        .dynamicTypeSize(SettingsTypography.contentTypeRange)
                        .foregroundStyle(AppTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
                .accessibilityLabel(L10n.string("清除搜索"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(AppTheme.border.opacity(0.85), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.string("搜索设置"))
    }

    private func sidebarRow(_ pane: SettingsPane) -> some View {
        let isSelected = selection == pane
        return Button {
            selectPane(pane)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: pane.symbol)
                    .settingsRowTitleText()
                    .frame(width: 18)
                Text(pane.title)
                    .font(isSelected ? SettingsTypography.rowTitle.weight(.semibold) : SettingsTypography.rowTitle)
                    .dynamicTypeSize(SettingsTypography.contentTypeRange)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? AppTheme.onAccent : AppTheme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isSelected
                            ? accent
                            : (sidebarHoverPane == pane ? AppTheme.surfaceHover : Color.clear)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            sidebarHoverPane = hovering ? pane : (sidebarHoverPane == pane ? nil : sidebarHoverPane)
            updateHandCursor(hovering)
        }
        .accessibilityLabel(pane.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .animation(.easeOut(duration: 0.12), value: sidebarHoverPane)
    }

    private func selectPane(_ pane: SettingsPane) {
        selection = pane
        if pane == .history {
            historyTab = .initial
        }
        // 点选结果后收起过滤，方便继续浏览同组其它项
        if isSidebarFiltering {
            sidebarSearch = ""
        }
    }

    // MARK: Detail

    @ViewBuilder
    private func detail(settings: SettingsStore) -> some View {
        // OCR / 翻译服务页自带纵向滚动，避免双重 ScrollView
        if selection == .ocrService {
            VStack(alignment: .leading, spacing: 12) {
                Text(detailTitle)
                    .settingsPageTitleText()
                OCRServiceSettingsView(
                    settings: settings,
                    ocrRouter: container.ocr
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if selection == .translateService {
            VStack(alignment: .leading, spacing: 12) {
                Text(detailTitle)
                    .settingsPageTitleText()
                TranslationServiceSettingsView(
                    settings: settings,
                    translation: container.translation
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if selection == .history {
            historyPage
        } else if selection == .favorites {
            favoritesPage
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(detailTitle)
                        .settingsPageTitleText()
                        .padding(.bottom, 4)

                    switch selection {
                    case .capture:
                        capturePage(settings: settings)
                    case .history, .favorites:
                        EmptyView()
                    case .ocrBasic:
                        ocrBasicPage(settings: settings)
                    case .ocrService, .translateService:
                        EmptyView()
                    case .translateBasic:
                        translateBasicPage(settings: settings)
                    case .clipboard:
                        clipboardPage(settings: settings)
                    case .recording:
                        RecordingSettingsView(settings: settings)
                    case .general:
                        generalPage(settings: settings)
                    case .about:
                        aboutPage
                    }
                }
                .padding(24)
                .frame(maxWidth: 720, alignment: .leading)
            }
        }
    }

    /// 统一历史页：默认打开剪切板历史，其余历史通过页面内分段控件切换（不进窗口顶栏）。
    private var historyPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(detailTitle)
                .settingsPageTitleText()

            Picker(L10n.string("历史类型"), selection: $historyTab) {
                ForEach(SettingsHistoryTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 640, alignment: .leading)
            .accessibilityLabel(L10n.string("历史类型"))

            Group {
                if historyContentReady {
                    switch historyTab {
                    case .clipboard:
                        embeddedClipboardHistoryContent(scope: .clipboard)
                    case .capture:
                        SnipHistorySettingsView()
                    case .recording:
                        RecordingHistoryView()
                    case .ocr:
                        OCRHistorySettingsView()
                    case .translate:
                        TranslationHistorySettingsView()
                    }
                } else {
                    // 首帧轻量占位，下一 runloop 再挂载重列表
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            guard !historyContentReady else { return }
            DispatchQueue.main.async {
                historyContentReady = true
            }
        }
    }

    /// 收藏列表：与剪切板同卡片格式。
    private var favoritesPage: some View {
        embeddedClipboardHistoryPage(title: detailTitle, scope: .favorites)
    }

    private func embeddedClipboardHistoryPage(
        title: String,
        scope: HistoryListScope
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .settingsPageTitleText()
            embeddedClipboardHistoryContent(scope: scope)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func embeddedClipboardHistoryContent(scope: HistoryListScope) -> some View {
        ClipboardHistoryView(
            container: container,
            onPaste: { item, plainText in
                // 设置页内：只写入系统剪切板，不自动粘贴到前台 App
                container.panelPresenter.copyClipboardItemToPasteboard(
                    item,
                    plainText: plainText
                )
            },
            onClose: {},
            onPreviewChanged: { _ in },
            onTranslate: { item in
                container.panelPresenter.translateClipboardHistoryItem(item)
            },
            presentation: .embedded,
            listScope: scope,
            autoPresentAddFavorite: openAddCustomFavorite && scope == .favorites
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var detailTitle: String {
        switch selection {
        case .capture: L10n.string("截图")
        case .ocrBasic: L10n.string("OCR 设置")
        case .ocrService: L10n.string("OCR 服务")
        case .translateBasic: L10n.string("翻译设置")
        case .translateService: L10n.string("翻译服务")
        case .clipboard: L10n.string("剪切板")
        case .recording: L10n.string("录制")
        case .history: L10n.string("历史")
        case .favorites: L10n.string("收藏")
        case .general: L10n.string("通用设置")
        case .about: L10n.string("关于")
        }
    }

    // MARK: Pages

    @ViewBuilder
    private func capturePage(settings: SettingsStore) -> some View {
        settingsCard(
            title: L10n.string("输出"),
            tip: L10n.string("范围：0 到 100 或 -1。\n设为 0 可最大压缩图像，100 为完全不压缩（PNG）。\n设为 -1 时自动使用 PNG 无损保存。")
        ) {
            HStack(alignment: .center, spacing: 12) {
                settingsRowLeadingIcon("photo")
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("图像质量"))
                        .settingsRowTitleText()
                    Text(snipImageQualitySubtitle(settings.snipImageQuality))
                        .settingsBodyText()
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                TextField(
                    "",
                    value: Binding(
                        get: { settings.snipImageQuality },
                        set: { settings.snipImageQuality = SnipImageExport.normalizedQuality($0) }
                    ),
                    format: .number
                )
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
                Stepper(
                    "",
                    value: Binding(
                        get: { settings.snipImageQuality },
                        set: { settings.snipImageQuality = SnipImageExport.normalizedQuality($0) }
                    ),
                    in: -1...100,
                    step: 1
                )
                .labelsHidden()
            }
            .padding(.vertical, 8)
        }

        settingsCard(title: L10n.string("截图历史")) {
            toggleRow(
                title: L10n.string("保存截图记录"),
                subtitle: L10n.string("关闭后不再新增；已有记录仍可在「历史 → 截图历史」浏览。框选内上一条/下一条共用此列表。"),
                isOn: Binding(
                    get: { settings.snipHistoryEnabled },
                    set: { settings.snipHistoryEnabled = $0 }
                ),
                systemImage: "clock.arrow.circlepath",
                showDivider: false
            )
        }

        settingsCard(title: L10n.string("全局快捷键")) {
            hotkeyRow(
                title: L10n.string("区域截图"),
                subtitle: L10n.string("框选屏幕区域进行截图。"),
                systemImage: "camera.viewfinder",
                chord: Binding(
                    get: { settings.hotkeyCaptureScreenshot },
                    set: {
                        settings.hotkeyCaptureScreenshot = $0
                        rebindGlobalHotkeys()
                    }
                )
            )
            hotkeyRow(
                title: L10n.string("贴到屏幕"),
                subtitle: L10n.string("将剪贴板内容贴为浮动图窗。"),
                systemImage: "pin",
                chord: Binding(
                    get: { settings.hotkeyPasteToScreen },
                    set: {
                        settings.hotkeyPasteToScreen = $0
                        rebindGlobalHotkeys()
                    }
                )
            )
            hotkeyRow(
                title: L10n.string("隐藏/显示全部贴图"),
                subtitle: L10n.string("不关闭贴图，仅切换可见性。"),
                systemImage: "eye.slash",
                chord: Binding(
                    get: { settings.hotkeyTogglePins },
                    set: {
                        settings.hotkeyTogglePins = $0
                        rebindGlobalHotkeys()
                    }
                )
            )
            hotkeyRow(
                title: L10n.string("贴图鼠标穿透"),
                subtitle: L10n.string("切换光标下贴图是否点击穿透。"),
                systemImage: "cursorarrow.rays",
                chord: Binding(
                    get: { settings.hotkeyClickThrough },
                    set: {
                        settings.hotkeyClickThrough = $0
                        rebindGlobalHotkeys()
                    }
                ),
                showDivider: false
            )
            restoreGroupDefaultsButton {
                settings.restoreGlobalHotkeys(group: .capture)
                rebindGlobalHotkeys()
            }
        }

        localShortcutCard(title: L10n.string("截屏内快捷键"), scope: .capture, settings: settings)
        localShortcutCard(title: L10n.string("贴图快捷键"), scope: .pinnedImage, settings: settings)

        Text(L10n.string("菜单栏图标：左键/右键均打开功能菜单；截图等能力通过菜单项或全局快捷键触发。"))
            .font(.caption)
            .foregroundStyle(AppTheme.textSecondary)
    }

    private func snipImageQualitySubtitle(_ quality: Int) -> String {
        let q = SnipImageExport.normalizedQuality(quality)
        if q < 0 {
            return L10n.string("自动：保存为 PNG 无损。复制到剪切板不受此设置影响。")
        }
        if q >= 100 {
            return L10n.string("不压缩：保存为 PNG 无损。")
        }
        return String(format: L10n.string("JPEG 质量 %lld%%（数值越低文件越小）。"), q)
    }

    @ViewBuilder
    private func ocrBasicPage(settings: SettingsStore) -> some View {
        settingsCard(title: L10n.string("OCR 历史")) {
            toggleRow(
                title: L10n.string("保存 OCR 识别记录"),
                subtitle: L10n.string("关闭后不再新增；已有记录仍可在「历史 → OCR 历史」打开查看。"),
                isOn: Binding(
                    get: { settings.ocrHistoryEnabled },
                    set: { settings.ocrHistoryEnabled = $0 }
                ),
                systemImage: "clock.arrow.circlepath",
                showDivider: false
            )
        }

        settingsCard(title: L10n.string("全局快捷键")) {
            hotkeyRow(
                title: L10n.string("区域 OCR"),
                subtitle: L10n.string("框选后直接识别文字并打开结果窗，不出现标注工具栏。"),
                systemImage: "text.viewfinder",
                chord: Binding(
                    get: { settings.hotkeyCaptureOCR },
                    set: {
                        settings.hotkeyCaptureOCR = $0
                        rebindGlobalHotkeys()
                    }
                )
            )
            hotkeyRow(
                title: L10n.string("原图 OCR"),
                subtitle: L10n.string("框选后在截图区域叠加识别原文，可一键翻译（对齐原图翻译叠层）。"),
                systemImage: "doc.text.viewfinder",
                chord: Binding(
                    get: { settings.hotkeyCaptureImageOCR },
                    set: {
                        settings.hotkeyCaptureImageOCR = $0
                        rebindGlobalHotkeys()
                    }
                ),
                showDivider: false
            )
            restoreGroupDefaultsButton {
                settings.restoreGlobalHotkeys(group: .ocr)
                rebindGlobalHotkeys()
            }
        }

        localShortcutCard(title: L10n.string("OCR 结果窗快捷键"), scope: .ocrResult, settings: settings)
    }

    @ViewBuilder
    private func translateBasicPage(settings: SettingsStore) -> some View {
        settingsCard(title: L10n.string("翻译历史")) {
            toggleRow(
                title: L10n.string("保存翻译记录"),
                subtitle: L10n.string("记录划词翻译与截图翻译；原图翻译不记录。关闭后不再新增；已有记录可在「历史 → 翻译历史」浏览。"),
                isOn: Binding(
                    get: { settings.translationHistoryEnabled },
                    set: { settings.translationHistoryEnabled = $0 }
                ),
                systemImage: "clock.arrow.circlepath",
                showDivider: false
            )
        }

        settingsCard(title: L10n.string("全局快捷键")) {
            hotkeyRow(
                title: L10n.string("截图翻译"),
                subtitle: L10n.string("框选区域后打开左图右译结果窗，多服务并发翻译。"),
                systemImage: "globe",
                chord: Binding(
                    get: { settings.hotkeyCaptureTranslate },
                    set: {
                        settings.hotkeyCaptureTranslate = $0
                        rebindGlobalHotkeys()
                    }
                )
            )
            hotkeyRow(
                title: L10n.string("原图翻译"),
                subtitle: L10n.string("框选区域后在截图上叠加译文（可选）。"),
                systemImage: "text.below.photo",
                chord: Binding(
                    get: { settings.hotkeyCaptureImageTranslate },
                    set: {
                        settings.hotkeyCaptureImageTranslate = $0
                        rebindGlobalHotkeys()
                    }
                )
            )
            hotkeyRow(
                title: L10n.string("划词翻译"),
                subtitle: L10n.string("读取当前选中文本并弹出译文。"),
                systemImage: "character.cursor.ibeam",
                chord: Binding(
                    get: { settings.hotkeySelectionTranslate },
                    set: {
                        settings.hotkeySelectionTranslate = $0
                        rebindGlobalHotkeys()
                    }
                ),
                showDivider: false
            )
            restoreGroupDefaultsButton {
                settings.restoreGlobalHotkeys(group: .translate)
                rebindGlobalHotkeys()
            }
        }

        popupPositionCard(
            title: L10n.string("划词窗口位置"),
            subtitle: L10n.string("默认显示在当前光标下方；也可改为菜单栏、前台窗口或屏幕中央等。"),
            position: Binding(
                get: { settings.translatePopupPosition },
                set: { settings.translatePopupPosition = $0 }
            ),
            screen: Binding(
                get: { settings.translatePopupScreen },
                set: { settings.translatePopupScreen = $0 }
            ),
            lastPosition: Binding(
                get: { settings.translateWindowPosition },
                set: { settings.translateWindowPosition = $0 }
            )
        )

        settingsCard(title: L10n.string("语言")) {
            pickerRow(
                title: L10n.string("源语言"),
                subtitle: L10n.string("「自动检测」使用本机 NLLanguageRecognizer；也可强制指定。"),
                // 不用 textformat.abc：中文系统会显示「甲乙丙」样例字，观感差
                systemImage: "text.magnifyingglass",
                selection: Binding(
                    get: { settings.sourceLanguage },
                    set: { settings.sourceLanguage = $0 }
                )
            ) {
                Text(L10n.string("自动检测")).tag(TranslationLanguage.autoSourceToken)
                Text(L10n.string("英语")).tag("en")
                Text(L10n.string("简体中文")).tag("zh-Hans")
                Text(L10n.string("繁体中文")).tag("zh-Hant")
                Text(L10n.string("日语")).tag("ja")
            }
            targetLanguageRow(settings: settings)
        }
    }

    /// 目标语言：收起只显示「跟随系统」等短名，展开菜单才显示「当前：简体中文」。
    private func targetLanguageRow(settings: SettingsStore) -> some View {
        let selection = Binding(
            get: { settings.targetLanguage },
            set: { settings.targetLanguage = $0 }
        )
        let systemName = TranslationLanguage.systemPreferredDisplayName()
        let options: [(id: String, title: String)] = [
            (TranslationLanguage.systemTargetToken, String(format: L10n.string("跟随系统（当前：%@）"), systemName)),
            ("zh-Hans", L10n.string("简体中文")),
            ("en", L10n.string("英语")),
            ("ja", L10n.string("日语")),
            ("zh-Hant", L10n.string("繁体中文")),
        ]

        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                settingsRowLeadingIcon("globe")
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("目标语言"))
                        .settingsRowTitleText()
                    Text(L10n.string("默认跟随系统语言；也可手动覆盖。"))
                        .settingsBodyText()
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Menu {
                    ForEach(options, id: \.id) { option in
                        Button {
                            selection.wrappedValue = option.id
                        } label: {
                            HStack {
                                Text(option.title)
                                Spacer(minLength: 12)
                                if selection.wrappedValue == option.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    // 收起态用短文案，避免「跟随系统（当前：简…）」挤爆固定宽度
                    Text(TranslationLanguage.displayName(for: selection.wrappedValue))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.regular)
                .frame(width: Self.formControlWidth, alignment: .trailing)
            }
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func clipboardPage(settings: SettingsStore) -> some View {
        popupPositionCard(
            title: L10n.string("窗口位置"),
            subtitle: L10n.string("默认显示在当前光标下方；也可改为菜单栏、前台窗口或屏幕中央等。"),
            position: Binding(
                get: { settings.clipboardPopupPosition },
                set: { settings.clipboardPopupPosition = $0 }
            ),
            screen: Binding(
                get: { settings.clipboardPopupScreen },
                set: { settings.clipboardPopupScreen = $0 }
            ),
            lastPosition: Binding(
                get: { settings.clipboardWindowPosition },
                set: { settings.clipboardWindowPosition = $0 }
            )
        )

        // 记录开关独立成组，避免与内容类型混在一起显得冗长
        settingsCard(title: L10n.string("记录")) {
            toggleRow(
                title: L10n.string("暂停记录"),
                subtitle: L10n.string("暂停后不再新增历史，已有内容仍可使用。"),
                isOn: Binding(
                    get: { settings.clipboardPaused },
                    set: { settings.clipboardPaused = $0 }
                ),
                systemImage: settings.clipboardPaused ? "pause.circle.fill" : "record.circle",
                showDivider: false
            )
        }

        settingsCard(title: L10n.string("内容类型")) {
            toggleRow(
                title: L10n.string("记录文本"),
                subtitle: L10n.string("纯文本、RTF 与 HTML。"),
                isOn: Binding(
                    get: { settings.clipboardRecordsText },
                    set: { settings.clipboardRecordsText = $0 }
                ),
                systemImage: "doc.plaintext.fill",
            )
            toggleRow(
                title: L10n.string("记录图片"),
                subtitle: L10n.string("PNG、TIFF、JPEG 与 HEIC。"),
                isOn: Binding(
                    get: { settings.clipboardRecordsImages },
                    set: { settings.clipboardRecordsImages = $0 }
                ),
                systemImage: "photo.fill",
            )
            toggleRow(
                title: L10n.string("记录文件"),
                subtitle: L10n.string("仅保存文件 URL，不复制文件本体。"),
                isOn: Binding(
                    get: { settings.clipboardRecordsFiles },
                    set: { settings.clipboardRecordsFiles = $0 }
                ),
                systemImage: "doc.fill",
                showDivider: false
            )
        }

        settingsCard(title: L10n.string("存储")) {
            stepperRow(
                title: L10n.string("历史上限"),
                subtitle: L10n.string("仅限制未固定内容，固定内容不计入上限。"),
                systemImage: "tray.full",
                value: Binding(
                    get: { settings.historyLimit },
                    set: {
                        settings.historyLimit = $0
                        container.historyStore.trimToCurrentLimit()
                    }
                ),
                range: 20...1000,
                step: 20,
                showDivider: false
            )
        }

        settingsCard(title: L10n.string("全局快捷键")) {
            hotkeyRow(
                title: L10n.string("剪切板历史"),
                subtitle: L10n.string("打开剪切板历史面板。"),
                systemImage: "clipboard",
                chord: Binding(
                    get: { settings.hotkeyClipboard },
                    set: {
                        settings.hotkeyClipboard = $0
                        rebindGlobalHotkeys()
                    }
                ),
                showDivider: false
            )
            restoreGroupDefaultsButton {
                settings.restoreGlobalHotkeys(group: .clipboard)
                rebindGlobalHotkeys()
            }
        }

        localShortcutCard(title: L10n.string("剪切板快捷键"), scope: .clipboard, settings: settings)

        if !container.historyStore.pinnedItems.isEmpty {
            settingsCard(title: L10n.string("固定内容快捷键")) {
                ForEach(Array(container.historyStore.pinnedItems.enumerated()), id: \.element.id) { index, item in
                    hotkeyRow(
                        title: item.title,
                        subtitle: L10n.string("固定内容排序变化后仍保持此快捷键。"),
                        systemImage: "pin.fill",
                        chord: Binding(
                            get: { item.pinShortcut ?? "" },
                            set: { container.historyStore.setPinShortcut($0, id: item.id) }
                        ),
                        showDivider: index < container.historyStore.pinnedItems.count - 1
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func generalPage(settings: SettingsStore) -> some View {
        settingsCard(
            title: L10n.string("界面语言"),
            tip: L10n.string("切换后立即生效。界面文案按所选语言显示。")
        ) {
            HStack(alignment: .center, spacing: 12) {
                settingsRowLeadingIcon("globe")
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("语言"))
                        .settingsRowTitleText()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Picker(
                    "",
                    selection: Binding(
                        get: { settings.appLanguagePreference },
                        set: { settings.appLanguagePreference = $0 }
                    )
                ) {
                    ForEach(AppLanguagePreference.allCases) { preference in
                        Text(preference.displayName).tag(preference)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                .pointingHandOnHover()
            }
            .padding(.vertical, 4)
        }

        settingsCard(title: L10n.string("权限")) {
            permissionRow(
                title: L10n.string("屏幕录制"),
                subtitle: L10n.string("区域截图、OCR 与截图翻译必需。"),
                systemImage: "rectangle.dashed.badge.record",
                granted: container.permissions.isScreenRecordingGranted(),
                permission: .screenRecording
            )
            permissionRow(
                title: L10n.string("辅助功能"),
                subtitle: L10n.string("划词翻译、模拟粘贴等可选能力。"),
                systemImage: "accessibility",
                granted: container.permissions.isAccessibilityGranted(),
                permission: .accessibility
            )
            permissionRow(
                title: L10n.string("麦克风"),
                subtitle: L10n.string("录制旁白可选；默认关闭，首次开启时才请求权限。拒绝后仍可录制视频与系统声音。"),
                systemImage: "mic",
                granted: container.permissions.isMicrophoneGranted(),
                permission: .microphone,
                showDivider: false
            )
        }

        settingsCard(
            title: L10n.string("外观"),
            tip: L10n.string("品牌色为 SnapFlow 默认靛蓝；开启后跟随「系统设置 → 外观 → 强调色」。")
        ) {
            toggleRow(
                title: L10n.string("跟随系统强调色"),
                subtitle: L10n.string("关闭时使用 SnapFlow 品牌色；开启后与系统强调色一致。"),
                isOn: Binding(
                    get: { settings.useSystemAccentColor },
                    set: { settings.useSystemAccentColor = $0 }
                ),
                systemImage: "paintpalette",
                showDivider: false
            )
        }

        settingsCard(title: L10n.string("启动")) {
            toggleRow(
                title: L10n.string("登录时启动"),
                subtitle: L10n.string("系统登录后自动启动 SnapFlow（需配合系统登录项权限）。"),
                isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { enabled in
                        do {
                            let status = try settings.setLaunchAtLogin(enabled)
                            if status == .requiresApproval {
                                FeedbackCenter.shared.post(
                                    L10n.string("settings.general.launch_at_login_approval"),
                                    level: .warning
                                )
                            }
                        } catch {
                            settings.refreshLaunchAtLogin()
                            FeedbackCenter.shared.post(
                                L10n.string("settings.general.launch_at_login_error"),
                                level: .error
                            )
                        }
                    }
                ),
                systemImage: "power.circle",
                showDivider: false
            )
            if settings.launchAtLoginStatus == .requiresApproval {
                HStack {
                    Spacer()
                    Button(L10n.string("打开系统设置")) {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointingHandOnHover()
                }
                .padding(.bottom, 8)
            }
        }

        settingsCard(title: L10n.string("功能历史")) {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    settingsRowLeadingIcon("calendar")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.string("保留时长"))
                            .settingsRowTitleText()
                        Text(L10n.string("截图 / OCR / 翻译历史共用；过期记录在启动与写入时清理。「永久」仍受条数上限约束。"))
                            .settingsBodyText()
                            .foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Picker(
                        "",
                        selection: Binding(
                            get: { settings.historyRetentionDays },
                            set: { settings.historyRetentionDays = $0 }
                        )
                    ) {
                        ForEach(HistoryRetentionOption.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: Self.formControlWidth, alignment: .trailing)
                }
                .padding(.vertical, 10)
                Divider()
                    .opacity(0.28)
            }

            stepperRow(
                title: L10n.string("截图历史上限"),
                subtitle: L10n.string("默认 100；设为 0 等同关闭写入。"),
                systemImage: "camera.viewfinder",
                value: Binding(
                    get: { settings.snipHistoryLimit },
                    set: { settings.snipHistoryLimit = $0 }
                ),
                range: 0...500,
                step: 10
            )
            stepperRow(
                title: L10n.string("OCR 历史上限"),
                subtitle: L10n.string("默认 100。"),
                systemImage: "text.viewfinder",
                value: Binding(
                    get: { settings.ocrHistoryLimit },
                    set: { settings.ocrHistoryLimit = $0 }
                ),
                range: 0...500,
                step: 10
            )
            stepperRow(
                title: L10n.string("翻译历史上限"),
                subtitle: L10n.string("默认 100。不含原图翻译叠层。"),
                systemImage: "globe",
                value: Binding(
                    get: { settings.translationHistoryLimit },
                    set: { settings.translationHistoryLimit = $0 }
                ),
                range: 0...500,
                step: 10,
                showDivider: false
            )
        }

        settingsCard(
            title: L10n.string("清除数据"),
            tip: L10n.string("仅清除截图 / OCR / 翻译历史，不影响剪切板历史、设置项与 API 密钥。")
        ) {
            HStack(spacing: 12) {
                destructiveHistoryButton(L10n.string("清除全部功能历史")) {
                    confirmClearAllFeatureHistory = true
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }

        settingsCard(
            title: L10n.string("快捷键维护"),
            tip: L10n.string("推荐方案：⌃⌥ 截图/贴图；⌥⌘ OCR/翻译/剪切板。恢复会覆盖当前全部全局功能热键。")
        ) {
            HStack(spacing: 12) {
                destructiveHistoryButton(L10n.string("恢复推荐功能热键")) {
                    settings.restoreSnipasteHotkeys()
                    rebindGlobalHotkeys()
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    private var aboutPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsCard(title: "SnapFlow") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(L10n.string("让截图、识字、翻译、录制和剪切板更顺手"))
                            .font(.body.weight(.semibold))
                            .dynamicTypeSize(SettingsTypography.contentTypeRange)
                            .foregroundStyle(AppTheme.textPrimary)
                        Spacer(minLength: 8)
                        Text(aboutVersionString)
                            .font(.caption.weight(.medium).monospacedDigit())
                            .dynamicTypeSize(SettingsTypography.contentTypeRange)
                            .foregroundStyle(AppTheme.textSecondary)
                    }

                    Text(
                        L10n.string("SnapFlow 是一款 macOS 菜单栏工具。截一段屏幕、认出图里的字、对照多服务译文、录下一段操作，或找回刚才复制的内容，都可用全局快捷键完成，不必在各个应用之间来回切换。")
                    )
                    .font(SettingsTypography.compact)
                    .dynamicTypeSize(SettingsTypography.contentTypeRange)
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            settingsCard(title: L10n.string("主要功能")) {
                VStack(alignment: .leading, spacing: 0) {
                    aboutFeatureRow(
                        symbol: "camera.viewfinder",
                        title: L10n.string("区域截图与贴图"),
                        detail: L10n.string("智能识窗或自由框选；支持标注、延迟截图、滚动长图、复制与保存。结果可钉在桌面对照，贴图可拖动、缩放、旋转与穿透。"),
                        showDivider: true
                    )
                    aboutFeatureRow(
                        symbol: "text.viewfinder",
                        title: L10n.string("OCR 文字识别"),
                        detail: L10n.string("框选后识别，左图右文可编辑与复制；支持结果窗 OCR 与原图叠层 OCR。默认本机 Vision，也可接入百度、腾讯、火山等云服务并设为默认。"),
                        showDivider: true
                    )
                    aboutFeatureRow(
                        symbol: "globe",
                        title: L10n.string("划词与截图翻译"),
                        detail: L10n.string("划词对照多服务译文；截图翻译打开图文对照窗，原图翻译在选区叠层显示。可配置系统翻译、传统 API，以及大模型 / 本地模型（含流式输出）。"),
                        showDivider: true
                    )
                    aboutFeatureRow(
                        symbol: "record.circle",
                        title: L10n.string("屏幕录制"),
                        detail: L10n.string("框选区域录制，可选系统声音与麦克风；结束后导出 MP4 或 GIF，并写入录制历史，便于回看与再导出。"),
                        showDivider: true
                    )
                    aboutFeatureRow(
                        symbol: "clipboard",
                        title: L10n.string("剪切板历史"),
                        detail: L10n.string("自动记录文本、图片与文件链接；支持搜索、固定、收藏与快捷键粘贴，常用内容一键回填。"),
                        showDivider: true
                    )
                    aboutFeatureRow(
                        symbol: "clock.arrow.circlepath",
                        title: L10n.string("历史与收藏"),
                        detail: L10n.string("剪切板、截图、录制、OCR、翻译历史统一管理，可搜索、分页与按时间筛选；重要内容可收藏，并在设置中调整保留天数与清理。"),
                        showDivider: false
                    )
                }
            }

            settingsCard(title: L10n.string("使用提示")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.string("• 首次使用请授权「屏幕录制」；划词与模拟粘贴需要「辅助功能」；带麦录制需「麦克风」。"))
                    Text(L10n.string("• 全局快捷键可在各功能设置页修改，也可一键恢复推荐方案；延时截图时屏幕中央会显示倒计时。"))
                    Text(L10n.string("• OCR / 翻译可在「服务」页添加密钥、设默认并验证连接；大模型可按需开启流式输出。"))
                    Text(L10n.string("• 重要结果状态会以系统通知提示（需允许通知）；菜单栏图标可打开功能菜单与偏好设置。"))
                }
                .font(SettingsTypography.compact)
                .dynamicTypeSize(SettingsTypography.contentTypeRange)
                .foregroundStyle(AppTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
    }

    private var aboutVersionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let short, let build, !build.isEmpty, build != short {
            return "v\(short) (\(build))"
        }
        if let short, !short.isEmpty {
            return "v\(short)"
        }
        return "v0.0.1"
    }

    private func aboutFeatureRow(
        symbol: String,
        title: String,
        detail: String,
        showDivider: Bool
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.body.weight(.medium))
                    .dynamicTypeSize(SettingsTypography.contentTypeRange)
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 22, height: 22)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .settingsRowTitleText()
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(detail)
                        .font(SettingsTypography.compact)
                .dynamicTypeSize(SettingsTypography.contentTypeRange)
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10)

            if showDivider {
                Divider()
                    .opacity(0.28)
                    .padding(.leading, 34)
            }
        }
    }

    private func servicePlaceholderPage(title: String, builtInName: String, note: String) -> some View {
        settingsCard(title: title) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(SettingsTypography.sectionHeader)
                            .dynamicTypeSize(SettingsTypography.contentTypeRange)
                    .frame(width: 14)
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(AppTheme.textPrimary.opacity(0.08))
                        .frame(width: 22, height: 22)
                    Image(systemName: "shippingbox")
                        .font(SettingsTypography.compact.weight(.medium))
                    .dynamicTypeSize(SettingsTypography.contentTypeRange)
                }
                Text(builtInName)
                    .font(SettingsTypography.rowTitle)
                    .dynamicTypeSize(SettingsTypography.contentTypeRange)
                Spacer()
                Text(L10n.string("内置"))
                    .settingsBodyText()
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(.vertical, 6)

            Divider().opacity(0.35)

            Text(note)
                .font(SettingsTypography.compact)
                .dynamicTypeSize(SettingsTypography.contentTypeRange)
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.vertical, 6)
        }
    }

    // MARK: Building blocks

    private func settingsCard<Content: View>(
        title: String,
        tip: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        // 独立 View 以便持有 tip 悬停态：标题行 / 整卡抬升，避免气泡被下方卡片盖住
        SettingsCardContainer(title: title, tip: tip, content: content())
    }

    /// 剪切板 / 划词翻译共用的「弹出位置」设置块。
    @ViewBuilder
    private func popupPositionCard(
        title: String,
        subtitle: String,
        position: Binding<ClipboardPopupPosition>,
        screen: Binding<Int>,
        lastPosition: Binding<NSPoint>
    ) -> some View {
        let defaultLast = NSPoint(x: 0.5, y: 0.8)
        settingsCard(title: title) {
            HStack(spacing: 12) {
                settingsRowLeadingIcon("macwindow")
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("弹出位置"))
                        .settingsRowTitleText()
                    Text(subtitle)
                        .settingsBodyText()
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Picker("", selection: position) {
                    ForEach(ClipboardPopupPosition.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .labelsHidden()
                .frame(width: 170)
            }
            .padding(.vertical, 8)

            if [.center, .lastPosition].contains(position.wrappedValue),
               NSScreen.screens.count > 1 {
                Divider()
                    .opacity(0.28)
                HStack(spacing: 12) {
                    settingsRowLeadingIcon("display")
                    Text(L10n.string("显示器"))
                        .settingsRowTitleText()
                    Spacer()
                    Picker("", selection: screen) {
                        Text(L10n.string("当前主屏幕")).tag(0)
                        ForEach(NSScreen.screens.indices, id: \.self) { index in
                            Text(NSScreen.screens[index].localizedName).tag(index + 1)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }
                .padding(.vertical, 8)
            }

            if position.wrappedValue == .lastPosition {
                Divider()
                    .opacity(0.28)
                HStack(spacing: 12) {
                    settingsRowLeadingIcon("arrow.counterclockwise")
                    Text(L10n.string("拖动窗口后会记住其位置。"))
                        .settingsBodyText()
                        .foregroundStyle(AppTheme.textSecondary)
                    Spacer()
                    Button(L10n.string("重置位置")) {
                        lastPosition.wrappedValue = defaultLast
                    }
                    .buttonStyle(.bordered)
                    .disabled(lastPosition.wrappedValue == defaultLast)
                }
                .padding(.vertical, 8)
            }
        }
    }

    /// 设置行前置图标：对齐录制设置（无底色，仅强调色 SF Symbol）。
    private func settingsRowLeadingIcon(
        _ systemImage: String,
        tint: Color? = nil
    ) -> some View {
        Image(systemName: systemImage)
            .foregroundStyle(tint ?? accent)
            .frame(width: 20)
            .accessibilityHidden(true)
    }

    private func hotkeyRow(
        title: String,
        subtitle: String,
        systemImage: String? = nil,
        chord: Binding<String>,
        showDivider: Bool = true
    ) -> some View {
        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                if let systemImage {
                    settingsRowLeadingIcon(systemImage)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .settingsRowTitleText()
                    Text(subtitle)
                        .settingsBodyText()
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HotkeyRecorderField(chord: chord)
            }
            .padding(.vertical, 8)

            if showDivider {
                Divider().opacity(0.28)
            }
        }
    }

    private func stepperRow(
        title: String,
        subtitle: String,
        systemImage: String? = nil,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int,
        showDivider: Bool = true
    ) -> some View {
        let clampedValue = Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }
        )
        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                if let systemImage {
                    settingsRowLeadingIcon(systemImage)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .settingsRowTitleText()
                    Text(subtitle)
                        .settingsBodyText()
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                TextField(
                    "",
                    value: clampedValue,
                    format: .number
                )
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                Stepper("", value: clampedValue, in: range, step: step)
                    .labelsHidden()
            }
            .padding(.vertical, 8)
            if showDivider {
                Divider().opacity(0.28)
            }
        }
    }

    private func toggleRow(
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        systemImage: String? = nil,
        showDivider: Bool = true
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                if let systemImage {
                    settingsRowLeadingIcon(systemImage)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .settingsRowTitleText()
                    Text(subtitle)
                        .settingsBodyText()
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                // 右侧固定开关区，避免长说明把开关挤到文案中间
                Toggle(title, isOn: isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.regular)
                    .frame(width: 48, alignment: .trailing)
                    .padding(.leading, 8)
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)

            if showDivider {
                Divider().opacity(0.28)
            }
        }
    }

    /// 表单右侧控件统一宽度（语言 Picker 等），保证纵向对齐。
    private static let formControlWidth: CGFloat = 168

    private func pickerRow<Content: View>(
        title: String,
        subtitle: String,
        systemImage: String? = nil,
        selection: Binding<String>,
        showDivider: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                if let systemImage {
                    settingsRowLeadingIcon(systemImage)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .settingsRowTitleText()
                    Text(subtitle)
                        .settingsBodyText()
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Picker("", selection: selection, content: content)
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.regular)
                    // 固定宽度，避免「自动检测 / 简体中文」因文案长短宽窄不一
                    .frame(width: Self.formControlWidth, alignment: .trailing)
            }
            .padding(.vertical, 10)

            if showDivider {
                Divider().opacity(0.28)
            }
        }
    }

    private func localShortcutCard(
        title: String,
        scope: LocalShortcutScope,
        settings: SettingsStore
    ) -> some View {
        settingsCard(title: title) {
            let actions = LocalShortcutAction.allCases.filter { $0.scope == scope }
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                hotkeyRow(
                    title: action.title,
                    subtitle: String(format: L10n.string("默认 %@"), HotKeyChord.displayString(from: action.defaultChord)),
                    systemImage: action.systemImage,
                    chord: Binding(
                        get: { settings.shortcut(for: action) },
                        set: { settings.setShortcut($0, for: action) }
                    ),
                    showDivider: index < actions.count - 1
                )
            }
            restoreGroupDefaultsButton {
                settings.restoreLocalShortcuts(scope: scope)
            }
        }
    }

    /// 分组底部「恢复本组默认」：危险操作样式（会覆盖本组当前配置）。
    private func restoreGroupDefaultsButton(action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.35)
                .padding(.top, 4)
            HStack {
                destructiveHistoryButton(L10n.string("恢复本组默认"), controlSize: .small, action: action)
                Spacer(minLength: 0)
            }
            .padding(.top, 10)
        }
    }

    private func permissionRow(
        title: String,
        subtitle: String,
        systemImage: String,
        granted: Bool,
        permission: AppPermission,
        showDivider: Bool = true
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                settingsRowLeadingIcon(
                    systemImage,
                    tint: granted ? AppTheme.success : AppTheme.warning
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .settingsRowTitleText()
                    Text(subtitle)
                        .settingsBodyText()
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if granted {
                    Text(L10n.string("已授权"))
                        .settingsBadgeText(weight: .semibold)
                        .foregroundStyle(AppTheme.success)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule(style: .continuous)
                                .fill(AppTheme.success.opacity(0.16))
                        )
                        .accessibilityLabel(String(format: L10n.string("%@，已授权"), title))
                } else {
                    HStack(spacing: 8) {
                        Text(L10n.string("未授权"))
                            .settingsBadgeText(weight: .semibold)
                            .foregroundStyle(AppTheme.warning)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(AppTheme.warning.opacity(0.16))
                            )
                        Button(L10n.string("打开设置")) {
                            container.permissions.openSystemSettings(for: permission)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .pointingHandOnHover()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(String(format: L10n.string("%@，未授权"), title))
                }
            }
            .padding(.vertical, 10)

            if showDivider {
                Divider()
                    .opacity(0.28)
            }
        }
    }

    private func rebindGlobalHotkeys() {
        container.hotKeyManager.registerDefaults()
    }
}

// MARK: - Settings card + section tip

/// 带可选 ⓘ 说明的设置分组容器：悬停时抬升整卡与标题行，保证气泡叠在卡片内容之上。
private struct SettingsCardContainer<Content: View>: View {
    let title: String
    let tip: String?
    let content: Content
    @State private var tipHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title)
                    .font(SettingsTypography.cardTitle)
                    .dynamicTypeSize(SettingsTypography.contentTypeRange)
                    .foregroundStyle(AppTheme.textSecondary)
                if let tip, !tip.isEmpty {
                    SettingsSectionTipIcon(tip: tip, isHovering: $tipHovering)
                }
                Spacer(minLength: 0)
            }
            // 标题行（含溢出气泡）高于本卡内容；不抬升整卡，避免盖住下一卡底部按钮
            .zIndex(tipHovering ? 2 : 1)

            VStack(spacing: 0) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(AppTheme.border, lineWidth: 1)
            )
            // 内容层保持可点；tip 气泡通过标题行 zIndex 浮出
            .zIndex(0)
        }
        // 仅 tip 悬停时抬升本卡，平时不抬升，防止兄弟卡片互相挡点击
        .zIndex(tipHovering ? 50 : 0)
    }
}

/// 分组标题旁提示。
/// SwiftUI `.help` 与空 `NSView.toolTip` 在 `NSHostingView` 设置窗中经常不弹出，
/// 因此用悬停自绘气泡（不依赖系统 tooltip 延迟与命中链）。
private struct SettingsSectionTipIcon: View {
    let tip: String
    @Binding var isHovering: Bool

    var body: some View {
        Image(systemName: "info.circle")
            .font(SettingsTypography.compact.weight(.medium))
                .dynamicTypeSize(SettingsTypography.contentTypeRange)
            .foregroundStyle(isHovering ? AppTheme.accent : AppTheme.textSecondary.opacity(0.75))
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovering = hovering
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active: updateHandCursor(true)
                case .ended: updateHandCursor(false)
                }
            }
            // 气泡画在图标右侧；层级由外层 SettingsCardContainer 保证
            .overlay(alignment: .topLeading) {
                if isHovering {
                    tipBubble
                        .offset(x: 22, y: -6)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
                }
            }
            .accessibilityLabel(L10n.string("说明"))
            .accessibilityValue(tip)
            .accessibilityHint(tip)
    }

    private var tipBubble: some View {
        Text(tip)
            .settingsBodyText()
            .foregroundStyle(AppTheme.textPrimary)
            .multilineTextAlignment(.leading)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: 268, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    // 略亮于卡片 surface，叠在上面时更易辨认
                    .fill(AppTheme.panelBackground)
                    .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(AppTheme.border, lineWidth: 1)
            )
            .allowsHitTesting(false)
    }
}
