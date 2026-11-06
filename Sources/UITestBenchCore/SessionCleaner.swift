import Foundation

/// 上次会话留下的痕迹。
///
/// 只记「该被清掉的东西」，不记任何业务内容。工具被强杀时退出钩子不会跑，
/// 下次启动靠这份记录去设备上补卸、把 `tmp/` 补清。
///
/// 包名是**一组**而不是一个：一次会话里换着包测是常事，只记最后一个的话，
/// 前面几个会一直留在设备上（1.5.0 及更早就是这个毛病）。
public struct SessionRecord: Codable, Equatable, Sendable {
    public var packageNames: [String]
    public var startedAt: Date

    public init(packageNames: [String], startedAt: Date = Date()) {
        self.packageNames = packageNames
        self.startedAt = startedAt
    }

    public init(packageName: String, startedAt: Date = Date()) {
        self.init(packageNames: [packageName], startedAt: startedAt)
    }

    /// 去掉空白与空串、按出现顺序去重。写盘与读盘都过一遍。
    public var normalizedPackageNames: [String] {
        var seen = Set<String>()
        return packageNames.compactMap { raw in
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return name
        }
    }

    private enum CodingKeys: String, CodingKey {
        case packageNames
        /// 1.5.0 及更早的单包格式，只读不写。
        case packageName
        case startedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        if let names = try container.decodeIfPresent([String].self, forKey: .packageNames) {
            packageNames = names
        } else if let legacy = try container.decodeIfPresent(String.self, forKey: .packageName) {
            packageNames = [legacy]
        } else {
            packageNames = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(normalizedPackageNames, forKey: .packageNames)
        try container.encode(startedAt, forKey: .startedAt)
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

    /// 把当前装的包名**追加**进记录，供下次启动时补卸。
    ///
    /// 追加而不是覆盖：一个会话里连着测几个包，退出时得一起卸干净。
    public func remember(packageName: String) throws {
        var names = (try? pendingPackageNames()) ?? []
        names.append(packageName)
        try write(names: names, startedAt: (try? loadRecord())?.startedAt ?? Date())
    }

    /// 卸载结果回写：只保留还没卸掉的那几个。传空数组等于 `forget()`。
    public func replacePending(_ packageNames: [String]) throws {
        let names = SessionRecord(packageNames: packageNames).normalizedPackageNames
        guard !names.isEmpty else {
            try forget()
            return
        }
        try write(names: names, startedAt: (try? loadRecord())?.startedAt ?? Date())
    }

    /// 正常退出、确认设备上已经没有这些包之后调用。
    public func forget() throws {
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return }
        try FileManager.default.removeItem(at: recordURL)
    }

    /// 上次遗留、还没卸掉的包名。记录不存在或损坏时返回空数组。
    public func pendingPackageNames() throws -> [String] {
        guard let record = try loadRecord() else { return [] }
        return record.normalizedPackageNames
    }

    /// 启动自检：清掉上次的临时文件，并把遗留的包名交回去，
    /// 等模拟器起来后再卸（设备没起时 adb 卸不了）。
    @discardableResult
    public func recover() throws -> SessionRecord? {
        let record = try loadRecord()
        try clearTemporaryData()
        guard let record, !record.normalizedPackageNames.isEmpty else { return nil }
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

    private func write(names: [String], startedAt: Date) throws {
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let record = SessionRecord(packageNames: names, startedAt: startedAt)
        try encoder.encode(record).write(to: recordURL, options: .atomic)
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
