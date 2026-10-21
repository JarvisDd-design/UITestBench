import Foundation

/// 团队统一的设备密钥。
///
/// 这是第一台验收用模拟器上生成的 userkey，也是本机已经配过的
/// `10f5f004470a2797` 的来源。把它作为常量下发：所有同事的模拟器
/// 共用同一把设备密钥，而 SSAID = HMAC(userkey, APK 签名证书)，
/// 所以同一套签名证书签的包，在所有电脑上都会得到同一个 ID。
///
/// 它是测试环境的设备标识，不是密钥材料，不参与鉴权。
public enum TeamDeviceKey {
    public static let value = "C0F8B2FAA0DA029E9AABDF6417C0961EDE427A37D3292BF8540C5170D0B6DA22"
}

public enum TeamDeviceKeyError: Error, Equatable, LocalizedError {
    case invalidKey
    case userKeyUnreadable(String)
    case userKeyMissing
    case commandFailed(String)
    case verificationFailed
    case frameworkDidNotStart

    public var explanation: String {
        switch self {
        case .invalidKey:
            return "团队设备 ID 的密钥格式不对（需要 64 位十六进制）。"
        case let .userKeyUnreadable(detail):
            return "读不到模拟器的设备密钥。" + (detail.isEmpty ? "" : "（\(detail)）")
        case .userKeyMissing:
            return "模拟器里没有设备密钥记录，可能系统镜像版本不对。请停止设备后重试。"
        case let .commandFailed(detail):
            return "设置团队设备 ID 失败：\(detail)"
        case .verificationFailed:
            return "团队设备 ID 没有写入成功，已恢复原设置。请停止设备后重试。"
        case .frameworkDidNotStart:
            return "写入团队设备 ID 后，模拟器系统没有重新启动完成。请停止设备后重试。"
        }
    }

    public var errorDescription: String? { explanation }
}

/// 设备起来后、把画面交出去之前要做的一次性配置。
public protocol DeviceProvisioning: Sendable {
    func provision(serial: String) async throws
}

/// 把模拟器的 SSAID userkey 固定成 `TeamDeviceKey.value`。
///
/// 步骤必须按这个顺序：先停系统框架，再改表，再启框架。
/// 不停框架直接改文件，SettingsProvider 内存里的旧表会在下次写入时
/// 把文件覆盖回去；用 `su 0 stop` 停掉框架就没有这个风险。
///
/// 写入前会把原文件备份到设备上；校验读回来的密钥不对时自动恢复。
public struct TeamDeviceKeyProvisioner: DeviceProvisioning {
    private static let tablePath = "/data/system/users/0/settings_ssaid.xml"
    private static let remoteXML = "/data/local/tmp/uitestbench-ssaid.xml"
    private static let remoteABX = "/data/local/tmp/uitestbench-ssaid.abx"
    private static let backupPath = "/data/local/tmp/uitestbench-ssaid-backup.abx"

    private let adbURL: URL
    private let runner: CommandRunning
    private let teamKey: String
    private let temporaryDirectory: URL
    private let stopTimeout: TimeInterval
    private let readinessTimeout: TimeInterval
    private let readinessDelay: TimeInterval

    /// - Parameters:
    ///   - stopTimeout: 等 `su 0 stop` 把 zygote 停下来的最长时间。
    ///   - readinessTimeout: `su 0 start` 后等 PackageManager 与 SettingsProvider
    ///     真正可用的最长时间。`sys.boot_completed` 在框架重启时不会清零，
    ///     不能拿它当判据。
    public init(
        sdkDirectory: URL,
        runner: CommandRunning = ProcessCommandRunner(),
        teamKey: String = TeamDeviceKey.value,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        stopTimeout: TimeInterval = 15,
        readinessTimeout: TimeInterval = 60,
        readinessDelay: TimeInterval = 0.5
    ) {
        self.adbURL = sdkDirectory
            .appendingPathComponent("platform-tools", isDirectory: true)
            .appendingPathComponent("adb")
        self.runner = runner
        self.teamKey = teamKey
        self.temporaryDirectory = temporaryDirectory
        self.stopTimeout = stopTimeout
        self.readinessTimeout = readinessTimeout
        self.readinessDelay = readinessDelay
    }

