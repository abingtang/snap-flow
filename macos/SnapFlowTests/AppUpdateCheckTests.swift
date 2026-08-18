import XCTest
@testable import SnapFlow

final class AppUpdateCheckTests: XCTestCase {
    func testSemanticVersionParsesPrefixAndPrerelease() {
        XCTAssertEqual(AppSemanticVersion(string: "v0.0.4"), AppSemanticVersion(string: "0.0.4"))
        XCTAssertEqual(AppSemanticVersion(string: "1.2")?.description, "1.2.0")
        XCTAssertEqual(AppSemanticVersion(string: "1.2.3-beta")?.description, "1.2.3")
        XCTAssertNil(AppSemanticVersion(string: ""))
        XCTAssertNil(AppSemanticVersion(string: "latest"))
    }

    func testSemanticVersionComparesNumerically() {
        XCTAssertTrue(AppSemanticVersion(string: "0.0.3")! < AppSemanticVersion(string: "0.0.4")!)
        XCTAssertTrue(AppSemanticVersion(string: "9.0.0")! < AppSemanticVersion(string: "10.0.0")!)
        XCTAssertFalse(AppSemanticVersion(string: "0.0.4")! < AppSemanticVersion(string: "0.0.4")!)
        XCTAssertTrue(AppSemanticVersion(string: "0.0.5")! > AppSemanticVersion(string: "0.0.4")!)
    }

    func testEvaluateReportsAvailableAndUpToDate() throws {
        let manifest = try AppUpdateManifestParser.parse(
            data: Self.validJSON(version: "0.0.5"),
            contentType: "application/json"
        )

        let available = try AppUpdateEvaluator.evaluate(currentVersion: "0.0.4", manifest: manifest)
        XCTAssertEqual(available, .available(manifest))

        let current = try AppUpdateEvaluator.evaluate(currentVersion: "0.0.5", manifest: manifest)
        XCTAssertEqual(current, .upToDate(latest: "0.0.5"))

        let newerLocal = try AppUpdateEvaluator.evaluate(currentVersion: "0.0.6", manifest: manifest)
        XCTAssertEqual(newerLocal, .upToDate(latest: "0.0.5"))
    }

    func testParseRejectsHTMLAndInsecureDownloadURL() {
        XCTAssertThrowsError(
            try AppUpdateManifestParser.parse(
                data: Data("<!DOCTYPE html><html></html>".utf8),
                contentType: "text/html; charset=utf-8"
            )
        ) { error in
            XCTAssertEqual(error as? AppUpdateCheckError, .invalidResponse)
        }

        XCTAssertThrowsError(
            try AppUpdateManifestParser.parse(
                data: Self.validJSON(version: "0.0.5", downloadURL: "http://zeycode.cn/snapflow/a.dmg"),
                contentType: "application/json"
            )
        ) { error in
            XCTAssertEqual(error as? AppUpdateCheckError, .invalidManifest)
        }
    }

    func testParseAcceptsOptionalFieldsAndHTTPSDownload() throws {
        let manifest = try AppUpdateManifestParser.parse(
            data: Self.validJSON(version: "0.0.4", includeOptionals: true),
            contentType: "application/json; charset=utf-8"
        )
        XCTAssertEqual(manifest.version, "0.0.4")
        XCTAssertEqual(manifest.build, "4")
        XCTAssertEqual(manifest.minOS, "15.0")
        XCTAssertEqual(manifest.notes, "修复若干问题")
        XCTAssertEqual(manifest.notesURL?.absoluteString, "https://zeycode.cn/snapflow/changelog.html")
        XCTAssertEqual(
            manifest.downloadURL.absoluteString,
            "https://zeycode.cn/snapflow/downloads/latest/SnapFlow-arm64.dmg"
        )
        XCTAssertFalse(manifest.mandatory)
    }

    private static func validJSON(
        version: String,
        downloadURL: String = "https://zeycode.cn/snapflow/downloads/latest/SnapFlow-arm64.dmg",
        includeOptionals: Bool = false
    ) -> Data {
        if includeOptionals {
            return Data(
                """
                {
                  "version": "\(version)",
                  "build": "4",
                  "minOS": "15.0",
                  "publishedAt": "2026-08-18T06:00:00Z",
                  "notes": "修复若干问题",
                  "notesURL": "https://zeycode.cn/snapflow/changelog.html",
                  "downloadURL": "\(downloadURL)",
                  "mandatory": false
                }
                """.utf8
            )
        }
        return Data(
            """
            {"version":"\(version)","downloadURL":"\(downloadURL)"}
            """.utf8
        )
    }
}
