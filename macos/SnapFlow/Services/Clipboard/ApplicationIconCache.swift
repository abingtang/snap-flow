import AppKit

/// 应用 / 文件图标内存缓存，避免列表每行反复问 `NSWorkspace`。
@MainActor
enum ApplicationIconCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        return cache
    }()

    /// 按 bundle id 取应用图标；找不到返回 `nil`。
    static func icon(bundleIdentifier: String) -> NSImage? {
        let key = "bundle:\(bundleIdentifier)" as NSString
        if let hit = cache.object(forKey: key) {
            return hit
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: key)
        return icon
    }

    /// 按文件路径取图标（文件类型 / 应用包）。
    static func icon(filePath: String) -> NSImage {
        let key = "path:\(filePath)" as NSString
        if let hit = cache.object(forKey: key) {
            return hit
        }
        let icon = NSWorkspace.shared.icon(forFile: filePath)
        cache.setObject(icon, forKey: key)
        return icon
    }

    static func removeAll() {
        cache.removeAllObjects()
    }
}
