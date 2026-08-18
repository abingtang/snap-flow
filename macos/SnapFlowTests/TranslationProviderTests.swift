import AppKit
import Foundation
import XCTest
@testable import SnapFlow

private final class TranslationURLProtocolStub: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        let statusCode: Int
        let data: Data
    }

    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> Reply)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw URLError(.badServerResponse)
            }
            var capturedRequest = request
            if capturedRequest.httpBody == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var body = Data()
                var buffer = [UInt8](repeating: 0, count: 4_096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    body.append(buffer, count: count)
                }
                capturedRequest.httpBody = body
            }
            let reply = try handler(capturedRequest)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: reply.statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class TranslationRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock()
        storage.append(request)
        lock.unlock()
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@MainActor
final class TranslationProviderTests: XCTestCase {
    override func tearDown() {
        TranslationURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testTranslationHostPreparesFirstRequestBeforeViewMountAndKeepsItCancellable() async {
        let model = HostModel()
        let started = expectation(description: "pending translation installed")
        let task = Task { @MainActor in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
                let pending = TranslationPendingBox(
                    requestID: 42,
                    texts: ["Hello"],
                    continuation: continuation
                )
                model.prepare(
                    pending,
                    source: Locale.Language(identifier: "en"),
                    target: Locale.Language(identifier: "zh-Hans")
                )
                started.fulfill()
            }
        }

        await fulfillment(of: [started], timeout: 1)
        let running = model.jobForExecution()

        XCTAssertTrue(running === model.pending)
        XCTAssertNotNil(model.configuration)
        if let running {
            model.finish(running)
            XCTAssertNil(model.pending)
            XCTAssertNotNil(
                model.configuration,
                "完成后必须保留已被 translationTask 观察的配置，供同语言对请求 invalidate"
            )
            let reusedConfiguration = model.prepare(
                running,
                source: Locale.Language(identifier: "en"),
                target: Locale.Language(identifier: "zh-Hans")
            )
            XCTAssertTrue(reusedConfiguration)
            XCTAssertTrue(model.pending === running)
            model.pending = nil
            running.resume(throwing: CancellationError())
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testServiceSettingsLayoutUsesSplitAtMinimumWidth() {
        XCTAssertFalse(ServiceSettingsLayoutMode.usesSplit(width: 599))
        XCTAssertTrue(ServiceSettingsLayoutMode.usesSplit(width: 600))
    }

    func testTranslationServiceKindsExposeDedicatedModelRecommendations() {
        XCTAssertEqual(
            TranslationServiceKind.siliconflow.recommendedTranslationModel,
            "tencent/Hunyuan-MT-7B"
        )
        XCTAssertEqual(
            TranslationServiceKind.ollama.recommendedTranslationModel,
            "translategemma:4b"
        )
        XCTAssertEqual(
            TranslationServiceKind.lmStudio.recommendedTranslationModel,
            "TranslateGemma 4B（搜索 translategemma-4b-it，选择可用的 GGUF/MLX 量化版本）"
        )
        XCTAssertNil(TranslationServiceKind.openai.recommendedTranslationModel)
        XCTAssertNil(TranslationServiceKind.deepl.recommendedTranslationModel)
    }

    func testServiceSettingsFilterMatchesReadinessAndEnabledState() {
        XCTAssertTrue(ServiceSettingsListFilter.all.matches(isEnabled: false, isReady: false))
        XCTAssertTrue(ServiceSettingsListFilter.enabled.matches(isEnabled: true, isReady: false))
        XCTAssertFalse(ServiceSettingsListFilter.enabled.matches(isEnabled: false, isReady: true))
        XCTAssertTrue(ServiceSettingsListFilter.needsConfiguration.matches(isEnabled: true, isReady: false))
        XCTAssertFalse(ServiceSettingsListFilter.needsConfiguration.matches(isEnabled: true, isReady: true))
        XCTAssertTrue(ServiceSettingsListFilter.disabled.matches(isEnabled: false, isReady: true))
    }

    func testTranslatePopupResizeStaysInsideItsCurrentScreen() {
        let visibleFrame = NSRect(x: 0, y: 24, width: 800, height: 400)
        let currentFrame = NSRect(x: 220, y: 80, width: 420, height: 320)

        let resized = PanelPresenter.clampedTranslateFrame(
            currentFrame,
            requestedHeight: 600,
            visibleFrame: visibleFrame
        )

        XCTAssertGreaterThanOrEqual(resized.minY, visibleFrame.minY + 8)
        XCTAssertLessThanOrEqual(resized.maxY, visibleFrame.maxY - 8)
        XCTAssertLessThanOrEqual(resized.height, visibleFrame.height - 16)
    }

    func testScreenTranslateToolbarAlignsToSelectionBottomRight() {
        let visibleFrame = NSRect(x: 0, y: 24, width: 1_200, height: 800)
        let selection = NSRect(x: 120, y: 300, width: 900, height: 320)
        let toolbarWidth = ScreenTranslateOverlayView.toolbarWidth(for: visibleFrame.width)
        let toolbarHeight = ScreenTranslateOverlayView.toolbarHeight(for: toolbarWidth)

        let placement = PanelPresenter.screenTranslateOverlayPlacement(
            selection: selection,
            visibleFrame: visibleFrame
        )

        XCTAssertFalse(placement.toolbarAbove)
        XCTAssertEqual(placement.frame.maxX, selection.maxX, accuracy: 0.1)
        XCTAssertEqual(
            placement.frame.minY,
            selection.minY - toolbarHeight - ScreenTranslateOverlayView.toolbarGap,
            accuracy: 0.1
        )

        let nearBottom = NSRect(x: 120, y: 40, width: 900, height: 320)
        let abovePlacement = PanelPresenter.screenTranslateOverlayPlacement(
            selection: nearBottom,
            visibleFrame: visibleFrame
        )
        XCTAssertTrue(abovePlacement.toolbarAbove)
    }

    func testSettingsPersistNormalizeAndFallbackDefault() throws {
        let suite = "TranslationProviderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.translationServices, [.system()])

        let google = configuredEntry(.google)
        settings.translationServices.append(google)
        settings.translationServices.append(configuredEntry(.google))
        XCTAssertEqual(settings.translationServices.filter { $0.kind == .google }.count, 1)

        settings.setDefaultTranslationServiceID(google.id)
        XCTAssertEqual(settings.resolvedDefaultTranslationServiceID(), google.id)

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.translationService(id: google.id)?.google?.apiKey, "google-key")
        XCTAssertEqual(reloaded.resolvedDefaultTranslationServiceID(), google.id)

        let index = try XCTUnwrap(reloaded.translationServices.firstIndex { $0.id == google.id })
        reloaded.translationServices[index].isEnabled = false
        XCTAssertEqual(reloaded.defaultTranslationServiceID, TranslationServiceEntry.systemID)

        reloaded.translationServices.removeAll { $0.kind == .system }
        XCTAssertEqual(reloaded.translationServices.first, .system())
    }

    func testExtendedTranslationConfigsPersistAndRemainReady() throws {
        let suite = "ExtendedTranslationConfigs.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults)
        let kinds: [TranslationServiceKind] = [
            .volcengine, .tencent, .aliyun, .caiyun, .niutrans, .amazon,
        ]
        for kind in kinds {
            settings.translationServices.append(configuredEntry(kind))
        }

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(
            Set(reloaded.translationServices.map(\.kind)),
            Set([TranslationServiceKind.system] + kinds)
        )
        for kind in kinds {
            XCTAssertTrue(reloaded.translationServices.first { $0.kind == kind }?.isReadyToTranslate == true)
        }
    }

    func testOpenAICompatibleTranslationConfigsPersistAndRemainReady() throws {
        let suite = "OpenAICompatibleTranslationConfigs.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults)
        let kinds: [TranslationServiceKind] = [
            .openai, .openrouter, .deepseek, .qwen, .zhipu,
            .siliconflow, .groq, .grok, .kimi,
        ]
        for kind in kinds {
            settings.translationServices.append(configuredEntry(kind))
        }

        let reloaded = SettingsStore(defaults: defaults)
        for kind in kinds {
            let entry = try XCTUnwrap(reloaded.translationServices.first { $0.kind == kind })
            XCTAssertEqual(entry.openAICompatible?.apiKey, "llm-key")
            XCTAssertEqual(entry.openAICompatible?.model, "test-model")
            XCTAssertTrue(entry.isReadyToTranslate)
        }
    }

    func testStreamingModeConfigPersistsAndLegacyPayloadDefaultsToNonStreaming() throws {
        let suite = "StreamingModeConfig.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults)
        var entry = configuredEntry(.openai)
        entry.openAICompatible?.streamingEnabled = true
        settings.translationServices.append(entry)

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertTrue(
            reloaded.translationServices.first(where: { $0.kind == .openai })?
                .openAICompatible?.streamingEnabled == true
        )

        var localEntry = configuredEntry(.ollama)
        localEntry.localModel?.streamingEnabled = true
        settings.translationServices.append(localEntry)
        let localReloaded = SettingsStore(defaults: defaults)
        XCTAssertTrue(
            localReloaded.translationServices.first(where: { $0.kind == .ollama })?
                .localModel?.streamingEnabled == true
        )

        var legacyJSON = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(configuredEntry(.openai))
        ) as? [String: Any]
        var legacyConfig = legacyJSON?["openAICompatible"] as? [String: Any]
        legacyConfig?.removeValue(forKey: "streamingEnabled")
        legacyJSON?["openAICompatible"] = legacyConfig
        let legacyData = try JSONSerialization.data(withJSONObject: try XCTUnwrap(legacyJSON))
        let legacyEntry = try JSONDecoder().decode(TranslationServiceEntry.self, from: legacyData)
        XCTAssertFalse(legacyEntry.openAICompatible?.streamingEnabled == true)
    }

