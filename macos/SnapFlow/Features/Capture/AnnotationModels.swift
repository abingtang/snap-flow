import AppKit
import Foundation

/// 标注工具（主工具栏）
enum AnnotateTool: String, CaseIterable, Sendable {
    case none
    case shape
    case arrow
    case pen
    case highlighter
    case text
    case mosaic
    case number
    case eraser
    case undo
    case redo

    var title: String {
        switch self {
        case .none: L10n.string("选择/移动")
        case .shape: L10n.string("形状")
        case .arrow: L10n.string("箭头")
        case .pen: L10n.string("画笔")
        case .highlighter: L10n.string("马克笔")
        case .text: L10n.string("文字")
        case .mosaic: L10n.string("马赛克")
        case .number: L10n.string("序号")
        case .eraser: L10n.string("橡皮擦")
        case .undo: L10n.string("撤销")
        case .redo: L10n.string("重做")
        }
    }

    var symbolName: String {
        switch self {
        case .none: "arrow.up.left.and.arrow.down.right"
        // 形状：方/圆组合，比 stacked rect 更贴「框选形状」
        case .shape: "square.on.circle"
        // 箭头/直线工具：斜向箭头，符合截图标注习惯
        case .arrow: "arrow.up.right"
        // 画笔：完整铅笔比 pencil.tip 更易辨认
        case .pen: "pencil"
        // 马克笔：尖头笔刷更像「粗笔划高亮」，比系统 highlighter 更易辨认
        case .highlighter: "paintbrush.pointed"
        case .text: "T" // 工具栏画成字母 T（非 SF Symbol）
        // 马赛克：实心宫格，比 split 线框更像像素块
        case .mosaic: "square.grid.3x3.fill"
        // 序号标注：实心圆数字，暗底工具栏对比更强
        case .number: "1.circle.fill"
        case .eraser: "eraser.line.dashed"
        case .undo: "arrow.uturn.backward"
        case .redo: "arrow.uturn.forward"
        }
    }

    var isDrawable: Bool {
        switch self {
        case .shape, .arrow, .pen, .highlighter, .mosaic, .text, .number, .eraser:
            true
        case .undo, .redo, .none:
            false
        }
    }
}

enum ShapeKind: Int, Sendable {
    case rectangle = 0
    case ellipse = 1
}

/// 马克笔的几何形态：只支持直线或区域，不支持自由绘画。
enum HighlighterMode: Int, Sendable {
    case line = 0
    case area = 1
}

/// 橡皮擦模式：涂抹（自由路径）或框选（矩形区域）。
enum EraserMode: Int, Sendable {
    case smear = 0
    case rect = 1
}

/// 单条标注
struct AnnotationStroke: Identifiable {
    let id: UUID
    let tool: AnnotateTool
    var shapeKind: ShapeKind = .rectangle
    var highlighterMode: HighlighterMode = .line
    var eraserMode: EraserMode = .smear
    var points: [CGPoint]
    /// 文字：中心点；形状：一角
    var start: CGPoint
    var end: CGPoint
    var text: String = ""
    var number: Int = 0
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 2.5
    var textBoxWidth: CGFloat = 40
    var textBoxHeight: CGFloat = 28
    /// 用户是否手动拖过宽度；未锁定时按内容撑开，锁定后按宽换行
    var textWidthLocked: Bool = false
    /// 文字旋转角度（度，顺时针为正在显示时取负以匹配 AppKit）
    var rotation: CGFloat = 0

    init(
        id: UUID = UUID(),
        tool: AnnotateTool,
        shapeKind: ShapeKind = .rectangle,
        highlighterMode: HighlighterMode = .line,
        eraserMode: EraserMode = .smear,
        points: [CGPoint],
        start: CGPoint,
        end: CGPoint,
        text: String = "",
        number: Int = 0,
        color: NSColor = .systemRed,
        lineWidth: CGFloat = 2.5,
        textBoxWidth: CGFloat = 40,
        textBoxHeight: CGFloat = 28,
        textWidthLocked: Bool = false,
        rotation: CGFloat = 0
    ) {
        self.id = id
        self.tool = tool
        self.shapeKind = shapeKind
        self.highlighterMode = highlighterMode
        self.eraserMode = eraserMode
        self.points = points
        self.start = start
        self.end = end
        self.text = text
        self.number = number
        self.color = color
        self.lineWidth = lineWidth
        self.textBoxWidth = textBoxWidth
        self.textBoxHeight = textBoxHeight
        self.textWidthLocked = textWidthLocked
        self.rotation = rotation
    }

    /// 文字框本地矩形（中心为 start，未旋转）
    var textLocalRect: CGRect {
        CGRect(
            x: start.x - textBoxWidth / 2,
            y: start.y - textBoxHeight / 2,
            width: textBoxWidth,
            height: textBoxHeight
        )
    }

    var bounds: CGRect {
        switch tool {
        case .pen:
            guard let first = points.first else {
                return CGRect(origin: start, size: .zero)
            }
            var r = CGRect(origin: first, size: .zero)
            for p in points { r = r.union(CGRect(origin: p, size: .zero)) }
            return r.insetBy(dx: -lineWidth, dy: -lineWidth)
        case .eraser:
            if eraserMode == .rect {
                return CGRect(
                    x: min(start.x, end.x),
                    y: min(start.y, end.y),
                    width: abs(end.x - start.x),
                    height: abs(end.y - start.y)
                )
            }
            guard let first = points.first else {
                return CGRect(origin: start, size: .zero)
            }
            var r = CGRect(origin: first, size: .zero)
            for p in points { r = r.union(CGRect(origin: p, size: .zero)) }
            return r.insetBy(dx: -lineWidth, dy: -lineWidth)
        case .text:
            return rotatedAABB(center: start, size: CGSize(width: textBoxWidth, height: textBoxHeight), degrees: rotation)
        default:
            return CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
        }
    }

    private func rotatedAABB(center: CGPoint, size: CGSize, degrees: CGFloat) -> CGRect {
        let rad = degrees * .pi / 180
        let cosA = cos(rad)
        let sinA = sin(rad)
        let hw = size.width / 2
        let hh = size.height / 2
        let corners = [
            CGPoint(x: -hw, y: -hh),
            CGPoint(x: hw, y: -hh),
            CGPoint(x: hw, y: hh),
            CGPoint(x: -hw, y: hh),
        ].map { p in
            CGPoint(
                x: center.x + p.x * cosA - p.y * sinA,
                y: center.y + p.x * sinA + p.y * cosA
            )
        }
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        let minX = xs.min() ?? center.x
        let maxX = xs.max() ?? center.x
        let minY = ys.min() ?? center.y
        let maxY = ys.max() ?? center.y
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
