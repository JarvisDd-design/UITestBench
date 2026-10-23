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
    /// 链接返回的是网页（登录页、下载落地页），不是文件。
    case webPage(finalURL: URL)
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
            return "下载到的文件不是 APK（不是 ZIP 包）。链接可能指向了普通文件。"
        case .inspection(.damagedArchive):
            return "下载到的文件像 APK，但包结构读不出来。可能没下载完整，请重试；反复出现就请开发重新上传。"
        case .inspection(.manifestMissing):
            return "这个 APK 里没有 AndroidManifest.xml，文件可能不完整。"
        case .inspection(.manifestUnreadable):
            return "APK 里的应用清单读不出来，文件可能已损坏。"
        case .webPage:
            return "这个链接打开的是网页，不是 APK 文件。它可能需要登录，或要在页面上点「下载」。用浏览器打开页面，下载 APK 后拖进来。"
        case .unreadableFile:
            return "读不到这个文件，可能已被移动或删除。"
        case let .network(reason):
            return "下载出错：\(reason)"
        }
    }
}

/// 下载失败后怎么处理临时文件。
public struct APKAcquisitionPolicy: Equatable, Sendable {
    /// 取消或解析失败时删除远程临时文件与其 `.part`。本地文件永远不删。
    public var removesRemoteOnFailure: Bool

    public init(removesRemoteOnFailure: Bool = false) {
        self.removesRemoteOnFailure = removesRemoteOnFailure
    }

    /// 拖入 / 粘贴 / 选择文件：保持原行为，失败文件留在 tmp 方便排查。
    public static let standard = APKAcquisitionPolicy()

    /// 扫码得到的链接：临时下载，失败或取消都不留垃圾。
    public static let scanned = APKAcquisitionPolicy(removesRemoteOnFailure: true)
}

/// 把「来源」变成「拿在手上的包」。
///
/// 本地文件原地使用，不复制；远程链接下载到自己的会话目录再解析。
/// 包本身不兼容**不算**获取失败——界面要先显示包信息，再给结论。
///
/// 二维码背后的链接经常不是直链：桌面 UA 可能拿到登录 / 下载页。
/// 因此远程获取会依次尝试桌面 UA、手机 UA，再从落地页里找一条 `.apk`
/// 直链。全都只拿到网页时报 `.webPage`，由界面引导用户用浏览器下载。
public final class APKAcquirer {
    private let downloader: FileDownloader
    private let directory: URL

    public init(downloader: FileDownloader = FileDownloader(), directory: URL) {
        self.downloader = downloader
        self.directory = directory
    }

