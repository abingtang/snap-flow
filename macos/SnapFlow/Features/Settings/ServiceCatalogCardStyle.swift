import SwiftUI

/// OCR 与翻译服务目录共用的卡片反馈。
struct ServiceCatalogCardStyle: ButtonStyle {
    let isHovered: Bool
    let isDisabled: Bool
    var isDimmed: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        isDisabled
                            ? AppTheme.surfaceMuted.opacity(0.34)
                            : (isHovered
                                ? AppTheme.surfaceHover.opacity(0.72)
                                : AppTheme.surface.opacity(0.52))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(
                        isDisabled
                            ? AppTheme.border.opacity(0.28)
                            : AppTheme.border.opacity(isHovered ? 0.72 : 0.46),
                        lineWidth: 0.5
                    )
            )
            .opacity(isDimmed ? 0.52 : (isDisabled ? 0.58 : 1))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

/// 服务设置页的列表筛选。
enum ServiceSettingsListFilter: String, CaseIterable, Identifiable {
    case all
    case enabled
    case needsConfiguration
    case disabled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: L10n.string("全部")
        case .enabled: L10n.string("已启用")
        case .needsConfiguration: L10n.string("待配置")
        case .disabled: L10n.string("未启用")
        }
    }

    func matches(isEnabled: Bool, isReady: Bool) -> Bool {
        switch self {
        case .all: true
        case .enabled: isEnabled
        case .needsConfiguration: !isReady
        case .disabled: !isEnabled
        }
    }
}

/// 服务设置页在足够宽时使用左右分栏；窄窗口自动降为上下布局。
enum ServiceSettingsLayoutMode {
    static let splitMinimumWidth: CGFloat = 600

    static func usesSplit(width: CGFloat) -> Bool {
        width >= splitMinimumWidth
    }
}

/// 服务设置页的视觉层级，列表与详情共用同一套低对比表面。
enum ServiceSettingsVisual {
    static let panelRadius: CGFloat = 12
    static let rowRadius: CGFloat = 10
    static let rowVerticalPadding: CGFloat = 12
    static let rowGap: CGFloat = 10
    static let groupGap: CGFloat = 18
    static let detailPadding: CGFloat = 22
    static let detailSectionSpacing: CGFloat = 16
    static let formRowPadding: CGFloat = 3
    static let listBackground = AppTheme.surfaceMuted.opacity(0.22)
    static let detailBackground = AppTheme.surface.opacity(0.78)
    static let controlBackground = AppTheme.surfaceMuted.opacity(0.58)
    static let normalBorder = AppTheme.border.opacity(0.42)
    static let rowBorder = AppTheme.border.opacity(0.24)
    static let panelBorder = AppTheme.border.opacity(0.48)
    static let selectedFill = AppTheme.accent.opacity(0.13)
    static let selectedBorder = AppTheme.accent.opacity(0.48)
    static let hoverFill = AppTheme.surfaceHover.opacity(0.64)
}

/// 翻译与 OCR 共用的列表工具栏，避免服务数量增长后只能依赖滚动查找。
struct ServiceSettingsListToolbar: View {
    @Binding var searchText: String
    @Binding var filter: ServiceSettingsListFilter
    let enabledCount: Int
    let totalCount: Int

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .settingsCompactText(weight: .medium)
                    .foregroundStyle(AppTheme.textTertiary)
                TextField(L10n.string("搜索服务…"), text: $searchText)
                    .textFieldStyle(.plain)
                    .settingsCompactText()
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .settingsCompactText()
                            .foregroundStyle(AppTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.string("清除搜索"))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(ServiceSettingsVisual.controlBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(ServiceSettingsVisual.normalBorder, lineWidth: 0.5)
            )
            .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 5) {
                Text(L10n.string("筛选"))
                    .settingsBadgeText(weight: .medium)
                    .foregroundStyle(AppTheme.textTertiary)
                Picker(L10n.string("服务筛选"), selection: $filter) {
                    ForEach(ServiceSettingsListFilter.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(ServiceSettingsVisual.controlBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(ServiceSettingsVisual.normalBorder, lineWidth: 0.5)
            )

            Spacer(minLength: 0)

            Text(String(format: L10n.string("已启用 %lld/%lld"), enabledCount, totalCount))
                .settingsBadgeText(weight: .medium)
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(ServiceSettingsVisual.controlBackground)
                )
        }
    }
}

/// 服务设置页的主工具栏：宽窗口单行展示，窄窗口自动分为筛选行与添加行。
struct ServiceSettingsSectionToolbar: View {
    let addSystemImage: String
    @Binding var searchText: String
    @Binding var filter: ServiceSettingsListFilter
    let enabledCount: Int
    let totalCount: Int
    let onAdd: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            compactBar
            stackedBar
        }
    }

    private var compactBar: some View {
        HStack(spacing: 12) {
            ServiceSettingsListToolbar(
                searchText: $searchText,
                filter: $filter,
                enabledCount: enabledCount,
                totalCount: totalCount
            )
            .layoutPriority(1)
            addButton
        }
    }

    private var stackedBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            ServiceSettingsListToolbar(
                searchText: $searchText,
                filter: $filter,
                enabledCount: enabledCount,
                totalCount: totalCount
            )
            HStack {
                Spacer(minLength: 0)
                addButton
            }
        }
    }

    private var addButton: some View {
        Button(action: onAdd) {
            Label(L10n.string("添加服务"), systemImage: addSystemImage)
                .settingsCompactText(weight: .medium)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
    }
}
