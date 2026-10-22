import CoreGraphics
import XCTest
@testable import UITestBenchCore

final class PhoneLayoutTests: XCTestCase {
    func testPortraitScreenFitsHeightAndKeepsAspect() {
        let layout = PhoneLayoutCalculator.layout(
            available: CGSize(width: 800, height: 700),
            profile: .standard
        )
        // 700 - 24*2 - 48 - 12 - 7*2 = 578
        XCTAssertEqual(layout.screenSize.height, 578, accuracy: 0.5)
        XCTAssertEqual(
            layout.screenSize.width / layout.screenSize.height,
            1080.0 / 2400.0,
            accuracy: 0.001
        )
        XCTAssertEqual(layout.bezel, 7)
    }

    func testCapsScreenWidthAt440() {
        let layout = PhoneLayoutCalculator.layout(
            available: CGSize(width: 1200, height: 1600),
            profile: .standard
        )
        XCTAssertEqual(layout.screenSize.width, 440, accuracy: 0.5)
    }

    func testCornerRadiusIsProportionalToScreenWidth() {
        let layout = PhoneLayoutCalculator.layout(
            available: CGSize(width: 1200, height: 1600),
            profile: .standard
        )
        XCTAssertEqual(layout.cornerRadius, layout.screenSize.width * 0.056, accuracy: 0.001)
    }

    func testHeightLimitedScreenUsesWidthForCornerRadius() {
        let layout = PhoneLayoutCalculator.layout(
            available: CGSize(width: 800, height: 700),
            profile: .standard
        )
        XCTAssertEqual(layout.screenSize.width, 260, accuracy: 0.5)
        XCTAssertEqual(layout.cornerRadius, 260 * 0.056, accuracy: 0.001)
    }

    func testCustomProfileKeepsItsOwnAspect() {
        let landscape = DeviceProfile(name: "横屏", width: 2400, height: 1080, density: 420)
        let layout = PhoneLayoutCalculator.layout(
            available: CGSize(width: 900, height: 700),
            profile: landscape
        )
        XCTAssertEqual(
            layout.screenSize.width / layout.screenSize.height,
            2400.0 / 1080.0,
            accuracy: 0.001
        )
    }

    func testNarrowWindowKeepsPhoneInsideAvailableWidth() {
        let layout = PhoneLayoutCalculator.layout(
            available: CGSize(width: 300, height: 1600),
            profile: .standard
        )
        XCTAssertEqual(layout.screenSize.width, 286, accuracy: 0.5)
        XCTAssertLessThanOrEqual(layout.screenSize.width + layout.bezel * 2, 300)
        XCTAssertEqual(
            layout.screenSize.width / layout.screenSize.height,
            1080.0 / 2400.0,
            accuracy: 0.001
        )
    }

    func testZeroAvailableSizeProducesZeroLayout() {
        let layout = PhoneLayoutCalculator.layout(available: .zero, profile: .standard)
        XCTAssertEqual(layout.screenSize, .zero)
        XCTAssertEqual(layout.cornerRadius, 0)
        XCTAssertEqual(layout.bezel, 7)
    }

    func testNegativeAvailableSizeProducesZeroLayout() {
        let layout = PhoneLayoutCalculator.layout(
            available: CGSize(width: -100, height: 700),
            profile: .standard
        )
        XCTAssertEqual(layout.screenSize, .zero)
    }

    func testZeroSizedProfileProducesZeroLayout() {
        let empty = DeviceProfile(name: "零", width: 0, height: 0, density: 420)
        let layout = PhoneLayoutCalculator.layout(
            available: CGSize(width: 800, height: 700),
            profile: empty
        )
        XCTAssertEqual(layout.screenSize, .zero)
    }
}
