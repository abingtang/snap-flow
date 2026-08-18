import Foundation
import NaturalLanguage
import Translation

/// 翻译语言解析：设置项 → 实际 BCP-47、检测、与系统 Translation 已装语言对齐。
enum TranslationLanguage {
    /// 目标语言设置：跟随系统首选语言。
    static let systemTargetToken = "system"
    /// 源语言设置：自动检测。
    static let autoSourceToken = "auto"

    // MARK: - Resolve

    /// 解析目标语言码（不含 region 优先）。
    static func resolvedTargetCode(setting: String) -> String {
        let raw = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty || raw == systemTargetToken {
            return systemPreferredLanguageCode()
        }
        return normalize(raw)
    }

    /// 会话 UI 上的目标选项：只反映设置，**不**因智能逻辑改成英语等具体语言。
    /// 空串视为「自动选择」(`system`)。
    static func sessionTargetSelection(
        settingsTarget: String,
        sampleText: String = "",
        sourceSetting: String = autoSourceToken
    ) -> String {
        _ = sampleText
        _ = sourceSetting
        let raw = settingsTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? systemTargetToken : raw
    }

    /// 「自动选择」实际译向：原文≈系统语言 → 对面语言（中→英 / 英→简中）；否则 → 系统首选语言。
    /// 仅用于翻译执行，不写回 UI 选项。
    static func resolveAutoSelectTargetCode(
        sampleText: String,
        sourceSetting: String = autoSourceToken,
        detectedSource: String? = nil
    ) -> String {
        let source = detectedSource
            ?? resolvedSourceCode(setting: sourceSetting, sampleText: sampleText)
            ?? inferLikelySourceCode(from: sampleText)
        let system = systemPreferredLanguageCode()
        if let source, areEquivalent(source, system) {
            return counterLanguage(forSource: source)
        }
        return systemPreferredLanguageCodePreservingRegion()
    }

    /// 解析翻译用的目标 BCP-47：固定语言原样；`system`/空走自动选择逻辑。
    static func resolveEffectiveTargetCode(
        targetSetting: String,
        sampleText: String,
        sourceSetting: String = autoSourceToken,
        detectedSource: String? = nil
    ) -> String {
        let raw = targetSetting.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty || raw == systemTargetToken {
            return resolveAutoSelectTargetCode(
                sampleText: sampleText,
                sourceSetting: sourceSetting,
                detectedSource: detectedSource
            )
        }
        return normalizePreservingRegion(raw)
    }

    /// 同源短路时的对面语言：英语原文 → 简中，其它 → 英语。
    static func counterLanguage(forSource sourceCode: String) -> String {
        if areEquivalent(sourceCode, "en") {
            return "zh-Hans"
        }
        return "en"
    }

    /// 源语言与系统语言相同时的默认目标。
    static func counterLanguageWhenSourceMatchesSystem(_ sourceCode: String?) -> String? {
        guard let sourceCode else { return nil }
        guard areEquivalent(sourceCode, systemPreferredLanguageCode()) else { return nil }
        return counterLanguage(forSource: sourceCode)
    }

    /// 脚本/字符分布粗判：假名→日；谚文→韩；汉字→简中；纯拉丁→英。
    /// 供 NL 失败、短文本、以及 `resolvePair` 候选扩展使用。
    static func inferLikelySourceCode(from text: String) -> String? {
        scriptDetectedLanguage(in: text)?.code
    }

    /// 解析源语言：固定设置 或自动检测。
    static func resolvedSourceCode(setting: String, sampleText: String) -> String? {
        let raw = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty || raw == autoSourceToken {
            return detectLanguageCode(in: sampleText)
        }
        return normalize(raw)
    }

    static func systemPreferredLanguageCode() -> String {
        if let preferred = Locale.preferredLanguages.first, !preferred.isEmpty {
            return normalize(preferred)
        }
        return normalize(Locale.current.identifier)
    }

    /// 系统首选的「完整」标识（尽量保留 region，便于匹配 en-GB 等模型）。
    static func systemPreferredLanguageCodePreservingRegion() -> String {
        if let preferred = Locale.preferredLanguages.first, !preferred.isEmpty {
            return normalizePreservingRegion(preferred)
        }
        return normalizePreservingRegion(Locale.current.identifier)
    }

