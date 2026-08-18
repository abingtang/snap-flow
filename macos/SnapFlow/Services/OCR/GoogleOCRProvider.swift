import CoreGraphics
import Foundation

/// Google Cloud Vision REST：TEXT_DETECTION / DOCUMENT_TEXT_DETECTION（API Key）。
struct GoogleOCRProvider: OCRProvider {
    let serviceID: String
    let kind: OCRServiceKind = .google

    init(serviceID: String) {
        self.serviceID = serviceID
    }

    func recognize(
        _ image: CGImage,
        languages: [String]?,
        entry: OCRServiceEntry
    ) async throws -> [OCRLine] {
        guard let config = entry.google, config.hasCredentials else {
            throw OCRProviderError.missingCredentials(entry.displayName)
        }
        let prepared = OCRImagePrep.prepareForUpload(image)
        guard let data = OCRImagePrep.jpegData(from: prepared.image)
            ?? OCRImagePrep.pngData(from: prepared.image)
        else {
            throw OCRProviderError.invalidImage
        }
        let base64 = data.base64EncodedString(options: [])
        let apiKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let feature = config.feature.apiType

        let body: [String: Any] = [
            "requests": [
                [
                    "image": ["content": base64],
                    "features": [["type": feature]],
                ],
            ],
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [])

        var comps = URLComponents(string: "https://vision.googleapis.com/v1/images:annotate")!
        comps.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = comps.url else {
            throw OCRProviderError.network(L10n.string("无法构造 Google Vision URL"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OCRProviderError.network(L10n.string("无效响应"))
        }
        guard let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any] else {
            throw OCRProviderError.invalidResponse(L10n.string("非 JSON"))
        }
        if let err = json["error"] as? [String: Any] {
            let msg = (err["message"] as? String) ?? L10n.string("Google Vision 错误")
            throw OCRProviderError.api(msg)
        }
        if !(200 ... 299).contains(http.statusCode) {
            throw OCRProviderError.api("HTTP \(http.statusCode)")
        }

        guard let responses = json["responses"] as? [[String: Any]],
              let first = responses.first
        else {
            return []
        }
        if let err = first["error"] as? [String: Any] {
            let msg = (err["message"] as? String) ?? L10n.string("识别失败")
            throw OCRProviderError.api(msg)
        }

        // DOCUMENT_TEXT_DETECTION：fullTextAnnotation.pages.blocks...
        if let full = first["fullTextAnnotation"] as? [String: Any] {
            let lines = parseFullText(full)
            if !lines.isEmpty {
                return prepared.mapLinesToOriginal(lines)
            }
        }

        // TEXT_DETECTION：textAnnotations[0] 为全文，后续为块
        if let annotations = first["textAnnotations"] as? [[String: Any]], annotations.count > 1 {
            var lines: [OCRLine] = []
            for item in annotations.dropFirst() {
                guard let text = item["description"] as? String, !text.isEmpty else { continue }
                let box = boundingPolyBox(item["boundingPoly"] as? [String: Any])
                lines.append(OCRLine(text: text, boundingBox: box, confidence: 1))
            }
            return prepared.mapLinesToOriginal(lines)
        }
        if let annotations = first["textAnnotations"] as? [[String: Any]],
           let firstAnn = annotations.first,
           let text = firstAnn["description"] as? String,
           !text.isEmpty
        {
            let box = boundingPolyBox(firstAnn["boundingPoly"] as? [String: Any])
            let fullBox = box == .zero
                ? CGRect(x: 0, y: 0, width: prepared.image.width, height: prepared.image.height)
                : box
            return prepared.mapLinesToOriginal([
                OCRLine(text: text, boundingBox: fullBox, confidence: 1),
            ])
        }
        return []
    }

    private func parseFullText(_ full: [String: Any]) -> [OCRLine] {
        var lines: [OCRLine] = []
        guard let pages = full["pages"] as? [[String: Any]] else {
            if let text = full["text"] as? String, !text.isEmpty {
                return [OCRLine(text: text, boundingBox: .zero, confidence: 1)]
            }
            return []
        }
        for page in pages {
            guard let blocks = page["blocks"] as? [[String: Any]] else { continue }
            for block in blocks {
                guard let paragraphs = block["paragraphs"] as? [[String: Any]] else { continue }
                for para in paragraphs {
                    guard let words = para["words"] as? [[String: Any]] else { continue }
                    var text = ""
                    var boxes: [CGRect] = []
                    for word in words {
                        guard let symbols = word["symbols"] as? [[String: Any]] else { continue }
                        for sym in symbols {
                            if let ch = sym["text"] as? String {
                                text += ch
                            }
                            if let box = optionalBox(sym["boundingBox"] as? [String: Any]) {
                                boxes.append(box)
                            }
                        }
                        text += " "
                    }
                    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let box = unionBoxes(boxes) ?? optionalBox(para["boundingBox"] as? [String: Any]) ?? .zero
                    lines.append(OCRLine(text: text, boundingBox: box, confidence: 1))
                }
            }
        }
        return lines
    }

    private func boundingPolyBox(_ poly: [String: Any]?) -> CGRect {
        guard let vertices = poly?["vertices"] as? [[String: Any]], !vertices.isEmpty else {
            return .zero
        }
        let xs = vertices.compactMap { number($0["x"]) }
        let ys = vertices.compactMap { number($0["y"]) }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max()
        else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func optionalBox(_ box: [String: Any]?) -> CGRect? {
        guard let box else { return nil }
        // vertices style
        if box["vertices"] != nil {
            let r = boundingPolyBox(box)
            return r == .zero ? nil : r
        }
        return nil
    }

    private func unionBoxes(_ boxes: [CGRect]) -> CGRect? {
        guard !boxes.isEmpty else { return nil }
        return boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
    }

    private func number(_ any: Any?) -> CGFloat? {
        if let n = any as? CGFloat { return n }
        if let n = any as? Double { return CGFloat(n) }
        if let n = any as? Int { return CGFloat(n) }
        if let n = any as? NSNumber { return CGFloat(truncating: n) }
        return nil
    }
}
