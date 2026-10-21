import Foundation

/// 安装失败的原因。每一条都能翻译成人话，`unknown` 则保留原始失败码。
public enum InstallFailure: Equatable, Sendable {
    case noMatchingAbis
    case olderSdk
    case updateIncompatible
    case unsigned
    case insufficientStorage
    case unknown(String)

    public var explanation: String {
        switch self {
        case .noMatchingAbis:
            return "这个包只带 32 位 ARM 库，Apple 芯片的模拟器装不了。"
                + "请让开发补一份含 arm64-v8a 的包。"
        case .olderSdk:
            return "这个包要求的 Android 版本比当前设备高。"
                + "请换用更高版本的系统镜像，或让开发降低 minSdk。"
        case .updateIncompatible:
            return "设备上已经装了同包名但签名不同的版本。请用「完全重装」先卸载再装。"
        case .unsigned:
            return "这个包没有签名或已损坏。请让开发用正式签名重新导出。"
        case .insufficientStorage:
            return "虚拟设备空间不足。请停止设备后清数据重启，或换一个更小的包。"
        case let .unknown(code):
            return "安装失败（\(code)）。把诊断信息发给开发看看。"
        }
    }
}

public enum InstallResult: Equatable, Sendable {
    case success
    case failure(InstallFailure)
}

/// 读 `adb install` 的输出。成功时通常只有一行 `Success`，
/// 失败时是一行 `Failure [INSTALL_FAILED_XXX: 细节]`。
public enum InstallOutputParser {
    public static func parse(_ output: String, status: Int32) -> InstallResult {
        if let code = failureCode(in: output) {
            return .failure(translated(code))
        }
        if status == 0 {
            return .success
        }
        return .failure(.unknown(output.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// `Failure [CODE]` 或 `Failure [CODE: 细节]` 里的 CODE。
    static func failureCode(in output: String) -> String? {
        guard let range = output.range(of: "Failure [") else { return nil }
        let rest = output[range.upperBound...]
        let end = rest.firstIndex(where: { $0 == "]" || $0 == ":" }) ?? rest.endIndex
        let code = rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return code.isEmpty ? nil : code
    }

    private static func translated(_ code: String) -> InstallFailure {
        switch code {
        case "INSTALL_FAILED_NO_MATCHING_ABIS":
            return .noMatchingAbis
        case "INSTALL_FAILED_OLDER_SDK":
            return .olderSdk
        case "INSTALL_FAILED_UPDATE_INCOMPATIBLE":
            return .updateIncompatible
        case "INSTALL_PARSE_FAILED_NO_CERTIFICATES":
            return .unsigned
        case "INSTALL_FAILED_INSUFFICIENT_STORAGE":
            return .insufficientStorage
        default:
            return .unknown(code)
        }
    }
}

public enum AppLifecycleError: Error, Equatable {
    case install(InstallFailure)
    case launchFailed(String)
    case clearDataFailed
    case uninstallFailed(String)

    public var explanation: String {
        switch self {
        case let .install(failure):
            return failure.explanation
        case let .launchFailed(detail):
            return "应用已安装，但没有找到能启动的界面。" + (detail.isEmpty ? "" : "（\(detail)）")
        case .clearDataFailed:
            return "清不掉应用数据。请停止设备后重新启动再试。"
        case let .uninstallFailed(detail):
            return "卸载失败（\(detail)）。请停止设备后重试。"
        }
    }
}

/// 应用生命周期的四个原子动作。`AppRunner` 只依赖这个协议，
/// 测试里换成记账的假件就能验证流程顺序。
public protocol AppLifecycleRunning: AnyObject {
    func install(apkAt url: URL) async throws
    func launch(packageName: String, activity: String?) async throws
    func clearData(packageName: String) async throws
    func uninstall(packageName: String) async throws
    func forceStop(packageName: String) async throws
    func isInstalled(packageName: String) async -> Bool
}

/// 对一个已连接设备上的应用做四件事：装、启动、清数据、卸载。
///
/// 只拼命令、读输出，不做重试编排——「清数据重开」「完全重装」由
/// `AppRunner` 按需要的顺序组合，界面才好逐段显示进度。
public final class AppLifecycle: AppLifecycleRunning {
    private let sdkDirectory: URL
    private let serial: String
    private let runner: CommandRunning

    public init(
        sdkDirectory: URL,
        serial: String,
        runner: CommandRunning = ProcessCommandRunner()
    ) {
        self.sdkDirectory = sdkDirectory
        self.serial = serial
        self.runner = runner
    }

    private var adbURL: URL {
        sdkDirectory
            .appendingPathComponent("platform-tools", isDirectory: true)
            .appendingPathComponent("adb")
    }

    private func adb(_ arguments: [String]) async throws -> CommandResult {
        try await runner.run(adbURL, ["-s", serial] + arguments)
    }

    public func install(apkAt url: URL) async throws {
        let result = try await adb(["install", "-r", "-t", url.path])
        if case let .failure(failure) = InstallOutputParser.parse(result.output, status: result.status) {
            throw AppLifecycleError.install(failure)
        }
    }

    /// 优先直接拉起已知的入口 Activity；入口不存在时退回让系统自己找桌面入口。
    public func launch(packageName: String, activity: String?) async throws {
        if let activity, !activity.isEmpty {
            let component = Self.component(packageName: packageName, activity: activity)
            let result = try await adb(["shell", "am", "start", "-W", "-n", component])
            let output = result.output
            let started = result.status == 0
                && !output.contains("Error type 3")
                && !output.contains("does not exist")
            if started { return }
        }

        let result = try await adb([
            "shell", "monkey", "-p", packageName,
            "-c", "android.intent.category.LAUNCHER", "1"
        ])
        let output = result.output.lowercased()
        if result.status != 0 || output.contains("no activities found") || output.contains("aborted") {
            throw AppLifecycleError.launchFailed(
                result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    public func clearData(packageName: String) async throws {
        let result = try await adb(["shell", "pm", "clear", packageName])
        guard result.status == 0, result.output.contains("Success") else {
            throw AppLifecycleError.clearDataFailed
        }
    }

    /// 设备上本来就没有这个包时视为成功——「完全重装」的第一步常常就是这样。
    public func uninstall(packageName: String) async throws {
        let result = try await adb(["uninstall", packageName])
        if result.status == 0 || result.output.contains("Success") { return }
        if result.output.contains("not installed") { return }

        let detail = InstallOutputParser.failureCode(in: result.output)
            ?? result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        throw AppLifecycleError.uninstallFailed(detail)
    }

    /// 只杀进程，不动数据。应用已经在跑时 `am start` 只会把任务提到前台，
    /// 想核对「第二次打开」的界面必须先真正结束进程。
    public func forceStop(packageName: String) async throws {
        let result = try await adb(["shell", "am", "force-stop", packageName])
        guard result.status == 0 else {
            throw AppLifecycleError.launchFailed(
                result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    public func isInstalled(packageName: String) async -> Bool {
        guard let result = try? await adb(["shell", "pm", "list", "packages", packageName]) else {
            return false
        }
        return result.output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains("package:\(packageName)")
    }

    static func component(packageName: String, activity: String) -> String {
        if activity.contains("/") { return activity }
        return "\(packageName)/\(activity)"
    }
}
