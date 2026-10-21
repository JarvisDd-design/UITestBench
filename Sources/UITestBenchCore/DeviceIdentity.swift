import CryptoKit
import Foundation

/// 应用看到的 Android ID（SSAID），以及设备的序列号和机型。
///
/// 开发在测试环境按「设备 ID」加白名单时，要的就是这里面的 `androidID`：
/// Android 8 以后每个应用拿到的 Android ID 不同，系统把它按 UID 存在
/// `settings_ssaid.xml` 里，`settings get secure android_id` 拿到的是设备种子，
/// 不是应用看到的值。
///
/// 这个值由「设备 userkey + APK 签名证书」做 HMAC-SHA256 得到（AOSP
/// `SettingsProvider.generateSsaidLocked`），与包名、UID、安装次数无关：
/// 同一个包卸载重装、清数据、工具重启都不会变；同一套签名证书签的包共用
/// 一个值。只有模拟器的 userdata（userkey）被重建才会全部改变。
public struct DeviceIdentity: Equatable, Sendable {
    public let serial: String
    public let model: String
    /// 应用实际读到的 Android ID；应用还没读过（或镜像不允许 su）时为 nil。
    public let androidID: String?

    public init(serial: String, model: String, androidID: String?) {
        self.serial = serial
        self.model = model
        self.androidID = androidID
    }
}

