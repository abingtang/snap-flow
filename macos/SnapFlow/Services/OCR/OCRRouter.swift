import CoreGraphics
import Foundation

/// 按服务 ID 路由到各 OCR Provider。
final class OCRRouter: TextRecognizing, @unchecked Sendable {
    private let settings: SettingsStore
    private let visionEngine = OCRService()

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func recognize(_ image: CGImage, languages: [String]?) async throws -> [OCRLine] {
        let id = await MainActor.run { settings.resolvedDefaultOCRServiceID() }
        return try await recognize(image, languages: languages, serviceID: id)
    }

    func recognize(
        _ image: CGImage,
        languages: [String]?,
        serviceID: String
    ) async throws -> [OCRLine] {
        let entry = try await MainActor.run { () throws -> OCRServiceEntry in
            guard let e = settings.ocrService(id: serviceID) else {
                throw OCRProviderError.serviceNotFound
            }
            if e.kind != .vision, !e.isEnabled {
                throw OCRProviderError.serviceDisabled
            }
            if !e.kind.isImplementable {
                throw OCRProviderError.notImplemented(e.displayName)
            }
            if !e.isReadyToRecognize {
                throw OCRProviderError.missingCredentials(e.displayName)
            }
            return e
        }
        return try await run(entry: entry, image: image, languages: languages)
    }

    func verify(entry: OCRServiceEntry) async throws -> String {
        guard let sample = OCRImagePrep.sampleVerificationImage() else {
            throw OCRProviderError.invalidImage
        }
        guard entry.kind.isImplementable else {
            throw OCRProviderError.notImplemented(entry.displayName)
        }
        // 验证不要求 isEnabled，但要有凭证
        var probe = entry
        probe.isEnabled = true
        if entry.kind != .vision, !probe.isReadyToRecognize {
            // isReady requires isEnabled which we set; still need credentials
            switch entry.kind {
            case .baidu where entry.baidu?.hasCredentials != true,
                 .youdao where entry.youdao?.hasCredentials != true,
                 .custom where entry.custom?.hasEndpoint != true,
                 .volcengine where entry.volcengine?.hasCredentials != true,
                 .tencent where entry.tencent?.hasCredentials != true,
                 .google where entry.google?.hasCredentials != true:
                throw OCRProviderError.missingCredentials(entry.displayName)
            default:
                break
            }
        }
        let lines = try await run(entry: probe, image: sample, languages: nil)
        let text = lines.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return L10n.string("验证通过（未识别到文字，但接口可用）")
        }
        let preview = text.count > 80 ? String(text.prefix(80)) + "…" : text
        return String(format: L10n.string("验证通过：%@"), preview)
    }

    private func run(
        entry: OCRServiceEntry,
        image: CGImage,
        languages: [String]?
    ) async throws -> [OCRLine] {
        switch entry.kind {
        case .vision:
            return try await VisionOCRProvider(engine: visionEngine)
                .recognize(image, languages: languages, entry: entry)
        case .baidu:
            let provider = BaiduOCRProvider(serviceID: entry.id) { [weak self] id, config in
                Task { @MainActor in
                    self?.settings.updateBaiduToken(serviceID: id, config: config)
                }
            }
            return try await provider.recognize(image, languages: languages, entry: entry)
        case .youdao:
            return try await YoudaoOCRProvider(serviceID: entry.id)
                .recognize(image, languages: languages, entry: entry)
        case .custom:
            return try await CustomOCRProvider(serviceID: entry.id)
                .recognize(image, languages: languages, entry: entry)
        case .volcengine:
            return try await VolcengineOCRProvider(serviceID: entry.id)
                .recognize(image, languages: languages, entry: entry)
        case .tencent:
            return try await TencentOCRProvider(serviceID: entry.id)
                .recognize(image, languages: languages, entry: entry)
        case .google:
            return try await GoogleOCRProvider(serviceID: entry.id)
                .recognize(image, languages: languages, entry: entry)
        }
    }
}
