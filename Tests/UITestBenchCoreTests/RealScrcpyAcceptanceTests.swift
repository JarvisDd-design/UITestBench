import XCTest
@testable import UITestBenchCore

/// 真机（模拟器）上跑一遍 M3a：握手、配置包、第一帧解码。
///
///     UITESTBENCH_REAL_SETUP=1 swift test --filter RealScrcpyAcceptanceTests
///
/// 想复用已装好的 SDK 就加上 `UITESTBENCH_SDK_DIR=<目录>`，否则会先下载约 2 GB。
final class RealScrcpyAcceptanceTests: XCTestCase {
    @MainActor
    func testHandshakesAndDecodesFirstFrame() async throws {
        guard RealEnvironment.isEnabled else {
            throw XCTSkip("未设置 UITESTBENCH_REAL_SETUP=1")
        }

        let support = try RealEnvironment.supportDirectory(purpose: "RealScrcpy")
        if support.isTemporary {
            addTeardownBlock { try? FileManager.default.removeItem(at: support.url) }
        }
        let paths = AppPaths(supportDirectory: support.url)

        let setup = SetupModel(paths: paths)
        setup.start()
        await setup.waitForCompletion()
        XCTAssertEqual(setup.phase, .ready, "安装失败：\(setup.statusText)")

        // 别的验收测试可能把同一台 AVD 换成过大屏；这里显式钉回主流机型，
        // 否则首帧尺寸的断言会取决于跑测试的顺序。
        let store = AVDStore(root: paths.avdDirectory)
        let configuration = AVDConfiguration.default
        if store.exists(named: configuration.name) {
            try store.updateProfile(named: configuration.name, to: .standard)
        } else {
            try store.create(configuration)
        }

        let controller = EmulatorController(
            sdkDirectory: paths.sdkDirectory,
            store: store,
            launcher: ProcessLauncher(outputURL: paths.emulatorLogURL),
            bootTimeout: 600,
            pollInterval: 2
        )
        defer { Task { try? await controller.stop() } }
        try await controller.start()

        let jar = RealEnvironment.scrcpyJarURL()
        try ScrcpyServerJar.validate(jar)

        let adb = paths.sdkDirectory.appendingPathComponent("platform-tools/adb")
        let session = ScrcpySession(
            adb: adb,
            jar: jar,
            serial: controller.serial,
            configuration: ScrcpySessionConfiguration(maxSize: 1920, maxFPS: 60)
        )
        let source = ScrcpyMirrorSource(session: session)
        defer { Task { await source.stop() } }

        let size = try await source.start()
        let frame = try XCTUnwrap(try source.nextFrame(), "没有解出第一帧")

        // 设备是 1080×2400，max_size=1920 后应缩成 864×1920。
        XCTAssertEqual(size, MirrorVideoSize(width: 864, height: 1920))
        XCTAssertEqual(frame.width, size.width)
        XCTAssertEqual(frame.height, size.height)
    }
}
