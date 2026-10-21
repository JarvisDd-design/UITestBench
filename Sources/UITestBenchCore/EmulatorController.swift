import Combine
import Darwin
import Foundation

public enum EmulatorError: Error, Equatable {
    case launchFailed(String)
    case bootTimeout(seconds: Double)
    case commandFailed(String)
    /// 进程还在等开机就退了。日志里那种 `FATAL | A snapshot operation ...` 就是它。
    case exitedDuringBoot
}

public enum EmulatorState: Equatable, Sendable {
    case stopped
    case starting
    /// `adb emu kill` 之后、进程真正退出之前。模拟器要先把快照写完，
    /// 这段时间里不能再启动一台新的，否则会撞上没做完的快照操作。
    case stopping
    case running(serial: String)
    case failed(String)
}

public enum EmulatorArguments {
    /// 模拟器自己不开窗：画面由 scrcpy 取，窗口留着只会多一个「黑影」。
    /// 不传 `-no-snapshot`，退出时要存快照，下次才能几秒内起来。
    public static func make(avdName: String, port: Int = 5554, wipeData: Bool = false) -> [String] {
        var arguments = [
            "-avd", avdName,
            "-port", String(port),
            "-no-window",
            "-no-audio",
            "-no-boot-anim",
            // 必须显式用宿主 GPU。`auto` 在 Apple 芯片上会退到 SwiftShader
            // （纯软件渲染），画面只有十几帧，输入到上屏的延迟接近翻倍。
            "-gpu", "host"
        ]
        if wipeData {
            arguments.append("-wipe-data")
        }
        return arguments
    }
}

public protocol BackgroundProcessHandle: AnyObject, Sendable {
    var isRunning: Bool { get }
    func terminate()
}

public protocol ProcessLaunching: Sendable {
    func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> BackgroundProcessHandle
}

public extension ProcessLaunching {
    func launch(executable: URL, arguments: [String]) throws -> BackgroundProcessHandle {
        try launch(executable: executable, arguments: arguments, environment: [:])
    }
}

public struct ProcessLauncher: ProcessLaunching {
    private let currentDirectory: URL
    private let outputURL: URL?

    /// - Parameter outputURL: 子进程的 stdout / stderr 追加到这个文件；
    ///   模拟器起不来时，这是唯一能说清楚原因的地方。
    public init(
        currentDirectory: URL = URL(fileURLWithPath: "/", isDirectory: true),
        outputURL: URL? = nil
    ) {
        self.currentDirectory = currentDirectory
        self.outputURL = outputURL
    }

    public func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> BackgroundProcessHandle {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = ProcessInfo.processInfo.environment
            .merging(environment) { _, override in override }

        if let outputURL {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !fileManager.fileExists(atPath: outputURL.path) {
                fileManager.createFile(atPath: outputURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: outputURL)
            try handle.seekToEnd()
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            try? handle.close()
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        }

        return ProcessEmulatorHandle(process: process)
    }
}

final class ProcessEmulatorHandle: BackgroundProcessHandle, @unchecked Sendable {
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    var isRunning: Bool {
        process.isRunning
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }
}

/// 管一个固定端口的模拟器：建 AVD、启动、等开机、关、存快照、换机型。
@MainActor
public final class EmulatorController: ObservableObject {
    @Published public private(set) var state: EmulatorState = .stopped
    /// 团队设备密钥是否已经确认生效。界面据此决定能不能说「全团队共用这个 ID」。
    @Published public private(set) var teamKeyActive = false
    /// 团队密钥没写成时的说明。设备仍然可用，但显示的是本机 ID。
    @Published public private(set) var provisioningWarning: String?

    public var configuration: AVDConfiguration
    public let port: Int
    public let bootTimeout: TimeInterval
    public let shutdownTimeout: TimeInterval

    private let sdkDirectory: URL
    private let store: AVDStore
    private let runner: CommandRunning
    private let launcher: ProcessLaunching
    private let provisioner: DeviceProvisioning?
    private let pollInterval: TimeInterval
    private var handle: BackgroundProcessHandle?

