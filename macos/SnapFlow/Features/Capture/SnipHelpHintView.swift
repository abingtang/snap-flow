import AppKit

/// 截图框选操作提示卡片：圆角 + 快捷键徽章 + 说明。
/// 字号固定 11pt；通过收紧边距/行距缩小占用面积。支持四角放置以躲避选区。
final class SnipHelpHintView: NSView {
    struct Row {
        let key: String
        let detail: String
    }

    enum Anchor: CaseIterable {
        case bottomLeading
        case bottomTrailing
        case topLeading
        case topTrailing
    }

    private var rows: [Row] = []
    private var cardSize: NSSize = .zero

    private let margin: CGFloat = 10
    private let padH: CGFloat = 8
    private let padV: CGFloat = 6
    private let rowGap: CGFloat = 4
    private let keyColW: CGFloat = 64
    private let colGap: CGFloat = 6
    private let detailMaxW: CGFloat = 168
    private let rowH: CGFloat = 20
    private let badgeH: CGFloat = 18
    private let corner: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = corner
        layer?.backgroundColor = SnipStyle.helpBG.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 更新文案并重算卡片尺寸；位置由 `place(in:anchor:)` 决定。
    func setRows(_ rows: [Row]) {
        self.rows = rows
        let height = padV * 2 + CGFloat(max(rows.count, 1)) * rowH
            + CGFloat(max(rows.count - 1, 0)) * rowGap
        let width = padH * 2 + keyColW + colGap + detailMaxW
        cardSize = NSSize(width: width, height: height)
        // 保留当前 origin，仅同步 size（避免 setRows 时跳回左下）
        var f = frame
        f.size = cardSize
        frame = f
        needsDisplay = true
    }

    /// 计算某锚点下的 frame（不修改自身）。
    func frame(for anchor: Anchor, in containerBounds: NSRect) -> NSRect {
        let size = cardSize.width > 0 ? cardSize : intrinsicCardSize
        let m = margin
        let origin: NSPoint
        switch anchor {
        case .bottomLeading:
            origin = NSPoint(x: m, y: m)
        case .bottomTrailing:
            origin = NSPoint(x: containerBounds.width - m - size.width, y: m)
        case .topLeading:
            origin = NSPoint(x: m, y: containerBounds.height - m - size.height)
        case .topTrailing:
            origin = NSPoint(
                x: containerBounds.width - m - size.width,
                y: containerBounds.height - m - size.height
            )
        }
        return NSRect(origin: origin, size: size)
    }

    func place(in containerBounds: NSRect, anchor: Anchor) {
        frame = frame(for: anchor, in: containerBounds)
    }

    private var intrinsicCardSize: NSSize {
        let height = padV * 2 + CGFloat(max(rows.count, 1)) * rowH
            + CGFloat(max(rows.count - 1, 0)) * rowGap
        let width = padH * 2 + keyColW + colGap + detailMaxW
        return NSSize(width: width, height: height)
    }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard !rows.isEmpty else { return }

        // 字号保持 11pt，不随卡片缩小
        let keyFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let detailFont = NSFont.systemFont(ofSize: 11, weight: .regular)
        let keyColor = NSColor.white.withAlphaComponent(0.95)
        let detailColor = NSColor.white.withAlphaComponent(0.84)
        let badgeFill = NSColor.white.withAlphaComponent(0.14)

        var y = bounds.maxY - padV - rowH
        for row in rows {
            let keyAttrs: [NSAttributedString.Key: Any] = [
                .font: keyFont,
                .foregroundColor: keyColor,
            ]
            let keySize = (row.key as NSString).size(withAttributes: keyAttrs)
            let badgeW = min(keyColW, max(32, keySize.width + 12))
            let badgeX = padH + (keyColW - badgeW) / 2
            let badgeY = y + (rowH - badgeH) / 2
            let badgeRect = NSRect(x: badgeX, y: badgeY, width: badgeW, height: badgeH)
            badgeFill.setFill()
            NSBezierPath(roundedRect: badgeRect, xRadius: 5, yRadius: 5).fill()

            let keyPt = NSPoint(
                x: badgeRect.midX - keySize.width / 2,
                y: badgeRect.midY - keySize.height / 2
            )
            (row.key as NSString).draw(at: keyPt, withAttributes: keyAttrs)

            let detailAttrs: [NSAttributedString.Key: Any] = [
                .font: detailFont,
                .foregroundColor: detailColor,
            ]
            let detailX = padH + keyColW + colGap
            let detailSize = (row.detail as NSString).size(withAttributes: detailAttrs)
            let detailPt = NSPoint(
                x: detailX,
                y: y + (rowH - detailSize.height) / 2
            )
            let drawRect = NSRect(
                x: detailX,
                y: detailPt.y,
                width: detailMaxW,
                height: detailSize.height
            )
            (row.detail as NSString).draw(
                with: drawRect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: detailAttrs
            )

            y -= rowH + rowGap
        }
    }
}
