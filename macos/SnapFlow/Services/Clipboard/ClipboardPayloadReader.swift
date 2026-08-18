import AppKit
import Foundation

struct ClipboardPayloadReadRequest: Sendable {
    let pasteboardName: String
    let supportedTypes: Set<String>
    let ignoredTypes: Set<String>
    let imageTypes: Set<String>
    let fileType: String
    let recordsText: Bool
    let recordsImages: Bool
    let recordsFiles: Bool

    func isEnabled(_ type: String) -> Bool {
        if type == fileType { return recordsFiles }
        if imageTypes.contains(type) { return recordsImages }
        return recordsText
    }
}

struct ClipboardPayloadReadResult: Sendable {
    let allTypeRawValues: Set<String>
    let payloads: [ClipboardPayload]
    let containsIgnoredType: Bool
}

/// 在后台串行读取系统剪切板，避免数据提供方的 IPC 阻塞主线程。
actor ClipboardPayloadReader {
    func read(_ request: ClipboardPayloadReadRequest) -> ClipboardPayloadReadResult {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(request.pasteboardName))
        let allTypeRawValues = Set((pasteboard.types ?? []).map(\.rawValue))
        let containsIgnoredType = !allTypeRawValues.isDisjoint(with: request.ignoredTypes)
        guard !containsIgnoredType else {
            return ClipboardPayloadReadResult(
                allTypeRawValues: allTypeRawValues,
                payloads: [],
                containsIgnoredType: true
            )
        }

        var payloads: [ClipboardPayload] = []
        for pasteboardItem in pasteboard.pasteboardItems ?? [] {
            for type in pasteboardItem.types where request.supportedTypes.contains(type.rawValue) {
                guard request.isEnabled(type.rawValue),
                      let data = pasteboardItem.data(forType: type)
                else {
                    continue
                }
                payloads.append(ClipboardPayload(type: type.rawValue, value: data))
            }
        }

        return ClipboardPayloadReadResult(
            allTypeRawValues: allTypeRawValues,
            payloads: payloads,
            containsIgnoredType: false
        )
    }
}
