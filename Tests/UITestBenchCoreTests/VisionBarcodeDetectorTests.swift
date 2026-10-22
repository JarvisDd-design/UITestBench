import XCTest
@testable import UITestBenchCore

/// 实时帧和静态图片共用的二维码检测器。
///
/// 只负责「这张画面里有哪些二维码、分别在哪」；内容判断和选哪一个由上层决定。
final class VisionBarcodeDetectorTests: XCTestCase {
    private let detector = VisionBarcodeDetector()

    func testDetectsAQrCode() throws {
        let image = try QRCodeFixture.cgImage(encoding: "https://example.com/app.apk")

        let candidates = try detector.detect(in: .cgImage(image))

        XCTAssertEqual(candidates.map(\.payload), ["https://example.com/app.apk"])
    }

    func testReportsANormalizedBoundingBox() throws {
        let image = try QRCodeFixture.cgImage(encoding: "https://example.com/app.apk")

        let box = try XCTUnwrap(try detector.detect(in: .cgImage(image)).first?.boundingBox)

        XCTAssertGreaterThan(box.width, 0)
        XCTAssertGreaterThan(box.height, 0)
        XCTAssertTrue((0...1).contains(box.minX))
        XCTAssertTrue((0...1).contains(box.minY))
        XCTAssertTrue((0...1).contains(box.maxX))
        XCTAssertTrue((0...1).contains(box.maxY))
    }

    func testDetectsMultipleQRCodes() throws {
        let image = try QRCodeFixture.compositeCGImage(
            codes: [
                ("https://example.com/a.apk", CGRect(x: 80, y: 80, width: 180, height: 180)),
                ("https://example.com/b.apk", CGRect(x: 540, y: 540, width: 180, height: 180)),
            ],
            canvas: CGSize(width: 800, height: 800)
        )

        let payloads = Set(try detector.detect(in: .cgImage(image)).map(\.payload))

        XCTAssertEqual(payloads, ["https://example.com/a.apk", "https://example.com/b.apk"])
    }

    /// 聊天窗里未放大的小图：码只占画面很小一块，仍要能读到。
    func testDetectsASmallQRCodeInALargeCanvas() throws {
        let image = try QRCodeFixture.compositeCGImage(
            codes: [
                ("https://example.com/small.apk", CGRect(x: 350, y: 350, width: 110, height: 110)),
            ],
            canvas: CGSize(width: 800, height: 800)
        )

        let payloads = try detector.detect(in: .cgImage(image)).map(\.payload)

        XCTAssertEqual(payloads, ["https://example.com/small.apk"])
    }

    /// 暗色主题/反色截图：白模块黑底。
    func testDetectsAnInvertedQRCode() throws {
        let data = try QRCodeFixture.invertedPNGData(encoding: "https://example.com/dark.apk")
        let image = try XCTUnwrap(OrientedImage.cgImage(from: data))

        let payloads = try detector.detect(in: .cgImage(image)).map(\.payload)

        XCTAssertEqual(payloads, ["https://example.com/dark.apk"])
    }

    /// 实时路径直接吃 CVPixelBuffer，不经过 PNG。
    func testDetectsInAPixelBuffer() throws {
        let image = try QRCodeFixture.cgImage(encoding: "https://example.com/frame.apk")
        let buffer = try QRCodeFixture.pixelBuffer(from: image)

        let payloads = try detector.detect(in: .pixelBuffer(buffer)).map(\.payload)

        XCTAssertEqual(payloads, ["https://example.com/frame.apk"])
    }

    func testReturnsEmptyForAnImageWithoutCodes() throws {
        let image = try XCTUnwrap(OrientedImage.cgImage(from: try QRCodeFixture.plainPNGData()))

        XCTAssertTrue(try detector.detect(in: .cgImage(image)).isEmpty)
    }
}
