import Foundation

/// 镜像设置的两个清单地址校验：只接受带主机名的 http / https。
public enum MirrorSettingsValidation {
    public static func endpoints(
        repository: String,
        systemImage: String
    ) -> (repository: URL, systemImage: URL)? {
        guard let repositoryURL = endpoint(from: repository),
              let systemImageURL = endpoint(from: systemImage)
        else { return nil }
        return (repositoryURL, systemImageURL)
    }

    private static func endpoint(from text: String) -> URL? {
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty
        else { return nil }
        return url
    }
}
