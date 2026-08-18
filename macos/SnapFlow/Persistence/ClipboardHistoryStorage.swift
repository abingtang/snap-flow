import Foundation

/// 剪切板 SwiftData 库路径。
///
/// `~/Library/Application Support/SnapFlow/ClipboardHistory/clipboard-history.store`
enum ClipboardHistoryStorage {
    static let storeFileName = "clipboard-history.store"
    static let directoryName = "ClipboardHistory"

    static var directoryURL: URL {
        FeatureHistoryIO.applicationSupportRoot
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static var storeURL: URL {
        directoryURL.appendingPathComponent(storeFileName)
    }

    static var supportDirectoryURL: URL {
        directoryURL.appendingPathComponent(
            ".\(storeFileName.replacingOccurrences(of: ".store", with: ""))_SUPPORT",
            isDirectory: true
        )
    }
}
