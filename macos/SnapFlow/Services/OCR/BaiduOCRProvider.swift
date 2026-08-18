import CoreGraphics
import Foundation

/// 百度文字识别（含位置）：general / accurate。
struct BaiduOCRProvider: OCRProvider {
    let serviceID: String
    let kind: OCRServiceKind = .baidu

    /// 识别成功后回写 token 缓存
    var onTokenUpdate: (@Sendable (String, BaiduOCRConfig) -> Void)?

    init(serviceID: String, onTokenUpdate: (@Sendable (String, BaiduOCRConfig) -> Void)? = nil) {
        self.serviceID = serviceID
        self.onTokenUpdate = onTokenUpdate
    }

    func recognize(
        _ image: CGImage,
        languages: [String]?,
        entry: OCRServiceEntry
    ) async throws -> [OCRLine] {
        guard var config = entry.baidu, config.hasCredentials else {
            throw OCRProviderError.missingCredentials(entry.displayName)
        }
        // 先缩放再编码；框坐标按 prepared 回映
        let prepared = OCRImagePrep.prepareForUpload(image)
        // 百度对 form 里 base64 的 `+` 极敏感；用 JPEG + 手工 urlencode（勿用 URLComponents）
        guard let jpeg = OCRImagePrep.jpegData(from: prepared.image)
            ?? OCRImagePrep.pngData(from: prepared.image)
        else {
            throw OCRProviderError.invalidImage
        }
        let base64 = jpeg.base64EncodedString(options: [])
        let token = try await validAccessToken(config: &config, entryID: entry.id)
        let lines = try await requestOCR(token: token, endpoint: config.endpoint, base64Image: base64)
        return prepared.mapLinesToOriginal(lines)
    }

    // MARK: - Token

    private func validAccessToken(config: inout BaiduOCRConfig, entryID: String) async throws -> String {
        let now = Date().timeIntervalSince1970 * 1000
        if !config.accessToken.isEmpty, config.tokenExpiryMs > now + 60_000 {
            return config.accessToken
        }
        let ak = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let sk = config.secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var comps = URLComponents(string: "https://aip.baidubce.com/oauth/2.0/token")!
        comps.queryItems = [
            URLQueryItem(name: "grant_type", value: "client_credentials"),
            URLQueryItem(name: "client_id", value: ak),
            URLQueryItem(name: "client_secret", value: sk),
        ]
        guard let url = comps.url else {
            throw OCRProviderError.network(L10n.string("无法构造 token URL"))
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw OCRProviderError.network(L10n.string("无效响应"))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OCRProviderError.invalidResponse(L10n.string("token 非 JSON"))
        }
        if let token = json["access_token"] as? String, !token.isEmpty {
            let expiresIn = (json["expires_in"] as? Double) ?? 2_592_000
            config.accessToken = token
            config.tokenExpiryMs = now + expiresIn * 1000
            onTokenUpdate?(entryID, config)
            return token
        }
        if http.statusCode != 200 {
            let desc = (json["error_description"] as? String) ?? (json["error"] as? String) ?? "HTTP \(http.statusCode)"
            if desc.contains("unknown client id") {
                throw OCRProviderError.api(L10n.string("API Key 错误"))
            }
            if desc.localizedCaseInsensitiveContains("authentication") {
                throw OCRProviderError.api(L10n.string("Secret Key 错误"))
            }
            throw OCRProviderError.api(desc)
        }
        let desc = (json["error_description"] as? String) ?? (json["error"] as? String) ?? L10n.string("获取 token 失败")
        throw OCRProviderError.api(desc)
    }

    // MARK: - OCR

    private func requestOCR(
        token: String,
        endpoint: BaiduOCREndpoint,
        base64Image: String
    ) async throws -> [OCRLine] {
        var comps = URLComponents(url: endpoint.url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "access_token", value: token)]
        guard let url = comps.url else {
            throw OCRProviderError.network(L10n.string("无法构造 OCR URL"))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        // 注意：URLComponents / URLQueryItem 不会把 base64 的 `+` 编成 %2B，
        // 服务端按 form 解码会把 `+` 当空格 → 216201 image format error
        guard let body = OCRImagePrep.formURLEncodedBody([
            ("image", base64Image),
            ("paragraph", "true"),
            ("detect_direction", "false"),
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
        if let errMsg = json["error_msg"] as? String, !errMsg.isEmpty {
            throw OCRProviderError.api(errMsg)
        }
        if let code = json["error_code"] as? Int, code != 0 {
            let msg = (json["error_msg"] as? String) ?? "error_code \(code)"
            throw OCRProviderError.api(msg)
        }
        if http.statusCode != 200 {
            throw OCRProviderError.api("HTTP \(http.statusCode)")
        }
        guard let words = json["words_result"] as? [[String: Any]] else {
            return []
        }
        var lines: [OCRLine] = []
        for item in words {
            guard let text = item["words"] as? String, !text.isEmpty else { continue }
            var box = CGRect.zero
            if let loc = item["location"] as? [String: Any] {
                let left = cgFloat(loc["left"])
                let top = cgFloat(loc["top"])
                let width = cgFloat(loc["width"])
                let height = cgFloat(loc["height"])
                box = CGRect(x: left, y: top, width: width, height: height)
            }
            lines.append(OCRLine(text: text, boundingBox: box, confidence: 1))
        }
        return lines
    }

    private func cgFloat(_ any: Any?) -> CGFloat {
        if let n = any as? CGFloat { return n }
        if let n = any as? Double { return CGFloat(n) }
        if let n = any as? Int { return CGFloat(n) }
        if let n = any as? NSNumber { return CGFloat(truncating: n) }
        return 0
    }
}
