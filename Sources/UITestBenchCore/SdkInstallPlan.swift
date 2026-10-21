import Foundation

public struct SdkDownload: Equatable, Sendable {
    public let packagePath: String
    public let url: URL
    public let size: Int64
    public let sha1: String

    public init(packagePath: String, url: URL, size: Int64, sha1: String) {
        self.packagePath = packagePath
        self.url = url
        self.size = size
        self.sha1 = sha1
    }
}

public enum SdkInstallPlanError: Error, Equatable {
    case missingPackage(String)
    case missingArchive(String)
    case invalidArchiveURL(String)
}

/// 首次启动要下载哪几个包、从哪下、多大、校验值是多少。
public struct SdkInstallPlan: Equatable, Sendable {
    public let downloads: [SdkDownload]

    public init(downloads: [SdkDownload]) {
        self.downloads = downloads
    }

    public var totalBytes: Int64 {
        downloads.reduce(0) { $0 + $1.size }
    }

    /// 顺序即下载顺序：工具 → 模拟器 → 系统镜像，后者依赖前者。
    public static func make(
        repository: SdkRepository,
        systemImageRepository: SdkRepository,
        hostOS: String,
        hostArch: String,
        repositoryBaseURL: URL,
        systemImageBaseURL: URL,
        systemImagePackagePath: String
    ) throws -> SdkInstallPlan {
        var downloads: [SdkDownload] = []
        for path in ["platform-tools", "emulator"] {
            downloads.append(
                try download(path, in: repository, base: repositoryBaseURL, hostOS: hostOS, hostArch: hostArch)
            )
        }
        downloads.append(
            try download(
                systemImagePackagePath,
                in: systemImageRepository,
                base: systemImageBaseURL,
                hostOS: hostOS,
                hostArch: hostArch
            )
        )
        return SdkInstallPlan(downloads: downloads)
    }

    private static func download(
        _ path: String,
        in repository: SdkRepository,
        base: URL,
        hostOS: String,
        hostArch: String
    ) throws -> SdkDownload {
        guard let package = repository.package(atPath: path) else {
            throw SdkInstallPlanError.missingPackage(path)
        }
        guard let archive = package.archive(forHostOS: hostOS, hostArch: hostArch) else {
            throw SdkInstallPlanError.missingArchive(path)
        }
        guard let url = URL(string: archive.url, relativeTo: base)?.absoluteURL else {
            throw SdkInstallPlanError.invalidArchiveURL(archive.url)
        }
        return SdkDownload(packagePath: path, url: url, size: archive.size, sha1: archive.sha1)
    }
}
