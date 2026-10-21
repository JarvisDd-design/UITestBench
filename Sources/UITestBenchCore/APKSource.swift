import Foundation

/// APK 的两个来源。下游只认这两种，不再关心用户是拖进来的还是粘贴的。
public enum APKSource: Equatable, Sendable {
    case localFile(URL)
    case remote(URL)
}

public enum APKSourceError: Error, Equatable, Sendable {
    /// 拖进来的文件既不是 APK，也不是能扫的图片。
    case unsupportedFile
    /// 图片里没有二维码，或者二维码里不是下载链接。
    case noLinkInImage
    /// 粘贴的文字不是 http / https 链接。
    case invalidLink

    public var explanation: String {
        switch self {
        case .unsupportedFile:
            return "只认识 APK 文件和二维码截图。请拖一个 .apk 或包含下载地址的图片进来。"
        case .noLinkInImage:
            return "这张图里没有找到下载地址。请确认二维码完整、清晰，并且里面是 http 或 https 链接。"
        case .invalidLink:
            return "这不是有效的下载链接。链接要以 http:// 或 https:// 开头。"
        }
    }
}

public enum APKSourceResolver {
    /// 常见截图与图片格式。HEIC 是 macOS 截图的默认格式之一，不能漏。
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "tif", "bmp", "webp",
    ]

    public static func source(forDroppedFile url: URL) throws -> APKSource {
        switch url.pathExtension.lowercased() {
        case "apk":
            return .localFile(url)
        case let format where imageExtensions.contains(format):
            guard let data = try? Data(contentsOf: url),
                  let link = QRCodeDecoder.downloadURL(from: data)
            else {
                throw APKSourceError.noLinkInImage
            }
            return .remote(link)
        default:
            throw APKSourceError.unsupportedFile
        }
    }

    public static func source(forPastedLink text: String) throws -> APKSource {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else {
            throw APKSourceError.invalidLink
        }
        return .remote(url)
    }
}
