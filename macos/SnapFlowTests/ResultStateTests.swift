import AppKit
import XCTest
@testable import SnapFlow

@MainActor
final class ResultStateTests: XCTestCase {
    func testOCROperationInvalidatesOlderOperationAndEntersEmptyState() {
        let image = makeTestImage()
        let session = OCRResultSession(
            image: image.nsImage,
            cgImage: image.cgImage,
            lines: [],
            text: ""
        )

        let first = session.beginOperation()
        let second = session.beginOperation()

        XCTAssertFalse(session.isCurrent(first))
        XCTAssertTrue(session.isCurrent(second))
        XCTAssertTrue(session.isRecognizing)

        session.applyRecognition(image: image.nsImage, cgImage: image.cgImage, lines: [])

        XCTAssertTrue(session.isEmptyResult)
        XCTAssertNil(session.errorMessage)
    }

    func testTranslationPopupErrorAndLoadingKeepExistingText() {
        let service = TranslationServiceEntry.system()
        let session = TranslatePopupSession(sourceText: "Hello", services: [service])
        let item = session.serviceResults[0]
        item.text = "已有部分译文"

        session.applyError(
            "网络错误",
            serviceID: item.id,
            retryable: true
        )

        XCTAssertEqual(item.text, "已有部分译文")
        XCTAssertEqual(item.statusMessage, "网络错误")
        XCTAssertTrue(item.isRetryable)

        session.setServiceLoading(true, serviceID: item.id)

        XCTAssertEqual(item.text, "已有部分译文")
        XCTAssertTrue(item.isLoading)
        XCTAssertNil(item.statusMessage)
    }

    func testScreenTranslateServiceErrorKeepsPartialTextAndExposesSettingsAction() {
        let image = makeTestImage()
        let service = TranslationServiceEntry.system()
        let session = ScreenTranslateResultSession(
            image: image.nsImage,
            cgImage: image.cgImage,
            lines: [],
            ocrText: "Hello",
            selectedOCRServiceID: OCRServiceEntry.visionID,
            targetSelection: TranslationLanguage.systemTargetToken,
            services: [service]
        )
        let item = session.serviceResults[0]
        item.text = "已有部分译文"

        session.applyError(
            "配置未完成",
            serviceID: item.id,
            retryable: false,
            openSettings: true
        )

        XCTAssertEqual(item.text, "已有部分译文")
        XCTAssertFalse(item.isRetryable)
        XCTAssertTrue(item.canOpenSettings)
    }

    private func makeTestImage() -> (nsImage: NSImage, cgImage: CGImage) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let cgImage = context.makeImage()!
        return (
            NSImage(cgImage: cgImage, size: NSSize(width: 1, height: 1)),
            cgImage
        )
    }
}
