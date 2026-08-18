import CoreGraphics
import XCTest
@testable import SnapFlow

final class ScreenGeometryTests: XCTestCase {
    func testClipboardPopupConstrainsCursorPositionToVisibleFrame() {
        let visible = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let size = NSSize(width: 360, height: 560)
        let origin = ClipboardPopupPosition.constrained(
            NSPoint(x: 990, y: -20),
            size: size,
            visibleFrame: visible
        )
        XCTAssertEqual(origin, NSPoint(x: 640, y: 0))
    }

    func testClipboardPopupRestoresNormalizedLastPosition() {
        let origin = ClipboardPopupPosition.lastPositionOrigin(
            size: NSSize(width: 360, height: 560),
            visibleFrame: NSRect(x: -1728, y: 0, width: 1728, height: 1080),
            relativePosition: NSPoint(x: 0.5, y: 0.8)
        )
        XCTAssertEqual(origin, NSPoint(x: -1044, y: 304))
    }

    func testAXRectUsesItsPhysicalDisplayForCoordinateConversion() {
        let displayBounds = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 0, y: 1080, width: 1920, height: 1080),
        ]
        let appKitFrame = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        let caret = CGRect(x: 900, y: 1300, width: 2, height: 24)

        XCTAssertEqual(
            ScreenGeometry.displayIndex(forAXRect: caret, displayBounds: displayBounds),
            1
        )
        XCTAssertEqual(
            ScreenGeometry.axGlobalRectToAppKit(
                caret,
                displayBounds: displayBounds[1],
                appKitFrame: appKitFrame
            ),
            CGRect(x: 900, y: -244, width: 2, height: 24)
        )

        let sharedEdgeCaret = CGRect(x: 1920, y: 500, width: 0, height: 24)
        XCTAssertNil(
            ScreenGeometry.displayIndex(
                forAXRect: sharedEdgeCaret,
                displayBounds: [
                    displayBounds[0],
                    CGRect(x: 1920, y: 0, width: 1920, height: 1080),
                ]
            )
        )
    }

    func testVisionNormalizedBoxToPixelRect() {
        // Vision: origin bottom-left, normalized
        let box = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.1)
        let pixel = ScreenGeometry.visionNormalizedBoxToPixelRect(box, imageWidth: 1000, imageHeight: 1000)
        XCTAssertEqual(pixel.origin.x, 100, accuracy: 0.001)
        XCTAssertEqual(pixel.width, 500, accuracy: 0.001)
        XCTAssertEqual(pixel.height, 100, accuracy: 0.001)
        // y from top: (1 - 0.2 - 0.1) * 1000 = 700
        XCTAssertEqual(pixel.origin.y, 700, accuracy: 0.001)
    }

    func testAppKitGlobalRectToDisplayLocal() {
        let display = CGRect(x: 100, y: 200, width: 1920, height: 1080)
        let global = CGRect(x: 200, y: 300, width: 100, height: 50)
        let local = ScreenGeometry.appKitGlobalRectToDisplayLocal(global, displayBounds: display)
        XCTAssertEqual(local.origin.x, 100, accuracy: 0.001)
        XCTAssertEqual(local.width, 100, accuracy: 0.001)
        XCTAssertEqual(local.height, 50, accuracy: 0.001)
        // display maxY = 1280; global maxY = 350; yFromTop = 1280 - 350 = 930
        XCTAssertEqual(local.origin.y, 930, accuracy: 0.001)
    }
}
