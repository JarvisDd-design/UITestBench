import CoreGraphics
import XCTest
@testable import UITestBenchCore

/// 标注必须真的画进导出的图片里，而不是只画在屏幕上。
/// 断言直接落在像素上：线经过的地方有颜色，没经过的地方仍是原图的白色。
final class AnnotationRendererTests: XCTestCase {
    private var baseImage: CGImage!

    override func setUpWithError() throws {
        baseImage = try makeImage(width: 100, height: 100, red: 1, green: 1, blue: 1)
    }

    func testRectangleDrawsBorderButLeavesCenterUntouched() throws {
        let annotation = Annotation(
            shape: .rectangle(CGRect(x: 10, y: 10, width: 40, height: 30)),
            color: .red,
            lineWidth: 4
        )

        let rendered = try XCTUnwrap(AnnotationRenderer.render([annotation], over: baseImage))

        let border = rgba(rendered, x: 10, y: 10)
        XCTAssertGreaterThan(border.red, 150, "边框上应当是红色：\(border)")
        XCTAssertLessThan(border.green, 130, "边框上应当是红色：\(border)")

        let center = rgba(rendered, x: 30, y: 25)
        XCTAssertGreaterThan(center.red, 240, "矩形内部不该被填充：\(center)")
        XCTAssertGreaterThan(center.green, 240, "矩形内部不该被填充：\(center)")
    }

    func testArrowDrawsALineBetweenItsEndpoints() throws {
        let annotation = Annotation(
            shape: .arrow(from: CGPoint(x: 10, y: 50), to: CGPoint(x: 90, y: 50)),
            color: .blue,
            lineWidth: 4
        )

        let rendered = try XCTUnwrap(AnnotationRenderer.render([annotation], over: baseImage))

        let middle = rgba(rendered, x: 50, y: 50)
        XCTAssertGreaterThan(middle.blue, 150, "箭杆应当经过中点：\(middle)")
        XCTAssertLessThan(middle.red, 130, "箭杆应当经过中点：\(middle)")
    }

    func testFreehandDrawsThroughEveryPoint() throws {
        let annotation = Annotation(
            shape: .freehand([
                CGPoint(x: 10, y: 80),
                CGPoint(x: 50, y: 80),
                CGPoint(x: 90, y: 80)
            ]),
            color: .green,
            lineWidth: 4
        )

        let rendered = try XCTUnwrap(AnnotationRenderer.render([annotation], over: baseImage))

        let point = rgba(rendered, x: 50, y: 80)
        XCTAssertGreaterThan(point.green, 120, "画笔应当经过这个点：\(point)")
        XCTAssertLessThan(point.red, 160, "画笔应当经过这个点：\(point)")
    }

    func testTextIsRenderedNearItsOrigin() throws {
        let annotation = Annotation(
            shape: .text(origin: CGPoint(x: 10, y: 20), content: "OK"),
            color: .black,
            fontSize: 30
        )

        let rendered = try XCTUnwrap(AnnotationRenderer.render([annotation], over: baseImage))

        var darkPixels = 0
        for x in 10..<80 {
            for y in 20..<70 where rgba(rendered, x: x, y: y).red < 120 {
                darkPixels += 1
            }
        }
        XCTAssertGreaterThan(darkPixels, 10, "文字应当在原点右下方留下笔画")
    }

    func testEmptyDocumentStillProducesTheOriginalPicture() throws {
        let rendered = try XCTUnwrap(AnnotationRenderer.render([], over: baseImage))

        XCTAssertEqual(rendered.width, 100)
        XCTAssertEqual(rendered.height, 100)
        let center = rgba(rendered, x: 50, y: 50)
        XCTAssertGreaterThan(center.red, 240)
    }

    func testPNGDataStartsWithPNGSignature() throws {
        let data = try XCTUnwrap(
            AnnotationRenderer.pngData([], over: baseImage)
        )

        XCTAssertTrue(
            data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
            "导出的应当是一张 PNG"
        )
    }

    // MARK: - 像素工具

    private struct Pixel {
        let red: Int
        let green: Int
        let blue: Int
        let alpha: Int
    }

    private func makeImage(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    /// 坐标以图片左上角为原点，与标注坐标一致。
    private func rgba(_ image: CGImage, x: Int, y: Int) -> Pixel {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &data,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        // 位图缓冲的第 0 行就是图像顶部，与标注坐标的方向一致。
        let index = (y * image.width + x) * 4
        return Pixel(
            red: Int(data[index]),
            green: Int(data[index + 1]),
            blue: Int(data[index + 2]),
            alpha: Int(data[index + 3])
        )
    }
}
