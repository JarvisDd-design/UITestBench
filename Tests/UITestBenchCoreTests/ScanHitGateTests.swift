import XCTest
@testable import UITestBenchCore

/// 连续两帧读到同一个链接才算命中：单帧误读不会触发下载。
final class ScanHitGateTests: XCTestCase {
    private let link = DownloadLinkParser.parse("https://example.com/app.apk")!

    func testRequiresTwoConsecutiveDetections() {
        let gate = ScanHitGate()

        XCTAssertFalse(gate.register(link: link, at: 0))
        XCTAssertTrue(gate.register(link: link, at: 0.1))
    }

    func testResetsWhenThePayloadChanges() {
        let gate = ScanHitGate()
        let other = DownloadLinkParser.parse("https://example.com/other.apk")!

        XCTAssertFalse(gate.register(link: link, at: 0))
        XCTAssertFalse(gate.register(link: other, at: 0.1))
        XCTAssertFalse(gate.register(link: link, at: 0.2))
        XCTAssertTrue(gate.register(link: link, at: 0.3))
    }

    func testResetsWhenTheConfirmationWindowExpires() {
        let gate = ScanHitGate()

        XCTAssertFalse(gate.register(link: link, at: 0))
        XCTAssertFalse(gate.register(link: link, at: 1.0))
        XCTAssertTrue(gate.register(link: link, at: 1.1))
    }

    /// 中间有一帧没看到码，连续计数必须归零，不能把两次偶然检测拼成命中。
    func testAMissingFrameResetsTheConfirmation() {
        let gate = ScanHitGate()

        XCTAssertFalse(gate.register(link: link, at: 0))
        gate.registerNoCode()
        XCTAssertFalse(gate.register(link: link, at: 0.1))
        XCTAssertTrue(gate.register(link: link, at: 0.2))
    }

    func testEmitsOnlyOncePerLink() {
        let gate = ScanHitGate()

        XCTAssertFalse(gate.register(link: link, at: 0))
        XCTAssertTrue(gate.register(link: link, at: 0.1))
        XCTAssertFalse(gate.register(link: link, at: 0.2))
        XCTAssertFalse(gate.register(link: link, at: 0.3))
    }

    func testResetAllowsTheSameLinkToBeScannedAgain() {
        let gate = ScanHitGate()
        XCTAssertFalse(gate.register(link: link, at: 0))
        XCTAssertTrue(gate.register(link: link, at: 0.1))

        gate.reset()

        XCTAssertFalse(gate.register(link: link, at: 0.2))
        XCTAssertTrue(gate.register(link: link, at: 0.3))
    }

    func testThrottlesNotALinkHints() {
        let gate = ScanHitGate()

        XCTAssertTrue(gate.registerNotALink(at: 0))
        XCTAssertFalse(gate.registerNotALink(at: 0.5))
        XCTAssertTrue(gate.registerNotALink(at: 2.0))
    }

    func testARealHitClearsPendingNotALinkHintState() {
        let gate = ScanHitGate()

        XCTAssertTrue(gate.registerNotALink(at: 0))
        XCTAssertFalse(gate.register(link: link, at: 0.1))
        XCTAssertTrue(gate.register(link: link, at: 0.2))
    }
}
