import XCTest
@testable import UITestBenchCore

final class EmulatorArgumentsTests: XCTestCase {
    func testArgumentsRunHeadlessAgainstTheGivenAVD() {
        let arguments = EmulatorArguments.make(avdName: "uitestbench", port: 5554)

        XCTAssertEqual(arguments[0...1], ["-avd", "uitestbench"])
        XCTAssertTrue(arguments.contains("-no-window"), "画面由 scrcpy 取，模拟器不需要自己的窗口")
        XCTAssertTrue(arguments.contains("-no-audio"))
        XCTAssertTrue(arguments.contains("-no-boot-anim"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-port")! + 1], "5554")
    }

    /// 必须显式要求宿主 GPU。`auto` 在这台 Apple 芯片机器上退到了 SwiftShader
    /// （纯软件渲染），画面只有十几帧，输入到上屏的延迟直接翻倍。
    func testArgumentsUseTheHostGPU() {
        let arguments = EmulatorArguments.make(avdName: "uitestbench")

        guard let index = arguments.firstIndex(of: "-gpu") else {
            return XCTFail("必须显式指定 -gpu")
        }
        XCTAssertEqual(arguments[index + 1], "host")
    }

    func testArgumentsDoNotDisableSnapshots() {
        let arguments = EmulatorArguments.make(avdName: "uitestbench")

        XCTAssertFalse(arguments.contains("-no-snapshot"), "退出时要能存快照，下次快速启动")
        XCTAssertFalse(arguments.contains("-no-snapshot-save"))
        XCTAssertFalse(arguments.contains("-wipe-data"), "普通启动不能清数据")
    }

    func testWipeDataArgumentsForFullReinstall() {
        let arguments = EmulatorArguments.make(avdName: "uitestbench", wipeData: true)

        XCTAssertTrue(arguments.contains("-wipe-data"))
    }
}

@MainActor
final class EmulatorControllerTests: XCTestCase {
    private var root: URL!
    private var sdk: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmulatorControllerTests-\(UUID().uuidString)", isDirectory: true)
        sdk = root.appendingPathComponent("sdk", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sdk.appendingPathComponent("emulator"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sdk.appendingPathComponent("platform-tools"),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var store: AVDStore {
        AVDStore(root: root.appendingPathComponent("avd"))
    }

    private func makeController(
        runner: FakeCommandRunner = FakeCommandRunner(),
        launcher: FakeProcessLauncher = FakeProcessLauncher(),
        provisioner: DeviceProvisioning? = nil,
        bootTimeout: TimeInterval = 5,
        shutdownTimeout: TimeInterval = 0.05
    ) -> EmulatorController {
        EmulatorController(
            sdkDirectory: sdk,
            store: store,
            runner: runner,
            launcher: launcher,
            provisioner: provisioner,
            bootTimeout: bootTimeout,
            pollInterval: 0,
            shutdownTimeout: shutdownTimeout
        )
    }

    func testStartCreatesDeviceLaunchesAndWaitsForBoot() async throws {
        let runner = FakeCommandRunner(outputs: ["", "1"])
        let launcher = FakeProcessLauncher()
        let controller = makeController(runner: runner, launcher: launcher)

        try await controller.start()

        XCTAssertEqual(controller.state, .running(serial: "emulator-5554"))
        XCTAssertTrue(store.exists(named: "uitestbench"), "启动前要先建好 AVD")

        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertEqual(launcher.launches[0].executable.lastPathComponent, "emulator")
        XCTAssertTrue(launcher.launches[0].arguments.contains("uitestbench"))

        let calls = await runner.calls
        XCTAssertEqual(
            calls.map(\.arguments),
            [
                ["-s", "emulator-5554", "shell", "getprop", "sys.boot_completed"],
                ["-s", "emulator-5554", "shell", "getprop", "sys.boot_completed"]
            ]
        )
        XCTAssertEqual(calls[0].executable.lastPathComponent, "adb")
    }

    /// 模拟器默认只在 `~/.android/avd` 找设备，不把它指到我们的目录就永远起不来。
    func testLaunchPointsEmulatorAtOurSdkAndAvdDirectories() async throws {
        let runner = FakeCommandRunner(outputs: ["", "1"])
        let launcher = FakeProcessLauncher()
        let controller = makeController(runner: runner, launcher: launcher)

        try await controller.start()

        let environment = try XCTUnwrap(launcher.launches.first?.environment)
        XCTAssertEqual(environment["ANDROID_SDK_ROOT"], sdk.path)
        XCTAssertEqual(environment["ANDROID_HOME"], sdk.path)
        XCTAssertEqual(environment["ANDROID_AVD_HOME"], store.root.path)
        let emulatorHome = try XCTUnwrap(environment["ANDROID_EMULATOR_HOME"])
        XCTAssertTrue(emulatorHome.hasPrefix(root.path), "模拟器自己的状态也要留在我们目录里：\(emulatorHome)")
    }

    func testStartIsNoOpWhenAlreadyRunning() async throws {
        let runner = FakeCommandRunner(outputs: ["1", "1"])
        let launcher = FakeProcessLauncher()
        let controller = makeController(runner: runner, launcher: launcher)

        try await controller.start()
        try await controller.start()

        XCTAssertEqual(launcher.launches.count, 1)
    }

    func testStartReportsLaunchFailure() async {
        let launcher = FakeProcessLauncher()
        launcher.error = EmulatorError.launchFailed("找不到模拟器")
        let controller = makeController(launcher: launcher)

        do {
            try await controller.start()
            XCTFail("应当失败")
        } catch {
            XCTAssertEqual(controller.state, .failed("找不到模拟器"))
        }
    }

    func testStartTimesOutWithoutReachingBootCompleted() async {
        let runner = FakeCommandRunner(outputs: [], defaultOutput: "")
        let controller = makeController(runner: runner, bootTimeout: 0.05)

        do {
            try await controller.start()
            XCTFail("应当超时")
        } catch {
            guard case let .failed(message) = controller.state else {
                return XCTFail("状态应为 failed，实际 \(controller.state)")
            }
            XCTAssertTrue(message.contains("超时"), message)
        }
    }

    func testStopKillsEmulatorAndReturnsToStopped() async throws {
        let runner = FakeCommandRunner(outputs: ["1", ""])
        let launcher = FakeProcessLauncher()
        let controller = makeController(runner: runner, launcher: launcher)
        try await controller.start()

        try await controller.stop()

        XCTAssertEqual(controller.state, .stopped)
        let calls = await runner.calls
        XCTAssertEqual(
            calls.last?.arguments,
            ["-s", "emulator-5554", "emu", "kill"]
        )
        XCTAssertTrue(launcher.handle.terminateCalled)
    }

    /// 模拟器退出前要把快照存完。以前 `adb emu kill` 之后立刻 SIGTERM，
    /// 急着再启动就会撞上没做完的快照操作——那正是「停止后重开卡住」的原因。
    func testStopWaitsForTheEmulatorToFinishSavingTheSnapshot() async throws {
        let runner = FakeCommandRunner(outputs: ["1", ""])
        let launcher = FakeProcessLauncher()
        let controller = makeController(
            runner: runner,
            launcher: launcher,
            shutdownTimeout: 5
        )
        try await controller.start()

        // 模拟器在 100 ms 后自己退完（存完快照）。
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            launcher.handle.isRunning = false
        }
        let began = Date()
        try await controller.stop()
        let elapsed = Date().timeIntervalSince(began)

        XCTAssertLessThan(elapsed, 3, "进程退出后应当立刻返回，而不是等满超时")
        XCTAssertFalse(launcher.handle.terminateCalled, "正常退出就不该再补一刀")
        XCTAssertEqual(controller.state, .stopped)
    }

    /// 真的卡住不退出时才强杀，不能一直挂着。
    func testStopForceKillsWhenTheEmulatorNeverExits() async throws {
        let runner = FakeCommandRunner(outputs: ["1", ""])
        let launcher = FakeProcessLauncher()
        let controller = makeController(
            runner: runner,
            launcher: launcher,
            shutdownTimeout: 0.1
        )
        try await controller.start()

        try await controller.stop()

        XCTAssertTrue(launcher.handle.terminateCalled)
        XCTAssertEqual(controller.state, .stopped)
    }

    /// 模拟器在等开机的时候自己退了（日志里那种 FATAL），要立刻报错。
    /// 以前会继续轮询 adb 直到 3 分钟超时，界面上就是「一直卡在正在启动」。
    func testStartFailsFastWhenTheEmulatorExitsDuringBoot() async {
        let launcher = FakeProcessLauncher()
        launcher.exitImmediately = true
        let controller = makeController(launcher: launcher, bootTimeout: 5)

        let began = Date()
        do {
            try await controller.start()
            XCTFail("模拟器已经退出，不该继续等开机")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(began), 2, "应当立刻失败")
            guard case let .failed(message) = controller.state else {
                return XCTFail("状态应为 failed，实际 \(controller.state)")
            }
            XCTAssertTrue(message.contains("退出"), message)
        }
    }

    /// 上次异常退出可能在 AVD 目录里留下锁文件（内容是进程号）。
    /// 进程早没了还留着锁，下一次启动会直接 FATAL，所以启动前要清掉。
    func testStartRemovesStaleLocksLeftByACrashedEmulator() async throws {
        _ = try store.create(AVDConfiguration.default)
        let directory = store.deviceDirectory(named: "uitestbench")
        let stale = ["hardware-qemu.ini.lock", "multiinstance.lock", "snapshot.lock.lock"]
        for name in stale {
            try Data("999999\0".utf8).write(to: directory.appendingPathComponent(name))
        }
        let controller = makeController(
            runner: FakeCommandRunner(outputs: ["1"]),
            launcher: FakeProcessLauncher()
        )

        try await controller.start()

        for name in stale {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path),
                "\(name) 是上次崩溃留下的，应当清掉"
            )
        }
    }

