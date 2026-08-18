import AppKit
import Combine
import SwiftUI
import Translation

/// 通过 SwiftUI `.translationTask` 获取 `TranslationSession`。
/// 保证：continuation 只 resume 一次、超时失败、不会永久卡在「正在翻译」。
@MainActor
final class TranslationSessionHost {
    private let model = HostModel()
    private var panel: NSPanel?
    private var requestID: UInt64 = 0
    private let requestTimeoutNs: UInt64 = 25_000_000_000 // 25s

    func translate(
        texts: [String],
        source: Locale.Language?,
        target: Locale.Language
    ) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        requestID &+= 1
        let myID = requestID

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String], Error>) in
            if let previous = model.pending {
                model.pending = nil
                previous.resume(throwing: TranslationServiceError.failed(L10n.string("上一次翻译已取消")))
            }

            let pending = TranslationPendingBox(
                requestID: myID,
                texts: texts,
                continuation: cont
            )
            // 先准备请求状态，再挂载 SwiftUI；避免首次挂载尚未完成时漏掉 configuration 更新。
            model.prepare(pending, source: source, target: target)
            ensurePanel()

            // 超时：必须 resume，否则 UI 一直转圈
            let timeoutNs = requestTimeoutNs
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + .nanoseconds(Int(timeoutNs))
            ) { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.failPendingIfNeeded(
                        requestID: myID,
                        error: TranslationServiceError.failed(L10n.string("翻译超时，请重试（系统翻译未在时限内响应）"))
                    )
                }
            }
        }
    }

    func invalidate() {
        requestID &+= 1
        guard let pending = model.pending else { return }
        model.pending = nil
        resetPanel()
        pending.resume(throwing: CancellationError())
    }

    func warmup() {
        ensurePanel()
    }

    private func failPendingIfNeeded(requestID: UInt64, error: Error) {
        guard let pending = model.pending, pending.requestID == requestID else { return }
        model.pending = nil
        resetPanel()
        pending.resume(throwing: error)
    }

    private func resetPanel() {
        model.configuration = nil
        panel?.contentView = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func ensurePanel() {
        if let panel, panel.contentView != nil {
            panel.orderFrontRegardless()
            return
        }

        let root = TranslationHostView(model: model)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 8, height: 8)

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 8, height: 8),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.alphaValue = 0.01
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: vf.minX + 2, y: vf.minY + 2))
        }
        p.contentView = hosting
        p.orderFrontRegardless()
        panel = p
    }
}

// MARK: - Pending (once-only resume)

final class TranslationPendingBox: @unchecked Sendable {
    let requestID: UInt64
    let texts: [String]
    private let continuation: CheckedContinuation<[String], Error>
    private let lock = NSLock()
    private var resumed = false

    init(
        requestID: UInt64,
        texts: [String],
        continuation: CheckedContinuation<[String], Error>
    ) {
        self.requestID = requestID
        self.texts = texts
        self.continuation = continuation
    }

    func resume(returning value: [String]) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(throwing: error)
    }
}

// MARK: - Model + View

@MainActor
final class HostModel: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    var pending: TranslationPendingBox?
    private var source: Locale.Language?
    private var target: Locale.Language?

    @discardableResult
    func prepare(
        _ job: TranslationPendingBox,
        source: Locale.Language?,
        target: Locale.Language
    ) -> Bool {
        pending = job
        if configuration != nil, self.source == source, self.target == target {
            configuration?.invalidate()
            return true
        }
        self.source = source
        self.target = target
        configuration = TranslationSession.Configuration(source: source, target: target)
        return false
    }

    func jobForExecution() -> TranslationPendingBox? {
        pending
    }

    func finish(_ job: TranslationPendingBox) {
        guard pending === job else { return }
        pending = nil
    }
}

private struct TranslationHostView: View {
    @ObservedObject var model: HostModel

    var body: some View {
        Color.clear
            .frame(width: 4, height: 4)
            .translationTask(model.configuration) { session in
                await performTranslation(session: session)
            }
    }

    private func performTranslation(session: TranslationSession) async {
        let job = await MainActor.run { model.jobForExecution() }
        guard let job else {
            NSLog("[SnapFlow] translationTask fired without pending job")
            return
        }

        nonisolated(unsafe) let sessionRef = session
        let texts = job.texts

        do {
            var ordered: [String] = []
            ordered.reserveCapacity(texts.count)
            for text in texts {
                let response = try await sessionRef.translate(text)
                ordered.append(response.targetText)
            }
            await MainActor.run { model.finish(job) }
            job.resume(returning: ordered)
        } catch {
            NSLog("[SnapFlow] translationTask error: \(error.localizedDescription)")
            await MainActor.run { model.finish(job) }
            job.resume(throwing: error)
        }
    }
}
