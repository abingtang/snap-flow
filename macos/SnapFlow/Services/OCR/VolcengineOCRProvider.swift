import CoreGraphics
import Foundation

/// 火山引擎视觉 OCR（OCRNormal），AK/SK + HMAC-SHA256 签名。
/// 文档：visual.volcengineapi.com，Service=cv，Region=cn-north-1
struct VolcengineOCRProvider: OCRProvider {
    let serviceID: String
    let kind: OCRServiceKind = .volcengine

    private let host = "visual.volcengineapi.com"
    private let region = "cn-north-1"
    private let service = "cv"
    private let action = "OCRNormal"
    private let version = "2020-08-26"

    init(serviceID: String) {
        self.serviceID = serviceID
    }

    func recognize(
        _ image: CGImage,
        languages: [String]?,
        entry: OCRServiceEntry
    ) async throws -> [OCRLine] {
        guard let config = entry.volcengine, config.hasCredentials else {
            throw OCRProviderError.missingCredentials(entry.displayName)
        }
        let prepared = OCRImagePrep.prepareForUpload(image)
        guard let data = OCRImagePrep.jpegData(from: prepared.image)
            ?? OCRImagePrep.pngData(from: prepared.image)
        else {
            throw OCRProviderError.invalidImage
        }
        let base64 = data.base64EncodedString(options: [])
        let ak = config.accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let sk = config.secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)

        // application/x-www-form-urlencoded body
        guard let body = OCRImagePrep.formURLEncodedBody([
            ("image_base64", base64),
        ]) else {
            throw OCRProviderError.invalidImage
        }

        let now = Date()
        let xDate = volcXDate(now)
        let shortDate = String(xDate.prefix(8)) // YYYYMMDD

        let contentType = "application/x-www-form-urlencoded"
        let contentSha256 = OCRCrypto.sha256Hex(body)
        // Query: Action & Version（签名用 canonical query 需排序）
        let query = "Action=\(action)&Version=\(version)"

        let signedHeaders = "content-type;host;x-content-sha256;x-date"
        let canonicalHeaders = [
            "content-type:\(contentType)",
            "host:\(host)",
            "x-content-sha256:\(contentSha256)",
            "x-date:\(xDate)",
        ].joined(separator: "\n") + "\n"

        let canonicalRequest = [
            "POST",
            "/",
            query,
            canonicalHeaders,
            signedHeaders,
            contentSha256,
        ].joined(separator: "\n")

        let credentialScope = "\(shortDate)/\(region)/\(service)/request"
        let stringToSign = [
            "HMAC-SHA256",
            xDate,
            credentialScope,
            OCRCrypto.sha256Hex(canonicalRequest),
        ].joined(separator: "\n")

        let kDate = OCRCrypto.hmacSHA256(key: sk, message: shortDate)
        let kRegion = OCRCrypto.hmacSHA256(key: kDate, message: region)
        let kService = OCRCrypto.hmacSHA256(key: kRegion, message: service)
        let kSigning = OCRCrypto.hmacSHA256(key: kService, message: "request")
        let signature = OCRCrypto.hmacSHA256Hex(key: kSigning, message: stringToSign)

        let authorization =
            "HMAC-SHA256 Credential=\(ak)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        guard let url = URL(string: "https://\(host)/?\(query)") else {
            throw OCRProviderError.network(L10n.string("无法构造火山 OCR URL"))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(xDate, forHTTPHeaderField: "X-Date")
        request.setValue(contentSha256, forHTTPHeaderField: "X-Content-Sha256")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.httpBody = body

        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OCRProviderError.network(L10n.string("无效响应"))
        }
        guard let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any] else {
            let snippet = String(data: respData, encoding: .utf8)?.prefix(200) ?? ""
            throw OCRProviderError.invalidResponse(String(format: L10n.string("非 JSON %@"), String(snippet)))
        }

        // code: 10000 成功；部分接口用 ResponseMetadata.Error
        if let code = json["code"] as? Int, code != 10000 {
            let msg = (json["message"] as? String)
                ?? (json["msg"] as? String)
                ?? "code \(code)"
            throw OCRProviderError.api(msg)
        }
        if let code = json["code"] as? String, code != "10000", Int(code) != 10000 {
            let msg = (json["message"] as? String) ?? code
            throw OCRProviderError.api(msg)
        }
        if let meta = json["ResponseMetadata"] as? [String: Any],
           let err = meta["Error"] as? [String: Any]
        {
            let msg = (err["Message"] as? String) ?? (err["Code"] as? String) ?? L10n.string("火山 API 错误")
            throw OCRProviderError.api(msg)
        }
        if !(200 ... 299).contains(http.statusCode) {
            throw OCRProviderError.api("HTTP \(http.statusCode)")
        }

        let lines = parseLines(json: json, image: prepared.image)
        return prepared.mapLinesToOriginal(lines)
    }

    private func parseLines(json: [String: Any], image: CGImage) -> [OCRLine] {
        let data = (json["data"] as? [String: Any]) ?? json

        // 常见：line_texts + line_rects
        if let texts = data["line_texts"] as? [String] {
            let rects = data["line_rects"] as? [[String: Any]] ?? []
            var lines: [OCRLine] = []
            for (i, text) in texts.enumerated() where !text.isEmpty {
                var box = CGRect.zero
                if i < rects.count {
                    let r = rects[i]
                    let x = number(r["x"]) ?? number(r["X"]) ?? 0
                    let y = number(r["y"]) ?? number(r["Y"]) ?? 0
                    let w = number(r["width"]) ?? number(r["Width"]) ?? 0
                    let h = number(r["height"]) ?? number(r["Height"]) ?? 0
                    box = CGRect(x: x, y: y, width: w, height: h)
                }
                lines.append(OCRLine(text: text, boundingBox: box, confidence: 1))
            }
            if !lines.isEmpty { return lines }
        }

        // ocr_infos
        if let infos = data["ocr_infos"] as? [[String: Any]] {
            var lines: [OCRLine] = []
            for info in infos {
                guard let text = info["text"] as? String, !text.isEmpty else { continue }
                var box = CGRect.zero
                if let rect = info["rect"] as? [[Any]], rect.count >= 4 {
                    let points = rect.compactMap { pair -> CGPoint? in
                        guard let arr = pair as? [Any], arr.count >= 2,
                              let x = number(arr[0]), let y = number(arr[1])
                        else { return nil }
                        return CGPoint(x: x, y: y)
                    }
                    if let minX = points.map(\.x).min(),
                       let maxX = points.map(\.x).max(),
                       let minY = points.map(\.y).min(),
                       let maxY = points.map(\.y).max()
                    {
                        box = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                    }
                }
                lines.append(OCRLine(text: text, boundingBox: box, confidence: 1))
            }
            if !lines.isEmpty { return lines }
        }

        if let text = data["text"] as? String, !text.isEmpty {
            let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            return [OCRLine(text: text, boundingBox: full, confidence: 1)]
        }
        return []
    }

    private func volcXDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
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
