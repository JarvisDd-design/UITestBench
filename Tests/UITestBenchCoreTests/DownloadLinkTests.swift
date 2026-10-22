import XCTest
@testable import UITestBenchCore

/// 二维码或粘贴文字里的「下载地址」统一成一个值对象。
///
/// 只认 http / https；host、文件名这些界面要展示的信息在解析时就算好，
/// 免得各个调用方各写一份。
final class DownloadLinkTests: XCTestCase {
    func testAcceptsHTTPAndHTTPSLinks() throws {
        XCTAssertEqual(
            DownloadLinkParser.parse("https://example.com/app.apk")?.url,
            try XCTUnwrap(URL(string: "https://example.com/app.apk"))
        )
        XCTAssertEqual(
            DownloadLinkParser.parse("http://example.com/app.apk")?.url,
            try XCTUnwrap(URL(string: "http://example.com/app.apk"))
        )
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(
            DownloadLinkParser.parse("  https://example.com/a.apk \n")?.url.absoluteString,
            "https://example.com/a.apk"
        )
    }

    func testRejectsNonHTTPSchemes() {
        XCTAssertNil(DownloadLinkParser.parse("ftp://example.com/a.apk"))
        XCTAssertNil(DownloadLinkParser.parse("file:///tmp/a.apk"))
    }

    func testRejectsTextWithoutAHost() {
        XCTAssertNil(DownloadLinkParser.parse("https:///a.apk"))
        XCTAssertNil(DownloadLinkParser.parse("example.com/a.apk"))
    }

    func testRejectsPlainText() {
        XCTAssertNil(DownloadLinkParser.parse("hello, this is not a link"))
        XCTAssertNil(DownloadLinkParser.parse(""))
        XCTAssertNil(DownloadLinkParser.parse("   "))
    }

    /// 内部下载页常用查询参数带 token，不能丢。
    func testPreservesQueryAndFragment() throws {
        let link = try XCTUnwrap(
            DownloadLinkParser.parse("https://example.com/download?id=123&token=abc#top")
        )
        XCTAssertEqual(link.url.absoluteString, "https://example.com/download?id=123&token=abc#top")
        XCTAssertEqual(link.host, "example.com")
        XCTAssertEqual(link.fileName, "download")
    }

    func testDerivesHostAndFileName() throws {
        let link = try XCTUnwrap(
            DownloadLinkParser.parse("https://download.example.com/builds/app-release.apk")
        )
        XCTAssertEqual(link.host, "download.example.com")
        XCTAssertEqual(link.fileName, "app-release.apk")
    }

    /// 链接只到目录、或根本看不出文件名时给一个兜底名字。
    func testFallsBackToDefaultFileName() throws {
        XCTAssertEqual(DownloadLinkParser.parse("https://example.com/")?.fileName, "download.apk")
        XCTAssertEqual(DownloadLinkParser.parse("https://example.com")?.fileName, "download.apk")
        // 路径本身有名字时保留它（下载页可能就叫 download）；只有根路径才兜底。
        XCTAssertEqual(DownloadLinkParser.parse("https://example.com/download?id=1")?.fileName, "download")
    }

    /// 等值性按 URL 判断，界面用它去重。
    func testEqualityUsesTheURL() throws {
        let first = try XCTUnwrap(DownloadLinkParser.parse("https://example.com/a.apk"))
        let second = try XCTUnwrap(DownloadLinkParser.parse(" https://example.com/a.apk "))
        XCTAssertEqual(first, second)
    }
}
