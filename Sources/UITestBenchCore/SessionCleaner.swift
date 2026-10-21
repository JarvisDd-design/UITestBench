import Foundation

/// 上次会话留下的痕迹。
///
/// 只记「该被清掉的东西」，不记任何业务内容。工具被强杀时退出钩子不会跑，
/// 下次启动靠这份记录去设备上补卸、把 `tmp/` 补清。
public struct SessionRecord: Codable, Equatable, Sendable {
    public var packageName: String
    public var startedAt: Date

    public init(packageName: String, startedAt: Date = Date()) {
        self.packageName = packageName
        self.startedAt = startedAt
    }
}

/// 「退出即清」的执行者。
///
/// 清理范围严格限定在 `supportDirectory/tmp/` 与会话记录本身；
/// SDK、AVD、日志是引擎，不属于被测内容，一律不碰。
public struct SessionCleaner {
    public let supportDirectory: URL

    public init(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
    }

    public var recordURL: URL {
        supportDirectory.appendingPathComponent("session.json")
    }

    public var temporaryRoot: URL {
        AppPaths(supportDirectory: supportDirectory).temporaryRoot
    }

    /// 记下当前装的包名，供下次启动时补卸。
    public func remember(packageName: String) throws {
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let record = SessionRecord(packageName: packageName)
        try encoder.encode(record).write(to: recordURL, options: .atomic)
    }

    /// 正常退出、确认设备上已经没有这个包之后调用。
    public func forget() throws {
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return }
        try FileManager.default.removeItem(at: recordURL)
    }

    /// 上次遗留、还没卸掉的包名。记录不存在或损坏时返回 nil。
    public func pendingPackageName() throws -> String? {
        guard let record = try loadRecord() else { return nil }
        let name = record.packageName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// 启动自检：清掉上次的临时文件，并把遗留的包名交回去，
    /// 等模拟器起来后再卸（设备没起时 adb 卸不了）。
    @discardableResult
    public func recover() throws -> SessionRecord? {
        let record = try loadRecord()
        try clearTemporaryData()
        guard let record,
              !record.packageName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return record
    }

    /// 删掉 `tmp/` 下的全部内容，目录本身留着。
    /// 用户选中的原始 APK 在 tmp 之外，不会被碰到。
    public func clearTemporaryData() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: temporaryRoot.path) else { return }
        let children = try fileManager.contentsOfDirectory(
            at: temporaryRoot,
            includingPropertiesForKeys: nil
        )
        for child in children {
            try fileManager.removeItem(at: child)
        }
    }

    private func loadRecord() throws -> SessionRecord? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: recordURL.path) else { return nil }
        guard let data = try? Data(contentsOf: recordURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // 记录坏了只说明「不知道上次装了什么」，不能因此拦下整个应用。
        guard let record = try? decoder.decode(SessionRecord.self, from: data) else {
            try? fileManager.removeItem(at: recordURL)
            return nil
        }
        return record
    }
}
