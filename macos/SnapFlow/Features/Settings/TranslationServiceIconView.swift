import AppKit
import SwiftUI

/// 翻译服务品牌图标：添加目录与已添加服务卡片共用。
struct TranslationServiceIconView: View {
    let kind: TranslationServiceKind
    var size: CGFloat = 34

    private var cornerRadius: CGFloat { size * 0.22 }

    var body: some View {
        Group {
            if kind == .system {
                // 内置系统翻译：强调色底 + 白标，避免灰底灰球
                systemBadge(
                    symbol: "globe",
                    background: AppTheme.accent,
                    foreground: AppTheme.onAccent
                )
            } else if let assetName, NSImage(named: assetName) != nil {
                Image(assetName)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            } else {
                systemBadge(
                    symbol: kind.symbolName,
                    background: AppTheme.accentSoft,
                    foreground: AppTheme.accent
                )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }

    private var assetName: String? {
        switch kind {
        case .system: nil
        case .baidu: "TranslationIconBaidu"
        case .youdao: "TranslationIconYoudao"
        case .google: "TranslationIconGoogle"
        case .deepl: "TranslationIconDeepl"
        case .microsoft: "TranslationIconMicrosoft"
        case .volcengine: "TranslationIconVolcengine"
        case .tencent: "TranslationIconTencent"
        case .aliyun: "TranslationIconAliyun"
        case .caiyun: "TranslationIconCaiyun"
        case .niutrans: "TranslationIconNiutrans"
        case .amazon: "TranslationIconAmazon"
        case .openai: "TranslationIconOpenAI"
        case .openrouter: "TranslationIconOpenRouter"
        case .deepseek: "TranslationIconDeepSeek"
        case .qwen: "TranslationIconQwen"
        case .zhipu: "TranslationIconZhipu"
        case .siliconflow: "TranslationIconSiliconFlow"
        case .groq: "TranslationIconGroq"
        case .grok: "TranslationIconGrok"
        case .kimi: "TranslationIconKimi"
        case .ollama: "TranslationIconOllama"
        case .lmStudio: "TranslationIconLMStudio"
        }
    }

    private func systemBadge(
        symbol: String,
        background: Color,
        foreground: Color
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(background)
            Image(systemName: symbol)
                // 小尺寸（工具栏 chip）按比例缩放，避免 12pt 下限把 12×12 框撑满
                .font(.system(size: max(7, size * 0.52), weight: .semibold))
                .foregroundStyle(foreground)
                .symbolRenderingMode(.monochrome)
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(foreground.opacity(0.12), lineWidth: 0.5)
        }
    }
}
