import XCTest
@testable import UITestBenchCore

/// 在**已经开着的**模拟器上验证「待卸记录能清干净」。
///
///     UITESTBENCH_REAL_SETUP=1 \
///     UITESTBENCH_SDK_DIR="$HOME/Library/Application Support/UI验收台" \
///     UITESTBENCH_SERIAL=emulator-5554 \
///     swift test --filter RealSessionCleanupAcceptanceTests
///
/// 不复用 `RealAppLifecycleAcceptanceTests` 里「自己开机」的做法：这条用例
/// 针对的是「设备上早就不存在这些包」的残留记录，边开机器边查设备状态反而看不清。
/// 记录写在临时目录里，不碰用户真实的 `session.json`。
final class RealSessionCleanupAcceptanceTests: XCTestCase {
    func testStaleRecordIsClearedWhenPackagesAreAlreadyGone() async throws {
        try XCTSkipUnless(RealEnvironment.isEnabled, "需要 UITESTBENCH_REAL_SETUP=1")
        let serial = ProcessInfo.processInfo.environment["UITESTBENCH_SERIAL"] ?? ""
        try XCTSkipIf(serial.isEmpty, "需要 UITESTBENCH_SERIAL 指向已开机的设备")
        let sdkPath = ProcessInfo.processInfo.environment["UITESTBENCH_SDK_DIR"] ?? ""
        try XCTSkipIf(sdkPath.isEmpty, "需要 UITESTBENCH_SDK_DIR 指向装好 platform-tools 的支持目录")

        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uitestbench-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        let cleaner = SessionCleaner(supportDirectory: supportDirectory)
        // 模拟 1.5.1 里攒下来的残留：设备上其实早就没有这些包了。
        let stale = [
            "com.uitestbench.stale.alpha",
            "com.uitestbench.stale.beta",
            "com.uitestbench.stale.gamma"
        ]
        try cleaner.replacePending(stale)
        XCTAssertEqual(try cleaner.pendingPackageNames(), stale)

        let lifecycle = AppLifecycle(
            sdkDirectory: AppPaths(
                supportDirectory: URL(fileURLWithPath: sdkPath, isDirectory: true)
            ).sdkDirectory,
            serial: serial
        )
        await SessionShutdown(
            cleaner: cleaner,
            lifecycle: lifecycle,
            packageNames: []
        ).run()

        XCTAssertEqual(
            try cleaner.pendingPackageNames(), [],
            "设备上已经没有这些包，待卸记录应当清空；留着重试就是界面上反复提示的根源"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cleaner.recordURL.path),
            "清干净之后 session.json 本身也不该留着"
        )
    }
}
