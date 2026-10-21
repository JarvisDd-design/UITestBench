import Foundation

/// 拿在手上的包：文件在哪、包里是什么、能不能在这台模拟器上跑。
public struct AcquiredAPK: Equatable {
    public let fileURL: URL
    public let info: ApkInfo
    public let compatibility: CompatibilityReport

    public init(fileURL: URL, info: ApkInfo, compatibility: CompatibilityReport) {
        self.fileURL = fileURL
        self.info = info
        self.compatibility = compatibility
    }
}

public enum APKAcquisitionError: Error, Equatable {
    case download(DownloadError)
    case inspection(ApkInspectionError)
    /// 文件在，但读不出来：被移动、被删除，或者没有权限。
    case unreadableFile
    /// 网络层的意外失败（DNS、握手、连接中断等），保留原始描述。
    case network(String)

    /// 给人看的解释。界面直接显示这句，不暴露底层错误类型。
    public var explanation: String {
        switch self {
        case let .download(.httpStatus(code)):
            return "下载失败：服务器返回 \(code)。请确认链接是否还能打开。"
        case let .download(.sizeMismatch(expected, actual)):
            return "下载不完整（应为 \(expected) 字节，实际 \(actual) 字节），请重试。"
        case .download(.checksumMismatch):
            return "下载的文件校验不通过，可能在传输中损坏了，请重试。"
        case .inspection(.notAZipArchive):
            return "这个文件不是有效的 APK（不是 ZIP 包）。"
        case .inspection(.manifestMissing):
            return "这个 APK 里没有 AndroidManifest.xml，文件可能不完整。"
        case .inspection(.manifestUnreadable):
            return "APK 里的应用清单读不出来，文件可能已损坏。"
        case .unreadableFile:
            return "读不到这个文件，可能已被移动或删除。"
        case let .network(reason):
            return "下载出错：\(reason)"
        }
    }
}

/// 把「来源」变成「拿在手上的包」。
///
/// 本地文件原地使用，不复制；远程链接下载到自己的会话目录再解析。
/// 包本身不兼容**不算**获取失败——界面要先显示包信息，再给结论。
public final class APKAcquirer {
    private let downloader: FileDownloader
    private let directory: URL

    public init(downloader: FileDownloader = FileDownloader(), directory: URL) {
        self.downloader = downloader
        self.directory = directory
    }

    public func acquire(
        _ source: APKSource,
        progress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws -> AcquiredAPK {
        let fileURL: URL
        switch source {
        case let .localFile(url):
            fileURL = url
        case let .remote(url):
            fileURL = destination(for: url)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                try await downloader.download(url: url, to: fileURL, progress: progress)
            } catch let error as DownloadError {
                throw APKAcquisitionError.download(error)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw APKAcquisitionError.network(error.localizedDescription)
            }
        }

        // 解析接口吃的是整块 Data，几十 MB 的包也装得下；若以后遇到超大包，
        // 再把 ApkInspector 改成按需读取 ZIP 条目即可，调用方不用动。
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw APKAcquisitionError.unreadableFile
        }

        do {
            let info = try ApkInspector.inspect(data)
            return AcquiredAPK(
                fileURL: fileURL,
                info: info,
                compatibility: CompatibilityChecker.check(info)
            )
        } catch let error as ApkInspectionError {
            throw APKAcquisitionError.inspection(error)
        }
    }

    /// 链接里的文件名做下载名；查参数会被自动排除。
    /// 链接只到目录（如 `https://example.com/`）时给一个兜底名字。
    private func destination(for url: URL) -> URL {
        let name = url.lastPathComponent
        let usable = !name.isEmpty && name != "." && name != ".." && name != "/"
        return directory.appendingPathComponent(usable ? name : "download.apk")
    }
}
