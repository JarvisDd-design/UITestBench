import XCTest
@testable import UITestBenchCore

final class SessionShutdownTests: XCTestCase {
    private var root: URL!
    private var cleaner: SessionCleaner!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionShutdown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cleaner = SessionCleaner(supportDirectory: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testUninstallsAndClearsTemporaryData() async throws {
        try cleaner.remember(packageName: "com.example.app")
        let lifecycle = RecordingLifecycle()

        await SessionShutdown(
            cleaner: cleaner,
            lifecycle: lifecycle,
            packageName: "com.example.app"
        ).run()

        XCTAssertEqual(lifecycle.calls, [.clearData("com.example.app"), .uninstall("com.example.app")])
        XCTAssertEqual(try temporaryContents(), [])
        XCTAssertNil(try cleaner.pendingPackageName(), "卸干净后不应当再留下待卸记录")
    }

    func testUninstallsPackageLeftBehindByPreviousSession() async throws {
        try cleaner.remember(packageName: "com.last.session")
        let lifecycle = RecordingLifecycle()

        await SessionShutdown(cleaner: cleaner, lifecycle: lifecycle).run()

        XCTAssertEqual(lifecycle.calls, [.clearData("com.last.session"), .uninstall("com.last.session")])
        XCTAssertNil(try cleaner.pendingPackageName())
    }

    func testWithoutDeviceKeepsTheRecordForNextLaunch() async throws {
        try cleaner.remember(packageName: "com.example.app")

        await SessionShutdown(cleaner: cleaner, lifecycle: nil).run()

        XCTAssertEqual(try cleaner.pendingPackageName(), "com.example.app")
        XCTAssertEqual(try temporaryContents(), [])
    }

    /// 卸载失败说明设备上可能还留着包，记录必须保留下次重试。
    func testUninstallFailureKeepsTheRecord() async throws {
        try cleaner.remember(packageName: "com.example.app")
        let lifecycle = RecordingLifecycle()
        lifecycle.uninstallError = AppLifecycleError.uninstallFailed("boom")

        await SessionShutdown(cleaner: cleaner, lifecycle: lifecycle).run()

        XCTAssertEqual(try cleaner.pendingPackageName(), "com.example.app")
        XCTAssertEqual(try temporaryContents(), [])
    }

    /// 停止设备前也要卸包（快照要干净），但用户还在这个会话里，
    /// 下载的 APK 不能因此被删掉。
    func testStoppingDeviceUninstallsButKeepsTemporaryFiles() async throws {
        let paths = AppPaths(supportDirectory: root)
        try paths.createDirectories()
        try Data("apk".utf8).write(to: paths.apkDirectory.appendingPathComponent("keep.apk"))
        try cleaner.remember(packageName: "com.example.app")
        let lifecycle = RecordingLifecycle()

        await SessionShutdown(
            cleaner: cleaner,
            lifecycle: lifecycle,
            packageName: "com.example.app"
        ).run(clearsTemporaryData: false)

        XCTAssertEqual(lifecycle.calls, [.clearData("com.example.app"), .uninstall("com.example.app")])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: paths.apkDirectory.appendingPathComponent("keep.apk").path
            )
        )
        XCTAssertNil(try cleaner.pendingPackageName(), "已卸干净，记录应当清掉")
    }

    func testWithoutAnythingToCleanStillRemovesTemporaryData() async throws {
        let paths = AppPaths(supportDirectory: root)
        try paths.createDirectories()
        try Data("残留".utf8).write(to: paths.apkDirectory.appendingPathComponent("a.apk"))

        await SessionShutdown(cleaner: cleaner, lifecycle: RecordingLifecycle()).run()

        XCTAssertEqual(try temporaryContents(), [])
    }

    private var temporaryRoot: URL {
        AppPaths(supportDirectory: root).temporaryRoot
    }

    private func temporaryContents() throws -> [String] {
        guard FileManager.default.fileExists(atPath: temporaryRoot.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path)
    }
}

private final class RecordingLifecycle: AppLifecycleRunning {
    enum Call: Equatable {
        case clearData(String)
        case uninstall(String)
    }

    var calls: [Call] = []
    var uninstallError: Error?

    func install(apkAt url: URL) async throws {}
    func launch(packageName: String, activity: String?) async throws {}
    func forceStop(packageName: String) async throws {}
    func clearData(packageName: String) async throws { calls.append(.clearData(packageName)) }
    func isInstalled(packageName: String) async -> Bool { false }
    func uninstall(packageName: String) async throws {
        calls.append(.uninstall(packageName))
        if let uninstallError { throw uninstallError }
    }
}
