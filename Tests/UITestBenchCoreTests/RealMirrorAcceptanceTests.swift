import XCTest
@testable import UITestBenchCore

/// 真机（模拟器）上跑 M3b：连续出帧、转屏、断流重连。
///
///     UITESTBENCH_REAL_SETUP=1 UITESTBENCH_SDK_DIR=<支持目录> swift test --filter RealMirrorAcceptanceTests
///
/// 两个用例共用同一台模拟器，因此收尾必须走 `tearDown()`（会被等待），
/// 不能用 `defer { Task { ... } }`：那样后一个用例已经开跑，前一个的收尾才去关模拟器。
@MainActor
final class RealMirrorAcceptanceTests: XCTestCase {
    private var controller: EmulatorController?
    private var source: ScrcpyMirrorSource?
    private var engine: MirrorEngine?

    override func tearDown() async throws {
        await engine?.stop()
        engine = nil
        await source?.stop()
        source = nil
        try? await controller?.stop()
        controller = nil
        try await super.tearDown()
    }

    func testKeepsDecodingAndFollowsRotation() async throws {
        guard RealEnvironment.isEnabled else {
            throw XCTSkip("未设置 UITESTBENCH_REAL_SETUP=1")
        }
        let (paths, controller) = try await prepareEnvironment(purpose: "RealMirror")
        self.controller = controller

        let adb = paths.sdkDirectory.appendingPathComponent("platform-tools/adb")
        let runner = ProcessCommandRunner()

        func adbShell(_ arguments: [String]) async throws {
            let result = try await runner.run(adb, ["-s", controller.serial, "shell"] + arguments)
            XCTAssertEqual(result.status, 0, result.output)
        }

        // 启动器把自己的方向锁成竖屏，光改 `user_rotation` 是不会转的；
        // 先让显示跟随用户旋转，之后才能用 `wm user-rotation` 真正转屏。
        try await adbShell(["wm", "fixed-to-user-rotation", "enabled"])
        try await adbShell(["wm", "user-rotation", "lock", "0"])
        try await Task.sleep(nanoseconds: 500_000_000)

        let source = try makeSource(paths: paths, serial: controller.serial)
        self.source = source

        let size = try await source.start()
        XCTAssertEqual(size, MirrorVideoSize(width: 864, height: 1920))

        // 静屏时编码器可能不出帧；持续滑动制造画面变化，再看能不能一帧接一帧地解。
        let poking = Task {
            while !Task.isCancelled {
                _ = try? await runner.run(
                    adb,
                    ["-s", controller.serial, "shell", "input", "swipe", "540", "1800", "540", "1000", "200"]
                )
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        defer { poking.cancel() }

        var decoded: [DecodedFrame] = []
        while decoded.count < 5, let frame = try source.nextFrame() {
            decoded.append(frame)
        }
        XCTAssertEqual(decoded.count, 5, "应当能连续解出 5 帧")
        XCTAssertTrue(
            decoded.allSatisfy { $0.width == 864 && $0.height == 1920 },
            "竖屏下每帧都应是 864×1920，实际 \(decoded.map { "\($0.width)×\($0.height)" })"
        )

        // 转屏：服务端会重发会话包与配置包，宽高应当互换。
        try await adbShell(["wm", "user-rotation", "lock", "1"])

        let deadline = Date().addingTimeInterval(20)
        var rotated: (width: Int, height: Int)?
        while Date() < deadline, let frame = try source.nextFrame() {
            if frame.width > frame.height {
                rotated = (frame.width, frame.height)
                break
            }
        }

        // 把设备还原成竖屏、方向跟随系统，别把状态留给下一次运行。
        try? await adbShell(["wm", "user-rotation", "lock", "0"])
        try? await adbShell(["wm", "fixed-to-user-rotation", "disabled"])

        XCTAssertEqual(rotated?.width, 1920, "转屏后应当解出横屏画面")
        XCTAssertEqual(rotated?.height, 864)
    }

    /// 服务端被杀掉（相当于断流）之后，引擎要自己重新拉起来，而不是停在最后一帧。
    func testReconnectsAfterServerDies() async throws {
        guard RealEnvironment.isEnabled else {
            throw XCTSkip("未设置 UITESTBENCH_REAL_SETUP=1")
        }
        let (paths, controller) = try await prepareEnvironment(purpose: "RealMirrorReconnect")
        self.controller = controller

        let adb = paths.sdkDirectory.appendingPathComponent("platform-tools/adb")
        let runner = ProcessCommandRunner()
        let source = try makeSource(paths: paths, serial: controller.serial)
        self.source = source
        let frames = FrameCounter()
        let states = MirrorStateRecorder()
        let engine = MirrorEngine(
            source: source,
            reconnectDelay: 0.2,
            onFrame: { _ in frames.increment() },
            onState: { states.record($0) }
        )
        self.engine = engine

        try await engine.start()
        await waitUntil(timeout: 20) { frames.count > 0 }
        XCTAssertGreaterThan(frames.count, 0, "先要有画面才能验证重连")

        // `[c]` 让模式串本身不被 pkill 匹配到，否则会把自己也杀掉。
        let killed = try await runner.run(
            adb,
            ["-s", controller.serial, "shell", "pkill", "-f", "[c]om.genymobile.scrcpy.Server"]
        )
        XCTAssertEqual(killed.status, 0, killed.output)

        try await Task.sleep(nanoseconds: 500_000_000)
        let before = frames.count
        await waitUntil(timeout: 25) { frames.count > before }

        XCTAssertGreaterThan(frames.count, before, "断流后应当自动重连并继续出帧")
        XCTAssertFalse(
            states.values.contains { if case .failed = $0 { return true } else { return false } },
            "重连过程中不该报失败：\(states.values)"
        )
    }

    // MARK: - 环境

    private func prepareEnvironment(purpose: String) async throws -> (AppPaths, EmulatorController) {
        let support = try RealEnvironment.supportDirectory(purpose: purpose)
        if support.isTemporary {
            addTeardownBlock { try? FileManager.default.removeItem(at: support.url) }
        }
        let paths = AppPaths(supportDirectory: support.url)

        let setup = SetupModel(paths: paths)
        setup.start()
        await setup.waitForCompletion()
        XCTAssertEqual(setup.phase, .ready, "安装失败：\(setup.statusText)")

        // 别的验收测试可能把同一台 AVD 换成过大屏；这里显式钉回主流机型。
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
        try await controller.start()
        return (paths, controller)
    }

    private func makeSource(paths: AppPaths, serial: String) throws -> ScrcpyMirrorSource {
        let jar = RealEnvironment.scrcpyJarURL()
        try ScrcpyServerJar.validate(jar)
        let session = ScrcpySession(
            adb: paths.sdkDirectory.appendingPathComponent("platform-tools/adb"),
            jar: jar,
            serial: serial,
            configuration: ScrcpySessionConfiguration(maxSize: 1920, maxFPS: 60)
        )
        return ScrcpyMirrorSource(session: session)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

private final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private final class MirrorStateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MirrorState] = []

    var values: [MirrorState] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func record(_ state: MirrorState) {
        lock.lock()
        storage.append(state)
        lock.unlock()
    }
}
