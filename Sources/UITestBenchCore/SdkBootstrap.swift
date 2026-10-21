import Foundation

public struct SdkBootstrapConfiguration: Equatable, Sendable {
    public let repositoryURL: URL
    public let systemImageRepositoryURL: URL
    public let systemImagePackagePath: String
    public let hostOS: String
    public let hostArch: String

    public init(
        repositoryURL: URL,
        systemImageRepositoryURL: URL,
        systemImagePackagePath: String,
        hostOS: String,
        hostArch: String
    ) {
        self.repositoryURL = repositoryURL
        self.systemImageRepositoryURL = systemImageRepositoryURL
        self.systemImagePackagePath = systemImagePackagePath
        self.hostOS = hostOS
        self.hostArch = hostArch
    }

    /// 默认 Google 源；换镜像时整份替换这两个清单地址即可。
    public static var `default`: SdkBootstrapConfiguration {
        SdkBootstrapConfiguration(
            repositoryURL: URL(string: "https://dl.google.com/android/repository/repository2-3.xml")!,
            systemImageRepositoryURL: URL(string: "https://dl.google.com/android/repository/sys-img/android/sys-img2-3.xml")!,
            systemImagePackagePath: "system-images;android-34;default;arm64-v8a",
            hostOS: "macosx",
            hostArch: currentHostArch
        )
    }

    public static var currentHostArch: String {
        #if arch(arm64)
        return "aarch64"
        #else
        return "x64"
        #endif
    }
}

public enum SdkBootstrapError: Error, Equatable {
    case httpStatus(Int)
}

/// 拉取 Google（或镜像）的清单 XML，算出首次安装要下什么。
public struct SdkBootstrap: Sendable {
    public let configuration: SdkBootstrapConfiguration
    private let session: URLSession

    public init(
        configuration: SdkBootstrapConfiguration = .default,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
    }

    public func plan() async throws -> SdkInstallPlan {
        async let repositoryData = fetch(configuration.repositoryURL)
        async let systemImageData = fetch(configuration.systemImageRepositoryURL)
        let (repository, systemImage) = try await (repositoryData, systemImageData)

        return try SdkInstallPlan.make(
            repository: try SdkRepository.parse(repository),
            systemImageRepository: try SdkRepository.parse(systemImage),
            hostOS: configuration.hostOS,
            hostArch: configuration.hostArch,
            repositoryBaseURL: configuration.repositoryURL.deletingLastPathComponent(),
            systemImageBaseURL: configuration.systemImageRepositoryURL.deletingLastPathComponent(),
            systemImagePackagePath: configuration.systemImagePackagePath
        )
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SdkBootstrapError.httpStatus(http.statusCode)
        }
        return data
    }
}
