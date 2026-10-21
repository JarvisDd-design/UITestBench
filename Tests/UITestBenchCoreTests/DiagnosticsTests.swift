import XCTest
@testable import UITestBenchCore

final class DiagnosticsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Diagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTailReturnsLastLines() throws {
        let url = root.appendingPathComponent("emulator.log")
        try Data("一\n二\n三\n四\n".utf8).write(to: url)

        let tail = try XCTUnwrap(LogTail.lastLines(of: url, count: 2))

        XCTAssertEqual(tail, "三\n四")
    }

    func testTailHandlesFewerLinesThanRequested() throws {
        let url = root.appendingPathComponent("a.log")
        try Data("只有一行".utf8).write(to: url)

        XCTAssertEqual(try LogTail.lastLines(of: url, count: 5), "只有一行")
    }

    func testTailReturnsNilForMissingFile() {
        XCTAssertNil(
            LogTail.lastLines(of: root.appendingPathComponent("nope.log"), count: 5)
        )
    }

    /// 日志可能很大，只读尾部，不能整个塞进内存。
    func testTailReadsOnlyTheEndOfALargeFile() throws {
        let url = root.appendingPathComponent("big.log")
        let head = String(repeating: "旧日志行\n", count: 100_000)
        let tail = (1...5).map { "末行\($0)" }.joined(separator: "\n")
        try Data((head + tail).utf8).write(to: url)

        let result = try XCTUnwrap(LogTail.lastLines(of: url, count: 3))

        XCTAssertEqual(result, "末行3\n末行4\n末行5")
    }

    func testReportContainsTheFactsSupportNeeds() {
        let text = DiagnosticsReport(
            appVersion: "1.0.0",
            supportDirectory: "/tmp/支持",
            sdkReady: true,
            deviceState: "运行中",
            serial: "emulator-5554",
            logTail: "启动完成"
        ).text

        XCTAssertTrue(text.contains("1.0.0"))
        XCTAssertTrue(text.contains("/tmp/支持"))
        XCTAssertTrue(text.contains("运行中"))
        XCTAssertTrue(text.contains("emulator-5554"))
        XCTAssertTrue(text.contains("启动完成"))
    }

    func testReportSaysWhenThereIsNoLog() {
        let text = DiagnosticsReport(
            appVersion: "1.0.0",
            supportDirectory: "/tmp",
            sdkReady: false,
            deviceState: "已停止",
            serial: nil,
            logTail: nil
        ).text

        XCTAssertTrue(text.contains("暂无"))
        XCTAssertTrue(text.contains("未就绪"))
    }
}
