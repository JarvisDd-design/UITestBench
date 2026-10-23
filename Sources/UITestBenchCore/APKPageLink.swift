import Foundation

/// 从下载落地页里找 APK 直链。
///
/// 只做「找一条明确指向 .apk 的链接」这一件事，不执行页面脚本、不跟随
/// 普通网页链接。页面是登录页或由 JS 生成下载地址时返回 nil，由调用方
/// 给用户「在浏览器里打开」的提示。
public enum APKPageLink {
    /// 找到了就返回解析后的绝对地址；找不到返回 nil。
    public static func link(inHTML data: Data, baseURL: URL) -> URL? {
        guard let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        else {
            return nil
        }

        var candidates: [(raw: String, requiresAPK: Bool)] = []
        candidates.append(contentsOf: metaRefreshTargets(in: html).map { ($0, true) })
        candidates.append(contentsOf: hrefTargets(in: html).map { ($0, true) })
        candidates.append(contentsOf: jsonTargets(in: html).map { ($0, false) })
        candidates.append(contentsOf: rawTargets(in: html).map { ($0, false) })

        var seen = Set<String>()
        for candidate in candidates {
            guard let url = resolve(candidate.raw, baseURL: baseURL),
                  seen.insert(url.absoluteString).inserted
            else { continue }

            if candidate.requiresAPK,
               !url.absoluteString.lowercased().contains(".apk") {
                continue
            }
            return url
        }

        return nil
    }

    // MARK: - 候选

    /// `<meta http-equiv="refresh" content="0; url=/x.apk">`
    private static func metaRefreshTargets(in html: String) -> [String] {
        firstCaptures(#"(<meta\b[^>]*>)"#, in: html).compactMap { tag in
            let lowercased = tag.lowercased()
            guard lowercased.contains("http-equiv"),
                  lowercased.contains("refresh"),
                  let content = firstCaptures(
                    #"content\s*=\s*(?:"([^"]*)"|'([^']*)')"#,
                    in: tag
                  ).first
            else { return nil }

            return firstCaptures(#"url\s*=\s*['"]?([^'";\s>]+)"#, in: content).first
        }
    }

    /// 只认 href，不认 onclick / javascript。
    private static func hrefTargets(in html: String) -> [String] {
        firstCaptures(#"href\s*=\s*(?:"([^"]*)"|'([^']*)')"#, in: html)
    }

    /// 内嵌 JSON 里常见的下载字段。
    private static func jsonTargets(in html: String) -> [String] {
        firstCaptures(
            #""(?:downloadUrl|download_url|contentUrl|content_url|apkUrl|apk_url)"\s*:\s*"([^"]+)""#,
            in: html
        )
    }

    /// 兜底：页面里直接出现的 APK 地址（可能写在脚本或注释里）。
    private static func rawTargets(in html: String) -> [String] {
        firstCaptures(#"(https?://[^\s"'<>]+?\.apk(?:\?[^\s"'<>]*)?)"#, in: html)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;)]}")) }
    }

    // MARK: - 解析

    private static func resolve(_ raw: String, baseURL: URL) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text
            .replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
            .replacingOccurrences(of: "&#38;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "\\/", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

        guard !text.isEmpty, !text.lowercased().hasPrefix("javascript:") else { return nil }
        if text.hasPrefix("//") {
            text = (baseURL.scheme ?? "https") + ":" + text
        }

        var url = URL(string: text, relativeTo: baseURL)?.absoluteURL
        if url == nil,
           let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) {
            url = URL(string: encoded, relativeTo: baseURL)?.absoluteURL
        }

        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty
        else {
            return nil
        }
        return url
    }

    // MARK: - 正则

    /// 每条匹配取第一个非空捕获组；没有捕获组时取整条匹配。
    private static func firstCaptures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            let groups = match.numberOfRanges > 1 ? 1..<match.numberOfRanges : 0..<1
            for group in groups {
                if let range = Range(match.range(at: group), in: text) {
                    return String(text[range])
                }
            }
            return nil
        }
    }
}
