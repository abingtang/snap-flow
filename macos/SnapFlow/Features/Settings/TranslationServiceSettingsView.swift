import AppKit
import SwiftUI

/// 翻译服务配置：紧凑列表 + 详情面板，复用 OCR 服务页的目录、即时保存与验证交互。
struct TranslationServiceSettingsView: View {
    @Bindable var settings: SettingsStore
    var translation: TranslationService

    @State private var selectedID: String? = TranslationServiceEntry.systemID
    @State private var showAddSheet = false
    @State private var pendingDeleteID: String?
    @State private var privacyPendingID: String?
    @State private var pairStatus: TranslationService.PairAvailability?
    @State private var isRefreshingStatus = false
    @State private var isVerifying = false
    @State private var verifyTargetID: String?
    @State private var verifyMessage: String?
    @State private var statusHint: String?
    @State private var statusTask: Task<Void, Never>?
    @State private var hoveredServiceID: String?
    @State private var searchText = ""
    @State private var listFilter: ServiceSettingsListFilter = .all

    private var services: [TranslationServiceEntry] { settings.translationServices }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            headerBlock
            serviceSection
        }
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dynamicTypeSize(SettingsTypography.contentTypeRange)
        .sheet(isPresented: $showAddSheet) {
            TranslationServiceCatalogSheet(
                existingKinds: Set(services.map(\.kind)),
                onPick: { kind in
                    showAddSheet = false
                    addService(kind: kind)
                },
                onCancel: { showAddSheet = false }
            )
            .presentationBackground(AppTheme.panelBackground)
        }
        .alert(L10n.string("移除翻译服务？"), isPresented: deleteAlertPresented) {
            Button(L10n.string("取消"), role: .cancel) { pendingDeleteID = nil }
            Button(L10n.string("移除"), role: .destructive) {
                if let id = pendingDeleteID { removeService(id: id) }
                pendingDeleteID = nil
            }
        } message: {
            Text(L10n.string("该服务的本机配置和密钥会一并删除。"))
        }
        .alert(L10n.string("启用在线翻译服务？"), isPresented: privacyAlertPresented) {
            Button(L10n.string("取消"), role: .cancel) { privacyPendingID = nil }
            Button(L10n.string("同意并启用")) {
                if let id = privacyPendingID { applyPrivacyAndEnable(id: id) }
                privacyPendingID = nil
            }
        } message: {
            Text(L10n.string("原文会上传到该第三方服务，且可能按字符计费。划词翻译会调用全部已启用服务。"))
        }
        .task { await refreshPairStatus() }
        .onChange(of: settings.sourceLanguage) { _, _ in
            Task { await refreshPairStatus() }
        }
        .onChange(of: settings.targetLanguage) { _, _ in
            Task { await refreshPairStatus() }
        }
        .onAppear {
            ensureSelection()
        }
    }

    private var deleteAlertPresented: Binding<Bool> {
        Binding(
            get: { pendingDeleteID != nil },
            set: { if !$0 { pendingDeleteID = nil } }
        )
    }

    private var privacyAlertPresented: Binding<Bool> {
        Binding(
            get: { privacyPendingID != nil },
            set: { if !$0 { privacyPendingID = nil } }
        )
    }

    // MARK: - Header

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("划词翻译与截图翻译会并发调用全部已启用且就绪的服务；原图翻译使用默认服务。修改后立即生效，无需保存。"))
                .settingsBodyText()
                .foregroundStyle(AppTheme.textSecondary.opacity(0.92))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Text(L10n.string("默认服务"))
                        .settingsCompactText(weight: .medium)
                        .foregroundStyle(AppTheme.textSecondary)

                    Picker(
                        L10n.string("默认服务"),
                        selection: Binding(
                            get: { settings.resolvedDefaultTranslationServiceID() },
                            set: { setAsDefault(id: $0) }
                        )
                    ) {
                        ForEach(defaultCandidates) { item in
                            Text(item.displayName).tag(item.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(ServiceSettingsVisual.controlBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(ServiceSettingsVisual.normalBorder, lineWidth: 0.5)
                )

                if let statusHint {
                    Text(statusHint)
                        .settingsBadgeText(weight: .medium)
                        .foregroundStyle(AppTheme.success)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(AppTheme.success.opacity(0.12)))
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var defaultCandidates: [TranslationServiceEntry] {
        services.filter { $0.kind == .system || ($0.isEnabled && $0.isReadyToTranslate) }
    }

    // MARK: - Service list and detail

    private var serviceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ServiceSettingsSectionToolbar(
                addSystemImage: "plus",
                searchText: $searchText,
                filter: $listFilter,
                enabledCount: services.filter(\.isEnabled).count,
                totalCount: services.count,
                onAdd: { showAddSheet = true }
            )

            GeometryReader { proxy in
                if ServiceSettingsLayoutMode.usesSplit(width: proxy.size.width) {
                    HStack(alignment: .top, spacing: 12) {
                        serviceListPanel
                            .frame(width: min(max(proxy.size.width * 0.42, 250), 320))
                        if let selectedEntry {
                            detailPanel(selectedEntry)
                        } else {
                            noSelectionPanel
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        serviceListPanel
                            .frame(maxHeight: 220)
                        if let selectedEntry {
                            detailPanel(selectedEntry)
                        } else {
                            noSelectionPanel
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var filteredServices: [TranslationServiceEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return services.filter { entry in
            let matchesQuery = query.isEmpty
                || entry.displayName.localizedCaseInsensitiveContains(query)
                || entry.kind.displayName.localizedCaseInsensitiveContains(query)
            return matchesQuery
                && listFilter.matches(
                    isEnabled: entry.kind == .system || entry.isEnabled,
                    isReady: entry.kind == .system || entry.isReadyToTranslate
                )
        }
    }

    private var selectedEntry: TranslationServiceEntry? {
        if let selectedID, let entry = services.first(where: { $0.id == selectedID }) {
            return entry
        }
        return services.first
    }

    private func ensureSelection() {
        if let selectedID, services.contains(where: { $0.id == selectedID }) {
            return
        }
        selectedID = services.first?.id
    }

    private var serviceListPanel: some View {
        ScrollView(.vertical, showsIndicators: false) {
            if filteredServices.isEmpty {
                listEmptyState
            } else {
                VStack(alignment: .leading, spacing: ServiceSettingsVisual.groupGap) {
                    ForEach(TranslationServiceCatalogGroup.allCases) { group in
                        let groupedServices = filteredServices.filter { group.contains($0.kind) }
                        if !groupedServices.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                TranslationServiceGroupHeader(group: group)
                                VStack(spacing: ServiceSettingsVisual.rowGap) {
                                    ForEach(groupedServices) { entry in
                                        serviceRow(entry).id(entry.id)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: ServiceSettingsVisual.panelRadius, style: .continuous)
                .fill(ServiceSettingsVisual.listBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ServiceSettingsVisual.panelRadius, style: .continuous)
                .stroke(ServiceSettingsVisual.panelBorder, lineWidth: 0.5)
        )
    }

    private var listEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .settingsCardTitleText()
                .foregroundStyle(AppTheme.textTertiary)
            Text(L10n.string("没有匹配的翻译服务"))
                .settingsCompactText(weight: .medium)
                .foregroundStyle(AppTheme.textSecondary)
            Button(L10n.string("清除筛选")) {
                searchText = ""
                listFilter = .all
            }
            .buttonStyle(.link)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
    }

    private func serviceRow(_ entry: TranslationServiceEntry) -> some View {
        let selected = selectedID == entry.id
        let isDefault = settings.defaultTranslationServiceID == entry.id

        return HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    selectedID = entry.id
                    verifyTargetID = nil
                    verifyMessage = nil
                }
            } label: {
                HStack(spacing: 11) {
                    serviceIcon(entry.kind)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 5) {
                            Text(entry.displayName)
                                .settingsCompactText(weight: .semibold)
                                .foregroundStyle(AppTheme.textPrimary)
                                .lineLimit(1)
                            if isDefault {
                                statusBadge(L10n.string("默认"), tint: AppTheme.accent, filled: true)
                            }
                            if let badge = entry.badgeTitle {
                                statusBadge(
                                    badge,
                                    tint: entry.kind.isBuiltIn ? AppTheme.info : AppTheme.accent
                                )
                            }
                        }
                        HStack(spacing: 5) {
                            Circle()
                                .fill(statusColor(for: entry))
                                .frame(width: 6, height: 6)
                            Text(statusLabel(for: entry))
                                .settingsBadgeText(weight: .regular)
                                .foregroundStyle(AppTheme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .settingsCompactText(weight: .semibold)
                        .foregroundStyle(AppTheme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .translationPointingHand()
            .onHover { hovering in
                hoveredServiceID = hovering ? entry.id : nil
            }

            if entry.kind == .system {
                Image(systemName: "lock.fill")
                    .settingsBadgeText(weight: .medium)
                    .foregroundStyle(AppTheme.textTertiary)
                    .help(L10n.string("内置服务始终可用"))
            } else {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { entry.isEnabled },
                        set: { setEnabled(entryID: entry.id, enabled: $0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, ServiceSettingsVisual.rowVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: ServiceSettingsVisual.rowRadius, style: .continuous)
                .fill(
                    selected
                        ? ServiceSettingsVisual.selectedFill
                        : (hoveredServiceID == entry.id
                            ? ServiceSettingsVisual.hoverFill
                            : AppTheme.surface.opacity(0.64))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: ServiceSettingsVisual.rowRadius, style: .continuous)
                .stroke(
                    selected ? ServiceSettingsVisual.selectedBorder : ServiceSettingsVisual.rowBorder,
                    lineWidth: selected ? 1 : 0.5
                )
        )
        .overlay(alignment: .leading) {
            if selected {
                Capsule()
                    .fill(AppTheme.accent)
                    .frame(width: 3, height: 22)
                    .padding(.leading, 4)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(entry.displayName)
        .accessibilityValue(statusLabel(for: entry))
    }

    private func statusBadge(_ title: String, tint: Color, filled: Bool = false) -> some View {
        Text(title)
            .settingsBadgeText(weight: .bold)
            .foregroundStyle(filled ? AppTheme.onAccent : tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(filled ? tint : tint.opacity(0.15))
            )
    }

    @ViewBuilder
    private func detailPanel(_ entry: TranslationServiceEntry) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: ServiceSettingsVisual.detailSectionSpacing) {
                detailHeader(entry)
                Divider().overlay(AppTheme.separator)
                expandedEditor(entry)
            }
            .padding(ServiceSettingsVisual.detailPadding)
        }
        .background(
            RoundedRectangle(cornerRadius: ServiceSettingsVisual.panelRadius, style: .continuous)
                .fill(ServiceSettingsVisual.detailBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ServiceSettingsVisual.panelRadius, style: .continuous)
                .stroke(ServiceSettingsVisual.panelBorder, lineWidth: 0.5)
        )
    }

    private func detailHeader(_ entry: TranslationServiceEntry) -> some View {
        HStack(spacing: 12) {
            serviceIcon(entry.kind)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(entry.displayName)
                        .settingsCardTitleText()
                        .foregroundStyle(AppTheme.textPrimary)
                    if settings.defaultTranslationServiceID == entry.id {
                        statusBadge(L10n.string("默认"), tint: AppTheme.accent, filled: true)
                    }
                    if let badge = entry.badgeTitle {
                        statusBadge(
                            badge,
                            tint: entry.kind.isBuiltIn ? AppTheme.info : AppTheme.accent
                        )
                    }
                }
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor(for: entry))
                        .frame(width: 7, height: 7)
                    Text(statusLabel(for: entry))
                        .settingsBodyText()
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            Spacer(minLength: 0)
            if entry.kind == .system {
                Image(systemName: "lock.fill")
                    .settingsBodyText()
                    .foregroundStyle(AppTheme.textTertiary)
            } else {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { entry.isEnabled },
                        set: { setEnabled(entryID: entry.id, enabled: $0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
    }

    private var noSelectionPanel: some View {
        VStack(spacing: 8) {
            Image(systemName: "sidebar.right")
                .settingsCardTitleText()
                .foregroundStyle(AppTheme.textTertiary)
            Text(L10n.string("选择一个服务查看详情"))
                .settingsCompactText(weight: .medium)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: ServiceSettingsVisual.panelRadius, style: .continuous)
                .fill(ServiceSettingsVisual.listBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ServiceSettingsVisual.panelRadius, style: .continuous)
                .stroke(ServiceSettingsVisual.panelBorder, lineWidth: 0.5)
        )
    }

    private func serviceIcon(_ kind: TranslationServiceKind) -> some View {
        TranslationServiceIconView(kind: kind, size: 30)
    }

    private func statusLabel(for entry: TranslationServiceEntry) -> String {
        if entry.kind == .system {
            if isRefreshingStatus { return L10n.string("正在检查模型…") }
            if let pairStatus {
                let pair =
                    "\(TranslationLanguage.displayName(for: pairStatus.sourceCode)) → \(TranslationLanguage.displayName(for: pairStatus.targetCode))"
                return "\(pairStatus.statusLabel) · \(pair)"
            }
            return L10n.string("本机系统 Translation")
        }
        if !entry.isReadyToTranslate { return L10n.string("配置未完成") }
        return entry.isEnabled ? L10n.string("配置完整") : L10n.string("配置完整 · 未启用")
    }

    private func statusColor(for entry: TranslationServiceEntry) -> Color {
        if entry.kind == .system, let pairStatus {
            switch pairStatus.status {
            case .installed: return .green
            case .supportedNotInstalled: return .orange
            case .unsupported: return .red
            case .sameLanguage: return .secondary
            }
        }
        if !entry.isReadyToTranslate { return AppTheme.warning }
        return entry.isEnabled ? AppTheme.success : AppTheme.textSecondary
    }

    // MARK: - Editors

    @ViewBuilder
    private func expandedEditor(_ entry: TranslationServiceEntry) -> some View {
        let id = entry.id
        VStack(alignment: .leading, spacing: ServiceSettingsVisual.detailSectionSpacing) {
            if entry.kind != .system {
                labeledField(L10n.string("服务名称")) {
                    TextField(L10n.string("服务名称"), text: nameBinding(id: id))
                        .textFieldStyle(.roundedBorder)
                }
            }

            usageNotice(for: entry.kind)

            switch entry.kind {
            case .system:
                systemFields
            case .baidu:
                secureField("APP ID", text: baiduBinding(id: id, keyPath: \.appID))
                secureField("Secret Key", text: baiduBinding(id: id, keyPath: \.secretKey))
            case .youdao:
                secureField("APP Key", text: youdaoBinding(id: id, keyPath: \.appKey))
                secureField("APP Secret", text: youdaoBinding(id: id, keyPath: \.appSecret))
            case .google:
                secureField("API Key", text: googleBinding(id: id, keyPath: \.apiKey))
            case .deepl:
                secureField("Auth Key", text: deeplBinding(id: id, keyPath: \.authKey))
                Text(L10n.string("以 :fx 结尾的密钥自动使用 DeepL Free 地址，其余使用 Pro 地址。"))
                    .settingsBadgeText(weight: .regular)
                    .foregroundStyle(AppTheme.textTertiary)
            case .microsoft:
                secureField(
                    "Subscription Key",
                    text: microsoftBinding(id: id, keyPath: \.subscriptionKey)
                )
                labeledField(L10n.string("Region（全局单服务资源可留空）")) {
                    TextField(L10n.string("例如 eastasia"), text: microsoftBinding(id: id, keyPath: \.region))
                        .textFieldStyle(.roundedBorder)
                }
            case .volcengine:
                secureField("Access Key", text: volcengineBinding(id: id, keyPath: \.accessKey))
                secureField("Secret Key", text: volcengineBinding(id: id, keyPath: \.secretKey))
                labeledField(L10n.string("Region（默认 cn-north-1）")) {
                    TextField(L10n.string("例如 cn-north-1"), text: volcengineBinding(id: id, keyPath: \.region))
                        .textFieldStyle(.roundedBorder)
                }
            case .tencent:
                secureField("SecretId", text: tencentBinding(id: id, keyPath: \.secretID))
                secureField("SecretKey", text: tencentBinding(id: id, keyPath: \.secretKey))
                labeledField(L10n.string("Region（默认 ap-beijing）")) {
                    TextField(L10n.string("例如 ap-beijing"), text: tencentBinding(id: id, keyPath: \.region))
                        .textFieldStyle(.roundedBorder)
                }
            case .aliyun:
                secureField("AccessKey ID", text: aliyunBinding(id: id, keyPath: \.accessKeyID))
                secureField("AccessKey Secret", text: aliyunBinding(id: id, keyPath: \.accessKeySecret))
            case .caiyun:
                secureField("Token", text: caiyunBinding(id: id, keyPath: \.token))
            case .niutrans:
                secureField("API Key", text: niutransBinding(id: id, keyPath: \.apiKey))
            case .amazon:
                secureField("Access Key ID", text: amazonBinding(id: id, keyPath: \.accessKeyID))
                secureField("Secret Access Key", text: amazonBinding(id: id, keyPath: \.secretAccessKey))
                labeledField(L10n.string("Region（默认 us-east-1）")) {
                    TextField(L10n.string("例如 us-east-1"), text: amazonBinding(id: id, keyPath: \.region))
                        .textFieldStyle(.roundedBorder)
                }
                secureField(L10n.string("Session Token（可选）"), text: amazonBinding(id: id, keyPath: \.sessionToken))
            case .openai, .openrouter, .deepseek, .qwen, .zhipu,
                 .siliconflow, .groq, .grok, .kimi:
                secureField("API Key", text: openAICompatibleBinding(id: id, keyPath: \.apiKey))
                labeledField("Model") {
                    TextField(L10n.string("填写服务商提供的模型 ID"), text: openAICompatibleBinding(id: id, keyPath: \.model))
                        .textFieldStyle(.roundedBorder)
                }
                recommendedModelHint(for: entry.kind)
                streamingOutputField(
                    isOn: openAICompatibleBoolBinding(id: id, keyPath: \.streamingEnabled)
                )
            case .ollama, .lmStudio:
                labeledField(L10n.string("服务地址")) {
                    TextField(
                        entry.kind == .ollama
                            ? L10n.string("例如 http://127.0.0.1:11434")
                            : L10n.string("例如 http://127.0.0.1:1234/v1"),
                        text: localModelBinding(id: id, keyPath: \.baseURL)
                    )
                    .textFieldStyle(.roundedBorder)
                }
                labeledField("Model") {
                    TextField(L10n.string("填写本地模型 ID"), text: localModelBinding(id: id, keyPath: \.model))
                        .textFieldStyle(.roundedBorder)
                }
                recommendedModelHint(for: entry.kind)
                if entry.kind == .lmStudio {
                    secureField(L10n.string("API Key（可选）"), text: localModelBinding(id: id, keyPath: \.apiKey))
                }
                streamingOutputField(
                    isOn: localModelBoolBinding(id: id, keyPath: \.streamingEnabled)
                )
            }

            Divider()
                .padding(.vertical, 2)

            HStack(spacing: 12) {
                Button {
                    Task { await verify(entryID: id) }
                } label: {
                    if isVerifying, verifyTargetID == id {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(L10n.string("验证连接"), systemImage: "checkmark.shield")
                    }
                }
                .disabled(isVerifying || !entry.isReadyToTranslate)
                .controlSize(.small)

                if settings.defaultTranslationServiceID == id {
                    Label(L10n.string("当前默认"), systemImage: "star.fill")
                        .settingsBodyText()
                        .foregroundStyle(AppTheme.textSecondary)
                } else {
                    Button {
                        setAsDefault(id: id)
                    } label: {
                        Label(L10n.string("设为默认"), systemImage: "star")
                    }
                    .disabled(!canSetDefault(entry))
                    .controlSize(.small)
                }

                Spacer()

                if entry.kind != .system {
                    Button {
                        pendingDeleteID = id
                    } label: {
                        Label(L10n.string("删除服务"), systemImage: "trash")
                            .foregroundStyle(AppTheme.danger)
                    }
                    .controlSize(.small)
                }
            }

            if verifyTargetID == id, let verifyMessage {
                Text(verifyMessage)
                    .settingsBodyText()
                    .foregroundStyle(verifyMessage.contains(L10n.string("成功")) ? AppTheme.success : AppTheme.warning)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var systemFields: some View {
        VStack(alignment: .leading, spacing: ServiceSettingsVisual.detailSectionSpacing) {
            if let pairStatus {
                labeledField(L10n.string("模型状态")) {
                    Text(pairStatus.statusLabel).foregroundStyle(statusColor(for: .system()))
                }
            }
            labeledField(L10n.string("当前源语言")) {
                Text(sourceSummary).foregroundStyle(AppTheme.textSecondary)
            }
            labeledField(L10n.string("当前目标语言")) {
                Text(targetSummary).foregroundStyle(AppTheme.textSecondary)
            }
            HStack {
                Button(L10n.string("刷新状态")) { Task { await refreshPairStatus() } }
                    .disabled(isRefreshingStatus)
                    .controlSize(.small)
                Button(L10n.string("打开系统翻译语言设置")) {
                    TranslationSystemSettingsOpener.openTranslationLanguages()
                }
                .controlSize(.small)
            }
        }
    }

    private var targetSummary: String {
        if settings.targetLanguage == TranslationLanguage.systemTargetToken {
            return String(format: L10n.string("跟随系统（%@）"), TranslationLanguage.systemPreferredDisplayName())
        }
        return TranslationLanguage.displayName(for: settings.targetLanguage)
    }

    private var sourceSummary: String {
        settings.sourceLanguage == TranslationLanguage.autoSourceToken
            ? L10n.string("自动检测")
            : TranslationLanguage.displayName(for: settings.sourceLanguage)
    }

    // MARK: - Bindings

    private func entry(_ id: String) -> TranslationServiceEntry? {
        settings.translationServices.first { $0.id == id }
    }

    private func mutate(_ id: String, _ body: (inout TranslationServiceEntry) -> Void) {
        guard let index = settings.translationServices.firstIndex(where: { $0.id == id }) else { return }
        var list = settings.translationServices
        body(&list[index])
        if let systemIndex = list.firstIndex(where: { $0.kind == .system }) {
            list[systemIndex] = .system()
        }
        settings.translationServices = list
    }

    private func nameBinding(id: String) -> Binding<String> {
        Binding(
            get: { entry(id)?.displayName ?? "" },
            set: { value in mutate(id) { $0.displayName = value } }
        )
    }

    private func baiduBinding(
        id: String,
        keyPath: WritableKeyPath<BaiduTranslationConfig, String>
    ) -> Binding<String> {
        configBinding(id: id, get: \.baidu, set: \.baidu, default: .init(), keyPath: keyPath)
    }

    private func youdaoBinding(
        id: String,
        keyPath: WritableKeyPath<YoudaoTranslationConfig, String>
    ) -> Binding<String> {
        configBinding(id: id, get: \.youdao, set: \.youdao, default: .init(), keyPath: keyPath)
    }

    private func googleBinding(
        id: String,
        keyPath: WritableKeyPath<GoogleTranslationConfig, String>
    ) -> Binding<String> {
        configBinding(id: id, get: \.google, set: \.google, default: .init(), keyPath: keyPath)
    }

    private func deeplBinding(
        id: String,
        keyPath: WritableKeyPath<DeepLTranslationConfig, String>
    ) -> Binding<String> {
        configBinding(id: id, get: \.deepl, set: \.deepl, default: .init(), keyPath: keyPath)
    }

    private func microsoftBinding(
        id: String,
        keyPath: WritableKeyPath<MicrosoftTranslationConfig, String>
    ) -> Binding<String> {
        configBinding(id: id, get: \.microsoft, set: \.microsoft, default: .init(), keyPath: keyPath)
    }

    private func volcengineBinding(
        id: String,
        keyPath: WritableKeyPath<VolcengineTranslationConfig, String>
    ) -> Binding<String> {
        configBinding(id: id, get: \.volcengine, set: \.volcengine, default: .init(), keyPath: keyPath)
    }

    private func tencentBinding(
        id: String,
        keyPath: WritableKeyPath<TencentTranslationConfig, String>
    ) -> Binding<String> {
        configBinding(id: id, get: \.tencent, set: \.tencent, default: .init(), keyPath: keyPath)
    }

    private func aliyunBinding(
        id: String,
        keyPath: WritableKeyPath<AliyunTranslationConfig, String>
    ) -> Binding<String> {
        configBinding(id: id, get: \.aliyun, set: \.aliyun, default: .init(), keyPath: keyPath)
    }

    private func caiyunBinding(
        id: String,
        keyPath: WritableKeyPath<CaiyunTranslationConfig, String>
    ) -> Binding<String> {
        configBinding(id: id, get: \.caiyun, set: \.caiyun, default: .init(), keyPath: keyPath)
    }

    private func niutransBinding(
        id: String,
        keyPath: WritableKeyPath<NiuTransTranslationConfig, String>
    ) -> Binding<String> {
        configBinding(id: id, get: \.niutrans, set: \.niutrans, default: .init(), keyPath: keyPath)
    }

    private func amazonBinding(
        id: String,
        keyPath: WritableKeyPath<AmazonTranslationConfig, String>
    ) -> Binding<String> {
        configBinding(id: id, get: \.amazon, set: \.amazon, default: .init(), keyPath: keyPath)
    }

    private func openAICompatibleBinding(
        id: String,
        keyPath: WritableKeyPath<OpenAICompatibleTranslationConfig, String>
    ) -> Binding<String> {
        configBinding(
            id: id,
            get: \.openAICompatible,
            set: \.openAICompatible,
            default: .init(),
            keyPath: keyPath
        )
    }

    private func localModelBinding(
        id: String,
        keyPath: WritableKeyPath<LocalModelTranslationConfig, String>
    ) -> Binding<String> {
        configBinding(
            id: id,
            get: \.localModel,
            set: \.localModel,
            default: .init(),
            keyPath: keyPath
        )
    }

    private func openAICompatibleBoolBinding(
        id: String,
        keyPath: WritableKeyPath<OpenAICompatibleTranslationConfig, Bool>
    ) -> Binding<Bool> {
        configBoolBinding(
            id: id,
            get: \.openAICompatible,
            set: \.openAICompatible,
            default: .init(),
            keyPath: keyPath
        )
    }

    private func localModelBoolBinding(
        id: String,
        keyPath: WritableKeyPath<LocalModelTranslationConfig, Bool>
    ) -> Binding<Bool> {
        configBoolBinding(
            id: id,
            get: \.localModel,
            set: \.localModel,
            default: .init(),
            keyPath: keyPath
        )
    }

    private func configBinding<Config>(
        id: String,
        get: KeyPath<TranslationServiceEntry, Config?>,
        set: WritableKeyPath<TranslationServiceEntry, Config?>,
        default defaultValue: Config,
        keyPath: WritableKeyPath<Config, String>
    ) -> Binding<String> {
        Binding(
            get: { entry(id)?[keyPath: get]?[keyPath: keyPath] ?? "" },
            set: { value in
                mutate(id) { item in
                    var config = item[keyPath: get] ?? defaultValue
                    config[keyPath: keyPath] = value
                    item[keyPath: set] = config
                }
            }
        )
    }

    private func configBoolBinding<Config>(
        id: String,
        get: KeyPath<TranslationServiceEntry, Config?>,
        set: WritableKeyPath<TranslationServiceEntry, Config?>,
        default defaultValue: Config,
        keyPath: WritableKeyPath<Config, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { entry(id)?[keyPath: get]?[keyPath: keyPath] ?? false },
            set: { value in
                mutate(id) { item in
                    var config = item[keyPath: get] ?? defaultValue
                    config[keyPath: keyPath] = value
                    item[keyPath: set] = config
                }
            }
        )
    }

    @ViewBuilder
    private func streamingOutputField(isOn: Binding<Bool>) -> some View {
        labeledField(L10n.string("输出模式")) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(L10n.string("启用流式输出"), isOn: isOn)
                    .toggleStyle(.switch)
                Text(L10n.string("开启后按增量显示译文；关闭后等待完整响应。模型或服务端不支持流式时请关闭。"))
                    .settingsBadgeText(weight: .regular)
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private func recommendedModelHint(for kind: TranslationServiceKind) -> some View {
        if let model = kind.recommendedTranslationModel {
            Text(String(format: L10n.string("推荐翻译专用模型：%@"), model))
                .settingsBadgeText(weight: .regular)
                .foregroundStyle(AppTheme.accent)
                .textSelection(.enabled)
        }
    }

    // MARK: - Actions

    private func setEnabled(entryID: String, enabled: Bool) {
        guard let item = entry(entryID), item.kind != .system else { return }
        if enabled, !item.privacyAccepted {
            privacyPendingID = entryID
            return
        }
        mutate(entryID) { $0.isEnabled = enabled }
        if !enabled, settings.defaultTranslationServiceID == entryID {
            settings.setDefaultTranslationServiceID(TranslationServiceEntry.systemID)
        }
        flashStatus(enabled ? L10n.string("已启用") : L10n.string("已关闭"))
    }

    private func applyPrivacyAndEnable(id: String) {
        mutate(id) {
            $0.privacyAccepted = true
            $0.isEnabled = true
        }
        flashStatus(L10n.string("已启用"))
    }

    private func canSetDefault(_ entry: TranslationServiceEntry) -> Bool {
        entry.kind == .system || (entry.isEnabled && entry.isReadyToTranslate)
    }

    private func setAsDefault(id: String) {
        guard let item = entry(id), canSetDefault(item) else {
            flashStatus(L10n.string("请先启用并完成配置"))
            return
        }
        settings.setDefaultTranslationServiceID(id)
        flashStatus(String(format: L10n.string("已设为默认：%@"), item.displayName))
    }

    private func addService(kind: TranslationServiceKind) {
        guard kind != .system else { return }
        if let existing = services.first(where: { $0.kind == kind }) {
            selectedID = existing.id
            flashStatus(String(format: L10n.string("已添加「%@」"), kind.displayName))
            return
        }
        let item = TranslationServiceEntry.make(kind: kind)
        settings.translationServices.append(item)
        selectedID = item.id
        flashStatus(String(format: L10n.string("已添加「%@」"), kind.displayName))
    }

    private func removeService(id: String) {
        guard let item = entry(id), item.kind != .system else { return }
        if settings.defaultTranslationServiceID == id {
            settings.setDefaultTranslationServiceID(TranslationServiceEntry.systemID)
        }
        settings.translationServices.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = settings.translationServices.first?.id
        }
        if verifyTargetID == id {
            verifyTargetID = nil
            verifyMessage = nil
        }
        flashStatus(String(format: L10n.string("已移除「%@」"), item.displayName))
    }

    private func verify(entryID: String) async {
        isVerifying = true
        verifyTargetID = entryID
        verifyMessage = nil
        defer { isVerifying = false }
        verifyMessage = await translation.verify(serviceID: entryID)
        if entryID == TranslationServiceEntry.systemID {
            await refreshPairStatus()
        }
    }

    private func refreshPairStatus() async {
        isRefreshingStatus = true
        defer { isRefreshingStatus = false }
        pairStatus = await translation.pairStatus()
    }

    private func flashStatus(_ message: String) {
        statusTask?.cancel()
        withAnimation { statusHint = message }
        statusTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation { statusHint = nil }
        }
    }

    private func labeledField<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .settingsCompactText(weight: .medium)
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 144, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                content()
            }
            .frame(maxWidth: 420, alignment: .leading)
        }
        .padding(.vertical, ServiceSettingsVisual.formRowPadding)
    }

    private func secureField(_ title: String, text: Binding<String>) -> some View {
        labeledField(title) {
            SecureField(title, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func usageNotice(for kind: TranslationServiceKind) -> some View {
        let tint = kind.isBuiltIn ? AppTheme.success : AppTheme.warning
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind.isBuiltIn ? "lock.shield" : "exclamationmark.shield")
                .settingsCompactText(weight: .semibold)
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(kind.isBuiltIn ? L10n.string("本机处理") : L10n.string("隐私与计费"))
                        .settingsCompactText(weight: .semibold)
                    Spacer()
                    if let url = helpURL(for: kind) {
                        TutorialLinkButton(destination: url)
                    }
                }
                Text(usageNote(for: kind))
                    .settingsBodyText()
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.surfaceMuted.opacity(0.48))
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tint)
                .frame(width: 2)
                .padding(.vertical, 8)
        }
    }

    private func helpURL(for kind: TranslationServiceKind) -> URL? {
        switch kind {
        case .system: nil
        case .baidu: URL(string: "https://fanyi-api.baidu.com/product/113")
        case .youdao: URL(string: "https://ai.youdao.com/DOCSIRMA/html/trans/api/plwbfy/index.html")
        case .google: URL(string: "https://cloud.google.com/translate/docs/reference/rest/v2/translate")
        case .deepl: URL(string: "https://developers.deepl.com/docs/getting-started/auth")
        case .microsoft:
            URL(string: "https://learn.microsoft.com/azure/ai-services/translator/text-translation/quickstart/rest-api")
        case .volcengine: URL(string: "https://www.volcengine.com/docs/4640/130872")
        case .tencent: URL(string: "https://cloud.tencent.com/document/product/551/104415")
        case .aliyun:
            URL(string: "https://help.aliyun.com/zh/machine-translation/developer-reference/api-reference-machine-translation-universal-version-call-guide")
        case .caiyun: URL(string: "https://docs.caiyunapp.com/lingocloud-api/index.html")
        case .niutrans: URL(string: "https://niutrans.com/documents/contents/trans_text")
        case .amazon: URL(string: "https://docs.aws.amazon.com/translate/latest/dg/getting-started.html")
        case .openai: URL(string: "https://platform.openai.com/docs/api-reference/chat/create")
        case .openrouter: URL(string: "https://openrouter.ai/docs/quickstart")
        case .deepseek: URL(string: "https://api-docs.deepseek.com/")
        case .qwen: URL(string: "https://help.aliyun.com/zh/model-studio/text-generation")
        case .zhipu: URL(string: "https://docs.bigmodel.cn/cn/guide/develop/openai/introduction")
        case .siliconflow:
            URL(string: "https://docs.siliconflow.cn/cn/api-reference/chat-completions/chat-completions")
        case .groq: URL(string: "https://console.groq.com/docs/openai")
        case .grok:
            URL(string: "https://docs.x.ai/developers/model-capabilities/legacy/chat-completions")
        case .kimi: URL(string: "https://platform.moonshot.cn/docs/api/chat")
        case .ollama: URL(string: "https://docs.ollama.com/api/chat")
        case .lmStudio: URL(string: "https://lmstudio.ai/docs/app/api/endpoints/openai")
        }
    }

    private func usageNote(for kind: TranslationServiceKind) -> String {
        switch kind {
        case .system:
            L10n.string("使用 macOS 系统翻译框架，文本在设备端处理；需下载对应语言模型。")
        case .baidu:
            L10n.string("文本会上传至百度翻译开放平台，并可能按字符计费。")
        case .youdao:
            L10n.string("文本会上传至有道智云批量翻译 API，并可能按字符计费。")
        case .google:
            L10n.string("文本会上传至 Google Cloud Translation Basic，并可能按字符计费。")
        case .deepl:
            L10n.string("文本会上传至 DeepL；Free 与 Pro 使用不同服务地址。")
        case .microsoft:
            L10n.string("文本会上传至 Microsoft Translator；区域资源还需填写 Region。")
        case .volcengine:
            L10n.string("文本会上传至火山机器翻译；请求使用 Access Key/Secret Key 签名，可能按字符计费。")
        case .tencent:
            L10n.string("文本会上传至腾讯机器翻译；请求使用 SecretId/SecretKey 签名，可能按字符计费。")
        case .aliyun:
            L10n.string("文本会上传至阿里云机器翻译；AccessKey 仅用于本机请求签名，可能按字符计费。")
        case .caiyun:
            L10n.string("文本会上传至彩云小译 API；Token 账户可能按字符计费。")
        case .niutrans:
            L10n.string("文本会上传至小牛翻译 API；可能按字符或积分计费。")
        case .amazon:
            L10n.string("文本会上传至 Amazon Translate；需要 AWS 区域和访问密钥，可能按字符计费。")
        case .openai, .openrouter, .deepseek, .qwen, .zhipu,
             .siliconflow, .groq, .grok, .kimi:
            L10n.string("文本会上传至该模型服务生成译文，并可能按 Token 计费；模型必须支持 Chat Completions。")
        case .ollama:
            L10n.string("默认连接本机 Ollama，文本不会离开本机；如果填写远程地址，文本将发送到该地址。")
        case .lmStudio:
            L10n.string("默认连接本机 LM Studio，文本不会离开本机；如果填写远程地址，文本将发送到该地址。")
        }
    }
}

private enum TranslationServiceCatalogGroup: String, CaseIterable, Identifiable {
    case standard
    case largeLanguageModel
    case localModel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: L10n.string("普通翻译服务")
        case .largeLanguageModel: L10n.string("大模型翻译服务")
        case .localModel: L10n.string("本地模型服务")
        }
    }

    var kinds: [TranslationServiceKind] {
        switch self {
        case .standard:
            [.baidu, .youdao, .google, .deepl, .microsoft,
             .volcengine, .tencent, .aliyun, .caiyun, .niutrans, .amazon]
        case .largeLanguageModel:
            [.openai, .openrouter, .deepseek, .qwen, .zhipu,
             .siliconflow, .groq, .grok, .kimi]
        case .localModel:
            [.ollama, .lmStudio]
        }
    }

    func contains(_ kind: TranslationServiceKind) -> Bool {
        (kind == .system && self == .standard) || kinds.contains(kind)
    }
}

private struct TranslationServiceGroupHeader: View {
    let group: TranslationServiceCatalogGroup

    var body: some View {
        HStack(spacing: 8) {
            Text(group.title)
                .settingsBadgeText(weight: .semibold)
                .foregroundStyle(AppTheme.textSecondary)
            Rectangle()
                .fill(AppTheme.separator.opacity(0.72))
                .frame(height: 1)
        }
    }
}

private struct TranslationServiceCatalogSheet: View {
    let existingKinds: Set<TranslationServiceKind>
    var onPick: (TranslationServiceKind) -> Void
    var onCancel: () -> Void
    @State private var hoveredKind: TranslationServiceKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("添加翻译服务"))
                        .font(.title3.bold())
                        .dynamicTypeSize(SettingsTypography.contentTypeRange)
                    Text(L10n.string("选择要接入的翻译服务，每个服务只能添加一次"))
                        .settingsBodyText()
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
                Button(L10n.string("取消"), action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(TranslationServiceCatalogGroup.allCases) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            TranslationServiceGroupHeader(group: group)
                            LazyVGrid(
                                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                                spacing: 12
                            ) {
                                ForEach(group.kinds) { kind in
                                    serviceChip(kind)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 410)
        }
        .padding(20)
        .frame(width: 640, height: 520)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(ServiceSettingsVisual.panelBorder, lineWidth: 0.5)
        )
    }

    private func serviceChip(_ kind: TranslationServiceKind) -> some View {
        let exists = existingKinds.contains(kind)
        return Button {
            onPick(kind)
        } label: {
            HStack(spacing: 10) {
                TranslationServiceIconView(kind: kind, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.displayName)
                        .settingsCardTitleText()
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 4) {
                        Image(systemName: exists ? "checkmark.circle.fill" : "plus.circle")
                            .settingsBadgeText(weight: .semibold)
                        Text(exists ? L10n.string("已添加") : L10n.string("点击添加"))
                    }
                    .settingsBadgeText(weight: .medium)
                    .foregroundStyle(exists ? AppTheme.success : AppTheme.textSecondary)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(
            ServiceCatalogCardStyle(
                isHovered: hoveredKind == kind,
                isDisabled: exists
            )
        )
        .disabled(exists)
        .onHover { hovering in
            guard !exists else {
                NSCursor.arrow.set()
                return
            }
            hoveredKind = hovering ? kind : (hoveredKind == kind ? nil : hoveredKind)
            updateHandCursor(hovering)
        }
    }
}

private extension View {
    func translationPointingHand(enabled: Bool = true) -> some View {
        onContinuousHover { phase in
            guard enabled else { return }
            switch phase {
            case .active: updateHandCursor(true)
            case .ended: updateHandCursor(false)
            }
        }
    }
}
