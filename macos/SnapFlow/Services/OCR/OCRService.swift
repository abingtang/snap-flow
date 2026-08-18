import CoreGraphics
import Foundation
import Vision

enum OCRError: LocalizedError {
    case emptyImage
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyImage: L10n.string("图像为空")
        case .recognitionFailed(let msg): String(format: L10n.string("OCR 失败：%@"), msg)
        }
    }
}

private final class OCRRecognitionState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[OCRLine], Error>?
    private var request: VNRequest?
    private var cancelled = false
    private var completed = false

    func setContinuation(_ continuation: CheckedContinuation<[OCRLine], Error>) {
        lock.lock()
        let shouldCancel = cancelled || completed
        if !shouldCancel {
            self.continuation = continuation
        }
        lock.unlock()

        if shouldCancel {
            continuation.resume(throwing: CancellationError())
        }
    }

    func setRequest(_ request: VNRequest) {
        lock.lock()
        let shouldCancel = cancelled || completed
        if !shouldCancel {
            self.request = request
        }
        lock.unlock()

        if shouldCancel {
            request.cancel()
        }
    }

    func cancel() {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        cancelled = true
        completed = true
        let request = self.request
        self.request = nil
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        request?.cancel()
        continuation?.resume(throwing: CancellationError())
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func finish(_ result: Result<[OCRLine], Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let cancelled = self.cancelled
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        guard !cancelled, let continuation else { return }
        continuation.resume(with: result)
    }
}

/// Vision `perform` 是同步阻塞调用，必须在后台队列执行，否则主线程转菊花、快捷键全失效。
final class OCRService: TextRecognizing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.snapflow.ocr", qos: .userInitiated)

    func recognize(_ image: CGImage, languages: [String]? = nil) async throws -> [OCRLine] {
        guard image.width > 0, image.height > 0 else {
            throw OCRError.emptyImage
        }

        let state = OCRRecognitionState()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[OCRLine], Error>) in
                state.setContinuation(continuation)
                queue.async {
                    guard !state.isCancelled() else { return }
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    if let languages, !languages.isEmpty {
                        request.recognitionLanguages = languages
                    } else {
                        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP"]
                    }
                    request.automaticallyDetectsLanguage = true
                    state.setRequest(request)
                    guard !state.isCancelled() else { return }

                    let handler = VNImageRequestHandler(cgImage: image, options: [:])
                    do {
                        try handler.perform([request])
                    } catch {
                        state.finish(.failure(OCRError.recognitionFailed(error.localizedDescription)))
                        return
                    }

                    guard !state.isCancelled() else { return }

                    let observations = request.results ?? []
                    let width = image.width
                    let height = image.height
                    var lines: [OCRLine] = []
                    for obs in observations {
                        guard let top = obs.topCandidates(1).first else { continue }
                        let pixelBox = ScreenGeometry.visionNormalizedBoxToPixelRect(
                            obs.boundingBox,
                            imageWidth: width,
                            imageHeight: height
                        )
                        lines.append(
                            OCRLine(
                                text: top.string,
                                boundingBox: pixelBox,
                                confidence: top.confidence
                            )
                        )
                    }
                    lines.sort {
                        if abs($0.boundingBox.minY - $1.boundingBox.minY) < 8 {
                            return $0.boundingBox.minX < $1.boundingBox.minX
                        }
                        return $0.boundingBox.minY < $1.boundingBox.minY
                    }
                    state.finish(.success(lines))
                }
            }
        }, onCancel: {
            state.cancel()
        })
    }
}