    func testOpenAICompatibleProvidersBuildExpectedRequestsAndParseSuccess() async throws {
        let recorder = TranslationRequestRecorder()
        TranslationURLProtocolStub.handler = { request in
            recorder.append(request)
            let content = #"{"translations":["你好"]}"#
            let data = try JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": content]]],
            ])
            return .init(statusCode: 200, data: data)
        }

        let expected: [(TranslationServiceKind, String, String)] = [
            (.openai, "api.openai.com", "/v1/chat/completions"),
            (.openrouter, "openrouter.ai", "/api/v1/chat/completions"),
            (.deepseek, "api.deepseek.com", "/chat/completions"),
            (.qwen, "dashscope.aliyuncs.com", "/compatible-mode/v1/chat/completions"),
            (.zhipu, "open.bigmodel.cn", "/api/paas/v4/chat/completions"),
            (.siliconflow, "api.siliconflow.cn", "/v1/chat/completions"),
            (.groq, "api.groq.com", "/openai/v1/chat/completions"),
            (.grok, "api.x.ai", "/v1/chat/completions"),
            (.kimi, "api.moonshot.cn", "/v1/chat/completions"),
        ]
        let session = stubSession()

        for (kind, host, path) in expected {
            let response = try await OpenAICompatibleTranslationProvider(
                kind: kind,
                session: session
            ).translate(
                ["Hello"],
                sourceLanguage: "en",
                targetLanguage: "zh-Hans",
                entry: configuredEntry(kind)
            )
            XCTAssertEqual(response.texts, ["你好"])

            let request = try XCTUnwrap(recorder.requests.last)
            XCTAssertEqual(request.url?.host, host)
            XCTAssertEqual(request.url?.path, path)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer llm-key")
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, "test-model")
            XCTAssertEqual(json["stream"] as? Bool, false)
            XCTAssertNotNil(json["messages"] as? [[String: String]])
        }
    }

    func testOpenAICompatibleProviderStreamsPlainTextAndEmitsCumulativeUpdates() async throws {
        let recorder = TranslationRequestRecorder()
        TranslationURLProtocolStub.handler = { request in
            recorder.append(request)
            let stream = """
            data: {"choices":[{"delta":{"content":"你"}}]}

            data: {"choices":[{"delta":{"content":"好"}}]}

            data: [DONE]

            """
            return .init(statusCode: 200, data: Data(stream.utf8))
        }

        var entry = configuredEntry(.openai)
        entry.openAICompatible?.streamingEnabled = true
        var updates: [String] = []
        let response = try await OpenAICompatibleTranslationProvider(
            kind: .openai,
            session: stubSession()
        ).translateStreaming(
            ["Hello"],
            sourceLanguage: "en",
            targetLanguage: "zh-Hans",
            entry: entry,
            onUpdate: { update in
                updates.append(update.texts.first ?? "")
            }
        )

        XCTAssertEqual(response.texts, ["你好"])
        XCTAssertEqual(updates, ["你", "你好"])
        let request = try XCTUnwrap(recorder.requests.first)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual((json["temperature"] as? NSNumber)?.doubleValue, 0)
        XCTAssertNotNil(json["max_tokens"] as? NSNumber)
    }

    func testSiliconFlowHunyuanTranslationUsesPlainTextPromptAndResponse() async throws {
        let recorder = TranslationRequestRecorder()
        TranslationURLProtocolStub.handler = { request in
            recorder.append(request)
            let data = try JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": "你好"]]],
            ])
            return .init(statusCode: 200, data: data)
        }

        var entry = configuredEntry(.siliconflow)
        entry.openAICompatible?.model = "tencent/Hunyuan-MT-7B"

        let response = try await OpenAICompatibleTranslationProvider(
            kind: .siliconflow,
            session: stubSession()
        ).translate(
            ["Hello"],
            sourceLanguage: "en",
            targetLanguage: "zh-Hans",
            entry: entry
        )

        XCTAssertEqual(response.texts, ["你好"])
        let request = try XCTUnwrap(recorder.requests.first)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["role"], "user")
        XCTAssertTrue(messages.first?["content"]?.contains("Hello") == true)
        XCTAssertTrue(messages.first?["content"]?.contains("翻译") == true)
    }

    func testOpenAICompatibleProviderRejectsMismatchedTranslationCount() async throws {
        TranslationURLProtocolStub.handler = { _ in
            let content = #"{"translations":["一","二"]}"#
            let data = try JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": content]]],
            ])
            return .init(statusCode: 200, data: data)
        }

        do {
            _ = try await OpenAICompatibleTranslationProvider(
                kind: .openai,
                session: stubSession()
            ).translate(
                ["One"],
                sourceLanguage: "en",
                targetLanguage: "zh-Hans",
                entry: configuredEntry(.openai)
            )
            XCTFail("译文数量不匹配时必须失败")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("数量"))
        }
    }

    func testLocalModelTranslationConfigsPersistAndRemainReady() throws {
        let suite = "LocalModelTranslationConfigs.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults)
        settings.translationServices.append(configuredEntry(.ollama))
        settings.translationServices.append(configuredEntry(.lmStudio))

        let reloaded = SettingsStore(defaults: defaults)
        let ollama = try XCTUnwrap(reloaded.translationServices.first { $0.kind == .ollama })
        XCTAssertEqual(ollama.localModel?.baseURL, "http://127.0.0.1:11434")
        XCTAssertEqual(ollama.localModel?.model, "qwen3:8b")
        XCTAssertTrue(ollama.isReadyToTranslate)

        let lmStudio = try XCTUnwrap(reloaded.translationServices.first { $0.kind == .lmStudio })
        XCTAssertEqual(lmStudio.localModel?.baseURL, "http://127.0.0.1:1234/v1")
        XCTAssertEqual(lmStudio.localModel?.model, "local-model")
        XCTAssertEqual(lmStudio.localModel?.apiKey, "local-key")
        XCTAssertTrue(lmStudio.isReadyToTranslate)
    }

    func testOllamaAndLMStudioProvidersBuildLocalRequestsAndParseSuccess() async throws {
        let recorder = TranslationRequestRecorder()
        TranslationURLProtocolStub.handler = { request in
            recorder.append(request)
            let content = #"{"translations":["你好"]}"#
            let data: Data
            if request.url?.path == "/api/chat" {
                data = try JSONSerialization.data(withJSONObject: [
                    "message": ["content": content],
                    "done": true,
                ])
            } else {
                data = try JSONSerialization.data(withJSONObject: [
                    "choices": [["message": ["content": content]]],
                ])
            }
            return .init(statusCode: 200, data: data)
        }

        let ollama = try await LocalModelTranslationProvider(
            kind: .ollama,
            session: stubSession()
        ).translate(
            ["Hello"],
            sourceLanguage: "en",
            targetLanguage: "zh-Hans",
            entry: configuredEntry(.ollama)
        )
        XCTAssertEqual(ollama.texts, ["你好"])
        let ollamaRequest = try XCTUnwrap(recorder.requests.last)
        XCTAssertEqual(ollamaRequest.url?.host, "127.0.0.1")
        XCTAssertEqual(ollamaRequest.url?.path, "/api/chat")
        XCTAssertNil(ollamaRequest.value(forHTTPHeaderField: "Authorization"))
        let ollamaBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(ollamaRequest.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(ollamaBody["stream"] as? Bool, false)
        XCTAssertEqual(ollamaBody["format"] as? String, "json")

        let lmStudio = try await LocalModelTranslationProvider(
            kind: .lmStudio,
            session: stubSession()
        ).translate(
            ["Hello"],
            sourceLanguage: "en",
            targetLanguage: "zh-Hans",
            entry: configuredEntry(.lmStudio)
        )
        XCTAssertEqual(lmStudio.texts, ["你好"])
        let lmRequest = try XCTUnwrap(recorder.requests.last)
        XCTAssertEqual(lmRequest.url?.host, "127.0.0.1")
        XCTAssertEqual(lmRequest.url?.path, "/v1/chat/completions")
        XCTAssertEqual(lmRequest.value(forHTTPHeaderField: "Authorization"), "Bearer local-key")

        var slashEntry = configuredEntry(.lmStudio)
        slashEntry.localModel?.baseURL = "http://127.0.0.1:1234/v1/"
        _ = try await LocalModelTranslationProvider(
            kind: .lmStudio,
            session: stubSession()
        ).translate(
            ["Hello"],
            sourceLanguage: "en",
            targetLanguage: "zh-Hans",
            entry: slashEntry
        )
        XCTAssertEqual(recorder.requests.last?.url?.path, "/v1/chat/completions")
    }

    func testOllamaProviderStreamsNDJSONAndEmitsCumulativeUpdates() async throws {
        let recorder = TranslationRequestRecorder()
        TranslationURLProtocolStub.handler = { request in
            recorder.append(request)
            let stream = """
            {"message":{"content":"你"},"done":false}
            {"message":{"content":"好"},"done":true}
            """
            return .init(statusCode: 200, data: Data(stream.utf8))
        }

        var entry = configuredEntry(.ollama)
        entry.localModel?.streamingEnabled = true
        var updates: [String] = []
        let response = try await LocalModelTranslationProvider(
            kind: .ollama,
            session: stubSession()
        ).translateStreaming(
            ["Hello"],
            sourceLanguage: "en",
            targetLanguage: "zh-Hans",
            entry: entry,
            onUpdate: { update in
                updates.append(update.texts.first ?? "")
            }
        )

        XCTAssertEqual(response.texts, ["你好"])
        XCTAssertEqual(updates, ["你", "你好"])
        let request = try XCTUnwrap(recorder.requests.first)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertNil(json["format"])
        let options = try XCTUnwrap(json["options"] as? [String: Any])
        XCTAssertEqual((options["temperature"] as? NSNumber)?.doubleValue, 0)
        XCTAssertNotNil(options["num_predict"] as? NSNumber)
    }

    func testLMStudioProviderStreamsOpenAISSEAndEmitsCumulativeUpdates() async throws {
        let recorder = TranslationRequestRecorder()
        TranslationURLProtocolStub.handler = { request in
            recorder.append(request)
            let stream = """
            data: {"choices":[{"delta":{"content":"你"}}]}

            data: {"choices":[{"delta":{"content":"好"}}]}

            data: [DONE]

            """
            return .init(statusCode: 200, data: Data(stream.utf8))
        }

        var entry = configuredEntry(.lmStudio)
        entry.localModel?.streamingEnabled = true
        var updates: [String] = []
        let response = try await LocalModelTranslationProvider(
            kind: .lmStudio,
            session: stubSession()
        ).translateStreaming(
            ["Hello"],
            sourceLanguage: "en",
            targetLanguage: "zh-Hans",
            entry: entry,
            onUpdate: { update in
                updates.append(update.texts.first ?? "")
            }
        )

        XCTAssertEqual(response.texts, ["你好"])
        XCTAssertEqual(updates, ["你", "你好"])
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/chat/completions")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["stream"] as? Bool, true)
    }

    func testTranslationServiceForwardsStreamingPartialTextToCaller() async throws {
        let suite = "TranslationServiceStreaming.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults)
        var entry = configuredEntry(.openai)
        entry.openAICompatible?.streamingEnabled = true
        settings.translationServices.append(entry)

        TranslationURLProtocolStub.handler = { _ in
            let stream = """
            data: {"choices":[{"delta":{"content":"你"}}]}

            data: {"choices":[{"delta":{"content":"好"}}]}

            data: [DONE]

            """
            return .init(statusCode: 200, data: Data(stream.utf8))
        }

        var updates: [String] = []
        let result = try await TranslationService(
            settings: settings,
            session: stubSession()
        ).translate(
            ["Hello"],
            sourceLanguage: "en",
            targetLanguage: "zh-Hans",
            serviceID: entry.id,
            onPartialText: { updates.append($0) }
        )

        XCTAssertEqual(result.texts, ["你好"])
        XCTAssertEqual(updates, ["你", "你好"])
    }

    func testTranslationServiceStreamingTranslatesMultilineTextWithOneRequest() async throws {
        let suite = "TranslationServiceStreamingMultiline.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults)
        var entry = configuredEntry(.openai)
        entry.openAICompatible?.streamingEnabled = true
        settings.translationServices.append(entry)

        let recorder = TranslationRequestRecorder()
        TranslationURLProtocolStub.handler = { request in
            recorder.append(request)
            let stream = """
            data: {"choices":[{"delta":{"content":"你好"}}]}

            data: {"choices":[{"delta":{"content":"\\n世界"}}]}

            data: [DONE]

            """
            return .init(statusCode: 200, data: Data(stream.utf8))
        }

        let result = try await TranslationService(
            settings: settings,
            session: stubSession()
        ).translate(
            ["Hello\nWorld"],
            sourceLanguage: "en",
            targetLanguage: "zh-Hans",
            serviceID: entry.id
        )

        XCTAssertEqual(result.texts, ["你好\n世界"])
        XCTAssertEqual(recorder.requests.count, 1)
        let body = try XCTUnwrap(recorder.requests.first?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertTrue(messages.first?["content"]?.contains("Hello\nWorld") == true)
    }

    func testPartialUpdateGateCoalescesBurstAndAllowsLaterUpdate() {
        let gate = TranslationPartialUpdateGate(minimumInterval: 0.04)
        let start = Date(timeIntervalSinceReferenceDate: 100)

        XCTAssertTrue(gate.shouldEmit(at: start))
        XCTAssertFalse(gate.shouldEmit(at: start.addingTimeInterval(0.01)))
        XCTAssertTrue(gate.shouldEmit(at: start.addingTimeInterval(0.04)))
    }

    func testSignaturesLanguageMappingsAndChunks() throws {
        XCTAssertEqual(
            BaiduTranslationProvider.signature(
                appID: "app",
                query: "hello",
                salt: "salt",
                secret: "secret"
            ),
            "4b7f3b8c77b5ee6a7a54cc35699d1fd1"
        )
        XCTAssertEqual(
            YoudaoTranslationProvider.signature(
                appKey: "app",
                texts: ["hello", "world"],
                salt: "salt",
                curtime: "1",
                appSecret: "secret"
            ),
            "09eab8dfcf726398799fd3ba96a226cb5a1e53eb7a8dbbb5c61ce14f222c54aa"
        )
        XCTAssertEqual(try BaiduTranslationProvider.languageCode("zh-Hant"), "cht")
        XCTAssertEqual(try YoudaoTranslationProvider.languageCode("zh-Hans"), "zh-CHS")
        XCTAssertEqual(try GoogleTranslationProvider.languageCode("zh-Hant"), "zh-TW")
        XCTAssertEqual(try DeepLTranslationProvider.languageCode("en", isTarget: true), "EN-US")
        XCTAssertEqual(try MicrosoftTranslationProvider.languageCode("zh-Hans"), "zh-Hans")
        XCTAssertEqual(
            TranslationProviderSupport.chunks(
                ["aa", "bb", "cc"],
                maxItems: 2,
                maxCharacters: 4
            ),
            [["aa", "bb"], ["cc"]]
        )
    }

    func testSystemTranslationOnlyRejectsUnsupportedPairBeforeStartingSession() throws {
        func pair(_ availability: TranslationLanguage.ResolvedPair.Availability)
            -> TranslationLanguage.ResolvedPair
        {
            TranslationLanguage.ResolvedPair(
                sourceCode: "en",
                targetCode: "zh-Hans",
                sourceLanguage: Locale.Language(identifier: "en"),
                targetLanguage: Locale.Language(identifier: "zh-Hans"),
                availability: availability,
                useSystemSourceDetection: false
            )
        }

        // installed / supported 都放行：LanguageAvailability 的 supported 不能当作「未安装」
        XCTAssertNoThrow(try TranslationService.requireSupportedSystemPair(pair(.installed)))
        XCTAssertNoThrow(try TranslationService.requireSupportedSystemPair(pair(.supported)))
        XCTAssertThrowsError(try TranslationService.requireSupportedSystemPair(pair(.unsupported))) { error in
            XCTAssertTrue(error.localizedDescription.contains("不支持"))
        }
    }

    // MARK: - Language detection (P0)

    func testScriptFirstLanguageDetection() {
        TranslationLanguage.clearDetectionCacheForTesting()

        XCTAssertEqual(
            TranslationLanguage.detectLanguageCodeUncached(in: "こんにちは、世界"),
            "ja"
        )
        XCTAssertEqual(
            TranslationLanguage.detectLanguageCodeUncached(in: "안녕하세요"),
            "ko"
        )
        XCTAssertEqual(
            TranslationLanguage.detectLanguageCodeUncached(in: "你好世界，这是一段中文测试"),
            "zh-Hans"
        )
        // 无假名汉字不应被判成日语
        let pureChinese = TranslationLanguage.detectLanguageCodeUncached(in: "登录")
        XCTAssertEqual(pureChinese, "zh-Hans")

        let english = TranslationLanguage.detectLanguageCodeUncached(
            in: "Hello world, this is a longer English sentence for detection."
        )
        XCTAssertEqual(english, "en")

        // 短拉丁走英语兜底
        XCTAssertEqual(
            TranslationLanguage.detectLanguageCodeUncached(in: "OK"),
            "en"
        )
    }

    func testTechnicalIdentifiersAreNotClaimedAsDetectedLanguage() {
        TranslationLanguage.clearDetectionCacheForTesting()

        let samples = [
            "chat-workbench-panel",
            "artifact-file-list",
            "XxzsAppUser",
            "ArtifactFileList",
            "get_user_info",
            "api/v2/users",
        ]
        for sample in samples {
            XCTAssertTrue(
                TranslationLanguage.looksLikeTechnicalIdentifier(sample),
                "expected identifier: \(sample)"
            )
            XCTAssertNil(
                TranslationLanguage.detectLanguageCodeUncached(in: sample),
                "identifier must not claim a language: \(sample)"
            )
            XCTAssertNil(
                TranslationLanguage.detectLanguageCode(in: sample),
                "cached path must also be nil: \(sample)"
            )
        }

        // 自然英文短语仍应识别
        XCTAssertFalse(TranslationLanguage.looksLikeTechnicalIdentifier("Hello world"))
        XCTAssertEqual(
            TranslationLanguage.detectLanguageCodeUncached(
                in: "Hello world, this is a longer English sentence for detection."
            ),
            "en"
        )
    }

    func testLanguageDetectionCacheAndConstraint() {
        TranslationLanguage.clearDetectionCacheForTesting()

        let text = "自动识别缓存测试文本一段"
        let first = TranslationLanguage.detectLanguageCode(in: text)
        let second = TranslationLanguage.detectLanguageCode(in: text)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, "zh-Hans")

        // 只允许英语时，中文检测应收敛到允许集（脚本不匹配则落到 en）
        let constrained = TranslationLanguage.detectLanguageCode(
            in: text,
            preferredAmong: ["en", "en-GB"]
        )
        XCTAssertTrue(
            TranslationLanguage.areEquivalent(constrained ?? "", "en"),
            "expected English fallback, got \(constrained ?? "nil")"
        )

        // 允许中英时保留中文
        let among = TranslationLanguage.detectLanguageCode(
            in: text,
            preferredAmong: ["en", "zh-Hans", "ja"]
        )
        XCTAssertTrue(
            TranslationLanguage.areEquivalent(among ?? "", "zh-Hans"),
            "expected Chinese, got \(among ?? "nil")"
        )
    }

    func testConstrainDetectedSourcePrefersScriptCompatibleInstalled() {
        // 误检为日语，但已装只有中英 → 按汉字脚本落到简中
        let constrained = TranslationLanguage.constrainDetectedSource(
            "ja",
            sampleText: "设置页面标题",
            allowedSourceCodes: ["en", "zh-Hans"]
        )
        XCTAssertTrue(
            TranslationLanguage.areEquivalent(constrained ?? "", "zh-Hans"),
            "expected zh-Hans, got \(constrained ?? "nil")"
        )

        // 拉丁误检为法语 → 落到英语
        let latin = TranslationLanguage.constrainDetectedSource(
            "fr",
            sampleText: "Hello",
            allowedSourceCodes: ["en", "zh-Hans"]
        )
        XCTAssertTrue(
            TranslationLanguage.areEquivalent(latin ?? "", "en"),
            "expected English, got \(latin ?? "nil")"
        )
    }

    func testSystemTranslationErrorSuppressesFocusDismissForMissingPackOrDownloadUI() {
        XCTAssertFalse(
            PanelPresenter.shouldSuppressFocusDismissAfterSystemFailure(
                message: "翻译网络错误：timeout",
                hasDownloadUI: false
            )
        )
        XCTAssertTrue(
            PanelPresenter.shouldSuppressFocusDismissAfterSystemFailure(
                message: "",
                hasDownloadUI: true
            )
        )
        XCTAssertTrue(
            PanelPresenter.shouldSuppressFocusDismissAfterSystemFailure(
                message: "系统需要「英语 → 简体中文」语言包才能翻译。请打开系统设置",
                hasDownloadUI: false
            )
        )
        XCTAssertTrue(PanelPresenter.isMissingLanguagePackMessage("Language pack not installed"))
    }

    func testAllCloudProvidersBuildExpectedRequestsAndParseSuccess() async throws {
        let recorder = TranslationRequestRecorder()
        TranslationURLProtocolStub.handler = { request in
            recorder.append(request)
            let json: String
            switch request.url?.host {
            case "fanyi-api.baidu.com":
                json = #"{"from":"en","to":"zh","trans_result":[{"src":"Hello","dst":"百度"}]}"#
            case "openapi.youdao.com":
                json = #"{"errorCode":"0","translateResults":[{"query":"Hello","translation":"有道","type":"en2zh-CHS"}]}"#
            case "translation.googleapis.com":
                json = #"{"data":{"translations":[{"detectedSourceLanguage":"en","translatedText":"Google"}]}}"#
            case "api-free.deepl.com":
                json = #"{"translations":[{"detected_source_language":"EN","text":"DeepL"}]}"#
            case "api.cognitive.microsofttranslator.com":
                json = #"[{"detectedLanguage":{"language":"en","score":1},"translations":[{"text":"Microsoft","to":"zh-Hans"}]}]"#
            case "open.volcengineapi.com":
                json = #"{"ResponseMetadata":{"RequestId":"test"},"Result":{"TranslationList":[{"DetectedSourceLanguage":"en","Translation":"火山"}]}}"#
            case "tmt.tencentcloudapi.com":
                json = #"{"Response":{"Source":"en","TargetText":"腾讯"}}"#
            case "mt.cn-hangzhou.aliyuncs.com":
                json = #"{"TranslateGeneralResponse":{"Code":200,"Data":{"DetectedLanguage":"en","Translated":"阿里"}}}"#
            case "api.interpreter.caiyunai.com":
                json = #"{"target":["彩云"]}"#
            case "api.niutrans.com":
                json = #"{"from":"en","to":"zh","tgt_text":"小牛"}"#
            case "translate.us-east-1.amazonaws.com":
                json = #"{"SourceLanguageCode":"en","TargetLanguageCode":"zh","TranslatedText":"Amazon"}"#
            default:
                throw URLError(.badURL)
            }
            return .init(statusCode: 200, data: Data(json.utf8))
        }
        let session = stubSession()

        let responses = try await [
            BaiduTranslationProvider(session: session).translate(
                ["Hello"], sourceLanguage: "en", targetLanguage: "zh-Hans",
                entry: configuredEntry(.baidu)
            ),
            YoudaoTranslationProvider(session: session).translate(
                ["Hello"], sourceLanguage: "en", targetLanguage: "zh-Hans",
                entry: configuredEntry(.youdao)
            ),
            GoogleTranslationProvider(session: session).translate(
                ["Hello"], sourceLanguage: "en", targetLanguage: "zh-Hans",
                entry: configuredEntry(.google)
            ),
            DeepLTranslationProvider(session: session).translate(
                ["Hello"], sourceLanguage: "en", targetLanguage: "zh-Hans",
                entry: configuredEntry(.deepl)
            ),
            MicrosoftTranslationProvider(session: session).translate(
                ["Hello"], sourceLanguage: "en", targetLanguage: "zh-Hans",
                entry: configuredEntry(.microsoft)
            ),
            VolcengineTranslationProvider(session: session).translate(
                ["Hello"], sourceLanguage: "en", targetLanguage: "zh-Hans",
                entry: configuredEntry(.volcengine)
            ),
            TencentTranslationProvider(session: session).translate(
                ["Hello"], sourceLanguage: "en", targetLanguage: "zh-Hans",
                entry: configuredEntry(.tencent)
            ),
            AliyunTranslationProvider(session: session).translate(
                ["Hello"], sourceLanguage: "en", targetLanguage: "zh-Hans",
                entry: configuredEntry(.aliyun)
            ),
            CaiyunTranslationProvider(session: session).translate(
                ["Hello"], sourceLanguage: "en", targetLanguage: "zh-Hans",
                entry: configuredEntry(.caiyun)
            ),
            NiuTransTranslationProvider(session: session).translate(
                ["Hello"], sourceLanguage: "en", targetLanguage: "zh-Hans",
                entry: configuredEntry(.niutrans)
            ),
            AmazonTranslationProvider(session: session).translate(
                ["Hello"], sourceLanguage: "en", targetLanguage: "zh-Hans",
                entry: configuredEntry(.amazon)
            ),
        ]

        XCTAssertEqual(
            responses.map(\.texts),
            [["百度"], ["有道"], ["Google"], ["DeepL"], ["Microsoft"], ["火山"], ["腾讯"], ["阿里"], ["彩云"], ["小牛"], ["Amazon"]]
        )
        let requests = recorder.requests
        XCTAssertEqual(requests.count, 11)
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "POST" })
        XCTAssertEqual(requests.first { $0.url?.host == "translation.googleapis.com" }?.url?.query, "key=google-key")
        XCTAssertEqual(
            requests.first { $0.url?.host == "api-free.deepl.com" }?
                .value(forHTTPHeaderField: "Authorization"),
            "DeepL-Auth-Key deepl-key:fx"
        )
        XCTAssertEqual(
            requests.first { $0.url?.host == "api.cognitive.microsofttranslator.com" }?
                .value(forHTTPHeaderField: "Ocp-Apim-Subscription-Region"),
            "eastasia"
        )
        let baiduBody = String(
            data: try XCTUnwrap(requests.first { $0.url?.host == "fanyi-api.baidu.com" }?.httpBody),
            encoding: .utf8
        )
        XCTAssertTrue(baiduBody?.contains("from=en") == true)
        XCTAssertTrue(baiduBody?.contains("to=zh") == true)
        XCTAssertNotNil(
            requests.first { $0.url?.host == "open.volcengineapi.com" }?.value(forHTTPHeaderField: "Authorization")
        )
        XCTAssertEqual(
            requests.first { $0.url?.host == "open.volcengineapi.com" }?.url?.query,
            "Action=TranslateText&Version=2020-06-01"
        )
        XCTAssertTrue(
            requests.first { $0.url?.host == "tmt.tencentcloudapi.com" }?
                .value(forHTTPHeaderField: "Authorization")?.hasPrefix("TC3-HMAC-SHA256") == true
        )
        XCTAssertEqual(
            requests.first { $0.url?.host == "api.interpreter.caiyunai.com" }?
                .value(forHTTPHeaderField: "X-Authorization"),
            "token caiyun-token"
        )
        XCTAssertTrue(
            requests.first { $0.url?.host == "translate.us-east-1.amazonaws.com" }?
                .value(forHTTPHeaderField: "Authorization")?.hasPrefix("AWS4-HMAC-SHA256") == true
        )
    }

    func testResponseValidationHTTPMappingAndCancellation() async throws {
        XCTAssertThrowsError(
            try TranslationProviderSupport.validatedTranslations([""], expectedCount: 1)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("译文为空"))
        }
        XCTAssertThrowsError(
            try TranslationProviderSupport.validatedTranslations([], expectedCount: 1)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("数量"))
        }

        let url = try XCTUnwrap(URL(string: "https://example.com"))
        let expected: [(Int, String)] = [
            (401, "认证失败"),
            (403, "认证失败"),
            (429, "过于频繁"),
            (500, "暂时不可用"),
        ]
        for (status, message) in expected {
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
            )
            XCTAssertThrowsError(
                try TranslationProviderSupport.requireSuccess(response, data: Data())
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains(message))
            }
        }

        let provider = GoogleTranslationProvider(session: stubSession())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await provider.translate(
                ["Hello"],
                sourceLanguage: "en",
                targetLanguage: "zh-Hans",
                entry: configuredEntry(.google)
            )
        }
        do {
            _ = try await task.value
            XCTFail("取消后的任务不应发送请求")
        } catch is CancellationError {
            // expected
        }
    }

    func testDefaultServiceRoutingAndSameLanguageShortCircuit() async throws {
        let suite = "TranslationRoutingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = TranslationRequestRecorder()
        TranslationURLProtocolStub.handler = { request in
            recorder.append(request)
            let json = #"{"data":{"translations":[{"detectedSourceLanguage":"en","translatedText":"你好"}]}}"#
            return .init(statusCode: 200, data: Data(json.utf8))
        }

        let settings = SettingsStore(defaults: defaults)
        let google = configuredEntry(.google)
        settings.translationServices.append(google)
        settings.setDefaultTranslationServiceID(google.id)
        let service = TranslationService(settings: settings, session: stubSession())

        let shortCircuited = try await service.translate(
            ["Hello"],
            sourceLanguage: "en",
            targetLanguage: "en"
        )
        XCTAssertTrue(shortCircuited.isSameLanguage)
        XCTAssertTrue(recorder.requests.isEmpty)

        let translated = try await service.translate(
            ["Hello"],
            sourceLanguage: "en",
            targetLanguage: "zh-Hans"
        )
        XCTAssertEqual(translated.texts, ["你好"])
        XCTAssertEqual(recorder.requests.count, 1)
    }

    func testVerifyAlwaysSendsANewRequestAfterPreviousVerification() async throws {
        let suite = "TranslationVerifyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let recorder = TranslationRequestRecorder()
        TranslationURLProtocolStub.handler = { request in
            recorder.append(request)
            if recorder.requests.count == 1 {
                return .init(statusCode: 500, data: Data(#"{"message":"temporary failure"}"#.utf8))
            }
            let json = #"{"data":{"translations":[{"detectedSourceLanguage":"en","translatedText":"你好"}]}}"#
            return .init(statusCode: 200, data: Data(json.utf8))
        }

        let settings = SettingsStore(defaults: defaults)
        settings.targetLanguage = "zh-Hans"
        let google = configuredEntry(.google)
        settings.translationServices.append(google)
        let service = TranslationService(settings: settings, session: stubSession())

        let first = await service.verify(serviceID: google.id)
        let second = await service.verify(serviceID: google.id)
        let third = await service.verify(serviceID: google.id)

        XCTAssertTrue(first.contains("暂时不可用"))
        XCTAssertTrue(second.contains("验证成功"))
        XCTAssertTrue(third.contains("验证成功"))
        XCTAssertEqual(recorder.requests.count, 3)
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private func configuredEntry(_ kind: TranslationServiceKind) -> TranslationServiceEntry {
        var entry = TranslationServiceEntry.make(kind: kind)
        entry.isEnabled = true
        entry.privacyAccepted = true
        switch kind {
        case .system:
            break
        case .baidu:
            entry.baidu = BaiduTranslationConfig(appID: "baidu-app", secretKey: "baidu-secret")
        case .youdao:
            entry.youdao = YoudaoTranslationConfig(appKey: "youdao-app", appSecret: "youdao-secret")
        case .google:
            entry.google = GoogleTranslationConfig(apiKey: "google-key")
        case .deepl:
            entry.deepl = DeepLTranslationConfig(authKey: "deepl-key:fx")
        case .microsoft:
            entry.microsoft = MicrosoftTranslationConfig(
                subscriptionKey: "microsoft-key",
                region: "eastasia"
            )
        case .volcengine:
            entry.volcengine = VolcengineTranslationConfig(
                accessKey: "volc-access",
                secretKey: "volc-secret",
                region: "cn-north-1"
            )
        case .tencent:
            entry.tencent = TencentTranslationConfig(
                secretID: "tencent-id",
                secretKey: "tencent-secret",
                region: "ap-beijing"
            )
        case .aliyun:
            entry.aliyun = AliyunTranslationConfig(
                accessKeyID: "aliyun-id",
                accessKeySecret: "aliyun-secret"
            )
        case .caiyun:
            entry.caiyun = CaiyunTranslationConfig(token: "caiyun-token")
        case .niutrans:
            entry.niutrans = NiuTransTranslationConfig(apiKey: "niutrans-key")
        case .amazon:
            entry.amazon = AmazonTranslationConfig(
                accessKeyID: "amazon-id",
                secretAccessKey: "amazon-secret",
                region: "us-east-1"
            )
        case .openai, .openrouter, .deepseek, .qwen, .zhipu,
             .siliconflow, .groq, .grok, .kimi:
            entry.openAICompatible = OpenAICompatibleTranslationConfig(
                apiKey: "llm-key",
                model: "test-model"
            )
        case .ollama:
            entry.localModel = LocalModelTranslationConfig(
                baseURL: "http://127.0.0.1:11434",
                model: "qwen3:8b"
            )
        case .lmStudio:
            entry.localModel = LocalModelTranslationConfig(
                baseURL: "http://127.0.0.1:1234/v1",
                model: "local-model",
                apiKey: "local-key"
            )
        }
        return entry
    }
}