    static func systemPreferredDisplayName() -> String {
        displayName(for: systemPreferredLanguageCode())
    }

    // MARK: - Detect

    /// 最低接受置信度。过低会把短 OCR 误判成未装语言包的语种。
    private static let minimumDetectionConfidence: Double = 0.35
    /// 短于此长度时优先脚本启发式，NL 仅作弱参考。
    private static let shortTextCharacterLimit = 12
    /// 检测结果缓存条数上限（同文案多次检测 / UI 刷新）。
    private static let detectionCacheLimit = 64
    private static let detectionCacheBox = DetectionCacheBox(limit: detectionCacheLimit)

    private final class DetectionCacheBox: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var map: [String: String?] = [:]
        private var order: [String] = []

        init(limit: Int) {
            self.limit = limit
        }

        func value(for key: String) -> DetectionCacheHit? {
            lock.lock()
            defer { lock.unlock() }
            guard let index = map.index(forKey: key) else { return nil }
            return DetectionCacheHit(value: map[index].value)
        }

        func store(_ value: String?, for key: String) {
            lock.lock()
            defer { lock.unlock() }
            if map.index(forKey: key) == nil {
                order.append(key)
            }
            map[key] = value
            while order.count > limit {
                let old = order.removeFirst()
                map.removeValue(forKey: old)
            }
        }

