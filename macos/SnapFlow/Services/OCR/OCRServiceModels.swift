import Foundation

// MARK: - Service kinds

/// OCR 服务类型（与参考设置页对齐）。
enum OCRServiceKind: String, Codable, CaseIterable, Sendable {
    case vision
    case volcengine
    case baidu
    case tencent
    case youdao
    case google
    case custom

    var displayName: String {
        switch self {
        case .vision: L10n.string("离线文本识别")
        case .volcengine: L10n.string("火山 OCR")
        case .baidu: L10n.string("百度 OCR")
        case .tencent: L10n.string("腾讯 OCR")
        case .youdao: L10n.string("有道 OCR")
        case .google: "Google OCR"
        case .custom: L10n.string("自定义 OCR")
        }
    }

    var symbolName: String {
        switch self {
        case .vision: "doc.text.image"
        case .volcengine: "mountain.2"
        case .baidu: "b.circle"
        case .tencent: "cloud"
        case .youdao: "y.circle"
        case .google: "g.circle"
        case .custom: "link"
        }
    }

    /// Asset catalog 中的品牌图标名（仅云服务；Vision/自定义走 SF Symbol）。
    var assetIconName: String {
        switch self {
        case .vision, .custom: ""
        case .volcengine: "OCRIconVolcengine"
        case .baidu: "OCRIconBaidu"
        case .tencent: "OCRIconTencent"
        case .youdao: "OCRIconYoudao"
        case .google: "OCRIconGoogle"
        }
    }

    var isBuiltIn: Bool { self == .vision }

    var isImplementable: Bool { true }

    var requiresCredentials: Bool {
        switch self {
        case .vision: false
        default: true
        }
    }

    /// 添加目录顺序（对齐参考图）
    static var catalogAddable: [OCRServiceKind] {
        [.volcengine, .baidu, .tencent, .youdao, .google, .custom]
    }

    static var catalogComingSoon: [OCRServiceKind] { [] }
}

// MARK: - Baidu

enum BaiduOCREndpoint: String, Codable, CaseIterable, Identifiable, Sendable {
    case general
    case accurate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L10n.string("标准含位置版")
        case .accurate: L10n.string("高精度含位置版")
        }
    }

    var url: URL {
        switch self {
        case .general:
            URL(string: "https://aip.baidubce.com/rest/2.0/ocr/v1/general")!
        case .accurate:
            URL(string: "https://aip.baidubce.com/rest/2.0/ocr/v1/accurate")!
        }
    }
}

struct BaiduOCRConfig: Codable, Equatable, Sendable {
    var apiKey: String = ""
    var secretKey: String = ""
    var endpoint: BaiduOCREndpoint = .general
    var accessToken: String = ""
    var tokenExpiryMs: Double = 0

    var hasCredentials: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Youdao

struct YoudaoOCRConfig: Codable, Equatable, Sendable {
    var appKey: String = ""
    var appSecret: String = ""

    var hasCredentials: Bool {
        !appKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !appSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Volcengine (火山)

struct VolcengineOCRConfig: Codable, Equatable, Sendable {
    var accessKeyID: String = ""
    var secretAccessKey: String = ""

    var hasCredentials: Bool {
        !accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Tencent

enum TencentOCREndpoint: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 通用印刷体识别（基础版）
    case generalBasic
    /// 通用印刷体识别（高精度版）
    case generalAccurate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .generalBasic: L10n.string("基础版")
        case .generalAccurate: L10n.string("高精度版")
        }
    }

    var action: String {
        switch self {
        case .generalBasic: "GeneralBasicOCR"
        case .generalAccurate: "GeneralAccurateOCR"
        }
    }
}

struct TencentOCRConfig: Codable, Equatable, Sendable {
    var secretID: String = ""
    var secretKey: String = ""
    var endpoint: TencentOCREndpoint = .generalBasic
    /// 默认广州
    var region: String = "ap-guangzhou"

