import XCTest
@testable import UITestBenchCore

/// 一帧画面进来之后：找到哪个码、要不要提示、算不算命中。
final class ScanSessionTests: XCTestCase {
    private var detector: StubDetector!
    private var session: ScanSession!

    override func setUp() {
        super.setUp()
        detector = StubDetector()
        session = ScanSession(detector: detector)
    }

    func testEmitsAHitAfterTwoConsecutiveFrames() throws {
        detector.candidates = [candidate("https://example.com/app.apk", center: CGPoint(x: 0.5, y: 0.5))]
        let image = try makeImage()

        XCTAssertEqual(session.process(.cgImage(image), at: 0), .none)
        XCTAssertEqual(
            session.process(.cgImage(image), at: 0.1),
            .hit(DownloadLinkParser.parse("https://example.com/app.apk")!)
        )
    }

    func testEmitsNotALinkAndKeepsScanning() throws {
        let image = try makeImage()
        detector.candidates = [candidate("hello", center: CGPoint(x: 0.5, y: 0.5))]

        XCTAssertEqual(session.process(.cgImage(image), at: 0), .notALink("hello"))

        detector.candidates = [candidate("https://example.com/app.apk", center: CGPoint(x: 0.5, y: 0.5))]
        XCTAssertEqual(session.process(.cgImage(image), at: 0.1), .none)
        XCTAssertEqual(
            session.process(.cgImage(image), at: 0.2),
            .hit(DownloadLinkParser.parse("https://example.com/app.apk")!)
        )
    }

    /// 用户对准的是中间那个非链接码，就不能偷偷把远处的下载码取走。
    func testTheNearestNonLinkWinsOverAFartherLink() throws {
        let image = try makeImage()
        detector.candidates = [
            candidate("hello", center: CGPoint(x: 0.5, y: 0.5)),
            candidate("https://example.com/far.apk", center: CGPoint(x: 0.1, y: 0.1)),
        ]

        var outcomes: [ScanOutcome] = []
        for index in 0..<5 {
            outcomes.append(session.process(.cgImage(image), at: Double(index) * 0.1))
        }

        XCTAssertEqual(outcomes.first, .notALink("hello"))
        XCTAssertFalse(outcomes.contains(.hit(DownloadLinkParser.parse("https://example.com/far.apk")!)))
    }

    /// 中间一帧没看到码，下一次看到要重新累计两帧。
    func testAMissingFrameResetsTheConfirmation() throws {
        let image = try makeImage()
        detector.candidates = [candidate("https://example.com/app.apk", center: CGPoint(x: 0.5, y: 0.5))]

        XCTAssertEqual(session.process(.cgImage(image), at: 0), .none)
        detector.candidates = []
        XCTAssertEqual(session.process(.cgImage(image), at: 0.1), .none)
        detector.candidates = [candidate("https://example.com/app.apk", center: CGPoint(x: 0.5, y: 0.5))]
        XCTAssertEqual(session.process(.cgImage(image), at: 0.2), .none)
        XCTAssertNotEqual(session.process(.cgImage(image), at: 0.3), .none)
    }

    func testReturnsNoneWhenThereAreNoCodes() throws {
        let image = try makeImage()

        XCTAssertEqual(session.process(.cgImage(image), at: 0), .none)
    }

    func testReturnsNoneWhenTheDetectorThrows() throws {
        detector.error = TestError.detectionFailed
        let image = try makeImage()

        XCTAssertEqual(session.process(.cgImage(image), at: 0), .none)
    }

    /// 取景框刚出现时用户还没对准，准备期内的帧不能开始累计命中。
    func testIgnoresFramesBeforeTheArmingDeadline() throws {
        let image = try makeImage()
        detector.candidates = [candidate("https://example.com/app.apk", center: CGPoint(x: 0.5, y: 0.5))]
        let armingSession = ScanSession(detector: detector, startAt: 2)

        XCTAssertEqual(armingSession.process(.cgImage(image), at: 1.9), .none)
        // 2.0 是准备期后的第一帧，不能把 1.9 那帧算成连续确认。
        XCTAssertEqual(armingSession.process(.cgImage(image), at: 2.0), .none)
        XCTAssertEqual(
            armingSession.process(.cgImage(image), at: 2.1),
            .hit(DownloadLinkParser.parse("https://example.com/app.apk")!)
        )
    }

    func testResetAllowsTheSameLinkToBeScannedAgain() throws {
        let image = try makeImage()
        detector.candidates = [candidate("https://example.com/app.apk", center: CGPoint(x: 0.5, y: 0.5))]

        XCTAssertEqual(session.process(.cgImage(image), at: 0), .none)
        XCTAssertNotEqual(session.process(.cgImage(image), at: 0.1), .none)

        session.reset()

        XCTAssertEqual(session.process(.cgImage(image), at: 0.2), .none)
        XCTAssertNotEqual(session.process(.cgImage(image), at: 0.3), .none)
    }

    // MARK: - 工具

    private enum TestError: Error { case detectionFailed }

    private final class StubDetector: BarcodeDetecting {
        var candidates: [BarcodeCandidate] = []
        var error: Error?

        func detect(in image: ScanImage) throws -> [BarcodeCandidate] {
            if let error { throw error }
            return candidates
        }
    }

    private func candidate(_ payload: String, center: CGPoint, size: CGFloat = 0.2) -> BarcodeCandidate {
        BarcodeCandidate(
            payload: payload,
            boundingBox: CGRect(
                x: center.x - size / 2,
                y: center.y - size / 2,
                width: size,
                height: size
            )
        )
    }

    private func makeImage() throws -> CGImage {
        QRCodeFixture.solidCGImage(width: 8, height: 8)
    }
}
