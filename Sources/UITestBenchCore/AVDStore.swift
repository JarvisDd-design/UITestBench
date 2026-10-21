import Foundation

public enum AVDStoreError: Error, Equatable {
    case deviceNotFound(String)
    case invalidConfig(String)
}

/// AVD 文件操作的唯一入口。
public struct AVDStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func deviceINIRoot(named name: String) -> URL {
        root.appendingPathComponent("\(name).ini")
    }

    public func deviceDirectory(named name: String) -> URL {
        root.appendingPathComponent("\(name).avd", isDirectory: true)
    }

    public func configINIURL(named name: String) -> URL {
        deviceDirectory(named: name).appendingPathComponent("config.ini")
    }

    public func exists(named name: String) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: deviceINIRoot(named: name).path)
            && fileManager.fileExists(atPath: configINIURL(named: name).path)
    }

    /// 建好设备入口和 config.ini；已经存在时只补齐缺的部分，不动设备数据。
    public func create(_ configuration: AVDConfiguration) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: deviceDirectory(named: configuration.name),
            withIntermediateDirectories: true
        )

        try configuration.deviceINI(root: root).write(
            to: deviceINIRoot(named: configuration.name),
            atomically: true,
            encoding: .utf8
        )

        let configURL = configINIURL(named: configuration.name)
        if fileManager.fileExists(atPath: configURL.path) {
            try updateProfile(named: configuration.name, to: configuration.profile)
        } else {
            try configuration.configINI.write(to: configURL, atomically: true, encoding: .utf8)
        }
    }

    public func profile(named name: String) throws -> DeviceProfile {
        let configURL = configINIURL(named: name)
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            throw AVDStoreError.deviceNotFound(name)
        }
        let values = AVDConfiguration.parseINI(text)
        guard let width = values["hw.lcd.width"].flatMap(Int.init),
              let height = values["hw.lcd.height"].flatMap(Int.init),
              let density = values["hw.lcd.density"].flatMap(Int.init)
        else {
            throw AVDStoreError.invalidConfig(name)
        }
        return DeviceProfile(
            name: values["avd.profile.name"] ?? name,
            width: width,
            height: height,
            density: density
        )
    }

    /// 只改分辨率相关的几行，其余键原样保留。
    public func updateProfile(named name: String, to profile: DeviceProfile) throws {
        let configURL = configINIURL(named: name)
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            throw AVDStoreError.deviceNotFound(name)
        }
        var values = AVDConfiguration.parseINI(text)
        values["avd.profile.name"] = profile.name
        values["hw.lcd.width"] = String(profile.width)
        values["hw.lcd.height"] = String(profile.height)
        values["hw.lcd.density"] = String(profile.density)

        let body = values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: "\n") + "\n"
        try body.write(to: configURL, atomically: true, encoding: .utf8)
    }

    public func delete(named name: String) throws {
        let fileManager = FileManager.default
        for url in [deviceINIRoot(named: name), deviceDirectory(named: name)] {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }
}