    public func provision(serial: String) async throws {
        guard SSAIDTable.isValidUserKey(teamKey) else {
            throw TeamDeviceKeyError.invalidKey
        }

        // 先读一次：已经对了就什么都不做，正常启动只多一条 adb 命令。
        // 表可能还不存在（全新设备第一次开机），这时要建一张。
        if let first = try await readTableIfPresent(serial: serial) {
            guard let firstKey = SSAIDTable.userKey(in: first) else {
                throw TeamDeviceKeyError.userKeyMissing
            }
            if firstKey == teamKey { return }
        }

        try await stopFramework(serial: serial)

        var backupCreated = false
        var createdTable = false
        var verificationPassed = false
        do {
            // 停完再读一次：刚才那次读的可能是 SettingsProvider 还没落盘的内容。
            let prepared: String
            if let xml = try await readTableIfPresent(serial: serial) {
                guard let updated = SSAIDTable.preparedForTeamKey(teamKey, in: xml) else {
                    throw TeamDeviceKeyError.userKeyMissing
                }
                prepared = updated
            } else {
                guard let fresh = SSAIDTable.table(forTeamKey: teamKey) else {
                    throw TeamDeviceKeyError.invalidKey
                }
                prepared = fresh
                createdTable = true
            }

            let localURL = temporaryDirectory
                .appendingPathComponent("uitestbench-ssaid-\(UUID().uuidString).xml")
            try prepared.write(to: localURL, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: localURL) }

            try require(
                try await run(["push", localURL.path, Self.remoteXML], serial: serial),
                "push"
            )
            try require(
                try await run(
                    ["shell", "su", "0", "xml2abx", Self.remoteXML, Self.remoteABX],
                    serial: serial
                ),
                "xml2abx"
            )

            if createdTable {
                try require(
                    try await run(
                        ["shell", "su", "0", "cp", Self.remoteABX, Self.tablePath],
                        serial: serial
                    ),
                    "写入"
                )
                // 新建出来的文件是 root:root，标签也来自 /data/local/tmp；
                // 不改回 system 的属主和 system_data_file，系统服务读不到，
                // 应用还是会拿到随机 ID。
                try require(
                    try await run(
                        ["shell", "su", "0", "chown", "system:system", Self.tablePath],
                        serial: serial
                    ),
                    "改属主"
                )
                try require(
                    try await run(
                        ["shell", "su", "0", "chmod", "600", Self.tablePath],
                        serial: serial
                    ),
                    "改权限"
                )
                try require(
                    try await run(
                        ["shell", "su", "0", "restorecon", Self.tablePath],
                        serial: serial
                    ),
                    "改 SELinux 标签"
                )
            } else {
                try require(
                    try await run(
                        ["shell", "su", "0", "cp", Self.tablePath, Self.backupPath],
                        serial: serial
                    ),
                    "备份"
                )
                backupCreated = true
                try require(
                    try await run(
                        ["shell", "su", "0", "cp", Self.remoteABX, Self.tablePath],
                        serial: serial
                    ),
                    "写入"
                )
            }

            let written = try await readTable(serial: serial)
            guard SSAIDTable.userKey(in: written) == teamKey else {
                throw TeamDeviceKeyError.verificationFailed
            }
            verificationPassed = true

            try require(
                try await run(["shell", "su", "0", "start"], serial: serial),
                "start"
            )
            try await waitForFramework(serial: serial)
        } catch {
            // 写到一半失败：把备份盖回去，保证下次启动还能正常工作。
            // 已经校验通过（只是框架没起来）时保留新密钥，下次启动会直接跳过。
            if backupCreated && !verificationPassed {
                _ = try? await run(
                    ["shell", "su", "0", "cp", Self.backupPath, Self.tablePath],
                    serial: serial
                )
            }
            if createdTable && !verificationPassed {
                // 没有原表可恢复，删掉坏文件让系统自己重建。
                _ = try? await run(
                    ["shell", "su", "0", "rm", "-f", Self.tablePath],
                    serial: serial
                )
            }
            _ = try? await run(["shell", "su", "0", "start"], serial: serial)
            throw error
        }
    }

    /// 读表；文件不存在返回 nil（全新设备第一次开机时就是这种情况）。
    /// 文件在但读不出来才算错误——不能把权限问题当成「没有表」。
    private func readTableIfPresent(serial: String) async throws -> String? {
        let result = try await run(
            ["shell", "su", "0", "abx2xml", Self.tablePath, "-"],
            serial: serial
        )
        if result.status == 0 { return result.output }

        let exists = try await run(
            ["shell", "su", "0", "ls", Self.tablePath],
            serial: serial
        )
        if exists.status != 0 { return nil }

        let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        throw TeamDeviceKeyError.userKeyUnreadable(detail)
    }

    private func readTable(serial: String) async throws -> String {
        let result = try await run(
            ["shell", "su", "0", "abx2xml", Self.tablePath, "-"],
            serial: serial
        )
        guard result.status == 0 else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw TeamDeviceKeyError.userKeyUnreadable(detail)
        }
        return result.output
    }

    /// 停系统框架，并等 zygote 真的停下来。只发 `stop` 就写文件太早了。
    private func stopFramework(serial: String) async throws {
        try require(
            try await run(["shell", "su", "0", "stop"], serial: serial),
            "stop"
        )

        let deadline = Date().addingTimeInterval(stopTimeout)
        while true {
            try Task.checkCancellation()
            let result = try? await run(
                ["shell", "getprop", "init.svc.zygote"],
                serial: serial
            )
            let value = result?.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if value == "stopped" { return }
            if Date() >= deadline {
                throw TeamDeviceKeyError.commandFailed(
                    "模拟器系统没有停下来（zygote：\(value ?? "未知")）"
                )
            }
            try await pause()
        }
    }

    /// `su 0 start` 只是把服务拉起来，PackageManager 可能还在初始化。
    /// 用 `pm path` 和 SettingsProvider 各探一次，两个都响应了才算好。
    private func waitForFramework(serial: String) async throws {
        let deadline = Date().addingTimeInterval(readinessTimeout)
        while true {
            try Task.checkCancellation()

            let packageManager = try? await run(
                ["shell", "pm", "path", "android"],
                serial: serial
            )
            let packageManagerReady = packageManager?.status == 0
                && (packageManager?.output.contains("package:") ?? false)

            if packageManagerReady {
                let settings = try? await run(
                    ["shell", "settings", "get", "secure", "android_id"],
                    serial: serial
                )
                let settingsReady = settings?.status == 0
                    && !(settings?.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                if settingsReady { return }
            }

            if Date() >= deadline {
                throw TeamDeviceKeyError.frameworkDidNotStart
            }
            try await pause()
        }
    }

    private func pause() async throws {
        guard readinessDelay > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(readinessDelay * 1_000_000_000))
    }

    private func run(_ arguments: [String], serial: String) async throws -> CommandResult {
        try await runner.run(adbURL, ["-s", serial] + arguments)
    }

    private func require(_ result: CommandResult, _ step: String) throws {
        guard result.status == 0 else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw TeamDeviceKeyError.commandFailed(detail.isEmpty ? step : "\(step)：\(detail)")
        }
    }
}
