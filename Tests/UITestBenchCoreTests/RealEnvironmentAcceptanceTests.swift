import XCTest
@testable import UITestBenchCore

/// 从零下载 → 安装 → 启动模拟器，一次跑通 M1 与 M2。
///
///     UITESTBENCH_REAL_SETUP=1 swift test --filter RealEnvironmentAcceptanceTests
///
/// 会下载约 2 GB，装到临时目录，跑完删除。首次运行 10–20 分钟。
final class RealEnvironmentAcceptanceTests: XCTestCase {
    @MainActor
    func testInstallsEnvironmentThenBootsDevice() async throws {
        guard ProcessInfo.processInfo.environment["UITESTBENCH_REAL_SETUP"] == "1" else {
            throw XCTSkip("未设置 UITESTBENCH_REAL_SETUP=1")
        }

        let support = try RealEnvironment.supportDirectory(purpose: "RealEnvironment")
        let paths = AppPaths(supportDirectory: support.url)
        if support.isTemporary {
            addTeardownBlock { try? FileManager.default.removeItem(at: support.url) }
        }

        let setup = SetupModel(paths: paths)
        setup.start()
        await setup.waitForCompletion()
        XCTAssertEqual(setup.phase, .ready, "安装失败：\(setup.statusText)")

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: paths.sdkDirectory.appendingPathComponent("platform-tools/adb").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: paths.sdkDirectory.appendingPathComponent("emulator/emulator").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: paths.sdkDirectory.appendingPathComponent(
                    "system-images/android-34/default/arm64-v8a/system.img"
                ).path
            )
        )

        let controller = EmulatorController(
            sdkDirectory: paths.sdkDirectory,
            store: AVDStore(root: paths.avdDirectory),
            launcher: ProcessLauncher(outputURL: paths.emulatorLogURL),
            bootTimeout: 600,
            pollInterval: 2
        )
        defer { Task { try? await controller.stop() } }

        try await controller.start()
        XCTAssertEqual(controller.state, .running(serial: "emulator-5554"))

        let runner = ProcessCommandRunner()
        let adb = paths.sdkDirectory.appendingPathComponent("platform-tools/adb")
        let version = try await runner.run(
            adb,
            ["-s", "emulator-5554", "shell", "getprop", "ro.build.version.sdk"]
        )
        XCTAssertEqual(version.output.trimmingCharacters(in: .whitespacesAndNewlines), "34")

        let size = try await runner.run(
            adb,
            ["-s", "emulator-5554", "shell", "wm", "size"]
        )
        XCTAssertTrue(size.output.contains("1080x2400"), size.output)

        try await controller.switchProfile(to: .large)
        let resized = try await runner.run(
            adb,
            ["-s", "emulator-5554", "shell", "wm", "size"]
        )
        XCTAssertTrue(resized.output.contains("1440x3120"), resized.output)

        try await controller.stop()
        XCTAssertEqual(controller.state, .stopped)
    }
}
