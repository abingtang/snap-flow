import Foundation

/// 语义化版本 `MAJOR.MINOR.PATCH`。忽略前导 `v` 与 `-` 后的预发布后缀。
struct AppSemanticVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var core = trimmed
        if core.first == "v" || core.first == "V" {
            core.removeFirst()
        }
        if let dash = core.firstIndex(of: "-") {
            core = String(core[..<dash])
        }

        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count) else { return nil }
        guard let major = Int(parts[0]) else { return nil }
        let minor = parts.count > 1 ? Int(parts[1]) : 0
        let patch = parts.count > 2 ? Int(parts[2]) : 0
        guard let minor, let patch else { return nil }

        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }
}

/// 服务器 `latest.json` 清单。未知字段忽略。
struct AppUpdateManifest: Equatable, Sendable {
    var version: String
    var build: String?
    var minOS: String?
    var publishedAt: String?
    var notes: String?
    var notesURL: URL?
    var downloadURL: URL
    var sha256: String?
    var mandatory: Bool
}

enum AppUpdateEvaluation: Equatable, Sendable {
    case upToDate(latest: String)
    case available(AppUpdateManifest)
}

enum AppUpdateCheckError: Error, Equatable, Sendable {
    case invalidResponse
    case invalidManifest
    case invalidCurrentVersion
}

enum AppUpdateManifestParser {
    static func parse(data: Data, contentType: String?) throws -> AppUpdateManifest {
        if looksLikeHTML(data, contentType: contentType) {
            throw AppUpdateCheckError.invalidResponse
        }
        do {
            return try JSONDecoder().decode(AppUpdateManifest.self, from: data)
        } catch let error as AppUpdateCheckError {
            throw error
        } catch {
            throw AppUpdateCheckError.invalidManifest
        }
    }

    private static func looksLikeHTML(_ data: Data, contentType: String?) -> Bool {
        if let contentType, contentType.lowercased().contains("text/html") {
            return true
        }
        let prefix = String(data: data.prefix(80), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return prefix.hasPrefix("<!doctype") || prefix.hasPrefix("<html")
    }
}

enum AppUpdateEvaluator {
    static func evaluate(
        currentVersion: String,
        manifest: AppUpdateManifest
    ) throws -> AppUpdateEvaluation {
        guard let current = AppSemanticVersion(string: currentVersion) else {
            throw AppUpdateCheckError.invalidCurrentVersion
        }
        guard let latest = AppSemanticVersion(string: manifest.version) else {
            throw AppUpdateCheckError.invalidManifest
        }
        if current < latest {
            return .available(manifest)
        }
        return .upToDate(latest: latest.description)
    }
}

struct AppUpdateChecker: Sendable {
    static let defaultFeedURL = URL(string: "https://zeycode.cn/snapflow/downloads/latest.json")!

    var feedURL: URL
    var session: URLSession
    var timeout: TimeInterval

    init(
        feedURL: URL = AppUpdateChecker.defaultFeedURL,
        session: URLSession = .shared,
        timeout: TimeInterval = 10
    ) {
        self.feedURL = feedURL
        self.session = session
        self.timeout = timeout
    }

    func fetchManifest() async throws -> AppUpdateManifest {
        var request = URLRequest(
            url: feedURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AppUpdateCheckError.invalidResponse
        }

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw AppUpdateCheckError.invalidResponse
        }
        return try AppUpdateManifestParser.parse(
            data: data,
            contentType: http.value(forHTTPHeaderField: "Content-Type")
        )
    }

    func check(currentVersion: String) async throws -> AppUpdateEvaluation {
        let manifest = try await fetchManifest()
        return try AppUpdateEvaluator.evaluate(currentVersion: currentVersion, manifest: manifest)
    }
}

extension AppUpdateManifest: Decodable {
    enum CodingKeys: String, CodingKey {
        case version
        case build
        case minOS
        case publishedAt
        case notes
        case notesURL
        case downloadURL
        case sha256
        case mandatory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(String.self, forKey: .version)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard AppSemanticVersion(string: version) != nil else {
            throw AppUpdateCheckError.invalidManifest
        }
        self.version = version
        build = try Self.trim(container.decodeIfPresent(String.self, forKey: .build))
        minOS = try Self.trim(container.decodeIfPresent(String.self, forKey: .minOS))
        publishedAt = try Self.trim(container.decodeIfPresent(String.self, forKey: .publishedAt))
        notes = try Self.trim(container.decodeIfPresent(String.self, forKey: .notes))
        notesURL = try Self.optionalHTTPSURL(container.decodeIfPresent(String.self, forKey: .notesURL))
        guard let downloadURL = try Self.httpsURL(container.decode(String.self, forKey: .downloadURL)) else {
            throw AppUpdateCheckError.invalidManifest
        }
        self.downloadURL = downloadURL
        sha256 = try Self.trim(container.decodeIfPresent(String.self, forKey: .sha256))
        mandatory = try container.decodeIfPresent(Bool.self, forKey: .mandatory) ?? false
    }

    private static func trim(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func httpsURL(_ raw: String) -> URL? {
        guard let trimmed = trim(raw),
              let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https"
        else { return nil }
        return url
    }

    private static func optionalHTTPSURL(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        return httpsURL(raw)
    }
}
