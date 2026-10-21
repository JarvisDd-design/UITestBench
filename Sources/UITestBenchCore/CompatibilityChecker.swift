import Foundation

/// 阻断安装的原因。每一条都必须能翻译成人话给设计同事看。
public enum CompatibilityIssue: Equatable, Sendable {
    case minSdkTooHigh(required: Int, device: Int)
    case noMatchingAbi(apk: [String])
    case splitApkUnsupported
    case manifestUnreadable

    public var explanation: String {
        switch self {
        case let .minSdkTooHigh(required, device):
            return "这个包要求 Android API \(required)，当前模拟器是 API \(device)。"
                + "请让开发降低 minSdk，或换用更高版本的系统镜像。"
        case let .noMatchingAbi(abis):
            return "这个包的原生库只有 \(abis.joined(separator: "、"))，"
                + "Apple 芯片的模拟器只能运行带 arm64-v8a 的包。"
        case .splitApkUnsupported:
            return "这是拆分包（split APK 或 XAPK），本工具只支持单个完整 APK。"
                + "请让开发导出一个完整包。"
        case .manifestUnreadable:
            return "读不出包信息，文件可能已损坏，或者根本不是标准 APK。"
        }
    }
}

public struct CompatibilityReport: Equatable, Sendable {
    public let issues: [CompatibilityIssue]

    public var isCompatible: Bool { issues.isEmpty }

    public init(issues: [CompatibilityIssue]) {
        self.issues = issues
    }
}

public enum CompatibilityChecker {
    /// 与首版锁定的系统镜像保持一致：Android 14 / API 34，arm64-v8a。
    public static let deviceApiLevel = 34
    public static let deviceAbi = "arm64-v8a"

    public static func check(_ info: ApkInfo) -> CompatibilityReport {
        var issues: [CompatibilityIssue] = []

        if info.isSplitApk {
            issues.append(.splitApkUnsupported)
        }

        if let minSdk = info.minSdkVersion, minSdk > deviceApiLevel {
            issues.append(.minSdkTooHigh(required: minSdk, device: deviceApiLevel))
        }

        // 纯 Java/Kotlin 包没有 lib/ 目录，任何架构都能装；只有带原生库时才需要匹配。
        if !info.abis.isEmpty, !info.abis.contains(deviceAbi) {
            issues.append(.noMatchingAbi(apk: info.abis))
        }

        return CompatibilityReport(issues: issues)
    }

    public static func check(_ inspection: Result<ApkInfo, ApkInspectionError>) -> CompatibilityReport {
        switch inspection {
        case let .success(info):
            return check(info)
        case .failure:
            return CompatibilityReport(issues: [.manifestUnreadable])
        }
    }
}
