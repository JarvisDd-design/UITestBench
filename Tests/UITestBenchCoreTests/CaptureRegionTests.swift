import XCTest
@testable import UITestBenchCore

/// 把 AppKit 的全局坐标（左下原点）换算成 ScreenCaptureKit 的显示器本地坐标
/// （左上原点），同时算出 Retina 下的像素尺寸。这是整个扫码功能最容易错的地方。
final class CaptureRegionTests: XCTestCase {
    private let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    func testRetinaDisplayProducesDoublePixelSize() throws {
        let panel = CGRect(x: 760, y: 340, width: 400, height: 400)

        let region = try XCTUnwrap(
            CaptureRegionCalculator.region(panelFrame: panel, screenFrame: primary, backingScale: 2)
        )

        XCTAssertEqual(region.sourceRect, CGRect(x: 760, y: 340, width: 400, height: 400))
        XCTAssertEqual(region.pixelWidth, 800)
        XCTAssertEqual(region.pixelHeight, 800)
    }

    func testOneXDisplayProducesPointSizedPixels() throws {
        let panel = CGRect(x: 760, y: 340, width: 400, height: 400)

        let region = try XCTUnwrap(
            CaptureRegionCalculator.region(panelFrame: panel, screenFrame: primary, backingScale: 1)
        )

        XCTAssertEqual(region.pixelWidth, 400)
        XCTAssertEqual(region.pixelHeight, 400)
    }

    /// 副屏在主屏右侧：显示器本地坐标要从副屏自己的原点算。
    func testSecondaryScreenToTheRight() throws {
        let screen = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let panel = CGRect(x: 2000, y: 340, width: 400, height: 400)

        let region = try XCTUnwrap(
            CaptureRegionCalculator.region(panelFrame: panel, screenFrame: screen, backingScale: 2)
        )

        XCTAssertEqual(region.sourceRect, CGRect(x: 80, y: 340, width: 400, height: 400))
    }

    /// 副屏在主屏上方：AppKit 的 y 会大于主屏高度，翻转仍要相对副屏自身。
    func testSecondaryScreenAboveTheMainScreen() throws {
        let screen = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        let panel = CGRect(x: 760, y: 1420, width: 400, height: 400)

        let region = try XCTUnwrap(
            CaptureRegionCalculator.region(panelFrame: panel, screenFrame: screen, backingScale: 2)
        )

        XCTAssertEqual(region.sourceRect, CGRect(x: 760, y: 340, width: 400, height: 400))
    }

    /// 取景框有一角拖出屏幕时，只捕获取景框仍在屏幕内的部分。
    func testClampsToTheVisiblePartOfTheScreen() throws {
        let panel = CGRect(x: -100, y: -100, width: 400, height: 400)

        let region = try XCTUnwrap(
            CaptureRegionCalculator.region(panelFrame: panel, screenFrame: primary, backingScale: 2)
        )

        XCTAssertEqual(region.sourceRect, CGRect(x: 0, y: 780, width: 300, height: 300))
        XCTAssertEqual(region.pixelWidth, 600)
        XCTAssertEqual(region.pixelHeight, 600)
    }

    func testReturnsNilWhenThePanelIsCompletelyOffScreen() {
        let panel = CGRect(x: 3000, y: 3000, width: 400, height: 400)

        XCTAssertNil(
            CaptureRegionCalculator.region(panelFrame: panel, screenFrame: primary, backingScale: 2)
        )
    }

    /// 缩放因子异常时按 1x 处理，避免抓出 0 像素的缓冲区。
    func testTreatsInvalidScaleAsOne() throws {
        let panel = CGRect(x: 760, y: 340, width: 400, height: 400)

        let region = try XCTUnwrap(
            CaptureRegionCalculator.region(panelFrame: panel, screenFrame: primary, backingScale: 0)
        )

        XCTAssertEqual(region.pixelWidth, 400)
    }
}
