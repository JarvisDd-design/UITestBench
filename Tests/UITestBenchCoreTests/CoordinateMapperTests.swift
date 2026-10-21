import CoreGraphics
import XCTest
@testable import UITestBenchCore

final class CoordinateMapperTests: XCTestCase {
    private let accuracy: CGFloat = 0.001

    func testMapsIdentityWhenViewSizeEqualsDeviceSize() throws {
        let mapper = CoordinateMapper(
            viewSize: CGSize(width: 1080, height: 2400),
            deviceSize: CGSize(width: 1080, height: 2400)
        )

        let point = try XCTUnwrap(mapper.devicePoint(from: CGPoint(x: 540, y: 1200)))

        XCTAssertEqual(point.x, 540, accuracy: accuracy)
        XCTAssertEqual(point.y, 1200, accuracy: accuracy)
        XCTAssertEqual(mapper.scale, 1, accuracy: accuracy)
    }

    /// 视图比设备更「方」，画面上下撑满、左右留黑边。
    func testCentersContentWithLetterboxAndMapsInsideIt() throws {
        let mapper = CoordinateMapper(
            viewSize: CGSize(width: 1000, height: 1000),
            deviceSize: CGSize(width: 1080, height: 2400)
        )

        XCTAssertEqual(mapper.scale, 1000.0 / 2400.0, accuracy: accuracy)
        XCTAssertEqual(mapper.contentRect.origin.x, 275, accuracy: accuracy)
        XCTAssertEqual(mapper.contentRect.origin.y, 0, accuracy: accuracy)
        XCTAssertEqual(mapper.contentRect.width, 450, accuracy: accuracy)
        XCTAssertEqual(mapper.contentRect.height, 1000, accuracy: accuracy)

        let center = try XCTUnwrap(mapper.devicePoint(from: CGPoint(x: 500, y: 500)))
        XCTAssertEqual(center.x, 540, accuracy: accuracy)
        XCTAssertEqual(center.y, 1200, accuracy: accuracy)
    }

    func testIgnoresClicksInTheLetterbox() {
        let mapper = CoordinateMapper(
            viewSize: CGSize(width: 1000, height: 1000),
            deviceSize: CGSize(width: 1080, height: 2400)
        )

        XCTAssertNil(mapper.devicePoint(from: CGPoint(x: 100, y: 500)))
        XCTAssertNil(mapper.devicePoint(from: CGPoint(x: 900, y: 500)))
    }

    func testAcceptsPointsExactlyOnTheContentEdges() throws {
        let mapper = CoordinateMapper(
            viewSize: CGSize(width: 1000, height: 1000),
            deviceSize: CGSize(width: 1080, height: 2400)
        )

        let topLeft = try XCTUnwrap(mapper.devicePoint(from: CGPoint(x: 275, y: 0)))
        XCTAssertEqual(topLeft.x, 0, accuracy: accuracy)
        XCTAssertEqual(topLeft.y, 0, accuracy: accuracy)

        let bottomRight = try XCTUnwrap(mapper.devicePoint(from: CGPoint(x: 725, y: 1000)))
        XCTAssertEqual(bottomRight.x, 1080, accuracy: accuracy)
        XCTAssertEqual(bottomRight.y, 2400, accuracy: accuracy)
    }

    func testMapsDevicePointBackToViewPoint() throws {
        let mapper = CoordinateMapper(
            viewSize: CGSize(width: 1000, height: 1000),
            deviceSize: CGSize(width: 1080, height: 2400)
        )

        let point = try XCTUnwrap(mapper.viewPoint(from: CGPoint(x: 540, y: 1200)))

        XCTAssertEqual(point.x, 500, accuracy: accuracy)
        XCTAssertEqual(point.y, 500, accuracy: accuracy)
    }

    /// 转屏只交换设备宽高，映射规则不变。
    func testRotatedMapperSwapsDeviceDimensions() throws {
        let portrait = CoordinateMapper(
            viewSize: CGSize(width: 1000, height: 1000),
            deviceSize: CGSize(width: 1080, height: 2400)
        )
        let landscape = portrait.rotated()

        XCTAssertEqual(landscape.deviceSize.width, 2400, accuracy: accuracy)
        XCTAssertEqual(landscape.deviceSize.height, 1080, accuracy: accuracy)

        let point = try XCTUnwrap(landscape.devicePoint(from: CGPoint(x: 500, y: 500)))
        XCTAssertEqual(point.x, 1200, accuracy: accuracy)
        XCTAssertEqual(point.y, 540, accuracy: accuracy)
    }

    func testRejectsDegenerateSizes() {
        let mapper = CoordinateMapper(viewSize: .zero, deviceSize: CGSize(width: 1080, height: 2400))

        XCTAssertEqual(mapper.scale, 0)
        XCTAssertEqual(mapper.contentRect, .zero)
        XCTAssertNil(mapper.devicePoint(from: .zero))
        XCTAssertNil(mapper.viewPoint(from: .zero))
    }
}
