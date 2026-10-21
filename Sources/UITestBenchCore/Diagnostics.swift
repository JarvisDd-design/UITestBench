import Foundation

/// 读日志尾部。模拟器日志会长到几十 MB，取最后 N 行时
/// 只读文件末尾的一段，避免一次把整个文件读进内存。
public enum LogTail {
    public static func lastLines(
        of url: URL,
        count: Int,
        maxBytes: Int = 64 * 1024
    ) -> String? {
        guard count > 0 else { return "" }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }

        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") {
            // 从文件中间切进来时，第一行多半是半个字，丢掉。
            text = String(text[text.index(after: newline)...])
        }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.suffix(count).joined(separator: "\n")
    }
}

/// 「复制诊断信息」真正复制的东西：让设计同事贴给开发时，
/// 对方不用再问「你装的哪版、用的哪个目录、设备什么状态」。
public struct DiagnosticsReport {
    public let appVersion: String
    public let supportDirectory: String
    public let sdkReady: Bool
    public let deviceState: String
    public let serial: String?
    public let logTail: String?

    public init(
        appVersion: String,
        supportDirectory: String,
        sdkReady: Bool,
        deviceState: String,
        serial: String?,
        logTail: String?
    ) {
        self.appVersion = appVersion
        self.supportDirectory = supportDirectory
        self.sdkReady = sdkReady
        self.deviceState = deviceState
        self.serial = serial
        self.logTail = logTail
    }

    public var text: String {
        var lines = [
            "UI验收台 诊断信息",
            "版本：\(appVersion)",
            "支持目录：\(supportDirectory)",
            "Android 组件：\(sdkReady ? "已就绪" : "未就绪")",
            "设备状态：\(deviceState)"
        ]
        if let serial, !serial.isEmpty {
            lines.append("设备序列号：\(serial)")
        }
        lines.append("—— 模拟器日志（尾部）——")
        if let logTail, !logTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(logTail)
        } else {
            lines.append("暂无日志")
        }
        return lines.joined(separator: "\n")
    }
}
