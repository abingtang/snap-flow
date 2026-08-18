import CoreGraphics
import Foundation

/// 腾讯云 OCR：GeneralBasicOCR / GeneralAccurateOCR（TC3-HMAC-SHA256）。
struct TencentOCRProvider: OCRProvider {
    let serviceID: String
    let kind: OCRServiceKind = .tencent

    init(serviceID: String) {
        self.serviceID = serviceID
    }

    func recognize(
        _ image: CGImage,
        languages: [String]?,
        entry: OCRServiceEntry
    ) async throws -> [OCRLine] {
        guard let config = entry.tencent, config.hasCredentials else {
            throw OCRProviderError.missingCredentials(entry.displayName)
        }
        let prepared = OCRImagePrep.prepareForUpload(image)
        guard let data = OCRImagePrep.jpegData(from: prepared.image)
            ?? OCRImagePrep.pngData(from: prepared.image)
        else {
            throw OCRProviderError.invalidImage
        }
        let base64 = data.base64EncodedString(options: [])
        let payloadDict: [String: Any] = ["ImageBase64": base64]
        let payloadData = try JSONSerialization.data(withJSONObject: payloadDict, options: [])
        let payload = String(data: payloadData, encoding: .utf8) ?? "{}"

        let secretID = config.secretID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretKey = config.secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = "ocr.tencentcloudapi.com"
        let service = "ocr"
        let action = config.endpoint.action
        let version = "2018-11-19"
        let region = config.region.isEmpty ? "ap-guangzhou" : config.region
        let timestamp = Int(Date().timeIntervalSince1970)
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let date = dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))

        let hashedPayload = OCRCrypto.sha256Hex(payloadData)
        let canonicalHeaders = "content-type:application/json; charset=utf-8\nhost:\(host)\nx-tc-action:\(action.lowercased())\n"
        let signedHeaders = "content-type;host;x-tc-action"
        let canonicalRequest = [
            "POST",
            "/",
            "",
            canonicalHeaders,
            signedHeaders,
            hashedPayload,
        ].joined(separator: "\n")

        let credentialScope = "\(date)/\(service)/tc3_request"
        let stringToSign = [
            "TC3-HMAC-SHA256",
            "\(timestamp)",
            credentialScope,
            OCRCrypto.sha256Hex(canonicalRequest),
        ].joined(separator: "\n")

        let secretDate = OCRCrypto.hmacSHA256(key: "TC3" + secretKey, message: date)
        let secretService = OCRCrypto.hmacSHA256(key: secretDate, message: service)
        let secretSigning = OCRCrypto.hmacSHA256(key: secretService, message: "tc3_request")
        let signature = OCRCrypto.hmacSHA256Hex(key: secretSigning, message: stringToSign)

        let authorization =
            "TC3-HMAC-SHA256 Credential=\(secretID)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var request = URLRequest(url: URL(string: "https://\(host)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("\(timestamp)", forHTTPHeaderField: "X-TC-Timestamp")
        request.setValue(version, forHTTPHeaderField: "X-TC-Version")
        request.setValue(action, forHTTPHeaderField: "X-TC-Action")
        request.setValue(region, forHTTPHeaderField: "X-TC-Region")
        request.httpBody = payloadData

        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OCRProviderError.network(L10n.string("无效响应"))
        }
        guard let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any] else {
            throw OCRProviderError.invalidResponse(L10n.string("非 JSON"))
        }
        if let err = (json["Response"] as? [String: Any])?["Error"] as? [String: Any] {
            let msg = (err["Message"] as? String) ?? (err["Code"] as? String) ?? L10n.string("未知错误")
            throw OCRProviderError.api(msg)
        }
        if !(200 ... 299).contains(http.statusCode) {
            throw OCRProviderError.api("HTTP \(http.statusCode)")
        }
        guard let resp = json["Response"] as? [String: Any],
              let detections = resp["TextDetections"] as? [[String: Any]]
        else {
            return []
        }

        var lines: [OCRLine] = []
        for item in detections {
            guard let text = item["DetectedText"] as? String, !text.isEmpty else { continue }
            var box = CGRect.zero
            if let poly = item["Polygon"] as? [[String: Any]], !poly.isEmpty {
                let xs = poly.compactMap { number($0["X"]) }
                let ys = poly.compactMap { number($0["Y"]) }
                if let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() {
                    box = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                }
            } else if let itemPoly = item["ItemPolygon"] as? [String: Any] {
                let x = number(itemPoly["X"]) ?? 0
                let y = number(itemPoly["Y"]) ?? 0
                let w = number(itemPoly["Width"]) ?? 0
                let h = number(itemPoly["Height"]) ?? 0
                box = CGRect(x: x, y: y, width: w, height: h)
            }
            let conf = Float(number(item["Confidence"]) ?? 1)
            lines.append(OCRLine(text: text, boundingBox: box, confidence: conf > 1 ? conf / 100 : conf))
        }
        return prepared.mapLinesToOriginal(lines)
    }

    private func number(_ any: Any?) -> CGFloat? {
        if let n = any as? CGFloat { return n }
        if let n = any as? Double { return CGFloat(n) }
        if let n = any as? Int { return CGFloat(n) }
        if let n = any as? NSNumber { return CGFloat(truncating: n) }
        return nil
    }
}
