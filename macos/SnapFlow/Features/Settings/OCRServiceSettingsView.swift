import AppKit
import SwiftUI

/// OCR 服务配置：紧凑列表 + 详情面板；即时写入。
struct OCRServiceSettingsView: View {
    @Bindable var settings: SettingsStore
    var ocrRouter: OCRRouter

    @State private var selectedID: String?
    @State private var showAddSheet = false
    @State private var pendingDeleteID: String?
    @State private var verifyMessage: String?
    @State private var verifyTargetID: String?
    @State private var isVerifying = false
    @State private var privacyPendingID: String?
    @State private var statusHint: String?
    @State private var statusTask: Task<Void, Never>?
    @State private var hoveredServiceID: String?
    @State private var searchText = ""
    @State private var listFilter: ServiceSettingsListFilter = .all

    private var services: [OCRServiceEntry] { settings.ocrServices }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            headerBlock
            serviceSection
        }
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dynamicTypeSize(SettingsTypography.contentTypeRange)
        .onAppear {
            ensureSelection()
        }
        .sheet(isPresented: $showAddSheet) {
            OCRServiceCatalogSheet(
                existingKinds: Set(services.map(\.kind)),
                onPick: { kind in
                    showAddSheet = false
                    addService(kind: kind)
                },
                onComingSoon: { name in
                    showAddSheet = false
                    flashStatus(String(format: L10n.string("「%@」即将支持"), name))
                },
                onCancel: { showAddSheet = false }
            )
            .presentationBackground(AppTheme.panelBackground)
        }
        .alert(
            L10n.string("移除服务"),
            isPresented: Binding(
                get: { pendingDeleteID != nil },
                set: { if !$0 { pendingDeleteID = nil } }
            )
        ) {
            Button(L10n.string("取消"), role: .cancel) { pendingDeleteID = nil }
            Button(L10n.string("移除"), role: .destructive) {
                if let id = pendingDeleteID {
                    performRemove(id: id)
                }
                pendingDeleteID = nil
            }
        } message: {
            let name = services.first { $0.id == pendingDeleteID }?.displayName ?? L10n.string("该服务")
            Text(String(format: L10n.string("确定移除「%@」？密钥将一并删除，此操作不可撤销。"), name))
        }
        .alert(
            L10n.string("上传隐私说明"),
            isPresented: Binding(
                get: { privacyPendingID != nil },
                set: { if !$0 { privacyPendingID = nil } }
            )
        ) {
            Button(L10n.string("取消"), role: .cancel) { privacyPendingID = nil }
            Button(L10n.string("同意并启用")) {
                if let id = privacyPendingID {
                    applyPrivacyAndEnable(id: id)
                }
                privacyPendingID = nil
            }
        } message: {
            Text(L10n.string("使用云端或自定义 OCR 时，截图会发送至对应服务端。请确认你了解并接受。"))
        }
    }

    // MARK: - Header

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("开启的服务会出现在识别结果窗菜单中。修改后立即生效，无需保存。"))
                .settingsBodyText()
                .foregroundStyle(AppTheme.textSecondary.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Text(L10n.string("默认服务"))
                        .settingsCompactText(weight: .medium)
                        .foregroundStyle(AppTheme.textSecondary)

                    Picker(
                        L10n.string("默认服务"),
                        selection: Binding(
                            get: { settings.resolvedDefaultOCRServiceID() },
                            set: { newID in
                                applyDefaultFromPicker(newID)
                            }
                        )
                    ) {
                        ForEach(defaultPickerCandidates) { item in
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

    /// 下拉可选：已启用且可识别的服务；Vision 始终在列。
    private var defaultPickerCandidates: [OCRServiceEntry] {
        services.filter { entry in
            if entry.kind == .vision { return true }
            return entry.isEnabled && entry.isReadyToRecognize
        }
    }

    private func applyDefaultFromPicker(_ newID: String) {
        guard let target = services.first(where: { $0.id == newID }) else { return }
        if target.kind != .vision {
            guard target.isEnabled, target.isReadyToRecognize else {
                flashStatus(L10n.string("请先启用并完成配置"))
                return
            }
        }
        settings.setDefaultOCRServiceID(newID)
        flashStatus(String(format: L10n.string("已设为默认：%@"), target.displayName))
    }

    // MARK: - Service list and detail

    private var serviceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ServiceSettingsSectionToolbar(
                addSystemImage: "plus.circle.fill",
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

    private var filteredServices: [OCRServiceEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return services.filter { entry in
            let matchesQuery = query.isEmpty
                || entry.displayName.localizedCaseInsensitiveContains(query)
                || entry.kind.displayName.localizedCaseInsensitiveContains(query)
            return matchesQuery
                && listFilter.matches(
                    isEnabled: entry.kind == .vision || entry.isEnabled,
                    isReady: entry.kind == .vision || entry.isReadyToRecognize
                )
        }
    }

    private var selectedEntry: OCRServiceEntry? {
        if let selectedID, let entry = services.first(where: { $0.id == selectedID }) {
            return entry
        }
        if let defaultEntry = services.first(where: { $0.id == settings.defaultOCRServiceID }) {
            return defaultEntry
        }
        return services.first
    }

    private func ensureSelection() {
        if let selectedID, services.contains(where: { $0.id == selectedID }) {
            return
        }
        selectedID = selectedEntry?.id
    }

    private var serviceListPanel: some View {
        ScrollView(.vertical, showsIndicators: false) {
            if filteredServices.isEmpty {
                listEmptyState
            } else {
                VStack(spacing: ServiceSettingsVisual.rowGap) {
                    ForEach(filteredServices) { entry in
                        serviceRow(entry).id(entry.id)
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
        VStack(spacing: 9) {
            Image(systemName: services.isEmpty ? "shippingbox" : "magnifyingglass")
                .settingsCardTitleText()
                .foregroundStyle(AppTheme.textTertiary)
            Text(services.isEmpty ? L10n.string("还没有 OCR 服务") : L10n.string("没有匹配的 OCR 服务"))
                .settingsCompactText(weight: .medium)
                .foregroundStyle(AppTheme.textSecondary)
            if services.isEmpty {
                Text(L10n.string("点击「添加服务」接入百度、腾讯等引擎"))
                    .settingsBodyText()
                    .foregroundStyle(AppTheme.textSecondary)
                Button {
                    showAddSheet = true
                } label: {
                    Label(L10n.string("添加服务"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Button(L10n.string("清除筛选")) {
                    searchText = ""
                    listFilter = .all
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
    }

    private func serviceRow(_ entry: OCRServiceEntry) -> some View {
        let selected = selectedID == entry.id
        let isDefault = settings.defaultOCRServiceID == entry.id

        return HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    selectedID = entry.id
                    verifyMessage = nil
                    verifyTargetID = nil
                }
            } label: {
                HStack(spacing: 11) {
                    OCRServiceIconView(kind: entry.kind, size: 30)
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
            .onHover { hovering in
                hoveredServiceID = hovering ? entry.id : nil
                updateHandCursor(hovering)
            }

            if entry.kind == .vision {
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
            .background(Capsule().fill(filled ? tint : tint.opacity(0.15)))
    }

    @ViewBuilder
    private func detailPanel(_ entry: OCRServiceEntry) -> some View {
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

    private func detailHeader(_ entry: OCRServiceEntry) -> some View {
        HStack(spacing: 12) {
            OCRServiceIconView(kind: entry.kind, size: 30)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(entry.displayName)
                        .settingsCardTitleText()
                        .foregroundStyle(AppTheme.textPrimary)
                    if settings.defaultOCRServiceID == entry.id {
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
            if entry.kind == .vision {
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

    // MARK: - Editor

    @ViewBuilder
    private func expandedEditor(_ entry: OCRServiceEntry) -> some View {
        // 全程按 id 取数，避免删除后下标失效崩溃
        let id = entry.id
        VStack(alignment: .leading, spacing: ServiceSettingsVisual.detailSectionSpacing) {
            if entry.kind != .vision {
                labeledField(L10n.string("服务名称")) {
                    TextField(L10n.string("服务名称"), text: nameBinding(id: id))
                        .textFieldStyle(.roundedBorder)
                }
            }

            usageNotice(for: entry.kind)

            switch entry.kind {
            case .vision:
                EmptyView()
            case .volcengine:
                volcengineFields(id: id)
            case .baidu:
                baiduFields(id: id)
            case .tencent:
                tencentFields(id: id)
            case .youdao:
                youdaoFields(id: id)
            case .google:
                googleFields(id: id)
            case .custom:
                customFields(id: id)
            }

            Divider()
                .padding(.vertical, 2)

            HStack(spacing: 12) {
                if entry.kind != .vision {
                    Button {
                        Task { await verify(entryID: id) }
                    } label: {
                        if isVerifying, verifyTargetID == id {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(L10n.string("验证连接"), systemImage: "checkmark.shield")
                        }
                    }
                    .disabled(isVerifying || !canVerify(entry))
                    .controlSize(.small)
                }

                if settings.defaultOCRServiceID == id {
                    Label(L10n.string("当前默认"), systemImage: "star.fill")
                        .settingsBodyText()
                        .foregroundStyle(AppTheme.textSecondary)
                } else {
                    Button {
                        setAsDefault(entry)
                    } label: {
                        Label(L10n.string("设为默认"), systemImage: "star")
                    }
                    .disabled(!canSetDefault(entry))
                    .controlSize(.small)
                }

                Spacer()

                if entry.kind != .vision {
                    // 不用 destructive role，避免 macOS 与确认框叠加异常
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
                    .foregroundStyle(verifyMessage.contains(L10n.string("通过")) ? AppTheme.success : AppTheme.warning)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Field groups（全部按 service id 绑定）

    @ViewBuilder
    private func volcengineFields(id: String) -> some View {
        secureField("Access Key ID", text: volcStringBinding(id: id, keyPath: \.accessKeyID))
        secureField("Secret Access Key", text: volcStringBinding(id: id, keyPath: \.secretAccessKey))
    }

    @ViewBuilder
    private func baiduFields(id: String) -> some View {
        secureField("API Key", text: baiduStringBinding(id: id, keyPath: \.apiKey))
        secureField("Secret Key", text: baiduStringBinding(id: id, keyPath: \.secretKey))
        labeledField(L10n.string("接口版本")) {
            Picker(
                "",
                selection: Binding(
                    get: { entry(id)?.baidu?.endpoint ?? .general },
                    set: { newValue in
                        mutate(id: id) { e in
                            if e.baidu == nil { e.baidu = BaiduOCRConfig() }
                            e.baidu?.endpoint = newValue
                        }
                        flashStatus(L10n.string("已更新接口版本"))
                    }
                )
            ) {
                ForEach(BaiduOCREndpoint.allCases) { ep in
                    Text(ep.title).tag(ep)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 240, alignment: .leading)
        }
    }

    @ViewBuilder
    private func tencentFields(id: String) -> some View {
        secureField("Secret ID", text: tencentStringBinding(id: id, keyPath: \.secretID))
        secureField("Secret Key", text: tencentStringBinding(id: id, keyPath: \.secretKey))
        labeledField(L10n.string("接口版本")) {
            Picker(
                "",
                selection: Binding(
                    get: { entry(id)?.tencent?.endpoint ?? .generalBasic },
                    set: { newValue in
                        mutate(id: id) { e in
                            if e.tencent == nil { e.tencent = TencentOCRConfig() }
                            e.tencent?.endpoint = newValue
                        }
                        flashStatus(L10n.string("已更新接口版本"))
                    }
                )
            ) {
                ForEach(TencentOCREndpoint.allCases) { ep in
                    Text(ep.title).tag(ep)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 200, alignment: .leading)
        }
    }

    @ViewBuilder
    private func youdaoFields(id: String) -> some View {
        secureField("APP Key", text: youdaoStringBinding(id: id, keyPath: \.appKey))
        secureField("APP Secret", text: youdaoStringBinding(id: id, keyPath: \.appSecret))
    }

    @ViewBuilder
    private func googleFields(id: String) -> some View {
        secureField("Key", text: googleStringBinding(id: id, keyPath: \.apiKey))
        labeledField(L10n.string("接口版本")) {
            Picker(
                "",
                selection: Binding(
                    get: { entry(id)?.google?.feature ?? .documentTextDetection },
                    set: { newValue in
                        mutate(id: id) { e in
                            if e.google == nil { e.google = GoogleOCRConfig() }
                            e.google?.feature = newValue
                        }
                        flashStatus(L10n.string("已更新接口版本"))
                    }
                )
            ) {
                ForEach(GoogleOCRFeature.allCases) { f in
                    Text(f.title).tag(f)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 300, alignment: .leading)
            Text((entry(id)?.google?.feature ?? .documentTextDetection).help)
                .settingsBadgeText(weight: .regular)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    @ViewBuilder
    private func customFields(id: String) -> some View {
        labeledField(L10n.string("服务 URL")) {
            TextField("https://example.com/ocr", text: customStringBinding(id: id, keyPath: \.url))
                .textFieldStyle(.roundedBorder)
        }
        labeledField(L10n.string("鉴权")) {
            Picker(
                "",
                selection: Binding(
                    get: { entry(id)?.custom?.authMode ?? .none },
                    set: { mode in
                        mutate(id: id) { e in
                            if e.custom == nil { e.custom = CustomOCRConfig() }
                            e.custom?.authMode = mode
                        }
                        flashStatus(L10n.string("已更新鉴权方式"))
                    }
                )
            ) {
                ForEach(CustomOCRAuthMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 200, alignment: .leading)
        }
        if entry(id)?.custom?.authMode == .bearer {
            secureField("Bearer Token", text: customStringBinding(id: id, keyPath: \.bearerToken))
        }
        if entry(id)?.custom?.authMode == .header {
            labeledField(L10n.string("Header 名")) {
                TextField("X-API-Key", text: customStringBinding(id: id, keyPath: \.headerName))
                    .textFieldStyle(.roundedBorder)
            }
            secureField(L10n.string("Header 值"), text: customStringBinding(id: id, keyPath: \.headerValue))
        }
        Text(L10n.string("POST multipart 字段 image；响应 JSON 优先 lines[{text,x,y,w,h}]，否则 text。"))
            .settingsBadgeText(weight: .regular)
            .foregroundStyle(AppTheme.textTertiary)
    }

    private func entry(_ id: String) -> OCRServiceEntry? {
        settings.ocrServices.first { $0.id == id }
    }

    // MARK: - Status helpers

    private func statusLabel(for entry: OCRServiceEntry) -> String {
        if entry.kind == .vision { return L10n.string("本机可用") }
        if !entry.isReadyToRecognize {
            return entry.isEnabled ? L10n.string("配置未完成") : L10n.string("配置未完成 · 未启用")
        }
        return entry.isEnabled ? L10n.string("配置完整") : L10n.string("配置完整 · 未启用")
    }

    private func statusColor(for entry: OCRServiceEntry) -> Color {
        // 可用态一律绿色：本机 Vision / 配置完整并启用
        if entry.kind == .vision { return AppTheme.success }
        if entry.isEnabled && entry.isReadyToRecognize { return AppTheme.success }
        // 已启用但密钥未齐 → 警告色
        if entry.isEnabled { return AppTheme.warning }
        // 配置完整但未启用 / 其它
        if entry.isReadyToRecognize { return AppTheme.textSecondary }
        return AppTheme.warning
    }

    // MARK: - Mutations

    private func mutate(id: String, _ body: (inout OCRServiceEntry) -> Void) {
        guard let idx = settings.ocrServices.firstIndex(where: { $0.id == id }) else { return }
        var list = settings.ocrServices
        body(&list[idx])
        if let v = list.firstIndex(where: { $0.kind == .vision }) {
            list[v].isEnabled = true
            list[v].id = OCRServiceEntry.visionID
        }
        settings.ocrServices = list
    }

    private func setEnabled(entryID: String, enabled: Bool) {
        guard let entry = services.first(where: { $0.id == entryID }), entry.kind != .vision else { return }
        if enabled {
            if entry.kind.requiresCredentials, !entry.privacyAccepted {
                privacyPendingID = entryID
                return
            }
            mutate(id: entryID) { $0.isEnabled = true }
            flashStatus(L10n.string("已启用"))
        } else {
            mutate(id: entryID) { $0.isEnabled = false }
            if settings.defaultOCRServiceID == entryID {
                settings.setDefaultOCRServiceID(OCRServiceEntry.visionID)
            }
            flashStatus(L10n.string("已关闭"))
        }
        verifyMessage = nil
    }

    private func applyPrivacyAndEnable(id: String) {
        mutate(id: id) { entry in
            entry.privacyAccepted = true
            entry.isEnabled = true
        }
        flashStatus(L10n.string("已启用"))
    }

    private func setAsDefault(_ entry: OCRServiceEntry) {
        guard canSetDefault(entry) else {
            flashStatus(L10n.string("请先启用并完成配置"))
            return
        }
        settings.setDefaultOCRServiceID(entry.id)
        flashStatus(L10n.string("已设为默认"))
    }

    private func canSetDefault(_ entry: OCRServiceEntry) -> Bool {
        if entry.kind == .vision { return true }
        return entry.isEnabled && entry.isReadyToRecognize
    }

    private func canVerify(_ entry: OCRServiceEntry) -> Bool {
        if entry.kind == .vision { return true }
        // 验证不强制已启用，但要有凭证
        switch entry.kind {
        case .baidu: return entry.baidu?.hasCredentials == true
        case .youdao: return entry.youdao?.hasCredentials == true
        case .custom: return entry.custom?.hasEndpoint == true
        case .volcengine: return entry.volcengine?.hasCredentials == true
        case .tencent: return entry.tencent?.hasCredentials == true
        case .google: return entry.google?.hasCredentials == true
        case .vision: return true
        }
    }

    private func addService(kind: OCRServiceKind) {
        guard kind.isImplementable, kind != .vision else { return }
        if let existing = services.first(where: { $0.kind == kind }) {
            withAnimation {
                selectedID = existing.id
            }
            flashStatus(String(format: L10n.string("已添加「%@」"), kind.displayName))
            return
        }
        var list = settings.ocrServices
        let entry = OCRServiceEntry.make(kind: kind)
        list.append(entry)
        settings.ocrServices = list
        withAnimation {
            selectedID = entry.id
        }
        verifyMessage = nil
        flashStatus(String(format: L10n.string("已添加「%@」"), kind.displayName))
    }

    private func performRemove(id: String) {
        guard let target = settings.ocrServices.first(where: { $0.id == id }),
              target.kind != .vision
        else { return }

        // 先收起展开态与校验态，避免 SwiftUI 仍持有已删项的 Binding
        if selectedID == id {
            selectedID = nil
        }
        if verifyTargetID == id {
            verifyTargetID = nil
            verifyMessage = nil
        }

        var list = settings.ocrServices.filter { $0.id != id }
        if !list.contains(where: { $0.kind == .vision }) {
            list.insert(.vision(), at: 0)
        }

        // 先修正默认引擎，再写列表，减少中间态
        if settings.defaultOCRServiceID == id {
            settings.defaultOCRServiceID = OCRServiceEntry.visionID
        }
        settings.ocrServices = list
        ensureSelection()
        flashStatus(String(format: L10n.string("已移除「%@」"), target.displayName))
    }

    private func verify(entryID: String) async {
        guard let entry = services.first(where: { $0.id == entryID }) else { return }
        isVerifying = true
        verifyTargetID = entryID
        verifyMessage = nil
        defer { isVerifying = false }
        do {
            verifyMessage = try await ocrRouter.verify(entry: entry)
        } catch {
            verifyMessage = error.localizedDescription
        }
    }

    private func flashStatus(_ message: String) {
        statusTask?.cancel()
        withAnimation {
            statusHint = message
        }
        statusTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled, statusHint == message {
                withAnimation { statusHint = nil }
            }
        }
    }

    // MARK: - Bindings

    private func nameBinding(id: String) -> Binding<String> {
        Binding(
            get: { entry(id)?.displayName ?? "" },
            set: { newValue in mutate(id: id) { $0.displayName = newValue } }
        )
    }

    private func volcStringBinding(id: String, keyPath: WritableKeyPath<VolcengineOCRConfig, String>) -> Binding<String> {
        Binding(
            get: { entry(id)?.volcengine?[keyPath: keyPath] ?? "" },
            set: { newValue in
                mutate(id: id) { e in
                    if e.volcengine == nil { e.volcengine = VolcengineOCRConfig() }
                    e.volcengine?[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func baiduStringBinding(id: String, keyPath: WritableKeyPath<BaiduOCRConfig, String>) -> Binding<String> {
        Binding(
            get: { entry(id)?.baidu?[keyPath: keyPath] ?? "" },
            set: { newValue in
                mutate(id: id) { e in
                    if e.baidu == nil { e.baidu = BaiduOCRConfig() }
                    e.baidu?[keyPath: keyPath] = newValue
                    if keyPath == \.apiKey || keyPath == \.secretKey {
                        e.baidu?.accessToken = ""
                        e.baidu?.tokenExpiryMs = 0
                    }
                }
            }
        )
    }

    private func tencentStringBinding(id: String, keyPath: WritableKeyPath<TencentOCRConfig, String>) -> Binding<String> {
        Binding(
            get: { entry(id)?.tencent?[keyPath: keyPath] ?? "" },
            set: { newValue in
                mutate(id: id) { e in
                    if e.tencent == nil { e.tencent = TencentOCRConfig() }
                    e.tencent?[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func youdaoStringBinding(id: String, keyPath: WritableKeyPath<YoudaoOCRConfig, String>) -> Binding<String> {
        Binding(
            get: { entry(id)?.youdao?[keyPath: keyPath] ?? "" },
            set: { newValue in
                mutate(id: id) { e in
                    if e.youdao == nil { e.youdao = YoudaoOCRConfig() }
                    e.youdao?[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func googleStringBinding(id: String, keyPath: WritableKeyPath<GoogleOCRConfig, String>) -> Binding<String> {
        Binding(
            get: { entry(id)?.google?[keyPath: keyPath] ?? "" },
            set: { newValue in
                mutate(id: id) { e in
                    if e.google == nil { e.google = GoogleOCRConfig() }
                    e.google?[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func customStringBinding(id: String, keyPath: WritableKeyPath<CustomOCRConfig, String>) -> Binding<String> {
        Binding(
            get: { entry(id)?.custom?[keyPath: keyPath] ?? "" },
            set: { newValue in
                mutate(id: id) { e in
                    if e.custom == nil { e.custom = CustomOCRConfig() }
                    e.custom?[keyPath: keyPath] = newValue
                }
            }
        )
    }

    // MARK: - UI helpers

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
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
            SecureField(title, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func usageNotice(for kind: OCRServiceKind) -> some View {
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
                    if let help = helpURL(for: kind) {
                        TutorialLinkButton(destination: help)
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

    private func helpURL(for kind: OCRServiceKind) -> URL? {
        switch kind {
        case .volcengine:
            URL(string: "https://www.volcengine.com/docs/6790/117930")
        case .baidu:
            URL(string: "https://cloud.baidu.com/doc/OCR/s/dk3iqnq51")
        case .tencent:
            URL(string: "https://cloud.tencent.com/document/product/866/33526")
        case .youdao:
            URL(string: "https://ai.youdao.com/doc.s#guide")
        case .google:
            URL(string: "https://cloud.google.com/vision/docs/ocr")
        default:
            nil
        }
    }

    private func usageNote(for kind: OCRServiceKind) -> String {
        switch kind {
        case .vision:
            return L10n.string("系统内置离线识别，无需密钥。")
        case .volcengine:
            return L10n.string("使用本服务需自行申请 Access Key ID / Secret Access Key。图像将上传至火山引擎。")
        case .baidu:
            return L10n.string("使用本服务需自行申请密钥并填到下方。图像将上传至百度云 OCR。")
        case .tencent:
            return L10n.string("使用本服务需自行申请 SecretId / SecretKey。图像将上传至腾讯云 OCR。")
        case .youdao:
            return L10n.string("创建应用时选择光学字符识别 · 通用文字识别（API）。图像将上传至有道。")
        case .google:
            return L10n.string("使用 Google Cloud Vision API Key。图像将上传至 Google。")
        case .custom:
            return L10n.string("接入自建或兼容约定的 HTTP OCR。图像将 POST 至你配置的 URL。")
        }
    }
}

// MARK: - Catalog sheet

private struct OCRServiceCatalogSheet: View {
    let existingKinds: Set<OCRServiceKind>
    var onPick: (OCRServiceKind) -> Void
    var onComingSoon: (String) -> Void
    var onCancel: () -> Void
    @State private var hoveredKind: OCRServiceKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("添加 OCR 服务"))
                        .font(.title3.bold())
                        .dynamicTypeSize(SettingsTypography.contentTypeRange)
                    Text(L10n.string("选择要接入的识别引擎，同类型服务仅可添加一个"))
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
                VStack(alignment: .leading, spacing: 16) {
                    catalogSectionTitle(L10n.string("云服务"))
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                        spacing: 12
                    ) {
                        ForEach(OCRServiceKind.catalogAddable, id: \.self) { kind in
                            let exists = existingKinds.contains(kind)
                            catalogChip(
                                kind: kind,
                                subtitle: exists ? L10n.string("已添加") : L10n.string("点击添加"),
                                enabled: !exists
                            ) {
                                onPick(kind)
                            }
                        }
                    }

                    if !OCRServiceKind.catalogComingSoon.isEmpty {
                        catalogSectionTitle(L10n.string("即将支持"))
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                            spacing: 12
                        ) {
                            ForEach(OCRServiceKind.catalogComingSoon, id: \.self) { kind in
                                catalogChip(
                                    kind: kind,
                                    subtitle: L10n.string("即将支持"),
                                    enabled: true,
                                    dimmed: true
                                ) {
                                    onComingSoon(kind.displayName)
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

    private func catalogSectionTitle(_ title: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .settingsCompactText(weight: .semibold)
                .foregroundStyle(AppTheme.textSecondary)
            Rectangle()
                .fill(AppTheme.separator)
                .frame(height: 1)
        }
    }

    private func catalogChip(
        kind: OCRServiceKind,
        subtitle: String,
        enabled: Bool,
        dimmed: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                OCRServiceIconView(kind: kind, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.displayName)
                        .settingsCardTitleText()
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 4) {
                        Image(systemName: dimmed
                            ? "clock"
                            : (enabled ? "plus.circle" : "checkmark.circle.fill"))
                            .settingsBadgeText(weight: .semibold)
                        Text(subtitle)
                    }
                    .settingsBadgeText(weight: .medium)
                    .foregroundStyle(dimmed ? AppTheme.warning : (enabled ? AppTheme.textSecondary : AppTheme.success))
                }
                Spacer()
            }
        }
        .buttonStyle(
            ServiceCatalogCardStyle(
                isHovered: hoveredKind == kind,
                isDisabled: !enabled && !dimmed,
                isDimmed: dimmed
            )
        )
        .disabled(!enabled && !dimmed)
        .onHover { hovering in
            guard enabled || dimmed else {
                NSCursor.arrow.set()
                return
            }
            hoveredKind = hovering ? kind : (hoveredKind == kind ? nil : hoveredKind)
            updateHandCursor(hovering)
        }
    }
}
