import Foundation

/// 手写 AVD 配置，绕过 avdmanager（它要 JDK）。
///
/// 目录结构遵循 Android 惯例，`ANDROID_AVD_HOME` 指到 `AppPaths.avdDirectory`：
///
///     avd/uitestbench.ini          设备入口，指向 .avd 目录
///     avd/uitestbench.avd/config.ini
public struct AVDConfiguration: Equatable, Sendable {
    public var name: String
    public var displayName: String
    public var systemImageDirectory: String
    public var profile: DeviceProfile
    public var ramSizeMB: Int

    public static let defaultName = "uitestbench"
    public static let defaultDisplayName = "UI验收台"
    public static let defaultSystemImageDirectory = "system-images/android-34/default/arm64-v8a/"

    public init(
        name: String,
        displayName: String,
        systemImageDirectory: String,
        profile: DeviceProfile,
        ramSizeMB: Int = 2048
    ) {
        self.name = name
        self.displayName = displayName
        self.systemImageDirectory = systemImageDirectory
        self.profile = profile
        self.ramSizeMB = ramSizeMB
    }

    public static var `default`: AVDConfiguration {
        AVDConfiguration(
            name: defaultName,
            displayName: defaultDisplayName,
            systemImageDirectory: defaultSystemImageDirectory,
            profile: .standard
        )
    }

    /// config.ini 的全部键值。键顺序另由 `configINI` 固定，保证输出稳定。
    public var configINIValues: [String: String] {
        [
            "AvdId": name,
            "avd.ini.displayname": displayName,
            "abi.type": "arm64-v8a",
            "hw.cpu.arch": "arm64",
            "hw.cpu.ncore": "4",
            "hw.ramSize": String(ramSizeMB),
            "vm.heapSize": "256",
            "disk.dataPartition.size": "6G",
            "image.sysdir.1": systemImageDirectory,
            "tag.id": "default",
            "avd.profile.name": profile.name,
            "hw.lcd.width": String(profile.width),
            "hw.lcd.height": String(profile.height),
            "hw.lcd.density": String(profile.density),
            "hw.keyboard": "yes",
            "hw.mainKeys": "no",
            "hw.gpu.enabled": "yes",
            "hw.gpu.mode": "auto",
            "showDeviceFrame": "no"
        ]
    }

    public var configINI: String {
        Self.renderINI(configINIValues, order: Self.configKeyOrder)
    }

    public func deviceINIValues(root: URL) -> [String: String] {
        let deviceDirectory = root.appendingPathComponent("\(name).avd", isDirectory: true)
        return [
            "avd.ini.encoding": "UTF-8",
            "path": deviceDirectory.path,
            "path.rel": "avd/\(name).avd",
            "target": "android-34"
        ]
    }

    public func deviceINI(root: URL) -> String {
        Self.renderINI(deviceINIValues(root: root), order: Self.deviceKeyOrder)
    }

    private static let configKeyOrder = [
        "AvdId",
        "avd.ini.displayname",
        "abi.type",
        "hw.cpu.arch",
        "hw.cpu.ncore",
        "hw.ramSize",
        "vm.heapSize",
        "disk.dataPartition.size",
        "image.sysdir.1",
        "tag.id",
        "avd.profile.name",
        "hw.lcd.width",
        "hw.lcd.height",
        "hw.lcd.density",
        "hw.keyboard",
        "hw.mainKeys",
        "hw.gpu.enabled",
        "hw.gpu.mode",
        "showDeviceFrame"
    ]

    private static let deviceKeyOrder = [
        "avd.ini.encoding",
        "path",
        "path.rel",
        "target"
    ]

    private static func renderINI(_ values: [String: String], order: [String]) -> String {
        var lines: [String] = []
        for key in order {
            if let value = values[key] {
                lines.append("\(key)=\(value)")
            }
        }
        // 不认识的键追加在后面，避免手改的配置在重写时消失。
        for key in values.keys.sorted() where !order.contains(key) {
            lines.append("\(key)=\(values[key]!)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 解析 config.ini 这类简单键值文件；`#` 开头与空行忽略。
    public static func parseINI(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            values[key] = value
        }
        return values
    }
}
