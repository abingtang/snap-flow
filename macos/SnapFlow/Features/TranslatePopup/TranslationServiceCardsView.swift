import AppKit
import SwiftUI

/// 多翻译服务结果列表（划词弹层 / 截图翻译结果窗复用）。
struct TranslationServiceCardsView: View {
    let items: [TranslateServiceResultItem]
    var canRetranslate: Bool = true
    var onCopy: (String) -> Void = { _ in }
    var onRetranslate: (() -> Void)? = nil
    var onRetryService: ((String) -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil
    /// 收藏当前译文文本
    var onFavorite: ((String) -> Void)? = nil

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    TranslationServiceResultCard(
                        item: item,
                        canRetranslate: canRetranslate,
                        onCopy: onCopy,
                        onRetranslate: onRetranslate,
                        onRetryService: onRetryService,
                        onOpenSettings: onOpenSettings,
                        onFavorite: onFavorite
                    )
                }
            }
            .padding(10)
        }
    }
}

/// 单张服务译文卡：折叠标题 + 正文 / 状态 + 复制 / 重新翻译 / 收藏
struct TranslationServiceResultCard: View {
    @Bindable var item: TranslateServiceResultItem
    var canRetranslate: Bool = true
    var onCopy: (String) -> Void
    var onRetranslate: (() -> Void)? = nil
    var onRetryService: ((String) -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil
    var onFavorite: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    item.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    if let kind = item.kind {
                        TranslationServiceIconView(kind: kind, size: 22)
                    } else {
                        Image(systemName: item.symbolName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppTheme.accent)
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(AppTheme.accent.opacity(0.15))
                            )
                    }

                    Text(item.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)

                    if item.isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    }

                    Spacer(minLength: 4)

                    if !item.isExpanded {
                        Text(item.summaryLine)
                            .font(.system(size: 11))
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1)
                    }

                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.textTertiary)
                        .rotationEffect(.degrees(item.isExpanded ? 0 : -90))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onContinuousHover { phase in
                switch phase {
                case .active: updateHandCursor(true)
                case .ended: updateHandCursor(false)
                }
            }

            if item.isExpanded {
                Group {
                    if item.isLoading && item.text.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(L10n.string("正在翻译…"))
                                .font(.system(size: 12))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    } else if item.text.isEmpty {
                        Text(item.statusMessage ?? L10n.string("暂无译文"))
                            .font(.system(size: 13))
                            .foregroundStyle(AppTheme.textSecondary)
                            .textSelection(.enabled)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.text)
                                .font(.system(size: 13))
                                .foregroundStyle(AppTheme.textPrimary)
                                .multilineTextAlignment(.leading)
                                .lineSpacing(3)
                                .textSelection(.enabled)

                            if let statusMessage = item.statusMessage {
                                Text(statusMessage)
                                    .font(.system(size: 11))
                                    .foregroundStyle(AppTheme.textTertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                        .padding(.bottom, 6)
                    }
                }

                HStack(spacing: 4) {
                    OCRChromeIconButton(
                        symbol: "doc.on.doc",
                        tooltip: L10n.string("复制译文"),
                        action: {
                            let t = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !t.isEmpty else { return }
                            onCopy(item.text)
                        }
                    )
                    .opacity(
                        item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.35 : 1
                    )
                    .disabled(item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let onRetranslate {
                        OCRChromeIconButton(
                            symbol: "arrow.clockwise",
                            tooltip: item.isRetryable
                                ? L10n.string("重试此服务")
                                : L10n.string("重新翻译"),
                            action: {
                                if item.isRetryable, let onRetryService {
                                    onRetryService(item.id)
                                } else {
                                    onRetranslate()
                                }
                            }
                        )
                        .opacity(canRetranslate && !item.isLoading ? 1 : 0.35)
                        .disabled(!canRetranslate || item.isLoading)
                    }
                    if item.canOpenSettings, let onOpenSettings {
                        OCRChromeIconButton(
                            symbol: "gearshape",
                            tooltip: L10n.string("打开翻译服务设置"),
                            action: onOpenSettings
                        )
                    }
                    if let onFavorite {
                        OCRChromeIconButton(
                            symbol: "star",
                            tooltip: L10n.string("收藏译文"),
                            action: {
                                let t = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !t.isEmpty else { return }
                                onFavorite(item.text)
                            }
                        )
                        .opacity(
                            item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? 0.35 : 1
                        )
                        .disabled(
                            item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(AppTheme.border, lineWidth: 1)
                }
        )
    }
}

/// 翻译方向条（源 ↔ 目标）+ 可选「再译」——划词 / 截图翻译复用
struct TranslationDirectionBar: View {
    let sourceTitle: String
    let targetTitle: String
    let sourceSelection: String
    let targetSelection: String
    var showRetranslate: Bool = false
    var canRetranslate: Bool = true
    var onSelectSource: (String) -> Void
    var onSelectTarget: (String) -> Void
    var onSwap: () -> Void
    var onRetranslate: (() -> Void)? = nil

    @State private var hoverSwap = false

    var body: some View {
        HStack(spacing: 0) {
            directionMenu(
                title: sourceTitle,
                selection: sourceSelection,
                options: TranslatePopupLanguageOption.sourceOptions,
                onSelect: onSelectSource
            )

            Button(action: onSwap) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 36, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(
                OCRPressableChromeStyle(
                    isHovered: hoverSwap,
                    idleFill: .clear,
                    hoverFill: AppTheme.textPrimary.opacity(0.10),
                    pressedFill: AppTheme.textPrimary.opacity(0.16),
                    idleForeground: AppTheme.textPrimary.opacity(0.75),
                    hoverForeground: AppTheme.textPrimary
                )
            )
            .help(L10n.string("交换翻译方向"))
            .accessibilityLabel(L10n.string("交换翻译方向"))
            .onHover { hovering in
                hoverSwap = hovering
                updateHandCursor(hovering)
            }

            directionMenu(
                title: targetTitle,
                selection: targetSelection,
                options: TranslatePopupLanguageOption.targetOptions,
                onSelect: onSelectTarget
            )

            if showRetranslate, let onRetranslate {
                Divider()
                    .frame(height: 18)
                    .padding(.horizontal, 4)
                Button(action: onRetranslate) {
                    Text(L10n.string("再译"))
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(
                                    canRetranslate
                                        ? AppTheme.accent.opacity(0.9)
                                        : AppTheme.textPrimary.opacity(0.08)
                                )
                        )
                        .foregroundStyle(canRetranslate ? Color.white : AppTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .disabled(!canRetranslate)
                .help(L10n.string("按当前原文与语言方向重新翻译"))
                .onContinuousHover { phase in
                    guard canRetranslate else { return }
                    switch phase {
                    case .active: updateHandCursor(true)
                    case .ended: updateHandCursor(false)
                    }
                }
                .padding(.trailing, 6)
            }
        }
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.textPrimary.opacity(0.08))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(AppTheme.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func directionMenu(
        title: String,
        selection: String,
        options: [TranslatePopupLanguageOption],
        onSelect: @escaping (String) -> Void
    ) -> some View {
        Menu {
            ForEach(options) { opt in
                Button {
                    onSelect(opt.rawValue)
                } label: {
                    if selection == opt.rawValue
                        || TranslationLanguage.normalize(selection)
                        == TranslationLanguage.normalize(opt.rawValue)
                    {
                        Label(opt.menuTitle, systemImage: "checkmark")
                    } else {
                        Text(opt.menuTitle)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .foregroundStyle(AppTheme.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
    }
}