/// 后台常见的另一种设备标识写法。
public enum DeviceFingerprint {
    /// 对 16 位小写 Android ID 的 UTF-8 文本做 MD5，输出 32 位小写十六进制。
    ///
    /// 有些反馈/分析后台不直接存 Android ID，而是存它的 MD5。
    /// 必须按「文本」哈希，不能先转成 8 字节再哈希；大小写也要保持原样。
    public static func md5(of androidID: String) -> String {
        Insecure.MD5.hash(data: Data(androidID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// 从系统里读 `DeviceIdentity`。
///
/// AVD 用的是 AOSP `default` 镜像（userdebug），`adb shell su 0` 可用，
/// 因此不需要把 adbd 切成 root——切 root 会重启 adbd，scrcpy 的连接会断。
public struct DeviceIdentityReader {
    private let adbURL: URL
    private let adbSerial: String
    private let runner: CommandRunning
    private let attempts: Int
    private let retryDelay: TimeInterval

    /// - Parameters:
    ///   - attempts: 应用启动后才会写 SSAID，所以要多试几次。
    ///   - retryDelay: 每次重试之间等多久。
    public init(
        sdkDirectory: URL,
        serial: String,
        runner: CommandRunning = ProcessCommandRunner(),
        attempts: Int = 8,
        retryDelay: TimeInterval = 0.5
    ) {
        self.adbURL = sdkDirectory
            .appendingPathComponent("platform-tools", isDirectory: true)
            .appendingPathComponent("adb")
        self.adbSerial = serial
        self.runner = runner
        self.attempts = attempts
        self.retryDelay = retryDelay
    }

    public func read(packageName: String) async throws -> DeviceIdentity {
        let serial = try await property("ro.serialno")
        let model = try await property("ro.product.model")

        var androidID: String?
        for attempt in 0..<max(attempts, 1) {
            if Task.isCancelled { break }
            androidID = try? await appAndroidID(packageName: packageName)
            if androidID != nil { break }
            if attempt + 1 < max(attempts, 1), retryDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            }
        }

        return DeviceIdentity(serial: serial, model: model, androidID: androidID)
    }

    private func property(_ name: String) async throws -> String {
        let result = try await runner.run(
            adbURL,
            ["-s", adbSerial, "shell", "getprop", name]
        )
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func appAndroidID(packageName: String) async throws -> String? {
        let result = try await runner.run(
            adbURL,
            [
                "-s", adbSerial, "shell",
                "su", "0", "abx2xml",
                "/data/system/users/0/settings_ssaid.xml", "-"
            ]
        )
        guard result.status == 0 else { return nil }
        return SSAIDTable.androidID(for: packageName, in: result.output)
    }
}

/// 解析 `settings_ssaid.xml`（abx2xml 输出的文本）。
///
/// 每行是 `<setting id="5" name="10142" value="10f5f004470a2797"
/// package="com.example" ...>`：`name` 是应用 UID，`value` 才是 ID。
/// 另有一行 `name="userkey"`，那是整台设备的随机密钥（64 位十六进制），
/// 不是应用 ID，必须排除，否则发给开发的永远是错的。
public enum SSAIDTable {
    public static func androidID(for packageName: String, in xml: String) -> String? {
        guard !packageName.isEmpty else { return nil }

        for chunk in xml.components(separatedBy: "<setting ") {
            let row = chunk.prefix { $0 != ">" }
            guard attribute("package", in: row) == packageName,
                  let name = attribute("name", in: row),
                  !name.isEmpty,
                  name.allSatisfy(\.isNumber),
                  let value = attribute("value", in: row),
                  value.count == 16,
                  value.allSatisfy(\.isHexDigit)
            else { continue }
            return value
        }
        return nil
    }

    /// 整台设备的随机密钥（`name="userkey"`），不是应用看到的 ID。
    ///
    /// 团队统一设备 ID 就是把它固定成同一个值：SSAID 由
    /// `HMAC(userkey, 签名证书)` 算出，所以所有电脑对同一套证书会得到同一个 ID。
    public static func userKey(in xml: String) -> String? {
        for line in normalizedLines(xml) where line.contains("<setting ") {
            let row = Substring(line)
            guard attribute("name", in: row) == "userkey" else { continue }
            return attribute("value", in: row)
        }
        return nil
    }

    /// 把表改成团队密钥，并丢掉所有旧的按 UID 行。
    ///
    /// 旧行是按「旧密钥 + 签名证书」算出来的；只换 userkey 不删它们，应用会
    /// 继续读到旧值，团队统一 ID 就只对还没读过 ID 的包生效。
    /// 返回 nil 表示没有 userkey 行（镜像不对）或密钥格式不合法。
    public static func preparedForTeamKey(_ key: String, in xml: String) -> String? {
        guard isValidUserKey(key) else { return nil }

        var foundUserKey = false
        var lines: [String] = []
        for line in normalizedLines(xml) {
            guard line.contains("<setting ") else {
                lines.append(line)
                continue
            }
            let row = Substring(line)
            guard attribute("name", in: row) == "userkey", !foundUserKey else { continue }
            foundUserKey = true
            lines.append(replacingValue(in: line, with: key))
        }

        guard foundUserKey else { return nil }
        return lines.joined(separator: "\n")
    }

    /// 全新设备第一次开机时，系统还没生成这张表。自己建一张只有 userkey
    /// 的空表，格式与 SettingsProvider 写出来的保持一致。
    ///
    /// 不建的话，别的电脑第一次打开时写不进团队密钥，应用会拿到本机的随机 ID。
    public static func table(forTeamKey key: String) -> String? {
        guard isValidUserKey(key) else { return nil }
        return """
        <?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
        <settings version="-1">
          <setting id="0" name="userkey" value="\(key)" package="android" defaultValue="\(key)" defaultSysSet="true" tag="null" />
        </settings>
        <namespaceHashes />
        """
    }

    public static func isValidUserKey(_ key: String) -> Bool {
        key.count == 64 && key.allSatisfy(\.isHexDigit)
    }

    /// `abx2xml` 在有些版本上输出 CRLF；统一成 LF，写回时更可控。
    private static func normalizedLines(_ xml: String) -> [String] {
        xml.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    /// 同时改 `value` 与 `defaultValue`：只改前者的话，「重置设置」会把
    /// 旧密钥又写回来，团队 ID 下次启动就失效了。
    private static func replacingValue(in line: String, with key: String) -> String {
        var result = line
        for name in ["value", "defaultValue"] {
            guard let old = attribute(name, in: Substring(result)) else { continue }
            result = result.replacingOccurrences(
                of: "\(name)=\"\(old)\"",
                with: "\(name)=\"\(key)\""
            )
        }
        return result
    }

    private static func attribute(_ key: String, in row: Substring) -> String? {
        guard let start = row.range(of: "\(key)=\"") else { return nil }
        let rest = row[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }
}
