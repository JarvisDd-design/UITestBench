import XCTest
@testable import UITestBenchCore

final class MirrorSettingsValidationTests: XCTestCase {
    private let validSystemImage = "https://dl.google.com/android/repository/sys-img/android/sys-img2-3.xml"

    func testRejectsEmptyHost() {
        XCTAssertNil(
            MirrorSettingsValidation.endpoints(
                repository: "http://",
                systemImage: validSystemImage
            )
        )
    }

    func testRejectsMalformedURL() {
        XCTAssertNil(
            MirrorSettingsValidation.endpoints(
                repository: "http:/x",
                systemImage: validSystemImage
            )
        )
    }

    func testRejectsUnknownScheme() {
        XCTAssertNil(
            MirrorSettingsValidation.endpoints(
                repository: "httpfoo://bar",
                systemImage: validSystemImage
            )
        )
    }

    func testAcceptsUppercaseScheme() {
        let endpoints = MirrorSettingsValidation.endpoints(
            repository: "HTTP://example.com/repository2-3.xml",
            systemImage: "HTTPS://example.com/sys-img2-3.xml"
        )
        XCTAssertEqual(endpoints?.repository.host, "example.com")
        XCTAssertEqual(endpoints?.systemImage.host, "example.com")
    }

    func testAcceptsHTTPS() {
        let endpoints = MirrorSettingsValidation.endpoints(
            repository: "https://mirror.example.com/repo/repository2-3.xml",
            systemImage: validSystemImage
        )
        XCTAssertEqual(
            endpoints?.repository.absoluteString,
            "https://mirror.example.com/repo/repository2-3.xml"
        )
        XCTAssertEqual(endpoints?.systemImage.absoluteString, validSystemImage)
    }

    func testRejectsWhenOnlySystemImageIsInvalid() {
        XCTAssertNil(
            MirrorSettingsValidation.endpoints(
                repository: "https://mirror.example.com/repository2-3.xml",
                systemImage: "httpfoo://bar"
            )
        )
    }
}
