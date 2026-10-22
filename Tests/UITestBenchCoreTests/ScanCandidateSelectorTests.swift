import XCTest
@testable import UITestBenchCore

/// 框里同时有多个码时，按「离取景框中心最近」选一个。
final class ScanCandidateSelectorTests: XCTestCase {
    func testReturnsNilForNoCandidates() {
        XCTAssertNil(ScanCandidateSelector.choose(from: []))
    }

    func testReturnsTheOnlyCandidate() {
        let candidate = makeCandidate("https://example.com/a.apk", center: CGPoint(x: 0.2, y: 0.2))

        XCTAssertEqual(ScanCandidateSelector.choose(from: [candidate]), candidate)
    }

    func testChoosesTheCandidateClosestToTheCenter() {
        let offCenter = makeCandidate("https://example.com/off.apk", center: CGPoint(x: 0.8, y: 0.8))
        let centered = makeCandidate("https://example.com/center.apk", center: CGPoint(x: 0.5, y: 0.5))

        XCTAssertEqual(ScanCandidateSelector.choose(from: [offCenter, centered]), centered)
    }

    func testNearestCandidateWinsEvenWhenItIsNotFirst() {
        let near = makeCandidate("https://example.com/near.apk", center: CGPoint(x: 0.55, y: 0.5))
        let far = makeCandidate("https://example.com/far.apk", center: CGPoint(x: 0.1, y: 0.1))

        XCTAssertEqual(ScanCandidateSelector.choose(from: [far, near]), near)
    }

    /// 距离一样时结果必须稳定，否则同一画面每帧选出来的码会跳。
    func testTieBreaksDeterministically() {
        let left = makeCandidate("https://example.com/left.apk", center: CGPoint(x: 0.4, y: 0.5))
        let right = makeCandidate("https://example.com/right.apk", center: CGPoint(x: 0.6, y: 0.5))

        let chosen = ScanCandidateSelector.choose(from: [right, left])

        XCTAssertEqual(chosen, ScanCandidateSelector.choose(from: [left, right]))
        XCTAssertEqual(chosen, left, "平局依次比 minY、minX，都取较小者（左下优先）")
    }

    /// 静态截图路径要按距离从近到远排列，再取第一个能解析成链接的。
    func testRanksCandidatesFromNearestToFarthest() {
        let center = makeCandidate("https://example.com/center.apk", center: CGPoint(x: 0.5, y: 0.5))
        let near = makeCandidate("https://example.com/near.apk", center: CGPoint(x: 0.6, y: 0.5))
        let far = makeCandidate("https://example.com/far.apk", center: CGPoint(x: 0.9, y: 0.9))

        XCTAssertEqual(
            ScanCandidateSelector.ranked(from: [far, center, near]).map(\.payload),
            [center.payload, near.payload, far.payload]
        )
    }

    // MARK: - 工具

    private func makeCandidate(_ payload: String, center: CGPoint, size: CGFloat = 0.2) -> BarcodeCandidate {
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
}