    /// 锁的主人还活着就不能动——哪怕不是我们这本进程（比如用户从终端起的模拟器）。
    func testStartKeepsLocksHeldByALiveProcess() async throws {
        _ = try store.create(AVDConfiguration.default)
        let directory = store.deviceDirectory(named: "uitestbench")
        let lock = directory.appendingPathComponent("snapshot.lock.lock")
        try Data("\(ProcessInfo.processInfo.processIdentifier)\0".utf8).write(to: lock)
        let controller = makeController(
            runner: FakeCommandRunner(outputs: ["1"]),
            launcher: FakeProcessLauncher()
        )

        try await controller.start()

        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path), "活着的进程的锁不能删")
    }

    func testStopWhenAlreadyStoppedDoesNothing() async throws {
        let runner = FakeCommandRunner()
        let launcher = FakeProcessLauncher()
        let controller = makeController(runner: runner, launcher: launcher)

        try await controller.stop()

        XCTAssertEqual(controller.state, .stopped)
        let calls = await runner.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(launcher.launches.count, 0)
    }

    func testSwitchProfileStopsUpdatesConfigAndRestarts() async throws {
        let runner = FakeCommandRunner(outputs: ["1", "", "1"])
        let launcher = FakeProcessLauncher()
        let controller = makeController(runner: runner, launcher: launcher)
        try await controller.start()

        try await controller.switchProfile(to: .large)

        let profile = try store.profile(named: "uitestbench")
        XCTAssertEqual(profile, .large)
        XCTAssertEqual(launcher.launches.count, 2, "换机型要重启模拟器才生效")
        XCTAssertEqual(controller.state, .running(serial: "emulator-5554"))
    }

    func testSwitchProfileWhileStoppedOnlyRewritesConfig() async throws {
        let launcher = FakeProcessLauncher()
        let controller = makeController(launcher: launcher)
        _ = try store.create(AVDConfiguration(
            name: "uitestbench",
            displayName: "UI验收台",
            systemImageDirectory: AVDConfiguration.defaultSystemImageDirectory,
            profile: .standard
        ))

        try await controller.switchProfile(to: .compact)

        XCTAssertEqual(try store.profile(named: "uitestbench"), .compact)
        XCTAssertEqual(launcher.launches.count, 0)
        XCTAssertEqual(controller.state, .stopped)
    }

    func testSaveSnapshotUsesEmulatorConsole() async throws {
        let runner = FakeCommandRunner(outputs: ["1", ""])
        let controller = makeController(runner: runner)
        try await controller.start()

        try await controller.saveSnapshot(named: "default_boot")

        let calls = await runner.calls
        XCTAssertEqual(
            calls.last?.arguments,
            ["-s", "emulator-5554", "emu", "avd", "snapshot", "save", "default_boot"]
        )
    }

    // MARK: - 团队统一设备 ID

    /// 写团队密钥要停一次系统框架，必须发生在「设备已就绪」之前，
    /// 否则画面会先连上、紧接着被重启打断。
    func testStartProvisionsTheTeamDeviceKeyBeforeReportingRunning() async throws {
        let provisioner = FakeProvisioner()
        let controller = makeController(
            runner: FakeCommandRunner(outputs: ["1"]),
            provisioner: provisioner
        )

        try await controller.start()

        XCTAssertEqual(controller.state, .running(serial: "emulator-5554"))
        XCTAssertEqual(provisioner.calls, ["emulator-5554"])
        XCTAssertTrue(controller.teamKeyActive)
        XCTAssertNil(controller.provisioningWarning)
    }

    /// 团队 ID 写失败不能把设备卡死：设计同事至少还能用本机 ID 干活，
    /// 但界面必须明确告诉他是「没生效」，不能拿本机 ID 当团队 ID 发出去。
    func testStartStillRunsWhenProvisioningFailsAndReportsAWarning() async throws {
        let provisioner = FakeProvisioner()
        provisioner.error = TeamDeviceKeyError.frameworkDidNotStart
        let controller = makeController(
            runner: FakeCommandRunner(outputs: ["1"]),
            provisioner: provisioner
        )

        try await controller.start()

        XCTAssertEqual(controller.state, .running(serial: "emulator-5554"))
        XCTAssertFalse(controller.teamKeyActive)
        let warning = try XCTUnwrap(controller.provisioningWarning)
        XCTAssertTrue(warning.contains("没有重新启动完成"), warning)
    }

    func testStartWithoutAProvisionerDoesNotClaimTheTeamKeyIsActive() async throws {
        let controller = makeController(runner: FakeCommandRunner(outputs: ["1"]))

        try await controller.start()

        XCTAssertFalse(controller.teamKeyActive)
        XCTAssertNil(controller.provisioningWarning)
    }

    func testStopClearsTheProvisioningState() async throws {
        let provisioner = FakeProvisioner()
        let controller = makeController(
            runner: FakeCommandRunner(outputs: ["1", ""]),
            provisioner: provisioner
        )
        try await controller.start()
        XCTAssertTrue(controller.teamKeyActive)

        try await controller.stop()

        XCTAssertFalse(controller.teamKeyActive)
        XCTAssertNil(controller.provisioningWarning)
    }
}

