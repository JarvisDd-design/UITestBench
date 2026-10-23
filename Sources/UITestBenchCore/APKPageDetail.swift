import Foundation

/// 有些 APK 分发平台的下载页只是空壳：真正的下载地址由页面脚本
/// 调详情接口取得，再写到「下载安装」按钮上。HTML 里没有 `.apk`，
/// 静态解析只能拿到网页。
///
/// 这里按页面路径识别这种平台，并照着页面自己的请求去问详情接口。
/// 只发 GET、只认 JSON 里的 APK 地址，不执行页面脚本。
public enum APKPageDetail {
    /// 下载页 → 详情接口。不是这种页面时返回 nil。
    ///
    /// 例：`/content-web/download.html?id=abc` →
    /// `/content-web/app/detail.do?id=abc`（有 `version` 时一并带上）。
    public static func endpoint(for pageURL: URL) -> URL? {
        guard pageURL.path.lowercased().hasSuffix("/content-web/download.html"),
              let components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false),
              let id = queryValue("id", in: components),
              !id.isEmpty
        else {
            return nil
        }

        var endpoint = URLComponents()
        endpoint.scheme = components.scheme
        endpoint.host = components.host
        endpoint.port = components.port
        endpoint.path = "/content-web/app/detail.do"

        var items = [URLQueryItem(name: "id", value: id)]
        if let version = queryValue("version", in: components), !version.isEmpty {
            items.append(URLQueryItem(name: "version", value: version))
        }
        endpoint.queryItems = items

        return endpoint.url
    }

    /// 从详情接口的 JSON 里找 APK 地址。
    ///
    /// 先认 `downloadUrl` 字段；没有就递归找任何以 `.apk` 结尾的字符串。
    /// `code` 非 0 表示接口明确拒绝（例如登录过期），这时不猜。
    public static func apkLink(inJSON data: Data, baseURL: URL) -> URL? {
        guard let object = try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) else {
            return nil
        }

        if let dictionary = object as? [String: Any], isErrorCode(dictionary["code"]) {
            return nil
        }

        var preferred: String?
        var fallback: String?
        collectStrings(in: object) { key, value in
            guard apkURL(from: value, baseURL: baseURL) != nil else { return }
            if preferred == nil, key?.lowercased() == "downloadurl" {
                preferred = value
            }
            if fallback == nil {
                fallback = value
            }
        }

        return apkURL(from: preferred ?? fallback ?? "", baseURL: baseURL)
    }

    // MARK: - 细节

    private static func queryValue(_ name: String, in components: URLComponents) -> String? {
        components.queryItems?.first(where: { $0.name == name })?.value
    }

    private static func isErrorCode(_ value: Any?) -> Bool {
        switch value {
        case let number as NSNumber:
            return number.intValue != 0
        case let text as String:
            return Int(text) != 0
        default:
            return false
        }
    }

    private static func apkURL(from raw: String, baseURL: URL) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let url = URL(string: text, relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty,
              url.absoluteString.lowercased().contains(".apk")
        else {
            return nil
        }
        return url
    }

    /// 只收集字符串值；key 是它所在的字段名（数组元素为 nil）。
    private static func collectStrings(
        in object: Any,
        visit: (String?, String) -> Void
    ) {
        switch object {
        case let dictionary as [String: Any]:
            for (key, value) in dictionary {
                if let text = value as? String {
                    visit(key, text)
                } else {
                    collectStrings(in: value, visit: visit)
                }
            }
        case let array as [Any]:
            for value in array {
                collectStrings(in: value, visit: visit)
            }
        default:
            break
        }
    }
}
