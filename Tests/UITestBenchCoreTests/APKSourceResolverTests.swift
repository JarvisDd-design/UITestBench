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

    func testDroppedImageWithoutAQRCodeIsRejected() throws {
        let image = try write(try QRCodeFixture.plainPNGData(), as: "plain.png")

        assertThrows(.noQRCodeInImage) {
            try APKSourceResolver.source(forDroppedFile: image)
        }
    }

    /// 扩展名像图片、内容却不是图片：要和「图里没有码」分开说。
    func testDroppedUnreadableImageIsRejected() throws {
        let image = try write(Data("not an image".utf8), as: "broken.png")

        assertThrows(.unreadableImage) {
            try APKSourceResolver.source(forDroppedFile: image)
        }
    }

    /// 有二维码，但里面是普通文字：要和「没有二维码」分开说。
    func testDroppedQRCodeWithPlainTextIsRejected() throws {
        let image = try write(
            QRCodeFixture.pngData(encoding: "hello, this is not a link"),
            as: "text-qr.png"
        )

        assertThrows(.qrCodeIsNotLink) {
            try APKSourceResolver.source(forDroppedFile: image)
        }
    }

    /// 剪贴板截图没有文件路径，只能按图片数据交给同一个解析入口。
    func testPastedImageDataBecomesARemoteDownload() throws {
        let data = try QRCodeFixture.pngData(encoding: "https://example.com/clipboard.apk")

        XCTAssertEqual(
            try APKSourceResolver.source(forImageData: data),
            .remote(try XCTUnwrap(URL(string: "https://example.com/clipboard.apk")))
        )
    }

    func testPastedImageDataWithoutAQRCodeIsRejected() throws {
        assertThrows(.noQRCodeInImage) {
            try APKSourceResolver.source(forImageData: QRCodeFixture.plainPNGData())
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

    /// 每种拒绝都要说清楚「哪里不对、下一步怎么做」，并且彼此不重复。
    func testSourceErrorsExplainWhatToDo() {
        XCTAssertTrue(APKSourceError.unsupportedFile.explanation.contains("APK"))
        XCTAssertTrue(APKSourceError.unreadableImage.explanation.contains("图片"))
        XCTAssertTrue(APKSourceError.noQRCodeInImage.explanation.contains("二维码"))
        XCTAssertTrue(APKSourceError.qrCodeIsNotLink.explanation.contains("http"))
        XCTAssertTrue(APKSourceError.invalidLink.explanation.contains("http"))

        let explanations = Set([
            APKSourceError.unsupportedFile.explanation,
            APKSourceError.unreadableImage.explanation,
            APKSourceError.noQRCodeInImage.explanation,
            APKSourceError.qrCodeIsNotLink.explanation,
            APKSourceError.invalidLink.explanation,
        ])
        XCTAssertEqual(explanations.count, 5, "五种失败原因不能共用一句提示")
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