// MARK: - 假件

actor FakeCommandRunner: CommandRunning {
    struct Call: Equatable {
        let executable: URL
        let arguments: [String]
    }

    private var _calls: [Call] = []
    private var outputs: [String]
    private var statuses: [Int32]
    private let defaultOutput: String
    private let status: Int32
    private var _pushedFiles: [String: String] = [:]
    var error: Error?

    init(
        outputs: [String] = [],
        defaultOutput: String = "",
        status: Int32 = 0,
        statuses: [Int32] = []
    ) {
        self.outputs = outputs
        self.defaultOutput = defaultOutput
        self.status = status
        self.statuses = statuses
    }

    var calls: [Call] { _calls }
    /// push 的本地文件内容，按设备端路径记下来。用来断言我们推上去的
    /// 确实是改写后的 SSAID 表，而不是只检查命令行。
    var pushedFiles: [String: String] { _pushedFiles }

    func run(_ executable: URL, _ arguments: [String]) async throws -> CommandResult {
        _calls.append(Call(executable: executable, arguments: arguments))
        if arguments.contains("push"), arguments.count >= 2 {
            let local = arguments[arguments.count - 2]
            let remote = arguments[arguments.count - 1]
            if let data = try? Data(contentsOf: URL(fileURLWithPath: local)) {
                _pushedFiles[remote] = String(decoding: data, as: UTF8.self)
            }
        }
        let output = outputs.isEmpty ? defaultOutput : outputs.removeFirst()
        let status = statuses.isEmpty ? self.status : statuses.removeFirst()
        if let error { throw error }
        return CommandResult(status: status, output: output)
    }
}

final class FakeProcessLauncher: ProcessLaunching, @unchecked Sendable {
    struct Launch {
        let executable: URL
        let arguments: [String]
        var environment: [String: String] = [:]
    }

    let handle = FakeProcessHandle()
    var launches: [Launch] = []
    var error: Error?
    /// 让模拟器进程「启动即退出」，用来模拟 FATAL 日志里那种情况。
    var exitImmediately = false

    func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> BackgroundProcessHandle {
        if let error { throw error }
        launches.append(Launch(executable: executable, arguments: arguments, environment: environment))
        handle.isRunning = !exitImmediately
        handle.terminateCalled = false
        return handle
    }
}

final class FakeProcessHandle: BackgroundProcessHandle, @unchecked Sendable {
    var isRunning = false
    var terminateCalled = false

    func terminate() {
        terminateCalled = true
        isRunning = false
    }
}

final class FakeProvisioner: DeviceProvisioning, @unchecked Sendable {
    var calls: [String] = []
    var error: Error?

    func provision(serial: String) async throws {
        calls.append(serial)
        if let error { throw error }
    }
}