    public init(
        sdkDirectory: URL,
        store: AVDStore,
        configuration: AVDConfiguration = .default,
        port: Int = 5554,
        runner: CommandRunning = ProcessCommandRunner(),
        launcher: ProcessLaunching = ProcessLauncher(),
        provisioner: DeviceProvisioning? = nil,
        bootTimeout: TimeInterval = 180,
        pollInterval: TimeInterval = 1,
        shutdownTimeout: TimeInterval = 45
    ) {
        self.sdkDirectory = sdkDirectory
        self.store = store
        self.configuration = configuration
        self.port = port
        self.runner = runner
        self.launcher = launcher
        self.provisioner = provisioner
        self.bootTimeout = bootTimeout
        self.pollInterval = pollInterval
        self.shutdownTimeout = shutdownTimeout
    }

    public var serial: String {
        "emulator-\(port)"
    }

    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    private var emulatorURL: URL {
        sdkDirectory
            .appendingPathComponent("emulator", isDirectory: true)
            .appendingPathComponent("emulator")
    }

    private var adbURL: URL {
        sdkDirectory
            .appendingPathComponent("platform-tools", isDirectory: true)
            .appendingPathComponent("adb")
    }

    /// 我们自己的目录，模拟器的所有状态都留在这里：既不读 `~/.android`，
    /// 也不往里写。`ANDROID_AVD_HOME` 不指过来，模拟器会去默认位置找设备，
    /// 找不到就静默退出。
    private var supportDirectory: URL {
        store.root.deletingLastPathComponent()
    }

    private var emulatorHome: URL {
        supportDirectory.appendingPathComponent("emu-home", isDirectory: true)
    }

    private var androidUserHome: URL {
        supportDirectory.appendingPathComponent("android-home", isDirectory: true)
    }

    private var emulatorEnvironment: [String: String] {
        [
            "ANDROID_SDK_ROOT": sdkDirectory.path,
            "ANDROID_HOME": sdkDirectory.path,
            "ANDROID_AVD_HOME": store.root.path,
            "ANDROID_EMULATOR_HOME": emulatorHome.path,
            "ANDROID_USER_HOME": androidUserHome.path
        ]
    }

    public func start(wipeData: Bool = false) async throws {
        guard !isRunning else { return }

        state = .starting
        teamKeyActive = false
        provisioningWarning = nil
        do {
            if !store.exists(named: configuration.name) {
                try store.create(configuration)
            }
            try FileManager.default.createDirectory(
                at: emulatorHome,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: androidUserHome,
                withIntermediateDirectories: true
            )
            // 上次异常退出（比如应用被强杀）会留下锁文件，内容里的进程号早就没了。
            // 不清掉的话，模拟器会直接 FATAL 退出，界面上就是「一直起不来」。
            removeStaleLocks()
            let arguments = EmulatorArguments.make(
                avdName: configuration.name,
                port: port,
                wipeData: wipeData
            )
            handle = try launcher.launch(
                executable: emulatorURL,
                arguments: arguments,
                environment: emulatorEnvironment
            )
            try await waitForBoot()

            // 必须在画面连上之前完成：写密钥会重启一次系统框架，
            // 晚做的话 scrcpy 刚连上就会被断开。
            if let provisioner {
                do {
                    try await provisioner.provision(serial: serial)
                    teamKeyActive = true
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    teamKeyActive = false
                    provisioningWarning = Self.provisioningMessage(for: error)
                }
            }

            state = .running(serial: serial)
        } catch {
            handle?.terminate()
            handle = nil
            state = .failed(Self.message(for: error))
            throw error
        }
    }

