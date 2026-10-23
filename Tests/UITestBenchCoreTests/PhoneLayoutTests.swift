import CoreGraphics
import XCTest
@testable import UITestBenchCore

final class PhoneLayoutTests: XCTestCase {
    // MARK: - 以手机外框为窗口尺寸

    func testFrameSizeAddsBezelOnBothAxes() {
        let frame = PhoneLayoutCalculator.frameSize(forScreenWidth: 300, profile: .standard)
        // 300 × 2400/1080 = 666.67 → 666；再加两侧 7pt 边框。
        XCTAssertEqual(frame.width, 314)
        XCTAssertEqual(frame.height, 680)
    }

    func testLayoutFromFrameRecoversScreenSize() {
        let layout = PhoneLayoutCalculator.layout(
            frameSize: CGSize(width: 314, height: 680),
            profile: .standard
        )
        XCTAssertEqual(layout.screenSize, CGSize(width: 300, height: 666))
        XCTAssertEqual(layout.bezel, 7)
        XCTAssertEqual(layout.cornerRadius, 300 * 0.056, accuracy: 0.001)
    }

    func testFrameSmallerThanBezelProducesZeroScreen() {
        let layout = PhoneLayoutCalculator.layout(
            frameSize: CGSize(width: 10, height: 10),
            profile: .standard
        )
        XCTAssertEqual(layout.screenSize, .zero)
        XCTAssertEqual(layout.cornerRadius, 0)
        XCTAssertEqual(layout.bezel, 7)
    }

    func testLayoutFromFrameWithInvalidProfileProducesZeroScreen() {
        let empty = DeviceProfile(name: "零", width: 0, height: 0, density: 420)
        let layout = PhoneLayoutCalculator.layout(
            frameSize: CGSize(width: 314, height: 680),
            profile: empty
        )
        XCTAssertEqual(layout.screenSize, .zero)
    }

    func testFrameSizeForNonPositiveWidthIsZero() {
        XCTAssertEqual(
            PhoneLayoutCalculator.frameSize(forScreenWidth: 0, profile: .standard),
            .zero
        )
        XCTAssertEqual(
            PhoneLayoutCalculator.frameSize(forScreenWidth: -10, profile: .standard),
            .zero
        )
    }

    func testMaximumScreenWidthIsCappedAtDesignMaximum() {
        let width = PhoneLayoutCalculator.maximumScreenWidth(
            visibleSize: CGSize(width: 2000, height: 1400),
            profile: .standard
        )
        XCTAssertEqual(width, 440)
    }

    func testMaximumScreenWidthLeavesRoomForCapsuleAndPadding() {
        // 900 - 24*2 - 48 - 12 - 7*2 = 778；778 × 1080/2400 = 350.1 → 350。
        let width = PhoneLayoutCalculator.maximumScreenWidth(
            visibleSize: CGSize(width: 1440, height: 900),
            profile: .standard
        )
        XCTAssertEqual(width, 350)
    }

    func testMaximumScreenWidthNeverGoesBelowTheMinimum() {
        let width = PhoneLayoutCalculator.maximumScreenWidth(
            visibleSize: CGSize(width: 800, height: 300),
            profile: .standard
        )
        XCTAssertEqual(width, PhoneLayoutCalculator.minScreenWidth)
    }

    func testDefaultScreenWidthSitsBetweenLimits() {
        XCTAssertGreaterThan(PhoneLayoutCalculator.defaultScreenWidth, PhoneLayoutCalculator.minScreenWidth)
        XCTAssertLessThan(PhoneLayoutCalculator.defaultScreenWidth, PhoneLayoutCalculator.maxScreenWidth)
    }
}
