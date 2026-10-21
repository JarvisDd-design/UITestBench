import XCTest
@testable import UITestBenchCore

/// 拖进来的东西 / 粘贴的链接 → 一个明确的 APK 来源。
///
/// 三条路最终都要落到「本地文件」或「远程链接」两种之一，后面的下载与解析
/// 就不用关心它是从哪来的。
final class APKSourceResolverTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("APKSourceResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDroppedAPKIsUsedAsALocalFile() throws {
        let apk = try write(Data([0x50, 0x4B]), as: "demo.apk")

        XCTAssertEqual(try APKSourceResolver.source(forDroppedFile: apk), .localFile(apk))
    }

    /// 扩展名大小写不敏感，macOS 上 `.APK` 也常见。
    func testDroppedAPKWithUppercaseExtensionWorks() throws {
        let apk = try write(Data([0x50, 0x4B]), as: "DEMO.APK")

        XCTAssertEqual(try APKSourceResolver.source(forDroppedFile: apk), .localFile(apk))
    }

    func testDroppedQRCodeImageBecomesARemoteDownload() throws {
        let image = try write(
            QRCodeFixture.pngData(encoding: "https://example.com/app.apk"),
            as: "qr.png"
        )

        XCTAssertEqual(
            try APKSourceResolver.source(forDroppedFile: image),
            .remote(try XCTUnwrap(URL(string: "https://example.com/app.apk")))
        )
    }

    func testDroppedImageWithoutALinkIsRejected() throws {
        let image = try write(try QRCodeFixture.plainPNGData(), as: "plain.png")

        assertThrows(.noLinkInImage) {
            try APKSourceResolver.source(forDroppedFile: image)
        }
    }

    func testDroppedUnsupportedFileIsRejected() throws {
        let text = try write(Data("hello".utf8), as: "notes.txt")

        assertThrows(.unsupportedFile) {
            try APKSourceResolver.source(forDroppedFile: text)
        }
    }

    func testPastedHTTPAndHTTPSLinksAreAccepted() throws {
        XCTAssertEqual(
            try APKSourceResolver.source(forPastedLink: "https://example.com/a.apk"),
            .remote(try XCTUnwrap(URL(string: "https://example.com/a.apk")))
        )
        XCTAssertEqual(
            try APKSourceResolver.source(forPastedLink: "http://example.com/a.apk"),
            .remote(try XCTUnwrap(URL(string: "http://example.com/a.apk")))
        )
    }

    /// 从聊天工具里复制链接常带首尾空白和换行。
    func testPastedLinkIsTrimmed() throws {
        XCTAssertEqual(
            try APKSourceResolver.source(forPastedLink: "  https://example.com/a.apk \n"),
            .remote(try XCTUnwrap(URL(string: "https://example.com/a.apk")))
        )
    }

    /// 没写协议的链接无从判断，明确报错比猜一个 https 更安全。
    func testPastedTextWithoutSchemeIsRejected() {
        assertThrows(.invalidLink) {
            try APKSourceResolver.source(forPastedLink: "example.com/a.apk")
        }
    }

    func testPastedNonHTTPLinkIsRejected() {
        assertThrows(.invalidLink) {
            try APKSourceResolver.source(forPastedLink: "ftp://example.com/a.apk")
        }
    }

    func testEmptyPastedLinkIsRejected() {
        assertThrows(.invalidLink) {
            try APKSourceResolver.source(forPastedLink: "   ")
        }
    }

    /// 三种拒绝各自要说清楚「哪里不对、下一步怎么做」，不能只甩一个错误类型。
    func testSourceErrorsExplainWhatToDo() {
        XCTAssertTrue(APKSourceError.unsupportedFile.explanation.contains("APK"))
        XCTAssertTrue(APKSourceError.noLinkInImage.explanation.contains("二维码"))
        XCTAssertTrue(APKSourceError.invalidLink.explanation.contains("http"))
    }

    // MARK: - 工具

    private func write(_ data: Data, as name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func assertThrows(
        _ expected: APKSourceError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> APKSource
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? APKSourceError, expected, file: file, line: line)
        }
    }
}
