import XCTest
@testable import UITestBenchCore

/// 从图片里取下载链接。
///
/// 测试素材现场生成：用系统自带的二维码生成器画一张图，再让解码器读回来。
/// 这样不依赖任何外部图片文件，也不会因为 fixture 过期而失效。
final class QRCodeDecoderTests: XCTestCase {
    func testDecodesAnHTTPDownloadLink() throws {
        let data = try QRCodeFixture.pngData(encoding: "http://example.com/app.apk")

        XCTAssertEqual(
            QRCodeDecoder.downloadURL(from: data)?.absoluteString,
            "http://example.com/app.apk"
        )
    }

    func testDecodesAnHTTPSDownloadLinkWithQuery() throws {
        let link = "https://download.example.com/a.apk?token=abc123&v=2"
        let data = try QRCodeFixture.pngData(encoding: link)

        XCTAssertEqual(QRCodeDecoder.downloadURL(from: data)?.absoluteString, link)
    }

    /// 二维码里可能装的是一段普通文字、Wi-Fi 配置之类，不是下载地址。
    func testRejectsPayloadThatIsNotAURL() throws {
        let data = try QRCodeFixture.pngData(encoding: "hello, this is not a link")

        XCTAssertNil(QRCodeDecoder.downloadURL(from: data))
    }

    /// 只接受 http / https：file:// 和 ftp:// 都不该被当成下载来源。
    func testRejectsNonHTTPURLs() throws {
        XCTAssertNil(QRCodeDecoder.downloadURL(from: try QRCodeFixture.pngData(encoding: "ftp://example.com/a.apk")))
        XCTAssertNil(QRCodeDecoder.downloadURL(from: try QRCodeFixture.pngData(encoding: "file:///tmp/a.apk")))
    }

    func testReturnsNilWhenTheImageHasNoQRCode() throws {
        XCTAssertNil(QRCodeDecoder.downloadURL(from: try QRCodeFixture.plainPNGData()))
    }

    func testReturnsNilForGarbageData() {
        XCTAssertNil(QRCodeDecoder.downloadURL(from: Data("not an image".utf8)))
    }

    /// 手机截图可能带 EXIF 方向；镜像方向最能暴露「只读像素、没应用方向」。
    func testAppliesEXIFOrientation() throws {
        let data = try QRCodeFixture.jpegData(
            encoding: "https://example.com/oriented.apk",
            orientation: .leftMirrored
        )

        XCTAssertEqual(
            QRCodeDecoder.downloadURL(from: data)?.absoluteString,
            "https://example.com/oriented.apk"
        )
    }

    /// 聊天工具转发过的截图常被压缩得很厉害。
    func testDecodesACompressedJPEG() throws {
        let data = try QRCodeFixture.jpegData(
            encoding: "https://example.com/compressed.apk",
            quality: 0.25
        )

        XCTAssertEqual(
            QRCodeDecoder.downloadURL(from: data)?.absoluteString,
            "https://example.com/compressed.apk"
        )
    }

    /// 一张截图里同时有两个下载码时，静态路径取离画面中心最近的。
    func testChoosesTheNearestValidLinkInAMultiCodeImage() throws {
        let image = try QRCodeFixture.compositeCGImage(
            codes: [
                ("https://example.com/far.apk", CGRect(x: 30, y: 30, width: 140, height: 140)),
                ("https://example.com/near.apk", CGRect(x: 330, y: 330, width: 140, height: 140)),
            ],
            canvas: CGSize(width: 800, height: 800)
        )
        let data = try QRCodeFixture.pngData(of: image)

        XCTAssertEqual(
            QRCodeDecoder.downloadURL(from: data)?.absoluteString,
            "https://example.com/near.apk"
        )
    }

    /// 打不开的图片要能和「图里没有码」区分开，交给上层给不同提示。
    func testUnreadableDataThrows() {
        XCTAssertThrowsError(try QRCodeDecoder.payloads(from: Data("not an image".utf8))) { error in
            XCTAssertEqual(error as? QRCodeDecodingError, .unreadableImage)
        }
    }

    func testReportsAllPayloadsInTheImage() throws {
        let image = try QRCodeFixture.compositeCGImage(
            codes: [
                ("hello", CGRect(x: 40, y: 40, width: 140, height: 140)),
                ("https://example.com/a.apk", CGRect(x: 500, y: 500, width: 140, height: 140)),
            ],
            canvas: CGSize(width: 800, height: 800)
        )

        let data = try QRCodeFixture.pngData(of: image)

        XCTAssertEqual(Set(try QRCodeDecoder.payloads(from: data)), ["hello", "https://example.com/a.apk"])
    }
}
