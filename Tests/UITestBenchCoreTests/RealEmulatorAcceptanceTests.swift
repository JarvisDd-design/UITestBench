import XCTest
@testable import UITestBenchCore

/// 用真装的 SDK 验收模拟器能起、能换分辨率、能关。
///
///     UITESTBENCH_SDK_DIR="$HOME/Library/Application Support/UI验收台" \
///       swift test --filter RealEmulatorAcceptanceTests
///
/// 首次跑会建 AVD 并冷启动，约 1–3 分钟。
final class RealEmulatorAcceptanceTests: XCTestCase {
    @MainActor
    func testBootsSwitchesProfileAndStops() async throws {
        guard let supportPath = ProcessInfo.processInfo.environment["UITESTBENCH_SDK_DIR"] else {
            throw XCTSkip("未设置 UITESTBENCH_SDK_DIR")
        }
        let paths = AppPaths(supportDirectory: URL(fileURLWithPath: supportPath, isDirectory: true))
        let sdk = paths.sdkDirectory
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RealEmulator-\(UUID().uuidString)", isDirectory: true)
        let avdRoot = root.appendingPathComponent("avd", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let controller = EmulatorController(
            sdkDirectory: sdk,
            store: AVDStore(root: avdRoot),
            launcher: ProcessLauncher(outputURL: root.appendingPathComponent("emulator.log")),
            bootTimeout: 300,
            pollInterval: 1
        )
        defer { Task { try? await controller.stop() } }

        try await controller.start()
        XCTAssertEqual(controller.state, .running(serial: "emulator-5554"))

        let runner = ProcessCommandRunner()
        let adb = sdk.appendingPathComponent("platform-tools/adb")
        let sdkVersion = try await runner.run(
            adb,
            ["-s", "emulator-5554", "shell", "getprop", "ro.build.version.sdk"]
        )
        XCTAssertEqual(sdkVersion.output.trimmingCharacters(in: .whitespacesAndNewlines), "34")

        let sizeBefore = try await runner.run(
            adb,
            ["-s", "emulator-5554", "shell", "wm", "size"]
        )
        XCTAssertTrue(sizeBefore.output.contains("1080x2400"), sizeBefore.output)

        try await controller.switchProfile(to: .large)
        XCTAssertEqual(controller.state, .running(serial: "emulator-5554"))

        let sizeAfter = try await runner.run(
            adb,
            ["-s", "emulator-5554", "shell", "wm", "size"]
        )
        XCTAssertTrue(sizeAfter.output.contains("1440x3120"), sizeAfter.output)

        try await controller.stop()
        XCTAssertEqual(controller.state, .stopped)
    }

    /// 用户实际踩到的流程：点「停止设备」，紧接着又点「启动设备」。
    ///
    /// 停止时模拟器还在存快照，旧代码发完 `emu kill` 就立刻 SIGTERM；重开的新
    /// 进程撞上没做完的快照操作，打出 FATAL 后直接退出，而界面要等到超时才报错，
    /// 看起来就是「卡在那儿」。
    @MainActor
    func testStopsAndStartsAgainImmediately() async throws {
        guard let supportPath = ProcessInfo.processInfo.environment["UITESTBENCH_SDK_DIR"] else {
            throw XCTSkip("未设置 UITESTBENCH_SDK_DIR")
        }
        let paths = AppPaths(supportDirectory: URL(fileURLWithPath: supportPath, isDirectory: true))
        let logURL = paths.emulatorLogURL
        let controller = EmulatorController(
            sdkDirectory: paths.sdkDirectory,
            store: AVDStore(root: paths.avdDirectory),
            launcher: ProcessLauncher(outputURL: logURL),
            bootTimeout: 300,
            pollInterval: 1
        )
        defer { Task { try? await controller.stop() } }

        try await controller.start()
        let marker = (try? String(contentsOf: logURL, encoding: .utf8))?
            .split(separator: "\n").count ?? 0

        try await controller.stop()
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertNil(
            ProcessInfo.processInfo.environment["UITESTBENCH_KEEP_RUNNING"],
            "留着这个变量时不要接着起，方便手工检查"
        )

        // 停完马上开，不给任何喘息时间——正是用户的操作。
        try await controller.start()
        XCTAssertEqual(controller.state, .running(serial: "emulator-5554"))

        let after = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n").dropFirst(marker).joined(separator: "\n")
        XCTAssertFalse(
            after.contains("snapshot operation") && after.contains("FATAL"),
            "重启撞上了没做完的快照操作：\n\(after.suffix(2000))"
        )
    }
}
