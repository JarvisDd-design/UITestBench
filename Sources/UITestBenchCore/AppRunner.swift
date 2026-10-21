import Foundation

public enum AppRunnerError: Error, Equatable {
    case incompatible([CompatibilityIssue])
    case missingPackageName

    public var explanation: String {
        switch self {
        case let .incompatible(issues):
            return issues.map(\.explanation).joined(separator: "\n")
        case .missingPackageName:
            return "读不出这个包的包名，文件可能已损坏。"
        }
    }
}

/// 四段固定流程。顺序不是随便定的：
///
/// - 运行：装好 → 清数据 → 启动，等价于第一次打开；
/// - 保留数据重启：装好 → 杀进程 → 启动，数据留在设备上；
/// - 清数据重开：清完再启，否则启动时数据又写回去了；
/// - 完全重装：先卸掉签名不同的旧版本，再装再启。
public final class AppRunner {
    private let lifecycle: AppLifecycleRunning

    public init(lifecycle: AppLifecycleRunning) {
        self.lifecycle = lifecycle
    }

    /// 默认就是「第一次打开」。引导页、隐私协议这类流程只在应用数据为空时出现，
    /// 而设计同事每次运行都是来核对首屏的——不清数据的话，第二次起就再也看不到。
    public func run(_ apk: AcquiredAPK) async throws {
        let target = try target(for: apk)
        try await lifecycle.install(apkAt: apk.fileURL)
        try await lifecycle.clearData(packageName: target.packageName)
        try await lifecycle.launch(packageName: target.packageName, activity: target.activity)
    }

    /// 保留数据重启：核对「非首次打开」的界面时用。
    public func resume(_ apk: AcquiredAPK) async throws {
        let target = try target(for: apk)
        try await lifecycle.install(apkAt: apk.fileURL)
        try await lifecycle.forceStop(packageName: target.packageName)
        try await lifecycle.launch(packageName: target.packageName, activity: target.activity)
    }

    public func restartClearingData(_ apk: AcquiredAPK) async throws {
        let target = try target(for: apk)
        try await lifecycle.clearData(packageName: target.packageName)
        try await lifecycle.launch(packageName: target.packageName, activity: target.activity)
    }

    public func reinstall(_ apk: AcquiredAPK) async throws {
        let target = try target(for: apk)
        try await lifecycle.uninstall(packageName: target.packageName)
        try await lifecycle.install(apkAt: apk.fileURL)
        try await lifecycle.launch(packageName: target.packageName, activity: target.activity)
    }

    /// 兼容性预检已经判了装不上，就不再浪费一轮 adb 安装和一条看不懂的错误。
    private func target(for apk: AcquiredAPK) throws -> (packageName: String, activity: String?) {
        guard apk.compatibility.isCompatible else {
            throw AppRunnerError.incompatible(apk.compatibility.issues)
        }
        guard let packageName = apk.info.packageName, !packageName.isEmpty else {
            throw AppRunnerError.missingPackageName
        }
        return (packageName, apk.info.launcherActivityName)
    }
}
