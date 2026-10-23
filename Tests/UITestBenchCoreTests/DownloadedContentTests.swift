import XCTest
@testable import UITestBenchCore

/// 下载回来的东西到底是什么。二维码背后的链接可能是 APK，也可能是
/// 登录页 / 下载落地页；把它们都叫「不是 APK」会误导用户。
final class DownloadedContentTests: XCTestCase {
    func testRecognizesAZipArchive() {
        let data = Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 0, count: 40)

        XCTAssertEqual(DownloadedContent.kind(of: data), .zipArchive)
    }

    func testRecognizesAnHTMLPageWithBOMAndLeadingWhitespace() {
        let html = "\u{FEFF}\n  <!doctype HTML><html><head><title>登录</title></head></html>"
        let data = Data(html.utf8)

        XCTAssertEqual(DownloadedContent.kind(of: data), .webPage)
    }

    func testRecognizesAnHTMLPageByMimeTypeEvenWhenTheBodyIsSmall() {
        let data = Data("请先登录".utf8)

        XCTAssertEqual(
            DownloadedContent.kind(of: data, mimeType: "text/html; charset=utf-8"),
            .webPage
        )
    }

    /// 有些服务器把 Content-Type 标错；内容以 PK 开头就按 ZIP 处理。
    func testZipSignatureWinsOverAWrongMimeType() {
        let data = Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00])

        XCTAssertEqual(
            DownloadedContent.kind(of: data, mimeType: "text/html"),
            .zipArchive
        )
    }

    func testTreatsOtherBytesAsAnOrdinaryFile() {
        let data = Data("this is a plain text file".utf8)

        XCTAssertEqual(
            DownloadedContent.kind(of: data, mimeType: "application/octet-stream"),
            .other
        )
    }

    func testEmptyBodyIsNotAPageJustBecauseOfAMimeType() {
        XCTAssertEqual(
            DownloadedContent.kind(of: Data(), mimeType: "text/html"),
            .webPage
        )
    }
}
