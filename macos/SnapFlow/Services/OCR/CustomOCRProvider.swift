import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// 自定义 HTTP OCR：POST multipart `image`；响应兼容 lines[] 或 text。
struct CustomOCRProvider: OCRProvider {
    let serviceID: String
    let kind: OCRServiceKind = .custom

    init(serviceID: String) {
        self.serviceID = serviceID
    }

    func recognize(
        _ image: CGImage,
        languages: [String]?,
        entry: OCRServiceEntry
    ) async throws -> [OCRLine] {
        guard let config = entry.custom, config.hasEndpoint else {
            throw OCRProviderError.missingCredentials(entry.displayName)
        }
        let urlString = config.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlString) else {
            throw OCRProviderError.api(L10n.string("URL 无效"))
        }

        let prepared = OCRImagePrep.prepareForUpload(image)
        guard let png = OCRImagePrep.pngData(from: prepared.image) else {
            throw OCRProviderError.invalidImage
        }

        let boundary = "SnapFlowBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        applyAuth(config, to: &request)

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"image\"; filename=\"ocr.png\"\r\n".data(using: .utf8)!
        )
        body.append("Content-Type: image/png\r\n\r\n".data(using: .utf8)!)
        body.append(png)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OCRProviderError.network(L10n.string("无效响应"))
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw OCRProviderError.api("HTTP \(http.statusCode) \(snippet)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OCRProviderError.invalidResponse(L10n.string("需要 JSON"))
        }
        if let err = json["error"] as? String, !err.isEmpty {
            throw OCRProviderError.api(err)
        }
        if let err = json["error"] as? [String: Any],
           let msg = err["message"] as? String
        {
            throw OCRProviderError.api(msg)
        }

        let lines = parseLines(json: json, image: prepared.image)
        return prepared.mapLinesToOriginal(lines)
    }

    private func applyAuth(_ config: CustomOCRConfig, to request: inout URLRequest) {
        switch config.authMode {
        case .none:
            break
        case .bearer:
            let token = config.bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        case .header:
            let name = config.headerName.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = config.headerValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, !value.isEmpty {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
    }

    private func parseLines(json: [String: Any], image: CGImage) -> [OCRLine] {
        if let linesArr = json["lines"] as? [[String: Any]] {
            var result: [OCRLine] = []
            for item in linesArr {
                let text = (item["text"] as? String) ?? ""
                guard !text.isEmpty else { continue }
                let x = number(item["x"])
                let y = number(item["y"])
                let w = number(item["w"]) ?? number(item["width"]) ?? 0
                let h = number(item["h"]) ?? number(item["height"]) ?? 0
                let box = CGRect(x: x ?? 0, y: y ?? 0, width: w, height: h)
                result.append(OCRLine(text: text, boundingBox: box, confidence: 1))
            }
            if !result.isEmpty { return result }
        }
        if let text = json["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            return [OCRLine(text: text, boundingBox: full, confidence: 1)]
        }
        return []
    }

    private func number(_ any: Any?) -> CGFloat? {
        if let n = any as? CGFloat { return n }
        if let n = any as? Double { return CGFloat(n) }
        if let n = any as? Int { return CGFloat(n) }
        if let n = any as? NSNumber { return CGFloat(truncating: n) }
        if let s = any as? String, let d = Double(s) { return CGFloat(d) }
        return nil
    }
}
