import XCTest
@testable import UITestBenchCore

/// 很多二维码指向的是下载落地页。页面里如果有 APK 直链，值得再试一次，
/// 而不是直接把「不是 APK」甩给用户。
final class APKPageLinkTests: XCTestCase {
    private let page = URL(string: "https://example.com/download?id=7")!

    private func link(_ html: String, base: URL? = nil) -> URL? {
        APKPageLink.link(inHTML: Data(html.utf8), baseURL: base ?? page)
    }

    func testFindsAnAbsoluteAPKLink() {
        let url = link("""
        <html><body>
          <a class="download" href="https://cdn.example.com/builds/demo.apk">下载 APK</a>
        </body></html>
        """)

        XCTAssertEqual(url?.absoluteString, "https://cdn.example.com/builds/demo.apk")
    }

    func testResolvesARelativeAPKLinkAgainstThePage() {
        let url = link(#"<a href="/files/demo.apk">下载</a>"#)

        XCTAssertEqual(url?.absoluteString, "https://example.com/files/demo.apk")
    }

    func testDecodesHTMLAmpersandsAndKeepsTheQuery() {
        let url = link(#"<a href="https://cdn.example.com/demo.apk?token=1&amp;x=2">下载</a>"#)

        XCTAssertEqual(
            url?.absoluteString,
            "https://cdn.example.com/demo.apk?token=1&x=2"
        )
    }

    func testFindsAnAPKLinkInAMetaRefresh() {
        let url = link("""
        <meta http-equiv="refresh" content="0; url=/downloads/demo.apk?from=qr">
        """)

        XCTAssertEqual(
            url?.absoluteString,
            "https://example.com/downloads/demo.apk?from=qr"
        )
    }

    func testFindsADownloadURLInEmbeddedJSON() {
        let url = link("""
        <script>window.__DATA__ = {"downloadUrl":"https:\\/\\/cdn.example.com\\/demo.apk?x=1"}</script>
        """)

        XCTAssertEqual(
            url?.absoluteString,
            "https://cdn.example.com/demo.apk?x=1"
        )
    }

    func testRecognizesUppercaseAPKExtension() {
        let url = link(#"<a href="https://cdn.example.com/DEMO.APK">下载</a>"#)

        XCTAssertEqual(url?.absoluteString, "https://cdn.example.com/DEMO.APK")
    }

    func testIgnoresLinksThatAreNotHTTPOrAPK() {
        XCTAssertNil(link(#"<a href="javascript:download()">下载</a>"#))
        XCTAssertNil(link(#"<a href="https://example.com/help">帮助</a>"#))
        XCTAssertNil(link("<html><body>请先登录</body></html>"))
    }

    func testDoesNotFollowADataURL() {
        XCTAssertNil(link(#"<a href="data:application/octet-stream;base64,AAAA">下载</a>"#))
    }
}
