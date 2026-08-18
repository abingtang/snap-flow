import AppKit
import SwiftUI

/// OCR 服务图标：列表与添加弹窗共用。
/// - 离线 Vision / 自定义：SF Symbol + 主题色徽章（避免灰底灰标）
/// - 云服务：Asset 官方图（原色）
struct OCRServiceIconView: View {
    let kind: OCRServiceKind
    var size: CGFloat = 28

    private var corner: CGFloat { size * 0.22 }

    var body: some View {
        Group {
            switch kind {
            case .vision:
                // 内置离线：靛蓝强调色底 + 白标，深浅色模式都清晰
                systemBadge(
                    symbol: "doc.text.viewfinder",
                    background: AppTheme.accent,
                    foreground: AppTheme.onAccent
                )
            case .custom:
                systemBadge(
                    symbol: "link",
                    background: AppTheme.info,
                    foreground: AppTheme.onAccent
                )
            default:
                brandAsset
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// 与添加弹窗一致的官方品牌图
    @ViewBuilder
    private var brandAsset: some View {
        if NSImage(named: kind.assetIconName) != nil {
            Image(kind.assetIconName)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        } else {
            systemBadge(
                symbol: kind.symbolName,
                background: AppTheme.accentSoft,
                foreground: AppTheme.accent
            )
        }
    }

    private func systemBadge(
        symbol: String,
        background: Color,
        foreground: Color
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(background)
            Image(systemName: symbol)
                // 小尺寸（工具栏 chip）按比例缩放，避免 12pt 下限把 12×12 框撑满
                .font(.system(size: max(7, size * 0.52), weight: .semibold))
                .foregroundStyle(foreground)
                .symbolRenderingMode(.monochrome)
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(foreground.opacity(0.12), lineWidth: 0.5)
        }
    }
}
