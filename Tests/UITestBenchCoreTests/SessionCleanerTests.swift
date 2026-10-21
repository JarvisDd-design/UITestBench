import XCTest
@testable import UITestBenchCore

/// 工具承诺「退出即清」：业务数据只活在 `tmp/`，退出时整片删掉。
/// 强杀时退出钩子不跑，靠 `session.json` 记下包名，下次启动补卸。
final class SessionCleanerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionCleaner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testClearingRemovesEverythingUnderTemporaryRoot() throws {
        let paths = AppPaths(supportDirectory: root)
        try paths.createDirectories()
        try write("apk", to: paths.apkDirectory.appendingPathComponent("a.apk"))
        try write("session", to: paths.temporaryRoot.appendingPathComponent("session/state.bin"))

        try SessionCleaner(supportDirectory: root).clearTemporaryData()

        let remaining = try FileManager.default.contentsOfDirectory(atPath: paths.temporaryRoot.path)
        XCTAssertEqual(remaining, [], "tmp 下不应当留下任何东西")
    }

    func testClearingKeepsSdkAndLogs() throws {
        let paths = AppPaths(supportDirectory: root)
        try paths.createDirectories()
        try write("adb", to: paths.sdkDirectory.appendingPathComponent("platform-tools/adb"))
        try write("log", to: paths.emulatorLogURL)

        try SessionCleaner(supportDirectory: root).clearTemporaryData()

        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.sdkDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.emulatorLogURL.path))
    }

    func testClearingDoesNotDeleteFilesNextToTemporaryRoot() throws {
        let other = root.appendingPathComponent("使用说明.rtf")
        try write("mine", to: other)

        try SessionCleaner(supportDirectory: root).clearTemporaryData()

        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testClearingWithoutTemporaryRootSucceeds() throws {
        XCTAssertNoThrow(try SessionCleaner(supportDirectory: root).clearTemporaryData())
    }

    func testRememberThenRecoverReturnsPackageName() throws {
        let cleaner = SessionCleaner(supportDirectory: root)
        try cleaner.remember(packageName: "com.example.app")

        let record = try cleaner.recover()

        XCTAssertEqual(record?.packageName, "com.example.app")
    }

    func testRecoverWithoutRecordReturnsNil() throws {
        XCTAssertNil(try SessionCleaner(supportDirectory: root).recover())
    }

    func testRecoverClearsTemporaryDataLeftBehind() throws {
        let paths = AppPaths(supportDirectory: root)
        try paths.createDirectories()
        try write("残留", to: paths.apkDirectory.appendingPathComponent("left.apk"))
        let cleaner = SessionCleaner(supportDirectory: root)
        try cleaner.remember(packageName: "com.example.app")

        _ = try cleaner.recover()

        let remaining = try FileManager.default.contentsOfDirectory(atPath: paths.temporaryRoot.path)
        XCTAssertEqual(remaining, [])
    }

    func testRecoverKeepsRecordSoThePackageCanBeUninstalledAfterBoot() throws {
        let cleaner = SessionCleaner(supportDirectory: root)
        try cleaner.remember(packageName: "com.example.app")

        _ = try cleaner.recover()

        XCTAssertEqual(try cleaner.pendingPackageName(), "com.example.app")
    }

    func testForgetRemovesTheRecord() throws {
        let cleaner = SessionCleaner(supportDirectory: root)
        try cleaner.remember(packageName: "com.example.app")

        try cleaner.forget()

        XCTAssertNil(try cleaner.pendingPackageName())
    }

    /// 记录文件被截断、被手改成别的格式时，不能把应用卡死在启动自检上。
    func testCorruptedRecordIsTreatedAsNoRecord() throws {
        try write("{ not json", to: root.appendingPathComponent("session.json"))

        let cleaner = SessionCleaner(supportDirectory: root)

        XCTAssertNil(try cleaner.recover())
        XCTAssertNil(try cleaner.pendingPackageName())
    }

    func testRememberCreatesDirectoriesOnDemand() throws {
        let cleaner = SessionCleaner(supportDirectory: root)
        XCTAssertNoThrow(try cleaner.remember(packageName: "com.example.app"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cleaner.recordURL.path))
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }
}
