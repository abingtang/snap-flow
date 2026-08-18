import Foundation
import Translation

typealias TranslationPartialTextHandler = @MainActor @Sendable (String) -> Void

/// 将高频增量合并到约 25 FPS，避免每个 token 都触发一次卡片重绘。
@MainActor
final class TranslationPartialUpdateGate {
    let minimumInterval: TimeInterval
    private var lastEmission: Date?
    private(set) var lastText: String?

    init(minimumInterval: TimeInterval = 0.04) {
        self.minimumInterval = minimumInterval
    }

    func shouldEmit(at now: Date) -> Bool {
        guard let lastEmission else {
            self.lastEmission = now
            return true
        }
        guard now.timeIntervalSince(lastEmission) >= minimumInterval else { return false }
        self.lastEmission = now
        return true
    }

    func shouldEmit(text: String, at now: Date) -> Bool {
        guard shouldEmit(at: now) else { return false }
        lastText = text
        return true
    }
}

/// 统一翻译入口：路由系统翻译或已配置的第三方 Provider。
@MainActor
final class TranslationService: Translating {
    private let settings: SettingsStore
    private let host = TranslationSessionHost()
    private let session: URLSession
    private var cache: [String: String] = [:]
    private let cacheLimit = 500

    /// 串行门闩，避免并发 translationTask 互踩。
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(settings: SettingsStore, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    func translate(
        _ texts: [String],
        sourceLanguage: String? = nil,
        targetLanguage: String? = nil
    ) async throws -> TranslationResult {
        try await translate(
            texts,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            serviceID: nil,
            onPartialText: nil
        )
    }

    /// 指定服务；`nil` 使用设置中的默认服务。
    func translate(
        _ texts: [String],
        sourceLanguage: String? = nil,
        targetLanguage: String? = nil,
        serviceID: String?,
        onPartialText: TranslationPartialTextHandler? = nil
    ) async throws -> TranslationResult {
        try await translateInternal(
            texts,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            serviceID: serviceID,
            allowDisabled: false,
            onPartialText: onPartialText
        )
    }

    private func translateInternal(
        _ texts: [String],
        sourceLanguage: String?,
        targetLanguage: String?,
        serviceID: String?,
        allowDisabled: Bool,
        useCache: Bool = true,
        onPartialText: TranslationPartialTextHandler? = nil
    ) async throws -> TranslationResult {
        let resolvedID = serviceID ?? settings.resolvedDefaultTranslationServiceID()
        guard let entry = settings.translationService(id: resolvedID) else {
            throw TranslationServiceError.serviceNotFound
        }
        if entry.kind != .system, !allowDisabled, !entry.isEnabled {
            throw TranslationServiceError.serviceDisabled
        }
        guard entry.isReadyToTranslate else {
            throw TranslationServiceError.missingCredentials(entry.displayName)
        }
        if entry.kind == .system {
            return try await translateWithSystem(
                texts,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                useCache: useCache,
                onPartialText: onPartialText
            )
        }
        return try await translateWithCloudProvider(
            texts,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            entry: entry,
            useCache: useCache,
            onPartialText: onPartialText
        )
    }

    private func translateWithSystem(
        _ texts: [String],
        sourceLanguage: String?,
        targetLanguage: String?,
        useCache: Bool,
        onPartialText: TranslationPartialTextHandler?
    ) async throws -> TranslationResult {
        let cleaned = texts.map { $0 }
        guard cleaned.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw TranslationServiceError.emptyInput
        }

        let sample = cleaned
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        let sourceSetting = (sourceLanguage ?? settings.sourceLanguage)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let useAutoSource = sourceSetting.isEmpty || sourceSetting == TranslationLanguage.autoSourceToken

        let detectedSource: String?
        if useAutoSource {
            detectedSource = TranslationLanguage.detectLanguageCode(in: sample)
                ?? TranslationLanguage.inferLikelySourceCode(from: sample)
        } else {
            detectedSource = TranslationLanguage.normalizePreservingRegion(sourceSetting)
        }

        // 固定语言：严格按选项；自动选择：源=系统语 → 英/简中，否则系统首选
        let targetSetting = (targetLanguage ?? settings.targetLanguage)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let targetCodeRaw = TranslationLanguage.resolveEffectiveTargetCode(
            targetSetting: targetSetting,
            sampleText: sample,
            sourceSetting: useAutoSource ? TranslationLanguage.autoSourceToken : sourceSetting,
            detectedSource: detectedSource
        )

        // 源与目标等价 → 短路（用户显式选了同源语言时也会走到这里）
        if let detectedSource,
           TranslationLanguage.areEquivalent(detectedSource, targetCodeRaw)
        {
            return TranslationResult(
                texts: cleaned,
                sourceLanguageCode: detectedSource,
                targetLanguageCode: targetCodeRaw,
                isSameLanguage: true
            )
        }

        // 预检只拦截明确 unsupported；`.supported` 必须继续尝试真实 TranslationSession。
        // LanguageAvailability 常把「已装可用」报成 supported，硬拦会导致误报「未安装语言包」。
        let resolvedPair = try Self.requireSupportedSystemPair(
            await TranslationLanguage.resolvePair(
                sourceCode: detectedSource,
                targetCode: targetCodeRaw,
                sampleText: sample,
                useAutoSource: useAutoSource
            )
        )

        // 源语：本地已检出则显式传入；标识符未识别时 pair 内静默 en，避免系统「无法自动检测」。
        // 按原文换行分段翻译，保留标题/空行/段落结构。
        let cacheSource = resolvedPair.sourceCode
        let cacheTarget = resolvedPair.targetCode
        let targetLang = resolvedPair.targetLanguage
        // 禁止 source:nil 让系统重猜（会与「识别为」标签不一致并弹窗）
        let sourceLang = resolvedPair.sourceLanguage
            ?? (resolvedPair.useSystemSourceDetection
                ? nil
                : Locale.Language(identifier: {
                    let code = resolvedPair.sourceCode
                    if code == TranslationLanguage.autoSourceToken || code.isEmpty {
                        return "en"
                    }
                    return code
                }()))

        // 整段缓存命中
        var results = Array(repeating: "", count: cleaned.count)
        var needWork: [Int] = []
        for (idx, text) in cleaned.enumerated() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                results[idx] = text
                continue
            }
            let key = cacheKey(text: text, source: cacheSource, target: cacheTarget)
            if useCache, let hit = cache[key] {
                results[idx] = hit
            } else {
                needWork.append(idx)
            }
        }

        if needWork.isEmpty {
            return TranslationResult(
                texts: results,
                sourceLanguageCode: cacheSource,
                targetLanguageCode: cacheTarget,
                isSameLanguage: false
            )
        }

        // 展开为行段：空行占位不送翻，非空行进入 batch
        var segmentTexts: [String] = []
        /// needWork 下标 → 该原文拆成的段：nil=空行，int=segmentTexts 下标
        var rebuildPlans: [[Int?]] = []
        for idx in needWork {
            let lines = Self.splitPreservingLines(cleaned[idx])
            var plan: [Int?] = []
            plan.reserveCapacity(lines.count)
            for line in lines {
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    plan.append(nil)
                } else {
                    plan.append(segmentTexts.count)
                    segmentTexts.append(line)
                }
            }
            rebuildPlans.append(plan)
        }

        // 段级缓存
        var segmentResults = Array(repeating: "", count: segmentTexts.count)
        var pendingSegIndices: [Int] = []
        var pendingSegTexts: [String] = []
        for (sIdx, seg) in segmentTexts.enumerated() {
            let key = cacheKey(text: seg, source: cacheSource, target: cacheTarget)
            if useCache, let hit = cache[key] {
                segmentResults[sIdx] = hit
            } else {
                pendingSegIndices.append(sIdx)
                pendingSegTexts.append(seg)
            }
        }

        await acquire()
        defer { release() }

        func runHost(source: Locale.Language?) async throws -> [String] {
            if pendingSegTexts.isEmpty { return [] }
            return try await host.translate(
                texts: pendingSegTexts,
                source: source,
                target: targetLang
            )
        }

        do {
            let translatedSegs = try await runHost(source: sourceLang)
            for (offset, value) in translatedSegs.enumerated() {
                let sIdx = pendingSegIndices[offset]
                segmentResults[sIdx] = value
                if useCache {
                    putCache(
                        cacheKey(text: pendingSegTexts[offset], source: cacheSource, target: cacheTarget),
                        value: value
                    )
                }
            }
        } catch let error as TranslationServiceError {
            throw error
        } catch is CancellationError {
            throw TranslationServiceError.failed(L10n.string("翻译已取消"))
        } catch {
            // 不再用 source:nil 重试：系统会弹「无法自动检测语言」，且与「识别为/未识别」标签不一致。
            let errorSource = (cacheSource == TranslationLanguage.autoSourceToken || cacheSource.isEmpty)
                ? "en"
                : cacheSource
            throw mapSystemError(error, source: errorSource, target: cacheTarget)
        }

        // 按原文换行结构拼回
        for (planOffset, textIdx) in needWork.enumerated() {
            let plan = rebuildPlans[planOffset]
            let originalLines = Self.splitPreservingLines(cleaned[textIdx])
            var outLines: [String] = []
            outLines.reserveCapacity(plan.count)
            for (lineIdx, ref) in plan.enumerated() {
                if let ref {
                    outLines.append(segmentResults[ref])
                } else {
                    // 保留原文空行（含仅空白的行）
                    outLines.append(originalLines.indices.contains(lineIdx) ? originalLines[lineIdx] : "")
                }
            }
            let joined = outLines.joined(separator: "\n")
            results[textIdx] = joined
            if useCache {
                putCache(
                    cacheKey(text: cleaned[textIdx], source: cacheSource, target: cacheTarget),
                    value: joined
                )
            }
        }

        return TranslationResult(
            texts: results,
            sourceLanguageCode: cacheSource,
            targetLanguageCode: cacheTarget,
            isSameLanguage: false
        )
    }

    private func translateWithCloudProvider(
        _ texts: [String],
        sourceLanguage: String?,
        targetLanguage: String?,
        entry: TranslationServiceEntry,
        useCache: Bool,
        onPartialText: TranslationPartialTextHandler?
    ) async throws -> TranslationResult {
        guard texts.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw TranslationServiceError.emptyInput
        }

        let sourceSetting = (sourceLanguage ?? settings.sourceLanguage)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let useAutoSource = sourceSetting.isEmpty || sourceSetting == TranslationLanguage.autoSourceToken
        let sample = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let detectedSource = useAutoSource
            ? (TranslationLanguage.detectLanguageCode(in: sample)
                ?? TranslationLanguage.inferLikelySourceCode(from: sample))
            : TranslationLanguage.normalizePreservingRegion(sourceSetting)

        let targetSetting = (targetLanguage ?? settings.targetLanguage)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let targetCode = TranslationLanguage.resolveEffectiveTargetCode(
            targetSetting: targetSetting,
            sampleText: sample,
            sourceSetting: useAutoSource ? TranslationLanguage.autoSourceToken : sourceSetting,
            detectedSource: detectedSource
        )

        if let detectedSource, TranslationLanguage.areEquivalent(detectedSource, targetCode) {
            return TranslationResult(
                texts: texts,
                sourceLanguageCode: detectedSource,
                targetLanguageCode: targetCode,
                isSameLanguage: true
            )
        }

        let cacheSource = detectedSource
            ?? (useAutoSource ? TranslationLanguage.autoSourceToken : sourceSetting)
        var segmentTexts: [String] = []
        var rebuildPlans: [[Int?]] = []
        if entry.isStreamingEnabled {
            // 流式模式整段发送，避免一个多行原文拆成多个串行请求。
            for text in texts {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    rebuildPlans.append([nil])
                    continue
                }
                rebuildPlans.append([segmentTexts.count])
                segmentTexts.append(text)
            }
        } else {
            for text in texts {
                let lines = Self.splitPreservingLines(text)
                var plan: [Int?] = []
                for line in lines {
                    if line.trimmingCharacters(in: .whitespaces).isEmpty {
                        plan.append(nil)
                    } else {
                        plan.append(segmentTexts.count)
                        segmentTexts.append(line)
                    }
                }
                rebuildPlans.append(plan)
            }
        }

        var segmentResults = Array(repeating: "", count: segmentTexts.count)
        var pendingIndices: [Int] = []
        var pendingTexts: [String] = []
        for (index, text) in segmentTexts.enumerated() {
            let key = cacheKey(
                text: text,
                source: cacheSource,
                target: targetCode,
                serviceID: entry.id
            )
            if useCache, let hit = cache[key] {
                segmentResults[index] = hit
            } else {
                pendingIndices.append(index)
                pendingTexts.append(text)
            }
        }

        var providerDetectedSource: String?
        let partialUpdateGate = TranslationPartialUpdateGate()
        if !pendingTexts.isEmpty {
            let response: TranslationProviderResponse
            do {
                let selectedProvider = provider(for: entry)
                if entry.isStreamingEnabled {
                    let baseSegmentResults = segmentResults
                    let pendingIndicesSnapshot = pendingIndices
                    let pendingTextsCount = pendingTexts.count
                    let sourceTexts = texts
                    let plans = rebuildPlans
                    let updateHandler: TranslationProviderUpdateHandler = { update in
                        guard let onPartialText else { return }
                        var partialSegments = baseSegmentResults
                        for offset in 0 ..< pendingTextsCount {
                            guard offset < update.texts.count else { continue }
                            partialSegments[pendingIndicesSnapshot[offset]] = update.texts[offset]
                        }
                        let partialResults = Self.rebuildCloudResults(
                            texts: sourceTexts,
                            plans: plans,
                            segmentResults: partialSegments
                        )
                        let partialText = partialResults.joined(separator: "\n")
                        guard partialUpdateGate.shouldEmit(text: partialText, at: Date()) else { return }
                        onPartialText(partialText)
                    }
                    response = try await selectedProvider.translateStreaming(
                        pendingTexts,
                        sourceLanguage: useAutoSource ? nil : detectedSource ?? sourceSetting,
                        targetLanguage: targetCode,
                        entry: entry,
                        onUpdate: updateHandler
                    )
                } else {
                    response = try await selectedProvider.translate(
                        pendingTexts,
                        sourceLanguage: useAutoSource ? nil : detectedSource ?? sourceSetting,
                        targetLanguage: targetCode,
                        entry: entry
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as TranslationServiceError {
                throw error
            } catch {
                throw TranslationServiceError.network(error.localizedDescription)
            }
            guard response.texts.count == pendingTexts.count else {
                throw TranslationServiceError.invalidResponse(
                    String(format: L10n.string("译文数量 %lld 与原文数量 %lld 不一致"), response.texts.count, pendingTexts.count)
                )
            }
            providerDetectedSource = response.detectedSourceLanguage
            for (offset, translated) in response.texts.enumerated() {
                let segmentIndex = pendingIndices[offset]
                segmentResults[segmentIndex] = translated
                if useCache {
                    putCache(
                        cacheKey(
                            text: pendingTexts[offset],
                            source: cacheSource,
                            target: targetCode,
                            serviceID: entry.id
                        ),
                        value: translated
                    )
                }
            }
        }

        let results = Self.rebuildCloudResults(
            texts: texts,
            plans: rebuildPlans,
            segmentResults: segmentResults
        )
        let finalText = results.joined(separator: "\n")
        if entry.isStreamingEnabled,
           !pendingTexts.isEmpty,
           let onPartialText,
           partialUpdateGate.lastText != finalText
        {
            onPartialText(finalText)
        }

        return TranslationResult(
            texts: results,
            sourceLanguageCode: detectedSource ?? providerDetectedSource ?? cacheSource,
            targetLanguageCode: targetCode,
            isSameLanguage: false
        )
    }

    private static func rebuildCloudResults(
        texts: [String],
        plans: [[Int?]],
        segmentResults: [String]
    ) -> [String] {
        var results: [String] = []
        results.reserveCapacity(texts.count)
        for (textIndex, plan) in plans.enumerated() {
            let originalLines = splitPreservingLines(texts[textIndex])
            let outputLines = plan.enumerated().map { lineIndex, segmentIndex in
                if let segmentIndex {
                    return segmentResults[segmentIndex]
                }
                return originalLines.indices.contains(lineIndex) ? originalLines[lineIndex] : ""
            }
            results.append(outputLines.joined(separator: "\n"))
        }
        return results
    }

    private func provider(for entry: TranslationServiceEntry) -> any TranslationProvider {
        switch entry.kind {
        case .system:
            preconditionFailure(L10n.string("系统翻译不走云 Provider"))
        case .baidu:
            BaiduTranslationProvider(session: session)
        case .youdao:
            YoudaoTranslationProvider(session: session)
        case .google:
            GoogleTranslationProvider(session: session)
        case .deepl:
            DeepLTranslationProvider(session: session)
        case .microsoft:
            MicrosoftTranslationProvider(session: session)
        case .volcengine:
            VolcengineTranslationProvider(session: session)
        case .tencent:
            TencentTranslationProvider(session: session)
        case .aliyun:
            AliyunTranslationProvider(session: session)
        case .caiyun:
            CaiyunTranslationProvider(session: session)
        case .niutrans:
            NiuTransTranslationProvider(session: session)
        case .amazon:
            AmazonTranslationProvider(session: session)
        case .openai, .openrouter, .deepseek, .qwen, .zhipu,
             .siliconflow, .groq, .grok, .kimi:
            OpenAICompatibleTranslationProvider(kind: entry.kind, session: session)
        case .ollama, .lmStudio:
            LocalModelTranslationProvider(kind: entry.kind, session: session)
        }
    }

    /// 按换行拆分并保留空行（统一 `\r\n` / `\r` → `\n`）。
    private static func splitPreservingLines(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalized.isEmpty { return [""] }
        return normalized.components(separatedBy: "\n")
    }

    /// 预创建 translationTask 宿主窗，避免首次翻译时再挂面板。
    func warmupHost() {
        host.warmup()
    }

    /// 取消进行中的系统翻译（解决卡在转圈时无法重试）。
    func cancelInFlight() {
        host.invalidate()
        // 释放串行门闩上的等待者
        while !waiters.isEmpty {
            waiters.removeFirst().resume()
        }
        busy = false
    }

    /// 设置页「验证」：用短句探测指定服务，允许验证尚未启用的完整配置。
    func verify(serviceID: String) async -> String {
        let target = TranslationLanguage.resolvedTargetCode(setting: settings.targetLanguage)
        let probe: String
        if TranslationLanguage.identityKey(target).hasPrefix("zh") {
            probe = "Hello"
        } else {
            probe = "你好"
        }
        do {
            let result = try await translateInternal(
                [probe],
                sourceLanguage: nil,
                targetLanguage: nil,
                serviceID: serviceID,
                allowDisabled: true,
                useCache: false
            )
            if result.isSameLanguage {
                return L10n.string("源语言与目标语言相同，验证跳过")
            }
            let out = result.texts.first ?? ""
            if out.isEmpty {
                return L10n.string("验证完成，但译文为空")
            }
            let pair =
                "\(TranslationLanguage.displayName(for: result.sourceLanguageCode)) → \(TranslationLanguage.displayName(for: result.targetLanguageCode))"
            return String(format: L10n.string("验证成功（%@）：%@ → %@"), pair, probe, out)
        } catch {
            return error.localizedDescription
        }
    }

    func verifyCurrentPair() async -> String {
        await verify(serviceID: settings.resolvedDefaultTranslationServiceID())
    }

    /// 查询语言对安装状态（设置卡展示）。
    func pairStatus(
        sourceSetting: String? = nil,
        targetSetting: String? = nil
    ) async -> PairAvailability {
        let targetRaw: String = {
            let setting = targetSetting ?? settings.targetLanguage
            let raw = setting.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty || raw == TranslationLanguage.systemTargetToken {
                return TranslationLanguage.systemPreferredLanguageCodePreservingRegion()
            }
            return TranslationLanguage.normalizePreservingRegion(raw)
        }()

        let sourceSetting = (sourceSetting ?? settings.sourceLanguage)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let useAuto = sourceSetting.isEmpty || sourceSetting == TranslationLanguage.autoSourceToken

        // 设置页探测用固定样句，避免「自动」误用日语探针
        let sample: String = {
            if TranslationLanguage.identityKey(targetRaw).hasPrefix("zh") {
                return "Hello, how are you?"
            }
            return "你好，今天天气怎么样？"
        }()

        let detected: String? = useAuto
            ? TranslationLanguage.detectLanguageCode(in: sample)
            : TranslationLanguage.normalizePreservingRegion(sourceSetting)

        let pair = await TranslationLanguage.resolvePair(
            sourceCode: detected,
            targetCode: targetRaw,
            sampleText: sample,
            useAutoSource: useAuto
        )

        let mapped: PairAvailability.Status
        switch pair.availability {
        case .installed: mapped = .installed
        case .supported: mapped = .supportedNotInstalled
        case .unsupported: mapped = .unsupported
        }

        return PairAvailability(
            sourceCode: pair.sourceCode,
            targetCode: pair.targetCode,
            status: mapped
        )
    }

    struct PairAvailability: Sendable, Equatable {
        enum Status: Sendable, Equatable {
            case installed
            case supportedNotInstalled
            case unsupported
            case sameLanguage
        }

        let sourceCode: String
        let targetCode: String
        let status: Status

        var statusLabel: String {
            switch status {
            case .installed: L10n.string("模型已就绪")
            case .supportedNotInstalled: L10n.string("模型可能未完全匹配（仍可尝试翻译）")
            case .unsupported: L10n.string("语言对不受支持")
            case .sameLanguage: L10n.string("源与目标相同")
            }
        }
    }

    // MARK: - Private

    /// 仅拦截系统明确不支持的语言对。
    /// - Note: `.supported` 与 `.installed` 一律放行；是否真正缺模型以 `TranslationSession` 抛错为准。
    static func requireSupportedSystemPair(
        _ pair: TranslationLanguage.ResolvedPair
    ) throws -> TranslationLanguage.ResolvedPair {
        switch pair.availability {
        case .installed, .supported:
            return pair
        case .unsupported:
            throw TranslationServiceError.unsupportedPair(
                source: pair.sourceCode,
                target: pair.targetCode
            )
        }
    }

    /// 兼容旧测试/调用名。
    @available(*, deprecated, renamed: "requireSupportedSystemPair")
    static func requireInstalledSystemPair(
        _ pair: TranslationLanguage.ResolvedPair
    ) throws -> TranslationLanguage.ResolvedPair {
        try requireSupportedSystemPair(pair)
    }

    private func mapSystemError(_ error: Error, source: String, target: String) -> TranslationServiceError {
        if #available(macOS 26.0, *), TranslationError.notInstalled ~= error {
            return .modelNotInstalled(source: source, target: target)
        }
        if TranslationError.unsupportedLanguagePairing ~= error
            || TranslationError.unsupportedSourceLanguage ~= error
            || TranslationError.unsupportedTargetLanguage ~= error
        {
            return .unsupportedPair(source: source, target: target)
        }
        if TranslationError.unableToIdentifyLanguage ~= error {
            return .cannotDetectLanguage
        }
        if TranslationError.nothingToTranslate ~= error {
            return .emptyInput
        }

        // 勿用单独的 "download" 做启发式：易把其它错误误标成「未安装」。
        let desc = error.localizedDescription.lowercased()
        if desc.contains("not installed")
            || desc.contains(L10n.string("未安装"))
            || (desc.contains("install") && (desc.contains("language") || desc.contains("model") || desc.contains(L10n.string("语言"))))
        {
            return .modelNotInstalled(source: source, target: target)
        }
        return .failed(error.localizedDescription)
    }

    private func cacheKey(
        text: String,
        source: String,
        target: String,
        serviceID: String = TranslationServiceEntry.systemID
    ) -> String {
        "\(serviceID):\(source)>\(target):\(text)"
    }

    private func putCache(_ key: String, value: String) {
        cache[key] = value
        if cache.count > cacheLimit {
            cache.removeAll(keepingCapacity: true)
        }
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
        busy = true
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}
