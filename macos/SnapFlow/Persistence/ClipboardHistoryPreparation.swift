import AppKit
import CryptoKit
import Foundation
import ImageIO

struct ClipboardHistoryPreparedItem: Sendable {
    let payloads: [ClipboardPayload]
    let fingerprint: String
    let title: String
    let searchText: String
}

struct ClipboardHistoryMetadata: Sendable {
    let title: String
    let searchText: String
}

/// 在非主线程准备剪切板历史数据，避免哈希和图片元数据处理占用主线程。
enum ClipboardHistoryPreparation {
    private static let imageContentTypes = Set(
        [
            NSPasteboard.PasteboardType.png,
            .tiff,
            .init("public.jpeg"),
            .init("public.heic"),
        ].map(\.rawValue)
    )

    static func prepare(_ payloads: [ClipboardPayload]) -> ClipboardHistoryPreparedItem {
        let metadata = metadata(for: payloads)
        return ClipboardHistoryPreparedItem(
            payloads: payloads,
            fingerprint: fingerprint(payloads),
            title: metadata.title,
            searchText: metadata.searchText
        )
    }

    static func fingerprint(_ payloads: [ClipboardPayload]) -> String {
        var hasher = SHA256()
        for payload in payloads.sorted(by: { $0.type < $1.type }) {
            hasher.update(data: Data(payload.type.utf8))
            hasher.update(data: payload.value)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func metadata(for payloads: [ClipboardPayload]) -> ClipboardHistoryMetadata {
        let textType = NSPasteboard.PasteboardType.string.rawValue
        if let data = payloads.first(where: { $0.type == textType })?.value,
           let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
        {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return ClipboardHistoryMetadata(
                title: String(trimmed.prefix(160)),
                searchText: trimmed
            )
        }

        let fileType = NSPasteboard.PasteboardType.fileURL.rawValue
        let urls = payloads
            .filter { $0.type == fileType }
            .compactMap { String(data: $0.value, encoding: .utf8) }
            .compactMap(URL.init(string:))
        if !urls.isEmpty {
            let names = urls.map(\.lastPathComponent)
            let title = names.joined(separator: ", ")
            return ClipboardHistoryMetadata(title: title, searchText: names.joined(separator: " "))
        }

        if let data = payloads.first(where: { imageContentTypes.contains($0.type) })?.value,
           let dimensions = imageDimensions(from: data)
        {
            let title = String(format: L10n.string("图片 %lld × %lld"), dimensions.width, dimensions.height)
            return ClipboardHistoryMetadata(title: title, searchText: title)
        }

        return ClipboardHistoryMetadata(title: L10n.string("剪切板内容"), searchText: L10n.string("剪切板内容"))
    }

    private static func imageDimensions(from data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0
        else {
            return nil
        }
        return (width, height)
    }
}

/// 串行执行预处理，避免多个大剪切板内容同时计算造成 CPU 和内存峰值。
actor ClipboardHistoryPreparationQueue {
    func prepare(_ payloads: [ClipboardPayload]) -> ClipboardHistoryPreparedItem {
        ClipboardHistoryPreparation.prepare(payloads)
    }
}
