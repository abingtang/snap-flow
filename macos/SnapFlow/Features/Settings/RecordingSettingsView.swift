import SwiftUI

/// 录制偏好：固定目录/FPS/质量说明 + 可配置指针、音频默认、保存策略、文件名、历史限制。
struct RecordingSettingsView: View {
    @Bindable var settings: SettingsStore
    @Environment(\.snapFlowAccent) private var accent

    private static let formControlWidth: CGFloat = 180

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if settings.recordingIndexCorruptedNotice {
                settingsNoticeCard(
                    title: L10n.string("录制历史索引曾损坏"),
                    detail: L10n.string("已备份损坏索引并重建空列表；媒体文件未被删除。关闭本提示不会扫描目录。")
                ) {
                    settings.recordingIndexCorruptedNotice = false
                }
            }

            settingsCard(
                title: L10n.string("保存位置与格式"),
                tip: L10n.string("目录固定为 ~/Movies/SnapFlow/，视频固定 30 FPS、H.264 High，不提供自定义。")
            ) {
                infoRow(
                    title: L10n.string("保存目录"),
                    value: "~/Movies/SnapFlow/",
                    systemImage: "folder",
                    showDivider: true
                )
                infoRow(
                    title: L10n.string("视频参数"),
                    value: "30 FPS · H.264 High",
                    systemImage: "film",
                    showDivider: true
                )
                pickerRow(
                    title: L10n.string("停止后保存"),
                    subtitle: L10n.string("每次询问会记住上次选择；总是 MP4/GIF 也会更新默认选择。GIF 不含音频。"),
                    selection: $settings.recordingSavePreference,
                    systemImage: "square.and.arrow.down"
                ) {
                    ForEach(RecordingSavePreference.allCases) { pref in
                        Text(pref.displayName).tag(pref)
                    }
                }
                toggleRow(
                    title: L10n.string("保存后在访达中显示"),
                    subtitle: L10n.string("默认关闭。"),
                    isOn: $settings.recordingRevealInFinder,
                    systemImage: "eye",
                    showDivider: false
                )
            }

            settingsCard(title: L10n.string("录制内容")) {
                toggleRow(
                    title: L10n.string("录制鼠标指针"),
                    subtitle: L10n.string("仅影响新录制。"),
                    isOn: $settings.recordingShowsCursor,
                    systemImage: "cursorarrow",
                    showDivider: true
                )
                toggleRow(
                    title: L10n.string("默认录制系统声音"),
                    subtitle: L10n.string("首次安装关闭；可在录制 HUD 中随时切换。"),
                    isOn: $settings.recordingSystemAudioEnabled,
                    systemImage: "speaker.wave.2",
                    showDivider: true
                )
                toggleRow(
                    title: L10n.string("默认录制麦克风"),
                    subtitle: L10n.string("首次安装关闭；首次开启时才请求麦克风权限。"),
                    isOn: $settings.recordingMicrophoneEnabled,
                    systemImage: "mic",
                    showDivider: false
                )
            }

            settingsCard(
                title: L10n.string("文件名"),
                tip: L10n.string("令牌：{date} {time} {counter} {rand} {type}；也支持 {yyyy}/{yy}/{MM}/{dd}/{HH}/{mm}/{ss}。")
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(L10n.string("文件名模板"), text: $settings.recordingFilenameTemplate)
                        .textFieldStyle(.roundedBorder)
                    Text(String(format: L10n.string("预览：%@"), previewFileName))
                        .font(.caption.monospaced())
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .padding(.vertical, 8)
            }