    public func acquire(
        _ source: APKSource,
        policy: APKAcquisitionPolicy = .standard,
        progress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws -> AcquiredAPK {
        switch source {
        case let .localFile(url):
            try Task.checkCancellation()
            let data = try read(url)
            try Task.checkCancellation()
            return try inspect(fileURL: url, data: data)
        case let .remote(url):
            return try await acquireRemote(url, policy: policy, progress: progress)
        }
    }

    // MARK: - 远程

    private func acquireRemote(
        _ url: URL,
        policy: APKAcquisitionPolicy,
        progress: (@Sendable (DownloadProgress) -> Void)?
    ) async throws -> AcquiredAPK {
        var created: [URL] = []

        do {
            let desktopFile = try await download(
                url,
                userAgent: DownloadUserAgent.desktop,
                referer: nil,
                progress: progress,
                created: &created
            )
            let desktopData = try read(desktopFile.url)
            try Task.checkCancellation()

            let desktopKind = DownloadedContent.kind(
                of: desktopData,
                mimeType: desktopFile.mimeType
            )
            guard desktopKind == .webPage else {
                return try inspect(
                    fileURL: desktopFile.url,
                    data: desktopData,
                    created: created
                )
            }

            // 二维码常常是给手机看的，手机 UA 可能直接拿到 APK；
            // 也可能反过来只给一句「请用电脑打开」。两个版本都留着找直链。
            var pages: [(data: Data, finalURL: URL, userAgent: String)] = [
                (desktopData, desktopFile.finalURL, DownloadUserAgent.desktop),
            ]
            do {
                let mobileFile = try await download(
                    url,
                    userAgent: DownloadUserAgent.android,
                    referer: nil,
                    progress: progress,
                    created: &created
                )
                let mobileData = try read(mobileFile.url)
                try Task.checkCancellation()

                if DownloadedContent.kind(of: mobileData, mimeType: mobileFile.mimeType) != .webPage {
                    return try inspect(
                        fileURL: mobileFile.url,
                        data: mobileData,
                        created: created
                    )
                }
                pages.insert(
                    (mobileData, mobileFile.finalURL, DownloadUserAgent.android),
                    at: 0
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 手机 UA 被拒也不影响从桌面页里找直链，继续用桌面页。
            }

            let direct = pages.lazy.compactMap {
                page -> (url: URL, referer: URL, userAgent: String)? in
                guard let link = APKPageLink.link(inHTML: page.data, baseURL: page.finalURL)
                else { return nil }
                let text = link.absoluteString
                // 页面链回自己（或另一张页面）时不要当成直链重试。
                if text == url.absoluteString
                    || pages.contains(where: { $0.finalURL.absoluteString == text }) {
                    return nil
                }
                // 用给出这条链接的那张页面的 UA，避免直链按 UA 又给回另一份页面。
                return (link, page.finalURL, page.userAgent)
            }.first

            if let direct {
                let directFile = try await download(
                    direct.url,
                    userAgent: direct.userAgent,
                    referer: direct.referer,
                    progress: progress,
                    created: &created
                )
                let directData = try read(directFile.url)
                try Task.checkCancellation()

                if DownloadedContent.kind(of: directData, mimeType: directFile.mimeType) == .webPage {
                    throw APKAcquisitionError.webPage(finalURL: directFile.finalURL)
                }
                return try inspect(
                    fileURL: directFile.url,
                    data: directData,
                    created: created
                )
            }

            // 有些分发平台的下载页是空壳：地址由页面脚本调详情接口取得。
            // 路径认得出来时，照页面自己的请求再问一次。
            var detailPages = pages.map(\.finalURL)
            if !detailPages.contains(where: { $0.absoluteString == url.absoluteString }) {
                detailPages.append(url)
            }

            var triedEndpoints = Set<String>()
            for pageURL in detailPages {
                guard let endpoint = APKPageDetail.endpoint(for: pageURL),
                      triedEndpoints.insert(endpoint.absoluteString).inserted
                else { continue }

                let detailData: Data
                do {
                    let detailFile = try await download(
                        endpoint,
                        userAgent: DownloadUserAgent.desktop,
                        referer: pageURL,
                        progress: nil,
                        created: &created
                    )
                    detailData = try read(detailFile.url)
                    try Task.checkCancellation()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // 详情接口不通就继续，最终仍按网页提示。
                    continue
                }

                guard let apkURL = APKPageDetail.apkLink(
                    inJSON: detailData,
                    baseURL: endpoint
                ) else { continue }

                // 已经拿到确定的包地址，这一步的失败要如实报给用户，
                // 不能再退回「这是网页」。
                let apkFile = try await download(
                    apkURL,
                    userAgent: DownloadUserAgent.android,
                    referer: pageURL,
                    progress: progress,
                    created: &created
                )
                let apkData = try read(apkFile.url)
                try Task.checkCancellation()

                if DownloadedContent.kind(of: apkData, mimeType: apkFile.mimeType) == .webPage {
                    throw APKAcquisitionError.webPage(finalURL: apkFile.finalURL)
                }
                return try inspect(fileURL: apkFile.url, data: apkData, created: created)
            }

            throw APKAcquisitionError.webPage(finalURL: pages[0].finalURL)
        } catch {
            discard(created, policy: policy)
            throw mapped(error)
        }
    }

    // MARK: - 下载与解析

    private func download(
        _ url: URL,
        userAgent: String,
        referer: URL?,
        progress: (@Sendable (DownloadProgress) -> Void)?,
        created: inout [URL]
    ) async throws -> DownloadedFile {
        let destination = destination(for: url)
        created.append(destination)
        return try await downloader.download(
            url: url,
            to: destination,
            userAgent: userAgent,
            referer: referer,
            progress: progress
        )
    }

    private func read(_ fileURL: URL) throws -> Data {
        do {
            return try Data(contentsOf: fileURL)
        } catch {
            throw APKAcquisitionError.unreadableFile
        }
    }

    private func inspect(
        fileURL: URL,
        data: Data,
        created: [URL] = []
    ) throws -> AcquiredAPK {
        do {
            let info = try ApkInspector.inspect(data)
            removeIntermediates(created, keeping: fileURL)
            return AcquiredAPK(
                fileURL: fileURL,
                info: info,
                compatibility: CompatibilityChecker.check(info)
            )
        } catch let error as ApkInspectionError {
            throw APKAcquisitionError.inspection(error)
        }
    }

    // MARK: - 清理

    /// 只清理工具自己下载的临时文件；用户选择的本地文件绝不动。
    private func discard(_ files: [URL], policy: APKAcquisitionPolicy) {
        guard policy.removesRemoteOnFailure else { return }
        for file in files {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: FileDownloader.partialURL(for: file))
        }
    }

    /// 成功拿到包以后，下载页等中间产物没有保留价值。
    private func removeIntermediates(_ files: [URL], keeping kept: URL) {
        let keepPath = kept.standardizedFileURL.path
        for file in files where file.standardizedFileURL.path != keepPath {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: FileDownloader.partialURL(for: file))
        }
    }

    private func mapped(_ error: Error) -> Error {
        switch error {
        case is CancellationError:
            return CancellationError()
        case let error as APKAcquisitionError:
            return error
        case let error as DownloadError:
            return APKAcquisitionError.download(error)
        case let error as ApkInspectionError:
            return APKAcquisitionError.inspection(error)
        default:
            return APKAcquisitionError.network(error.localizedDescription)
        }
    }

    /// 链接里的文件名做下载名；查参数会被自动排除。
    /// 链接只到目录（如 `https://example.com/`）时给一个兜底名字。
    ///
    /// 同一次会话里可能先后扫到多个同名 APK。已经存在同名文件时加序号，
    /// 否则后一次失败清理会把前一次已经拿到的包删掉。
    private func destination(for url: URL) -> URL {
        let rawName = url.lastPathComponent
        let usable = !rawName.isEmpty && rawName != "." && rawName != ".." && rawName != "/"
        let name = usable ? rawName : "download.apk"

        var candidate = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            return candidate
        }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        repeat {
            let suffixed = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            candidate = directory.appendingPathComponent(suffixed)
            index += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }
}
