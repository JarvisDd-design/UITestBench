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
        XCTAssertEqual(layout.cornerRadius, layout.screenSize.width * 0.056, accuracy: 0.6)
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

    func testZeroAvailableSizeProducesNoNegativeNumbers() {
        let layout = PhoneLayoutCalculator.layout(available: .zero, profile: .standard)
        XCTAssertGreaterThanOrEqual(layout.screenSize.width, 0)
        XCTAssertGreaterThanOrEqual(layout.screenSize.height, 0)
    }
}