        func clear() {
            lock.lock()
            defer { lock.unlock() }
            map.removeAll()
            order.removeAll()
        }
    }

    /// 自动识别源语言：脚本优先 → NL（高置信 + hints）→ 粗判；结果带进程内缓存。
    /// - Parameters:
    ///   - text: 样本文本
    ///   - allowedSourceCodes: 若提供，结果必须落在该集合（按 identity 匹配）；不匹配则脚本收敛或返回 nil
    static func detectLanguageCode(
        in text: String,
        preferredAmong allowedSourceCodes: [String]? = nil
    ) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let cacheKey = detectionCacheKey(for: trimmed, allowed: allowedSourceCodes)
        if let hit = detectionCacheBox.value(for: cacheKey) {
            return hit.value
        }

        let raw = detectLanguageCodeUncached(in: trimmed)
        let constrained = constrainDetectedSource(
            raw,
            sampleText: trimmed,
            allowedSourceCodes: allowedSourceCodes
        )
        detectionCacheBox.store(constrained, for: cacheKey)
        return constrained
    }

    /// 无缓存检测（测试/调试可用）。
    /// - Note: 技术标识符（camelCase / kebab-case 等）**不声称**语种，返回 `nil`，UI 显示「未识别」。
    static func detectLanguageCodeUncached(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 标识符：不跑 NL、不猜 en/fr，避免「识别为英语」与系统「无法检测」打架
        if looksLikeTechnicalIdentifier(trimmed) {
            return nil
        }

        let script = scriptDetectedLanguage(in: trimmed)
        let isShort = trimmed.count < shortTextCharacterLimit

        // 强脚本信号（假名/谚文/明显汉字）在短文本上直接信任，避免 NL 把中文判成日语等。
        if let script, script.isStrong {
            if isShort { return script.code }
            // 长文本仍跑 NL：若 NL 高置信且与脚本冲突且脚本非「绝对强」(纯假名/谚文)，再权衡
            if script.isAbsolute {
                return script.code
            }
        }

        let nl = nlDetectedLanguage(in: trimmed)

        if let script {
            if let nl {
                if areEquivalent(script.code, nl.code) {
                    return script.code
                }
                // 文本里几乎没有假名却被判成日语 → 信脚本中文
                if script.isStrong, nl.confidence < 0.55 {
                    return script.code
                }
                if nl.confidence >= 0.55 {
                    return nl.code
                }
                return script.code
            }
            return script.code
        }

        if let nl, nl.confidence >= minimumDetectionConfidence {
            return nl.code
        }

        // 短拉丁：默认英语，避免漂到 fr/de 触发未装语言包
        if isShort, let fallback = inferLikelySourceCode(from: trimmed) {
            return fallback
        }

        if let nl, nl.confidence >= 0.22 {
            return nl.code
        }

        return inferLikelySourceCode(from: trimmed)
    }

    /// 是否像代码/产品标识符（非自然语言句子）。
    /// 命中时语种检测返回 nil，标签显示「未识别」；翻译执行可另做静默兜底。
    static func looksLikeTechnicalIdentifier(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // 多行：每一非空行都像标识符才算
        if trimmed.contains(where: \.isNewline) {
            let lines = trimmed
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { return false }
            return lines.allSatisfy { looksLikeTechnicalIdentifier(String($0)) }
        }

        // 含空白 → 自然短语（如 "hello world"），不当标识符
        if trimmed.contains(where: \.isWhitespace) { return false }

        // 含汉字/假名/谚文 → 自然语言脚本
        let counts = scriptCounts(in: trimmed)
        if counts.han > 0 || counts.kana > 0 || counts.hangul > 0 { return false }

        // 仅允许字母数字与常见连接符
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:"))
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        guard counts.latin >= 2 || trimmed.contains(where: \.isNumber) else { return false }

        // kebab / snake / path / dotted
        if trimmed.contains(where: { "-_./:".contains($0) }) {
            return true
        }
        // camelCase / PascalCase 内部大小写切换
        if trimmed.range(of: #"[a-z][A-Z]"#, options: .regularExpression) != nil {
            return true
        }
        if trimmed.range(of: #"[A-Z]{2,}[a-z]"#, options: .regularExpression) != nil {
            return true
        }
        // 含数字的单 token（api2、user3）
        if trimmed.contains(where: \.isNumber) {
            return true
        }
        return false
    }

    /// 将检测结果收敛到允许的源语集合；用于系统翻译「只在已装语言里选」。
    static func constrainDetectedSource(
        _ detected: String?,
        sampleText: String,
        allowedSourceCodes: [String]?
    ) -> String? {
        guard let allowedSourceCodes, !allowedSourceCodes.isEmpty else {
            return detected.map { normalize($0) }
        }

        let allowedKeys = Set(allowedSourceCodes.map { identityKey($0) })
        func pick(matching code: String) -> String? {
            let key = identityKey(code)
            guard allowedKeys.contains(key) else { return nil }
            // 优先返回调用方给的原始码（可能带 region）
            if let exact = allowedSourceCodes.first(where: { identityKey($0) == key }) {
                return normalizePreservingRegion(exact)
            }
            return normalize(code)
        }

        if let detected, let hit = pick(matching: detected) {
            return hit
        }

        // 脚本兼容：拉丁→en，汉字→zh，假名→ja，谚文→ko
        if let script = scriptDetectedLanguage(in: sampleText) {
            if let hit = pick(matching: script.code) { return hit }
            // 简繁互通：只装了一种中文时用已装的
            if identityKey(script.code).hasPrefix("zh") {
                if let hans = pick(matching: "zh-Hans") { return hans }
                if let hant = pick(matching: "zh-Hant") { return hant }
            }
        }

        // 常见兜底顺序
        for code in ["en", "zh-Hans", "zh-Hant", "ja", "ko"] {
            if let hit = pick(matching: code) { return hit }
        }
        return allowedSourceCodes.first.map { normalizePreservingRegion($0) }
    }

    // MARK: Script / NL helpers

    private struct ScriptDetection {
        let code: String
        /// 有明确文字系统证据（假名/谚文/足够汉字）
        let isStrong: Bool
        /// 几乎可单独定论（假名/谚文为主）
        let isAbsolute: Bool
    }

    private struct NLDetection {
        let code: String
        let confidence: Double
    }

    private struct ScriptCounts {
        var han = 0
        var hiragana = 0
        var katakana = 0
        var hangul = 0
        var latin = 0
        var traditionalHint = 0
        var simplifiedHint = 0

        var kana: Int { hiragana + katakana }
        var letterLike: Int { han + kana + hangul + latin }
    }

    private static func scriptCounts(in text: String) -> ScriptCounts {
        var c = ScriptCounts()
        for scalar in text.unicodeScalars {
            let v = scalar.value
            // CJK Unified + Ext A + Compatibility
            if (0x4E00 ... 0x9FFF).contains(v)
                || (0x3400 ... 0x4DBF).contains(v)
                || (0xF900 ... 0xFAFF).contains(v)
            {
                c.han += 1
                // 常见繁体/简体互异字粗判（非完备，仅启发式）
                // 常见繁简互异字粗判（非完备）
                if "國語東廣會學對發時書長門開關這麼個來為說過還點業電車後無".unicodeScalars.contains(scalar) {
                    c.traditionalHint += 1
                } else if "国语东广会学对发时书长门开关这么个来为说过还点业电车后无".unicodeScalars.contains(scalar) {
                    c.simplifiedHint += 1
                }
            } else if (0x3040 ... 0x309F).contains(v) {
                c.hiragana += 1
            } else if (0x30A0 ... 0x30FF).contains(v) || (0x31F0 ... 0x31FF).contains(v) {
                c.katakana += 1
            } else if (0xAC00 ... 0xD7AF).contains(v) || (0x1100 ... 0x11FF).contains(v) {
                c.hangul += 1
            } else if (0x41 ... 0x5A).contains(v) || (0x61 ... 0x7A).contains(v) {
                c.latin += 1
            }
        }
        return c
    }

    private static func scriptDetectedLanguage(in text: String) -> ScriptDetection? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let c = scriptCounts(in: trimmed)
        guard c.letterLike > 0 else { return nil }

        // 谚文优先
        if c.hangul >= 1, c.hangul >= c.kana, c.hangul * 2 >= max(c.han, 1) || c.hangul >= 2 {
            return ScriptDetection(code: "ko", isStrong: true, isAbsolute: c.hangul >= 2)
        }
        // 假名 → 日语（即使夹杂汉字）
        if c.kana >= 1 {
            let absolute = c.kana >= 2 || (c.kana >= 1 && c.han == 0)
            return ScriptDetection(code: "ja", isStrong: true, isAbsolute: absolute)
        }
        // 汉字且无假名/谚文 → 中文（默认简体；繁体提示足够则繁体）
        if c.han >= 1, c.kana == 0, c.hangul == 0 {
            let code: String
            if c.traditionalHint >= 2, c.traditionalHint > c.simplifiedHint {
                code = "zh-Hant"
            } else {
                code = "zh-Hans"
            }
            let strong = c.han >= 2 || (c.han >= 1 && c.latin == 0)
            return ScriptDetection(code: code, isStrong: strong, isAbsolute: c.han >= 4 && c.latin == 0)
        }
        // 纯拉丁
        if c.latin >= 2, c.han == 0, c.kana == 0, c.hangul == 0 {
            return ScriptDetection(code: "en", isStrong: false, isAbsolute: false)
        }
        return nil
    }

    private static func nlDetectedLanguage(in text: String) -> NLDetection? {
        let recognizer = NLLanguageRecognizer()
        // 收窄到产品真实支持的语种，降低漂到未装语言包语种的概率
        recognizer.languageHints = [
            .english: 0.45,
            .simplifiedChinese: 0.45,
            .traditionalChinese: 0.30,
            .japanese: 0.30,
            .korean: 0.25,
            .french: 0.12,
            .german: 0.12,
            .spanish: 0.12,
        ]
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage else { return nil }
        let hypotheses = recognizer.languageHypotheses(withMaximum: 4)
        let score = hypotheses[dominant] ?? 0
        return NLDetection(code: normalize(dominant.rawValue), confidence: score)
    }

    private static func detectionCacheKey(for text: String, allowed: [String]?) -> String {
        let base: String
        if text.count <= 240 {
            base = text
        } else {
            base = "\(text.prefix(200))|#\(text.count)"
        }
        guard let allowed, !allowed.isEmpty else { return base }
        let allowedPart = allowed.map { identityKey($0) }.sorted().joined(separator: ",")
        return base + "|A:" + allowedPart
    }

    private struct DetectionCacheHit {
        let value: String?
    }

    /// 测试用：清空检测缓存。
    static func clearDetectionCacheForTesting() {
        detectionCacheBox.clear()
    }

    /// 测试用：清空系统语言列表缓存。
    static func clearSupportedLanguagesCacheForTesting() {
        supportedLanguagesCacheBox.clear()
    }

    // MARK: - Equivalence / normalize

    /// 是否视为同一翻译语言（同 language + script；忽略 region）。
    /// `zh-Hans` 与 `zh-Hant` 不相同。
    static func areEquivalent(_ a: String, _ b: String) -> Bool {
        identityKey(a) == identityKey(b)
    }

    static func identityKey(_ code: String) -> String {
        let n = normalize(code)
        let lang = Locale.Language(identifier: n)
        let language = lang.languageCode?.identifier ?? n
        if let script = lang.script?.identifier, !script.isEmpty {
            let scriptKey = script.lowercased()
            // Latn 是大多数字母语言的默认书写系统，纳入 key 会让 `en` 变成 `en-latn` 并破坏等价判断。
            // 中文等需区分 script 的语言保留 Hans/Hant。
            if scriptKey != "latn" {
                return "\(language)-\(script)".lowercased()
            }
        }
        // 中文无 script 时按简体兜底，避免裸 `zh` 与 `zh-Hans` 判成不同
        if language.lowercased() == "zh" {
            return "zh-hans"
        }
        return language.lowercased()
    }

    /// 归一为 Translation / Locale 可用的标识（默认去掉 region）。
    static func normalize(_ code: String) -> String {
        normalizeInternal(code, keepRegion: false)
    }

    /// 尽量保留 region（如 en-GB），便于匹配英国英语翻译模型。
    static func normalizePreservingRegion(_ code: String) -> String {
        normalizeInternal(code, keepRegion: true)
    }

    private static func normalizeInternal(_ code: String, keepRegion: Bool) -> String {
        var s = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return s }
        if let at = s.firstIndex(of: "@") {
            s = String(s[..<at])
        }
        let parts = s.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let first = parts.first, !first.isEmpty else { return s }

        if first.lowercased() == "zh" {
            if parts.count >= 2 {
                let second = parts[1]
                let lower = second.lowercased()
                if lower == "hans" || lower == "cn" || lower == "sg" {
                    return "zh-Hans"
                }
                if lower == "hant" || lower == "tw" || lower == "hk" || lower == "mo" {
                    return "zh-Hant"
                }
            }
            return "zh-Hans"
        }

        if parts.count >= 2 {
            let second = parts[1]
            // ISO 15924 scripts are 4 letters (Hans, Hant, Latn…)
            if second.count == 4, second.first?.isLetter == true {
                if keepRegion, parts.count >= 3 {
                    return "\(first)-\(second)-\(parts[2])"
                }
                return "\(first)-\(second)"
            }
            // region: en-GB / en-US
            if keepRegion, second.count == 2, second.uppercased() == second || second.lowercased() == second {
                return "\(first)-\(second.uppercased())"
            }
        }
        return first
    }

    /// 为 Translation 可用性查询准备候选标识（含 region 变体）。
    /// 用户常装「英语（英国）」= `en-GB`，而检测/设置给的是 `en`，必须交叉尝试。
    static func candidates(for code: String) -> [String] {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var list: [String] = []
        func append(_ c: String) {
            let v = c.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty, !list.contains(where: { $0.caseInsensitiveCompare(v) == .orderedSame }) else { return }
            list.append(v)
        }

        append(normalizePreservingRegion(trimmed))
        append(normalize(trimmed))

        let key = identityKey(trimmed)
        if key == "en" {
            // 系统翻译语言里常见：英语 / 英语（英国）/ 英语（美国）
            append("en")
            append("en-GB")
            append("en-US")
            append("en-AU")
            append("en-CA")
        } else if key == "zh-hans" {
            append("zh-Hans")
            append("zh-CN")
            append("zh")
        } else if key == "zh-hant" {
            append("zh-Hant")
            append("zh-TW")
            append("zh-HK")
        } else if key == "ja" {
            append("ja")
            append("ja-JP")
        }

        return list
    }

    static func displayName(for code: String) -> String {
        if code == systemTargetToken { return L10n.string("跟随系统") }
        if code == autoSourceToken { return L10n.string("自动检测") }
        let n = normalizePreservingRegion(code)
        let locale = Locale.current
        if let name = locale.localizedString(forIdentifier: n) {
            return name
        }
        let fallback = normalize(code)
        if let name = locale.localizedString(forIdentifier: fallback) {
            return name
        }
        if let lang = Locale.Language(identifier: fallback).languageCode?.identifier,
           let name = locale.localizedString(forLanguageCode: lang)
        {
            return name
        }
        return n
    }

    static func localeLanguage(from code: String) -> Locale.Language {
        Locale.Language(identifier: normalizePreservingRegion(code).isEmpty ? normalize(code) : normalizePreservingRegion(code))
    }

    // MARK: - Pair resolution against system Translation models

    struct ResolvedPair: Sendable, Equatable {
        let sourceCode: String
        let targetCode: String
        /// 源语言固定时非 nil；自动检测时可为 nil（交给 TranslationSession）。
        let sourceLanguage: Locale.Language?
        let targetLanguage: Locale.Language
        let availability: Availability
        /// 是否用 nil source 让系统从文本识别
        let useSystemSourceDetection: Bool

        enum Availability: String, Sendable, Equatable {
            case installed
            case supported
            case unsupported
        }
    }

    // MARK: Supported-language list cache

    private static let supportedLanguagesCacheTTL: TimeInterval = 60
    /// 供 async 路径读写；内部 NSLock，避免在 async 上下文直接 lock/unlock。
    private static let supportedLanguagesCacheBox = SupportedLanguagesCacheBox()

    private final class SupportedLanguagesCacheBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cache: (languages: [Locale.Language], loadedAt: Date)?

        func snapshot(ttl: TimeInterval) -> [Locale.Language]? {
            lock.lock()
            defer { lock.unlock() }
            guard let cache, Date().timeIntervalSince(cache.loadedAt) < ttl else { return nil }
            return cache.languages
        }

        func store(_ languages: [Locale.Language]) {
            lock.lock()
            defer { lock.unlock() }
            cache = (languages, Date())
        }

        func clear() {
            lock.lock()
            defer { lock.unlock() }
            cache = nil
        }
    }

    /// 在系统 Translation 支持的语言中，解析最可能已安装的语言对。
    /// 解决：用户装了「英语（英国）」而我们查 `en` 被误判未安装。
    /// 自动源语时：检测结果优先，但始终附带脚本/常见语种候选，避免误检直接撞「语言包缺失」。
    static func resolvePair(
        sourceCode: String?,
        targetCode: String,
        sampleText: String,
        useAutoSource: Bool
    ) async -> ResolvedPair {
        let fallbackSource = sourceCode
            ?? inferLikelySourceCode(from: sampleText)
            ?? "en"
        let fallbackTarget = candidates(for: targetCode).first ?? targetCode

        let availability = LanguageAvailability()
        let supportedList = await cachedSupportedLanguages(using: availability)

        let targetCandidates = expandWithSupported(candidates(for: targetCode), supported: supportedList)
        // 目标按 identity 去重，减少 status 往返
        let primaryTargets = uniqueIdentityPreservingOrder(targetCandidates)

        let sourceSeed = autoSourceCandidateSeeds(
            detected: sourceCode,
            sampleText: sampleText,
            useAutoSource: useAutoSource
        )
        let sourceCandidates: [String]
        if useAutoSource {
            sourceCandidates = expandWithSupported(sourceSeed, supported: supportedList)
        } else if let sourceCode {
            sourceCandidates = expandWithSupported(candidates(for: sourceCode), supported: supportedList)
        } else {
            sourceCandidates = []
        }
        let primarySources = uniqueIdentityPreservingOrder(sourceCandidates)

        var bestSupported: (String, String)?
        var installedSourcesForTarget: [String] = []

        for t in primaryTargets {
            let targetLang = Locale.Language(identifier: t)

            // 文本级状态只查主目标，避免每个 region 变体都跑一遍（慢）
            if useAutoSource,
               t == primaryTargets.first,
               !sampleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                if let textStatus = try? await availability.status(for: sampleText, to: targetLang) {
                    switch textStatus {
                    case .installed:
                        // 本地已检出源语 → 显式传入，避免系统再猜失败弹「无法自动检测」
                        return makeResolvedPair(
                            sourceCode: sourceCode,
                            targetCode: t,
                            targetLanguage: targetLang,
                            availability: .installed,
                            useAutoSource: useAutoSource,
                            sampleText: sampleText
                        )
                    case .supported:
                        if bestSupported == nil {
                            bestSupported = (sourceCode ?? "auto", t)
                        }
                    case .unsupported:
                        break
                    @unknown default:
                        break
                    }
                }
            }

            for s in primarySources {
                if areEquivalent(s, t) { continue }
                let status = await availability.status(
                    from: Locale.Language(identifier: s),
                    to: targetLang
                )
                switch status {
                case .installed:
                    // 自动源语：优先与检测结果同族的已装源语；否则收集后按种子顺序选
                    if useAutoSource {
                        installedSourcesForTarget.append(s)
                        if let sourceCode, areEquivalent(s, sourceCode) {
                            return makeResolvedPair(
                                sourceCode: s,
                                targetCode: t,
                                targetLanguage: targetLang,
                                availability: .installed,
                                useAutoSource: true,
                                sampleText: sampleText
                            )
                        }
                        // 脚本强匹配也立即返回
                        if let script = inferLikelySourceCode(from: sampleText),
                           !looksLikeTechnicalIdentifier(sampleText),
                           areEquivalent(s, script)
                        {
                            return makeResolvedPair(
                                sourceCode: s,
                                targetCode: t,
                                targetLanguage: targetLang,
                                availability: .installed,
                                useAutoSource: true,
                                sampleText: sampleText
                            )
                        }
                        continue
                    }
                    return makeResolvedPair(
                        sourceCode: s,
                        targetCode: t,
                        targetLanguage: targetLang,
                        availability: .installed,
                        useAutoSource: false,
                        sampleText: sampleText
                    )
                case .supported:
                    if bestSupported == nil {
                        bestSupported = (s, t)
                    }
                case .unsupported:
                    continue
                @unknown default:
                    continue
                }
            }

            // 自动源语：本目标下已有已装源语 → 按种子优先级取第一个
            if useAutoSource, !installedSourcesForTarget.isEmpty {
                let ordered = orderCodes(installedSourcesForTarget, preferring: sourceSeed)
                if let best = ordered.first {
                    return makeResolvedPair(
                        sourceCode: best,
                        targetCode: t,
                        targetLanguage: targetLang,
                        availability: .installed,
                        useAutoSource: true,
                        sampleText: sampleText
                    )
                }
            }
            installedSourcesForTarget.removeAll(keepingCapacity: true)
        }

        if let (s, t) = bestSupported {
            let code = (s == "auto") ? (sourceCode ?? "auto") : s
            return makeResolvedPair(
                sourceCode: code,
                targetCode: t,
                targetLanguage: Locale.Language(identifier: t),
                availability: .supported,
                useAutoSource: useAutoSource,
                sampleText: sampleText
            )
        }

        // 自动源语：不要因预检失败直接 unsupported；有本地检出/标识符则显式 source，避免系统弹窗。
        if useAutoSource {
            return makeResolvedPair(
                sourceCode: sourceCode ?? fallbackSource,
                targetCode: primaryTargets.first ?? fallbackTarget,
                targetLanguage: Locale.Language(identifier: primaryTargets.first ?? fallbackTarget),
                availability: .supported,
                useAutoSource: true,
                sampleText: sampleText
            )
        }

        return ResolvedPair(
            sourceCode: fallbackSource,
            targetCode: primaryTargets.first ?? fallbackTarget,
            sourceLanguage: Locale.Language(identifier: fallbackSource),
            targetLanguage: Locale.Language(identifier: primaryTargets.first ?? fallbackTarget),
            availability: .unsupported,
            useSystemSourceDetection: false
        )
    }

    /// 组装语言对：本地已确定源语时**显式**传给 TranslationSession，不再 source:nil 让系统重猜。
    /// - Note: `sourceCode` 为**实际执行**源语（标识符静默 en）。译前 UI 仍靠 `detectLanguageCode==nil` 显示「未识别」；
    ///   译成功后 `applyResult` 用本字段回写「识别为 英语」。
    private static func makeResolvedPair(
        sourceCode: String?,
        targetCode: String,
        targetLanguage: Locale.Language,
        availability: ResolvedPair.Availability,
        useAutoSource: Bool,
        sampleText: String
    ) -> ResolvedPair {
        _ = useAutoSource
        let raw = (sourceCode ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasConcreteSource = !raw.isEmpty && raw != autoSourceToken

        // 执行用源语：有检出用检出；标识符/未识别则静默 en（避免系统弹窗）
        let executionCode: String = {
            if hasConcreteSource { return raw }
            if looksLikeTechnicalIdentifier(sampleText) { return "en" }
            if let inferred = inferLikelySourceCode(from: sampleText) { return inferred }
            return "en"
        }()

        return ResolvedPair(
            sourceCode: executionCode,
            targetCode: targetCode,
            sourceLanguage: Locale.Language(identifier: executionCode),
            targetLanguage: targetLanguage,
            availability: availability,
            useSystemSourceDetection: false
        )
    }

    /// 自动源语候选种子：检测结果 → 脚本粗判 → 常见语种（始终包含，防止误检锁死）。
    private static func autoSourceCandidateSeeds(
        detected: String?,
        sampleText: String,
        useAutoSource: Bool
    ) -> [String] {
        guard useAutoSource else {
            return detected.map { candidates(for: $0) } ?? []
        }

        var seeds: [String] = []
        func appendSeed(_ code: String) {
            let parts = candidates(for: code)
            for p in parts where !seeds.contains(where: { $0.caseInsensitiveCompare(p) == .orderedSame }) {
                seeds.append(p)
            }
        }

        if let detected, !detected.isEmpty, detected != autoSourceToken {
            appendSeed(detected)
        }
        if let script = inferLikelySourceCode(from: sampleText) {
            appendSeed(script)
        }
        // 产品高频 + 系统常装
        for code in ["en", "zh-Hans", "zh-Hant", "ja", "ko", "fr", "de", "es"] {
            appendSeed(code)
        }
        return seeds
    }

    private static func uniqueIdentityPreservingOrder(_ codes: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for code in codes {
            let key = identityKey(code)
            // 同一 identity 只保留第一个（通常是更精确的系统码）
            if seen.insert(key).inserted {
                result.append(code)
            }
        }
        return result
    }

    private static func orderCodes(_ codes: [String], preferring seeds: [String]) -> [String] {
        let seedKeys = seeds.map { identityKey($0) }
        return codes.sorted { a, b in
            let ia = seedKeys.firstIndex(of: identityKey(a)) ?? Int.max
            let ib = seedKeys.firstIndex(of: identityKey(b)) ?? Int.max
            if ia != ib { return ia < ib }
            return a < b
        }
    }

    private static func cachedSupportedLanguages(
        using availability: LanguageAvailability
    ) async -> [Locale.Language] {
        if let cached = supportedLanguagesCacheBox.snapshot(ttl: supportedLanguagesCacheTTL) {
            return cached
        }
        let list = await availability.supportedLanguages
        supportedLanguagesCacheBox.store(list)
        return list
    }

    /// 把候选与系统 `supportedLanguages` 对齐，优先系统给出的精确 identifier。
    private static func expandWithSupported(_ candidates: [String], supported: [Locale.Language]) -> [String] {
        var result: [String] = []
        func append(_ c: String) {
            guard !c.isEmpty, !result.contains(where: { $0.caseInsensitiveCompare(c) == .orderedSame }) else { return }
            result.append(c)
        }

        for c in candidates {
            append(c)
            // 在系统列表中找同族语言的精确码
            for lang in supported {
                let id = languageIdentifier(lang)
                guard !id.isEmpty else { continue }
                if areEquivalent(id, c) {
                    append(id)
                }
            }
        }

        // 再补一轮：supported 中同 languageCode 的全部变体
        for c in candidates {
            let key = identityKey(c)
            for lang in supported {
                let id = languageIdentifier(lang)
                guard !id.isEmpty else { continue }
                if identityKey(id) == key {
                    append(id)
                }
            }
        }

        return result
    }

    private static func languageIdentifier(_ language: Locale.Language) -> String {
        // maximalIdentifier 往往带 region/script，更接近系统翻译语言列表
        let max = language.maximalIdentifier
        if !max.isEmpty { return max }
        if let code = language.languageCode?.identifier {
            if let script = language.script?.identifier, !script.isEmpty {
                return "\(code)-\(script)"
            }
            if let region = language.region?.identifier, !region.isEmpty {
                return "\(code)-\(region)"
            }
            return code
        }
        return ""
    }
}
