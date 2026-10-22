import ImageIO
import XCTest
@testable import UITestBenchCore

/// 图片方向归一化：EXIF 里的旋转/镜像必须在读像素时应用。
final class OrientedImageTests: XCTestCase {
    func testReturnsNilForGarbageData() {
        XCTAssertNil(OrientedImage.cgImage(from: Data("not an image".utf8)))
    }

    func testAppliesEXIFOrientationAndSwapsDimensions() throws {
        let source = QRCodeFixture.solidCGImage(width: 300, height: 150)
        let jpeg = try QRCodeFixture.jpegData(of: source, orientation: .right)

        let image = try XCTUnwrap(OrientedImage.cgImage(from: jpeg))

        XCTAssertEqual(image.width, 150)
        XCTAssertEqual(image.height, 300)
    }

    func testKeepsDimensionsForUprightImages() throws {
        let source = QRCodeFixture.solidCGImage(width: 300, height: 150)
        let jpeg = try QRCodeFixture.jpegData(of: source, orientation: .up)

        let image = try XCTUnwrap(OrientedImage.cgImage(from: jpeg))

        XCTAssertEqual(image.width, 300)
        XCTAssertEqual(image.height, 150)
    }
}
