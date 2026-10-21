import Foundation

/// 工具自己管理的数据目录，全部收在 `~/Library/Application Support/UI验收台/` 下。
///
///     sdk/   platform-tools、emulator、system-images
///     avd/   AVD 配置（通过 ANDROID_AVD_HOME 指过来）
///     tmp/   会话临时目录，退出即删
public struct AppPaths: Equatable, Sendable {
    public let supportDirectory: URL

    public init(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
    }

    public var sdkDirectory: URL {
        supportDirectory.appendingPathComponent("sdk", isDirectory: true)
    }

    public var avdDirectory: URL {
        supportDirectory.appendingPathComponent("avd", isDirectory: true)
    }

    public var temporaryRoot: URL {
        supportDirectory.appendingPathComponent("tmp", isDirectory: true)
    }

    /// 从链接下载的 APK 落在这里，随 `tmp/` 一起清掉。
    /// 用户从本机选中的原始 APK 不会复制过来，也不在清理范围内。
    public var apkDirectory: URL {
        temporaryRoot.appendingPathComponent("apk", isDirectory: true)
    }

    public var logsDirectory: URL {
        supportDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    /// 模拟器把自己的输出写在这里。它是 `-no-window` 启动的，
    /// 起不来时不在屏幕上留任何东西，只有这个文件能说清原因。
    public var emulatorLogURL: URL {
        logsDirectory.appendingPathComponent("emulator.log")
    }

    public static var standard: AppPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppPaths(supportDirectory: base.appendingPathComponent("UI验收台", isDirectory: true))
    }

    public func createDirectories() throws {
        let fileManager = FileManager.default
        for directory in [supportDirectory, sdkDirectory, avdDirectory, temporaryRoot, apkDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