    var hasCredentials: Bool {
        !secretID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Google

enum GoogleOCRFeature: String, Codable, CaseIterable, Identifiable, Sendable {
    case documentTextDetection
    case textDetection

    var id: String { rawValue }

    var title: String {
        switch self {
        case .documentTextDetection: "DOCUMENT_TEXT_DETECTION"
        case .textDetection: "TEXT_DETECTION"
        }
    }

    var apiType: String {
        switch self {
        case .documentTextDetection: "DOCUMENT_TEXT_DETECTION"
        case .textDetection: "TEXT_DETECTION"
        }
    }

    var help: String {
        switch self {
        case .documentTextDetection: L10n.string("适合文档、PDF 等密集文本")
        case .textDetection: L10n.string("适合标志、海报等一般场景")
        }
    }
}

struct GoogleOCRConfig: Codable, Equatable, Sendable {
    var apiKey: String = ""
    var feature: GoogleOCRFeature = .documentTextDetection

    var hasCredentials: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Custom

enum CustomOCRAuthMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case bearer
    case header

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: L10n.string("无")
        case .bearer: "Bearer Token"
        case .header: L10n.string("自定义 Header")
        }
    }
}

struct CustomOCRConfig: Codable, Equatable, Sendable {
    var url: String = ""
    var authMode: CustomOCRAuthMode = .none
    var bearerToken: String = ""
    var headerName: String = "X-API-Key"
    var headerValue: String = ""

    var hasEndpoint: Bool {
        guard let u = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return u.scheme == "http" || u.scheme == "https"
    }
}

// MARK: - Entry

struct OCRServiceEntry: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var kind: OCRServiceKind
    var displayName: String
    var isEnabled: Bool
    var privacyAccepted: Bool
    var baidu: BaiduOCRConfig?
    var youdao: YoudaoOCRConfig?
    var custom: CustomOCRConfig?
    var volcengine: VolcengineOCRConfig?
    var tencent: TencentOCRConfig?
    var google: GoogleOCRConfig?

    static func vision() -> OCRServiceEntry {
        OCRServiceEntry(
            id: OCRServiceEntry.visionID,
            kind: .vision,
            displayName: OCRServiceKind.vision.displayName,
            isEnabled: true,
            privacyAccepted: true
        )
    }

    static let visionID = "vision"

    static func make(kind: OCRServiceKind) -> OCRServiceEntry {
        var entry = OCRServiceEntry(
            id: kind == .vision ? visionID : UUID().uuidString,
            kind: kind,
            displayName: kind.displayName,
            isEnabled: kind == .vision,
            privacyAccepted: kind == .vision
        )
        switch kind {
        case .vision: break
        case .baidu: entry.baidu = BaiduOCRConfig()
        case .youdao: entry.youdao = YoudaoOCRConfig()
        case .custom: entry.custom = CustomOCRConfig()
        case .volcengine: entry.volcengine = VolcengineOCRConfig()
        case .tencent: entry.tencent = TencentOCRConfig()
        case .google: entry.google = GoogleOCRConfig()
        }
        return entry
    }

    var badgeTitle: String? {
        kind.isBuiltIn ? L10n.string("内置") : (kind.requiresCredentials ? L10n.string("密钥") : nil)
    }

    var isReadyToRecognize: Bool {
        if kind == .vision { return true }
        guard isEnabled, kind.isImplementable else { return false }
        switch kind {
        case .baidu: return baidu?.hasCredentials == true
        case .youdao: return youdao?.hasCredentials == true
        case .custom: return custom?.hasEndpoint == true
        case .volcengine: return volcengine?.hasCredentials == true
        case .tencent: return tencent?.hasCredentials == true
        case .google: return google?.hasCredentials == true
        case .vision: return true
        }
    }
}

// MARK: - Errors

enum OCRProviderError: LocalizedError {
    case serviceNotFound
    case serviceDisabled
    case missingCredentials(String)
    case notImplemented(String)
    case network(String)
    case api(String)
    case invalidResponse(String)
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .serviceNotFound: L10n.string("未找到 OCR 服务，请到设置中配置")
        case .serviceDisabled: L10n.string("该 OCR 服务未启用，请到设置中开启")
        case .missingCredentials(let name): String(format: L10n.string("「%@」缺少有效密钥或地址，请到设置中配置"), name)
        case .notImplemented(let name): String(format: L10n.string("「%@」即将支持"), name)
        case .network(let msg): String(format: L10n.string("网络错误：%@"), msg)
        case .api(let msg): String(format: L10n.string("OCR 服务返回错误：%@"), msg)
        case .invalidResponse(let msg): String(format: L10n.string("OCR 响应无法解析：%@"), msg)
        case .invalidImage: L10n.string("图像无效")
        }
    }
}
