import Foundation

/// APK 的两个来源。下游只认这两种，不再关心用户是拖进来的、粘贴的、还是扫码得到的。
public enum APKSource: Equatable, Sendable {
    case localFile(URL)
    case remote(URL)
}

public enum APKSourceError: Error, Equatable, Sendable {
    /// 拖进来的文件既不是 APK，也不是能扫的图片。
    case unsupportedFile
    /// 扩展名像图片，但文件读不出来或不是有效图片。
    case unreadableImage
    /// 图片能打开，但里面没有二维码。
    case noQRCodeInImage
    /// 找到了二维码，但内容不是 http(s) 下载链接。
    case qrCodeIsNotLink
    /// 粘贴的文字不是 http / https 链接。
    case invalidLink

    public var explanation: String {
        switch self {
        case .unsupportedFile:
            return "只认识 APK 文件和二维码图片。请拖一个 .apk，或包含二维码的图片进来。"
        case .unreadableImage:
            return "打不开这张图片。文件可能已损坏，或不是 PNG、JPG、HEIC 等常见格式。请换一张截图试试。"
        case .noQRCodeInImage:
            return "这张图里没有找到二维码。请换一张二维码完整、清晰的截图。"
        case .qrCodeIsNotLink:
            return "找到了二维码，但里面不是下载链接。二维码内容要以 http:// 或 https:// 开头。"
        case .invalidLink:
            return "这不是有效的下载链接。链接要以 http:// 或 https:// 开头。"
        }
    }
}

public enum APKSourceResolver {
    /// 常见截图与图片格式。HEIC 是 macOS 截图的默认格式之一，不能漏。
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "tif", "bmp", "webp", "avif",
    ]

    public static func source(forDroppedFile url: URL) throws -> APKSource {
        switch url.pathExtension.lowercased() {
        case "apk":
            return .localFile(url)
        case let format where imageExtensions.contains(format):
            guard let data = try? Data(contentsOf: url) else {
                throw APKSourceError.unreadableImage
            }
            return try source(forImageData: data)
        default:
            throw APKSourceError.unsupportedFile
        }
    }

    /// 剪贴板截图、屏幕截图、拖入的图片数据都走这里。
    public static func source(forImageData data: Data) throws -> APKSource {
        let payloads: [String]
        do {
            payloads = try QRCodeDecoder.payloads(from: data)
        } catch {
            throw APKSourceError.unreadableImage
        }

        guard !payloads.isEmpty else {
            throw APKSourceError.noQRCodeInImage
        }
        guard let link = payloads.lazy.compactMap({ DownloadLinkParser.parse($0) }).first else {
            throw APKSourceError.qrCodeIsNotLink
        }
        return .remote(link.url)
    }

    public static func source(forPastedLink text: String) throws -> APKSource {
        guard let link = DownloadLinkParser.parse(text) else {
            throw APKSourceError.invalidLink
        }
        return .remote(link.url)
    }
}
