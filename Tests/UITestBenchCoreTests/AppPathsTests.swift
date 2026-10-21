import XCTest
@testable import UITestBenchCore

final class AppPathsTests: XCTestCase {
    func testDerivesManagedDirectoriesFromSupportDirectory() {
        let support = URL(fileURLWithPath: "/tmp/UI验收台", isDirectory: true)
        let paths = AppPaths(supportDirectory: support)

        XCTAssertEqual(paths.sdkDirectory.lastPathComponent, "sdk")
        XCTAssertEqual(paths.avdDirectory.lastPathComponent, "avd")
        XCTAssertEqual(paths.temporaryRoot.lastPathComponent, "tmp")
        XCTAssertEqual(paths.sdkDirectory.deletingLastPathComponent(), support)
    }

    /// 模拟器起不来时只有它自己的输出能说明原因，日志要留在我们能找到的地方。
    func testKeepsEmulatorLogUnderOurOwnDirectory() {
        let support = URL(fileURLWithPath: "/tmp/UI验收台", isDirectory: true)
        let paths = AppPaths(supportDirectory: support)

        XCTAssertEqual(paths.logsDirectory.deletingLastPathComponent(), support)
        XCTAssertEqual(paths.emulatorLogURL.lastPathComponent, "emulator.log")
        XCTAssertEqual(paths.emulatorLogURL.deletingLastPathComponent(), paths.logsDirectory)
    }

    /// 下载的包只活在这一场会话里，必须落在 tmp 下面，退出清理时才带得走。
    func testAPKDownloadsLiveUnderTemporaryRoot() {
        let paths = AppPaths(supportDirectory: URL(fileURLWithPath: "/tmp/UI验收台", isDirectory: true))

        XCTAssertEqual(paths.apkDirectory.lastPathComponent, "apk")
        XCTAssertEqual(paths.apkDirectory.deletingLastPathComponent(), paths.temporaryRoot)
    }

    func testCreateDirectoriesIsIdempotent() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppPathsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let paths = AppPaths(supportDirectory: support)

        try paths.createDirectories()
        try paths.createDirectories()

        for directory in [paths.sdkDirectory, paths.avdDirectory, paths.temporaryRoot, paths.apkDirectory] {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
        }
    }
}
