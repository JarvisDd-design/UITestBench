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
}
