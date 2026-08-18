import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 区域截图结果预览：复制 / 保存 / 关闭。
struct ScreenshotPreviewView: View {
    let image: NSImage
    /// 保存编码质量（-1 自动 / 0…100）；默认无损 PNG。
    var imageQuality: Int = -1
    let onClose: () -> Void
    let onRequestOCR: (() -> Void)?

    @State private var statusText: String = L10n.string("已复制到剪切板")

    init(
        image: NSImage,
        imageQuality: Int = -1,
        onClose: @escaping () -> Void,
        onRequestOCR: (() -> Void)? = nil
    ) {
        self.image = image
        self.imageQuality = imageQuality
        self.onClose = onClose
        self.onRequestOCR = onRequestOCR
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.string("截图预览"))
                    .font(.headline)
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 480, maxHeight: 320)
                .background(AppTheme.surfaceMuted)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppTheme.border, lineWidth: 1)
                )

            HStack(spacing: 10) {
                Button(L10n.string("复制图片")) {
                    copyImage()
                    statusText = L10n.string("已复制到剪切板")
                }
                .keyboardShortcut("c", modifiers: .command)

                Button(L10n.string("保存…")) {
                    saveImage()
                }
                .keyboardShortcut("s", modifiers: .command)

                if let onRequestOCR {
                    Button(L10n.string("识别文字")) {
                        onRequestOCR()
                    }
                }

                Spacer()

                Button(L10n.string("关闭"), action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(minWidth: 360)
        .foregroundStyle(AppTheme.textPrimary)
        .tint(AppTheme.accent)
        .background(AppTheme.windowBackground)
    }

    private func copyImage() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }

    private func saveImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = SnipImageExport.defaultFileName(quality: imageQuality)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            _ = try SnipImageExport.write(image, quality: imageQuality, to: url)
            statusText = L10n.string("已保存")
        } catch {
            statusText = String(format: L10n.string("保存失败：%@"), error.localizedDescription)
        }
    }
}