            settingsCard(title: L10n.string("录制历史")) {
                toggleRow(
                    title: L10n.string("记录到历史"),
                    subtitle: L10n.string("关闭后仍保存媒体到 ~/Movies/SnapFlow/，但不登记、不生成缩略图、不清理。已有记录可在「历史 → 录制历史」浏览。"),
                    isOn: $settings.recordingHistoryEnabled,
                    systemImage: "clock.arrow.circlepath",
                    showDivider: true
                )
                stepperRow(
                    title: L10n.string("数量上限"),
                    subtitle: L10n.string("默认 20；0 表示不按条数清理。"),
                    value: $settings.recordingHistoryLimit,
                    range: 0...200,
                    showDivider: true
                )
                mediaLimitRow
                Text(L10n.string("保留天数与截图/OCR/翻译共用「通用 → 功能历史」。清理优先最旧未收藏项。"))
                    .settingsBodyText()
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.vertical, 8)
            }

            settingsCard(title: L10n.string("恢复默认")) {
                HStack {
                    Button(L10n.string("恢复录制推荐默认值")) {
                        settings.restoreRecordingDefaults()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var previewFileName: String {
        RecordingFilenameTemplate.render(
            template: settings.recordingFilenameTemplate,
            fileExtension: settings.recordingLastSaveFormat.fileExtension,
            counter: 1
        )
    }

    private var mediaLimitRow: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string("媒体总大小上限"))
                    .settingsRowTitleText()
                Text(L10n.string("默认 5 GB；0 表示不按大小清理。"))
                    .settingsBodyText()
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Picker(
                "",
                selection: Binding(
                    get: { mediaLimitOption(for: settings.recordingHistoryMaxMediaBytes) },
                    set: { settings.recordingHistoryMaxMediaBytes = $0.bytes }
                )
            ) {
                ForEach(MediaLimitOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: Self.formControlWidth, alignment: .trailing)
        }
        .padding(.vertical, 10)
    }

    // MARK: - Row helpers（对齐 SettingsView 风格的精简版）

    private func settingsCard(
        title: String,
        tip: String? = nil,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .padding(.bottom, 8)
            if let tip {
                Text(tip)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.bottom, 8)
            }
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppTheme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(AppTheme.border.opacity(0.35), lineWidth: 1)
                )
        }
    }

    private func settingsNoticeCard(
        title: String,
        detail: String,
        onDismiss: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            Button(L10n.string("知道了"), action: onDismiss)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.warning.opacity(0.12))
        )
    }

    private func infoRow(
        title: String,
        value: String,
        systemImage: String,
        showDivider: Bool
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(accent)
                    .frame(width: 20)
                Text(title).settingsRowTitleText()
                Spacer()
                Text(value)
                    .font(.body.monospaced())
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(.vertical, 10)
            if showDivider { Divider().opacity(0.28) }
        }
    }

    private func toggleRow(
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        systemImage: String,
        showDivider: Bool
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(accent)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).settingsRowTitleText()
                    Text(subtitle)
                        .settingsBodyText()
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .padding(.vertical, 10)
            if showDivider { Divider().opacity(0.28) }
        }
    }

    private func pickerRow<T: Hashable>(
        title: String,
        subtitle: String,
        selection: Binding<T>,
        systemImage: String,
        @ViewBuilder options: () -> some View
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(accent)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).settingsRowTitleText()
                    Text(subtitle)
                        .settingsBodyText()
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Picker("", selection: selection) {
                    options()
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: Self.formControlWidth, alignment: .trailing)
            }
            .padding(.vertical, 10)
            Divider().opacity(0.28)
        }
    }

    private func stepperRow(
        title: String,
        subtitle: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        showDivider: Bool
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "number")
                    .foregroundStyle(accent)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).settingsRowTitleText()
                    Text(subtitle)
                        .settingsBodyText()
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Stepper(value: value, in: range) {
                    Text("\(value.wrappedValue)")
                        .font(.body.monospacedDigit())
                        .frame(minWidth: 36, alignment: .trailing)
                }
            }
            .padding(.vertical, 10)
            if showDivider { Divider().opacity(0.28) }
        }
    }

    private enum MediaLimitOption: Int64, CaseIterable, Identifiable {
        case unlimited = 0
        case oneGB = 1_073_741_824
        case twoGB = 2_147_483_648
        case fiveGB = 5_368_709_120
        case tenGB = 10_737_418_240

        var id: Int64 { rawValue }
        var bytes: Int64 { rawValue }

        var title: String {
            switch self {
            case .unlimited: L10n.string("不限制")
            case .oneGB: "1 GB"
            case .twoGB: "2 GB"
            case .fiveGB: "5 GB"
            case .tenGB: "10 GB"
            }
        }
    }

    private func mediaLimitOption(for bytes: Int64) -> MediaLimitOption {
        MediaLimitOption.allCases.first { $0.bytes == bytes } ?? .fiveGB
    }
}
