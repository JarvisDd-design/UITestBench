import Foundation

/// 一个可信的下载地址：`url` 是原样链接，`host` 和 `fileName` 是界面直接展示的摘要。
public struct DownloadLink: Equatable, Sendable {
    public let url: URL
    public let host: String
    public let fileName: String

    public init(url: URL, host: String, fileName: String) {
        self.url = url
        self.host = host
        self.fileName = fileName
    }
}

/// 把二维码内容或粘贴的文字解析成下载地址。
///
/// 只接受 http / https 且必须有 host：二维码里也可能是普通文字、Wi-Fi 配置、
/// `file://` 路径，那些都不该被当成「要安装的包」。
public enum DownloadLinkParser {
    public static func parse(_ text: String) -> DownloadLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty
        else {
            return nil
        }

        return DownloadLink(url: url, host: host, fileName: fileName(for: url))
    }

    /// 链接只到目录（如 `https://example.com/`）或看不出文件名时给一个兜底名字。
    private static func fileName(for url: URL) -> String {
        let name = url.lastPathComponent
        let usable = !name.isEmpty && name != "." && name != ".." && name != "/"
        return usable ? name : "download.apk"
    }
}
