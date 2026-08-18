import Foundation

/// 截图工具栏定位：优先框外下/右，其次框外上/左，四边都不够才进框内。
enum CaptureToolbarLayout {
    struct Request {
        var bounds: NSRect
        var selection: NSRect
        var editorSize: NSSize
        var actionSize: NSSize
        var optionsSize: NSSize
        var showsOptions: Bool
        var edgeInset: CGFloat = 8
        var gap: CGFloat = 6
    }

    struct Result: Equatable {
        var editor: NSRect
        var action: NSRect
        var options: NSRect
        var editorInside: Bool
        var actionInside: Bool
    }

    enum VerticalSlot: Equatable {
        case below
        case above
        case inside
    }

    enum HorizontalSlot: Equatable {
        case right
        case left
        case inside
    }

    static func frames(for request: Request) -> Result {
        let inset = request.edgeInset
        let gap = request.gap
        let bounds = request.bounds
        let rect = request.selection
        let editorSize = request.editorSize
        let actionSize = request.actionSize
        let optionsSize = request.showsOptions ? request.optionsSize : .zero
        let extraOptions = request.showsOptions ? gap + optionsSize.height : 0
        let editorClusterHeight = editorSize.height + extraOptions

        let fitsBelow = rect.minY - gap - editorClusterHeight >= inset
        let fitsAbove = rect.maxY + gap + editorClusterHeight <= bounds.height - inset
        let fitsRight = rect.maxX + gap + actionSize.width <= bounds.width - inset
        let fitsLeft = rect.minX - gap - actionSize.width >= inset

        let vertical: VerticalSlot = fitsBelow ? .below : (fitsAbove ? .above : .inside)
        let horizontal: HorizontalSlot = fitsRight ? .right : (fitsLeft ? .left : .inside)
        let editorInside = vertical == .inside
        let actionInside = horizontal == .inside

        let editorX = clampedX(
            width: editorSize.width,
            right: rect.maxX,
            boundsWidth: bounds.width,
            inset: inset
        )
        let optionsX = clampedX(
            width: optionsSize.width,
            right: rect.midX + optionsSize.width / 2,
            boundsWidth: bounds.width,
            inset: inset
        )

        let editorY: CGFloat
        let optionsY: CGFloat
        switch vertical {
        case .below:
            editorY = rect.minY - editorSize.height - gap
            optionsY = editorY - optionsSize.height - gap
        case .above:
            editorY = rect.maxY + gap
            optionsY = editorY + editorSize.height + gap
        case .inside:
            editorY = rect.minY + gap
            optionsY = editorY + editorSize.height + gap
        }

        let actionX: CGFloat
        let actionY: CGFloat
        switch horizontal {
        case .right:
            actionX = rect.maxX + gap
            actionY = rect.minY
        case .left:
            actionX = rect.minX - gap - actionSize.width
            actionY = rect.minY
        case .inside:
            actionX = clampedX(
                width: actionSize.width,
                right: rect.maxX - gap,
                boundsWidth: bounds.width,
                inset: inset
            )
            actionY = rect.minY + gap
        }

        var editorFrame = NSRect(origin: NSPoint(x: editorX, y: editorY), size: editorSize)
        var actionFrame = NSRect(origin: NSPoint(x: actionX, y: actionY), size: actionSize)
        var optionsFrame = request.showsOptions
            ? NSRect(origin: NSPoint(x: optionsX, y: optionsY), size: optionsSize)
            : .zero

        if editorInside {
            editorFrame.origin.y = rect.minY + gap
            clampY(&editorFrame, boundsHeight: bounds.height, inset: inset)
            if request.showsOptions {
                optionsFrame.origin.y = editorFrame.maxY + gap
                clampY(&optionsFrame, boundsHeight: bounds.height, inset: inset)
            }
            if actionInside {
                actionFrame.origin.y = (request.showsOptions ? optionsFrame.maxY : editorFrame.maxY) + gap
                clampY(&actionFrame, boundsHeight: bounds.height, inset: inset)
                if request.showsOptions {
                    optionsFrame.origin.y = editorFrame.maxY + gap
                    actionFrame.origin.y = optionsFrame.maxY + gap
                    clampY(&optionsFrame, boundsHeight: bounds.height, inset: inset)
                    clampY(&actionFrame, boundsHeight: bounds.height, inset: inset)
                }
            }
        } else {
            clampY(&editorFrame, boundsHeight: bounds.height, inset: inset)
            if request.showsOptions {
                clampY(&optionsFrame, boundsHeight: bounds.height, inset: inset)
            }
            clampY(&actionFrame, boundsHeight: bounds.height, inset: inset)
        }

        return Result(
            editor: editorFrame,
            action: actionFrame,
            options: optionsFrame,
            editorInside: editorInside,
            actionInside: actionInside
        )
    }

    private static func clampedX(
        width: CGFloat,
        right: CGFloat,
        boundsWidth: CGFloat,
        inset: CGFloat
    ) -> CGFloat {
        min(max(inset, right - width), max(inset, boundsWidth - width - inset))
    }

    private static func clampY(_ frame: inout NSRect, boundsHeight: CGFloat, inset: CGFloat) {
        let minY = inset
        let maxY = max(minY, boundsHeight - frame.height - inset)
        frame.origin.y = min(max(frame.origin.y, minY), maxY)
    }
}