    /// 关掉模拟器。
    ///
    /// `adb emu kill` 只是「请关」，模拟器还要把快照写完才真正退出（这台机器上
    /// 大约两三秒）。以前发完就 SIGTERM，紧接着再启动，新进程会撞上没做完的
    /// 快照操作——日志里 `A snapshot operation ... is pending`，然后直接退出。
    /// 所以这里要等进程自己走完，实在不走才强杀。
    public func stop() async throws {
        guard handle != nil || isRunning else {
            state = .stopped
            return
        }
        state = .stopping
        _ = try? await runner.run(adbURL, ["-s", serial, "emu", "kill"])

        let deadline = Date().addingTimeInterval(shutdownTimeout)
        while handle?.isRunning == true {
            if Date() >= deadline {
                handle?.terminate()
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        handle = nil
        state = .stopped
        teamKeyActive = false
        provisioningWarning = nil
    }

    /// 换机型：改 config.ini，重启设备。分辨率只在启动时读，必须重启才生效。
    public func switchProfile(to profile: DeviceProfile) async throws {
        if store.exists(named: configuration.name) {
            try store.updateProfile(named: configuration.name, to: profile)
        } else {
            configuration.profile = profile
            try store.create(configuration)
            return
        }
        configuration.profile = profile
        guard isRunning else { return }
        try await stop()
        try await start()
    }

    public func saveSnapshot(named name: String = "default_boot") async throws {
        let result = try await runner.run(
            adbURL,
            ["-s", serial, "emu", "avd", "snapshot", "save", name]
        )
        guard result.status == 0 else {
            throw EmulatorError.commandFailed(
                result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// 清掉 AVD 目录里「主人已经死了」的 `*.lock`。
    ///
    /// 模拟器的锁文件里写着持有者的进程号（可能带一个 NUL 结尾）。进程号还在，
    /// 说明锁真的有人用——比如用户自己从终端起了一台——绝不碰。没有进程号的
    /// （`multiinstance.lock` 常见）再试着拿一次 flock：拿得到就是没人用。
    private func removeStaleLocks() {
        let directory = store.deviceDirectory(named: configuration.name)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        for name in names where name.hasSuffix(".lock") {
            let url = directory.appendingPathComponent(name)
            guard !Self.isHeldByLiveProcess(url) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func isHeldByLiveProcess(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        let text = String(decoding: data, as: UTF8.self)
        let digits = text.prefix { $0.isNumber }
        if let pid = pid_t(digits), pid > 0 {
            // 信号 0 只做存在性检查，不给对方发任何东西。
            return kill(pid, 0) == 0 || errno == EPERM
        }
        // 没有进程号：谁能拿到排他锁，就说明没人在用。
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    private func waitForBoot() async throws {
        let deadline = Date().addingTimeInterval(bootTimeout)
        while true {
            try Task.checkCancellation()
            // 进程没了就别再轮询 adb 了。以前这里只等超时，界面上会卡好几分钟
            // 显示「正在启动」，而真正的原因（模拟器 FATAL 退出）藏在日志里。
            if let handle, !handle.isRunning {
                throw EmulatorError.exitedDuringBoot
            }
            let result = try await runner.run(
                adbURL,
                ["-s", serial, "shell", "getprop", "sys.boot_completed"]
            )
            if result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                return
            }
            if Date() >= deadline {
                throw EmulatorError.bootTimeout(seconds: bootTimeout)
            }
            if pollInterval > 0 {
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }
        }
    }

    private static func provisioningMessage(for error: Error) -> String {
        if let error = error as? TeamDeviceKeyError {
            return error.explanation
        }
        return "团队设备 ID 未生效：\(error.localizedDescription)"
    }

    private static func message(for error: Error) -> String {
        switch error {
        case let error as EmulatorError:
            switch error {
            case let .launchFailed(reason):
                return reason
            case let .bootTimeout(seconds):
                return "模拟器启动超时（\(Int(seconds)) 秒）。请重试，或在诊断里查看模拟器日志。"
            case let .commandFailed(output):
                return "模拟器命令失败：\(output)"
            case .exitedDuringBoot:
                return "模拟器启动后立刻退出了。通常是上一次没有正常关闭，重试一次；"
                    + "如果还不行，在诊断里查看模拟器日志。"
            }
        default:
            return "模拟器启动失败：\(error.localizedDescription)"
        }
    }
}
