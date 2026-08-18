import CryptoKit
import CoreGraphics
import Foundation

/// 有道通用文字识别 API（`openapi.youdao.com/ocrapi`）。
struct YoudaoOCRProvider: OCRProvider {
    let serviceID: String
    let kind: OCRServiceKind = .youdao

    init(serviceID: String) {
        self.serviceID = serviceID
    }

    func recognize(
        _ image: CGImage,
        languages: [String]?,
        entry: OCRServiceEntry
    ) async throws -> [OCRLine] {
        guard let config = entry.youdao, config.hasCredentials else {
            throw OCRProviderError.missingCredentials(entry.displayName)
        }
        let prepared = OCRImagePrep.prepareForUpload(image)
        guard let imageData = OCRImagePrep.jpegData(from: prepared.image)
            ?? OCRImagePrep.pngData(from: prepared.image)
        else {
            throw OCRProviderError.invalidImage
        }
        let base64 = imageData.base64EncodedString(options: [])
        let appKey = config.appKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let appSecret = config.appSecret.trimmingCharacters(in: .whitespacesAndNewlines)

        let input: String
        if base64.count >= 20 {
            let start = base64.prefix(10)
            let end = base64.suffix(10)
            input = "\(start)\(base64.count)\(end)"
        } else {
            input = base64
        }
        let salt = UUID().uuidString
        let curtime = String(Int(Date().timeIntervalSince1970))
        let signStr = appKey + input + salt + curtime + appSecret
        let sign = sha256Hex(signStr)

        var request = URLRequest(url: URL(string: "https://openapi.youdao.com/ocrapi")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        // 与百度相同：手工 urlencode，避免 base64 中 `+` 被当成空格
        guard let body = OCRImagePrep.formURLEncodedBody([
            ("img", base64),
            ("langType", "auto"),
            ("detectType", "10012"),
            ("imageType", "1"),
            ("appKey", appKey),
            ("docType", "json"),
            ("signType", "v3"),
            ("salt", salt),
            ("sign", sign),
            ("curtime", curtime),
        ]) else {
            throw OCRProviderError.invalidImage
        }
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OCRProviderError.network(L10n.string("无效响应"))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OCRProviderError.invalidResponse(L10n.string("非 JSON"))
        }
        let errorCode = "\(json["errorCode"] ?? "")"
        if errorCode != "0" {
            throw OCRProviderError.api("errorCode \(errorCode)")
        }
        if http.statusCode != 200 {
            throw OCRProviderError.api("HTTP \(http.statusCode)")
        }

        guard let result = json["Result"] as? [String: Any],
              let regions = result["regions"] as? [[String: Any]]
        else {
            return []
        }

        var lines: [OCRLine] = []
        for region in regions {
            guard let regionLines = region["lines"] as? [[String: Any]] else { continue }
            for line in regionLines {
                guard let text = line["text"] as? String, !text.isEmpty else { continue }
                var box = CGRect.zero
                if let bb = line["boundingBox"] as? String {
                    let nums = bb.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    // lt, rt, rb, lb → axis-aligned rect
                    if nums.count >= 8 {
                        let xs = [nums[0], nums[2], nums[4], nums[6]]
                        let ys = [nums[1], nums[3], nums[5], nums[7]]
                        let minX = xs.min() ?? 0
                        let maxX = xs.max() ?? 0
                        let minY = ys.min() ?? 0
                        let maxY = ys.max() ?? 0
                        box = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                    }
                }
                lines.append(OCRLine(text: text, boundingBox: box, confidence: 1))
            }
        }
        return prepared.mapLinesToOriginal(lines)
    }

    private func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
