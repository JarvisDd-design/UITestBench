import XCTest
@testable import UITestBenchCore

/// 有些分发平台的下载页是空壳：页面由 JS 调详情接口，拿到地址后再改按钮的 href。
/// 链接不在 HTML 里，只能照着页面自己的请求再问一次。
final class APKPageDetailTests: XCTestCase {
    private let page = URL(
        string: "https://app.push.example.com/content-web/download.html"
            + "?id=ea54fa46-5925-4099-b025-000069a893a3"
    )!

    func testBuildsTheDetailEndpointFromTheDownloadPage() {
        XCTAssertEqual(
            APKPageDetail.endpoint(for: page)?.absoluteString,
            "https://app.push.example.com/content-web/app/detail.do"
                + "?id=ea54fa46-5925-4099-b025-000069a893a3"
        )
    }

    func testKeepsTheVersionParameter() {
        let url = URL(
            string: "https://app.push.example.com/content-web/download.html?id=abc&version=12"
        )!

        XCTAssertEqual(
            APKPageDetail.endpoint(for: url)?.absoluteString,
            "https://app.push.example.com/content-web/app/detail.do?id=abc&version=12"
        )
    }

    func testDoesNotBuildAnEndpointForOtherPages() {
        XCTAssertNil(
            APKPageDetail.endpoint(for: URL(string: "https://example.com/download.html?id=abc")!)
        )
        XCTAssertNil(
            APKPageDetail.endpoint(
                for: URL(string: "https://app.push.example.com/content-web/download.html")!
            ),
            "没有 id 就问不出详情"
        )
    }

    func testFindsTheDownloadURLInTheDetailJSON() {
        let json = Data("""
        {"code":0,"msg":null,"data":{
          "appName":"私人播放器",
          "iconUrl":"https://oss.example.com/icon/x.png",
          "downloadUrl":"https://oss.example.com/app/x/demo_11.apk",
          "manifestUrl":null
        }}
        """.utf8)

        XCTAssertEqual(
            APKPageDetail.apkLink(inJSON: json, baseURL: page)?.absoluteString,
            "https://oss.example.com/app/x/demo_11.apk"
        )
    }

    func testResolvesARelativeDownloadURL() {
        let json = Data(#"{"code":0,"data":{"downloadUrl":"/files/demo.apk"}}"#.utf8)

        XCTAssertEqual(
            APKPageDetail.apkLink(inJSON: json, baseURL: page)?.absoluteString,
            "https://app.push.example.com/files/demo.apk"
        )
    }

    func testRejectsAnErrorResponse() {
        let json = Data(#"{"code":-1,"msg":"登录已过期","data":null}"#.utf8)

        XCTAssertNil(APKPageDetail.apkLink(inJSON: json, baseURL: page))
    }

    func testFindsANestedAPKURLWhenThereIsNoDownloadURLKey() {
        let json = Data("""
        {"code":0,"data":{"versions":[{"file":"https://cdn.example.com/a/demo.apk?x=1"}]}}
        """.utf8)

        XCTAssertEqual(
            APKPageDetail.apkLink(inJSON: json, baseURL: page)?.absoluteString,
            "https://cdn.example.com/a/demo.apk?x=1"
        )
    }

    func testIgnoresURLsThatAreNotAPKs() {
        let json = Data("""
        {"code":0,"data":{"iconUrl":"https://cdn.example.com/icon.png","help":"https://example.com/help"}}
        """.utf8)

        XCTAssertNil(APKPageDetail.apkLink(inJSON: json, baseURL: page))
    }
}
