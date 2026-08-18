import AppKit
import SwiftUI

/// 设置 → 关于：手动检查 `latest.json`，有新版本则打开下载地址。
struct AboutUpdateCheckView: View {
    let currentVersion: String
    var checker: AppUpdateChecker = AppUpdateChecker()

    @State private var isChecking = false
    @State private var evaluation: AppUpdateEvaluation?
    @State private var didFail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(L10n.string("检查更新")) {
                    Task { await checkNow() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isChecking)
                .pointingHandOnHover(enabled: !isChecking)

                if isChecking {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.string("正在检查更新…"))
                        .settingsBodyText()
                        .foregroundStyle(AppTheme.textSecondary)
                } else if didFail {
                    Text(L10n.string("无法检查更新"))
                        .settingsBodyText()
                        .foregroundStyle(AppTheme.textSecondary)
                } else if let evaluation {
                    statusText(for: evaluation)
                }
            }

            if case .available(let manifest) = evaluation {
                if let notes = manifest.notes {
                    Text(notes)
                        .settingsBodyText()
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(L10n.string("前往下载")) {
                    NSWorkspace.shared.open(manifest.downloadURL)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .pointingHandOnHover()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func statusText(for evaluation: AppUpdateEvaluation) -> some View {
        switch evaluation {
        case .upToDate:
            Text(L10n.string("已是最新版本"))
                .settingsBodyText()
                .foregroundStyle(AppTheme.textSecondary)
        case .available(let manifest):
            Text(String(format: L10n.string("发现新版本 %@"), manifest.version))
                .settingsBodyText()
                .foregroundStyle(AppTheme.textPrimary)
        }
    }

    @MainActor
    private func checkNow() async {
        isChecking = true
        didFail = false
        evaluation = nil
        defer { isChecking = false }

        do {
            evaluation = try await checker.check(currentVersion: currentVersion)
        } catch {
            didFail = true
        }
    }
}
