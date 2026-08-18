import CoreGraphics
import XCTest
@testable import SnapFlow

final class ScrollCaptureFrameMatcherTests: XCTestCase {
    func testByteIdenticalFramesAreDetected() {
        let first = makeFrame(width: 4, height: 4, value: 80)
        let same = makeFrame(width: 4, height: 4, value: 80)
        let changed = makeFrame(width: 4, height: 4, value: 81)

        XCTAssertTrue(ScrollCaptureFrameMatcher.isByteIdentical(first, same))
        XCTAssertFalse(ScrollCaptureFrameMatcher.isByteIdentical(first, changed))
    }

    func testOffsetUsesAbsoluteValueAndRejectsSubpixelJitter() {
        XCTAssertNil(ScrollCaptureFrameMatcher.acceptedOffset(2))
        XCTAssertNil(ScrollCaptureFrameMatcher.acceptedOffset(-2))
        XCTAssertEqual(ScrollCaptureFrameMatcher.acceptedOffset(3), 3)
        XCTAssertEqual(ScrollCaptureFrameMatcher.acceptedOffset(-7), 7)
    }

    func testStitcherAppendsOnlyDetectedRowsToBottom() throws {
        let first = makeFrame(width: 4, height: 6, value: 40)
        let next = makeFrame(width: 4, height: 6, value: 200)
        let stitcher = ScrollCaptureStitcher()

        stitcher.setInitialFrame(first)
        XCTAssertEqual(stitcher.totalHeight, 6)

        guard case .stitched(let yOffset) = stitcher.stitch(
            newFrame: next,
            detectedOffset: 2
        ) else {
            return XCTFail("expected a stitched frame")
        }

        XCTAssertEqual(yOffset, 2)
        XCTAssertEqual(stitcher.totalHeight, 8)
        let merged = try XCTUnwrap(stitcher.mergedImage)
        XCTAssertEqual(merged.width, 4)
        XCTAssertEqual(merged.height, 8)
        XCTAssertEqual(pixelValue(in: merged, atY: 0), 200)
        XCTAssertEqual(pixelValue(in: merged, atY: 1), 200)
        XCTAssertEqual(pixelValue(in: merged, atY: 2), 40)
        XCTAssertEqual(pixelValue(in: merged, atY: 7), 40)
    }

    func testStitcherClampsOffsetToFrameHeight() {
        let first = makeFrame(width: 2, height: 3, value: 20)
        let next = makeFrame(width: 2, height: 3, value: 180)
        let stitcher = ScrollCaptureStitcher()

        stitcher.setInitialFrame(first)
        guard case .stitched(let yOffset) = stitcher.stitch(
            newFrame: next,
            detectedOffset: 20
        ) else {
            return XCTFail("expected a stitched frame")
        }

        XCTAssertEqual(yOffset, 3)
        XCTAssertEqual(stitcher.totalHeight, 6)
    }

    func testControlPanelsStayOnVisibleScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 700)
        let region = CGRect(x: 800, y: 250, width: 180, height: 300)

        let layout = ScrollCapturePanelLayout.make(region: region, visibleScreen: screen)

        XCTAssertTrue(screen.contains(layout.toolbar))
        XCTAssertTrue(screen.contains(layout.preview))
        XCTAssertLessThanOrEqual(layout.preview.maxX, region.minX)
    }

    private func makeFrame(width: Int, height: Int, value: UInt8) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(
            red: CGFloat(value) / 255,
            green: CGFloat(value) / 255,
            blue: CGFloat(value) / 255,
            alpha: 1
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func pixelValue(in image: CGImage, atY y: Int) -> UInt8 {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(
            image,
            in: CGRect(
                x: 0,
                y: -CGFloat(y),
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            )
        )
        return pixel[0]
    }
}
