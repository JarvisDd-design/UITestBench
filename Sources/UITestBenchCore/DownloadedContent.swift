import Foundation

/// 下载回来的字节大致是什么。
///
/// 二维码背后的链接并不保证直接给文件：飞书 / 网盘的分享页、下载落地页、
/// 登录页都会以 200 返回 HTML。先分辨清楚，才能给用户正确的提示。
public enum DownloadedContentKind: Equatable, Sendable {
    /// 以 `PK` 开头的 ZIP，通常是 APK。是否真的是 APK 还要看 AndroidManifest。
    case zipArchive
    /// HTML 页面：登录页、下载落地页或错误页。
    case webPage
    /// 其他普通文件（文本、JSON、图片等）。
    case other
}

public enum DownloadedContent {
    /// 只看内容开头，不信扩展名；MIME 只作补充。
    ///
    /// 内容以 `PK` 开头时一律优先按 ZIP 处理：有些服务器会把 APK 的
    /// `Content-Type` 标成 `text/html` 或 `application/octet-stream`。
    public static func kind(of data: Data, mimeType: String? = nil) -> DownloadedContentKind {
        let bytes = Array(data.prefix(4096))

        if bytes.count >= 2, bytes[0] == 0x50, bytes[1] == 0x4B {
            return .zipArchive
        }

        var index = 0
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            index = 3
        }
        while index < bytes.count, isHTMLWhitespace(bytes[index]) {
            index += 1
        }

        if let prefix = String(bytes: bytes[index...], encoding: .utf8)?.lowercased(),
           looksLikeHTML(prefix) {
            return .webPage
        }

        if let mimeType = mimeType?.lowercased(),
           mimeType.contains("text/html") || mimeType.contains("application/xhtml+xml") {
            return .webPage
        }

        return .other
    }

    private static func looksLikeHTML(_ text: String) -> Bool {
        guard text.first == "<" else { return false }
        return text.hasPrefix("<!doctype html")
            || text.hasPrefix("<html")
            || text.hasPrefix("<head")
            || text.hasPrefix("<body")
            || text.hasPrefix("<meta")
            || (text.hasPrefix("<!--") && text.contains("<html"))
    }

    private static func isHTMLWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}
