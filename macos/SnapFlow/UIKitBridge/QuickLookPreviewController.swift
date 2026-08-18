import AppKit
import QuickLookUI

/// 调用系统快速查看(Quick Look)预览本地文件（图片 / 视频等）。
/// 历史图等已落盘资源可直接传入 URL；无文件时需先导出临时路径再调用。
@MainActor
final class QuickLookPreviewController: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    static let shared = QuickLookPreviewController()

    /// 跨线程读写预览列表；QL 数据源回调可能非隔离，故用锁保护。
    private let storage = PreviewItemStorage()
    private var bridge: ResponderBridge?

    private override init() {
        super.init()
    }

    /// 预览一组本地文件；`startingAt` 为 `urls` 中的起始下标（缺失文件会自动跳过并重映射）。
    func preview(urls: [URL], startingAt index: Int = 0) {
        let valid = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !valid.isEmpty else {
            FeedbackCenter.shared.post(L10n.string("预览文件不存在或已删除"), level: .error)
            return
        }

        let preferred: URL? = (index >= 0 && index < urls.count) ? urls[index] : nil
        let mappedIndex: Int
        if let preferred, let found = valid.firstIndex(of: preferred) {
            mappedIndex = found
        } else {
            mappedIndex = min(max(0, index), valid.count - 1)
        }
        storage.replace(urls: valid, startIndex: mappedIndex)

        NSApp.activate(ignoringOtherApps: true)
        installBridgeInKeyWindow()

        guard let panel = QLPreviewPanel.shared() else {
            FeedbackCenter.shared.post(L10n.string("无法打开系统快速查看"), level: .error)
            return
        }
        if panel.isVisible {
            panel.reloadData()
            panel.currentPreviewItemIndex = mappedIndex
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// 单文件便捷入口。
    func preview(url: URL) {
        preview(urls: [url], startingAt: 0)
    }

    // MARK: - QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        storage.count
    }

    nonisolated func previewPanel(
        _ panel: QLPreviewPanel!,
        previewItemAt index: Int
    ) -> (any QLPreviewItem)! {
        storage.url(at: index).map { $0 as NSURL }
    }

    // MARK: - Private

    private func installBridgeInKeyWindow() {
        let bridge = ensureBridge()
        let window = NSApp.keyWindow
            ?? NSApp.windows.first(where: \.isVisible)
            ?? NSApp.mainWindow
        guard let window else { return }

        if bridge.window !== window {
            bridge.removeFromSuperview()
            bridge.frame = .zero
            bridge.isHidden = true
            window.contentView?.addSubview(bridge)
        }
        window.makeFirstResponder(bridge)
    }

    private func ensureBridge() -> ResponderBridge {
        if let bridge { return bridge }
        let created = ResponderBridge()
        created.owner = self
        bridge = created
        return created
    }

    fileprivate func beginControl(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = storage.startIndex
    }

    fileprivate func endControl(_ panel: QLPreviewPanel) {
        if panel.dataSource === self {
            panel.dataSource = nil
        }
        if panel.delegate === self {
            panel.delegate = nil
        }
    }

    fileprivate var hasItems: Bool { storage.count > 0 }

    /// 不可见 NSView：挂在 key window 上承接 QL 的 accepts/begin/end 回调。
    private final class ResponderBridge: NSView {
        weak var owner: QuickLookPreviewController?

        override var acceptsFirstResponder: Bool { true }

        override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
            owner?.hasItems == true
        }

        override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
            owner?.beginControl(panel)
        }

        override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
            owner?.endControl(panel)
        }
    }
}

/// 线程安全的预览项存储，供 QL 数据源非隔离回调读取。
private final class PreviewItemStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var _startIndex = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return urls.count
    }

    var startIndex: Int {
        lock.lock()
        defer { lock.unlock() }
        return _startIndex
    }

    func replace(urls: [URL], startIndex: Int) {
        lock.lock()
        self.urls = urls
        self._startIndex = startIndex
        lock.unlock()
    }

    func url(at index: Int) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard urls.indices.contains(index) else { return nil }
        return urls[index]
    }
}
