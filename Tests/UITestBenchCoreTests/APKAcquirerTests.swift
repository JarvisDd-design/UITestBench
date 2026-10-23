import XCTest
@testable import UITestBenchCore

/// 把「来源」变成「拿在手上、已经看过的包」：本地直接用，远程先下载。
final class APKAcquirerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("APKAcquirerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        StubURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
    }

    private func acquirer() -> APKAcquirer {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return APKAcquirer(
            downloader: FileDownloader(configuration: configuration),
            directory: directory
        )
    }

    private var remoteURL: URL {
        URL(string: "https://example.com/builds/demo.apk?token=abc")!
    }

    func testLoadsALocalAPKInPlace() async throws {
        let apk = directory.appendingPathComponent("demo.apk")
        try APKFixture.minimalAPK().write(to: apk)

        let acquired = try await acquirer().acquire(.localFile(apk))

        XCTAssertEqual(acquired.fileURL, apk, "本地文件应当直接用，不再复制一份")
        XCTAssertEqual(acquired.info.packageName, "com.example.demo")
        XCTAssertTrue(acquired.compatibility.isCompatible)
    }

    func testDownloadsRemoteAPKThenInspectsIt() async throws {
        let body = APKFixture.minimalAPK()
        StubURLProtocol.handler = { _ in .init(status: 200, body: body) }
        let progress = ProgressRecorder()

        let acquired = try await acquirer().acquire(.remote(remoteURL)) { progress.record($0) }

        XCTAssertEqual(acquired.fileURL.lastPathComponent, "demo.apk", "用链接里的文件名，查参数不算")
        XCTAssertEqual(try Data(contentsOf: acquired.fileURL), body)
        XCTAssertEqual(acquired.info.packageName, "com.example.demo")
        XCTAssertEqual(progress.values.last?.fraction, 1)
    }

    /// 下载成功但包本身不兼容，不应该报错——界面要能显示包信息再给结论。
    func testReturnsCompatibilityReportInsteadOfFailing() async throws {
        let apk = directory.appendingPathComponent("future.apk")
        try APKFixture.minimalAPK(minSdk: 99).write(to: apk)

        let acquired = try await acquirer().acquire(.localFile(apk))

        XCTAssertEqual(
            acquired.compatibility.issues,
            [.minSdkTooHigh(required: 99, device: 34)]
        )
    }

    func testMapsDownloadFailure() async throws {
        StubURLProtocol.handler = { _ in .init(status: 404, body: Data()) }

        do {
            _ = try await acquirer().acquire(.remote(remoteURL))
            XCTFail("404 应当让整次获取失败")
        } catch {
            XCTAssertEqual(error as? APKAcquisitionError, .download(.httpStatus(404)))
            XCTAssertTrue(
                (error as? APKAcquisitionError)?.explanation.contains("404") == true,
                "错误说明里要带上状态码"
            )
        }
    }

    func testMapsInspectionFailure() async throws {
        let broken = directory.appendingPathComponent("broken.apk")
        try Data("not a zip".utf8).write(to: broken)

        do {
            _ = try await acquirer().acquire(.localFile(broken))
            XCTFail("损坏的包应当报错")
        } catch {
            XCTAssertEqual(error as? APKAcquisitionError, .inspection(.notAZipArchive))
        }
    }

    func testReportsMissingLocalFile() async throws {
        let missing = directory.appendingPathComponent("gone.apk")

        do {
            _ = try await acquirer().acquire(.localFile(missing))
            XCTFail("文件不存在应当报错")
        } catch {
            XCTAssertEqual(error as? APKAcquisitionError, .unreadableFile)
        }
    }

    /// 链接末尾没有文件名时给一个兜底名字，避免下载到一个空路径。
    func testFallsBackToADefaultNameWhenURLHasNoFilename() async throws {
        StubURLProtocol.handler = { _ in .init(status: 200, body: APKFixture.minimalAPK()) }

        let acquired = try await acquirer().acquire(.remote(URL(string: "https://example.com/")!))

        XCTAssertEqual(acquired.fileURL.lastPathComponent, "download.apk")
    }

    /// 扫码得到的链接是临时下载：解析失败就把远程文件删掉，别在 tmp 里留垃圾。
    func testScannedPolicyDeletesTheRemoteFileWhenInspectionFails() async throws {
        StubURLProtocol.handler = { _ in .init(status: 200, body: Data("not a zip".utf8)) }
        let destination = directory.appendingPathComponent("demo.apk")
        let partial = FileDownloader.partialURL(for: destination)

        do {
            _ = try await acquirer().acquire(.remote(remoteURL), policy: .scanned)
            XCTFail("不是 APK 应当报错")
        } catch {
            XCTAssertEqual(error as? APKAcquisitionError, .inspection(.notAZipArchive))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    /// 用户自己拖进来的文件永远不能删，哪怕解析失败。
    func testScannedPolicyDoesNotDeleteAUsersLocalFileWhenInspectionFails() async throws {
        let broken = directory.appendingPathComponent("user-broken.apk")
        try Data("not a zip".utf8).write(to: broken)

        do {
            _ = try await acquirer().acquire(.localFile(broken), policy: .scanned)
            XCTFail("损坏的包应当报错")
        } catch {
            XCTAssertEqual(error as? APKAcquisitionError, .inspection(.notAZipArchive))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: broken.path))
    }

    /// 默认策略保持原样：远程文件留在 tmp 里，方便排查。
    func testStandardPolicyKeepsTheRemoteFileWhenInspectionFails() async throws {
        StubURLProtocol.handler = { _ in .init(status: 200, body: Data("not a zip".utf8)) }
        let destination = directory.appendingPathComponent("demo.apk")

        do {
            _ = try await acquirer().acquire(.remote(remoteURL))
            XCTFail("不是 APK 应当报错")
        } catch {
            XCTAssertEqual(error as? APKAcquisitionError, .inspection(.notAZipArchive))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    /// 两个链接都以 app.apk 结尾时，不能共用同一个临时文件，
    /// 否则第二次下载失败会删掉第一次已经拿到的包。
    func testDownloadsWithTheSameFileNameDoNotShareAPath() async throws {
        StubURLProtocol.handler = { _ in .init(status: 200, body: APKFixture.minimalAPK()) }
        let acquirer = acquirer()

        let first = try await acquirer.acquire(.remote(remoteURL))
        let second = try await acquirer.acquire(.remote(remoteURL))

        XCTAssertNotEqual(first.fileURL, second.fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.fileURL.path))
    }

    /// 第二次下载失败并走 .scanned 清理时，只能删这次的文件。
    func testScannedFailureKeepsAPreviouslyDownloadedFile() async throws {
        StubURLProtocol.handler = { _ in .init(status: 200, body: APKFixture.minimalAPK()) }
        let first = try await acquirer().acquire(.remote(remoteURL))

        StubURLProtocol.handler = { _ in .init(status: 200, body: Data("not a zip".utf8)) }
        do {
            _ = try await acquirer().acquire(.remote(remoteURL), policy: .scanned)
            XCTFail("不是 APK 应当报错")
        } catch {
            XCTAssertEqual(error as? APKAcquisitionError, .inspection(.notAZipArchive))
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: first.fileURL.path),
            "上一次成功拿到的包不能被这一次的清理删掉"
        )
    }

    /// 取消扫码下载后，文件与 .part 都不能留下。
    func testScannedPolicyDeletesPartialDownloadWhenCancelled() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowStubURLProtocol.self]
        let acquirer = APKAcquirer(
            downloader: FileDownloader(configuration: configuration),
            directory: directory
        )
        let destination = directory.appendingPathComponent("demo.apk")
        let partial = FileDownloader.partialURL(for: destination)

        let task = Task { try await acquirer.acquire(.remote(remoteURL), policy: .scanned) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("取消后应当抛错")
        } catch is CancellationError {
            // 预期
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    // MARK: - 二维码指向下载页

    /// 链接返回网页时要说是网页，不能笼统地说「不是 APK」。
    func testReportsAWebPageInsteadOfCallingItNotAnAPK() async throws {
        let html = Data("<!doctype html><html><body>请先登录</body></html>".utf8)
        StubURLProtocol.handler = { _ in
            .init(status: 200, body: html, headers: ["Content-Type": "text/html"])
        }

        do {
            _ = try await acquirer().acquire(.remote(remoteURL), policy: .scanned)
            XCTFail("网页应当报错")
        } catch {
            guard case let .webPage(finalURL) = error as? APKAcquisitionError else {
                return XCTFail("意外的错误：\(error)")
            }
            XCTAssertEqual(finalURL, remoteURL)
            XCTAssertTrue(
                (error as? APKAcquisitionError)?.explanation.contains("网页") == true
            )
            XCTAssertFalse(
                (error as? APKAcquisitionError)?.explanation.contains("不是有效的 APK") == true,
                "已经知道是网页，就不要再说成打包错误"
            )
        }
    }

    /// 二维码常常是给手机扫的：桌面 UA 拿到落地页时，用手机 UA 再试一次。
    func testRetriesWithAnAndroidUserAgentWhenTheResponseIsAPage() async throws {
        let apk = APKFixture.minimalAPK()
        let html = Data("<html><body>请用手机打开</body></html>".utf8)
        StubURLProtocol.handler = { request in
            let ua = request.value(forHTTPHeaderField: "User-Agent") ?? ""
            if ua.contains("Android") {
                return .init(status: 200, body: apk)
            }
            return .init(status: 200, body: html, headers: ["Content-Type": "text/html"])
        }

        let acquired = try await acquirer().acquire(.remote(remoteURL), policy: .scanned)

        XCTAssertEqual(acquired.info.packageName, "com.example.demo")
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        XCTAssertTrue(
            (StubURLProtocol.requests.last?.value(forHTTPHeaderField: "User-Agent") ?? "")
                .contains("Android")
        )
    }

    /// 两种 UA 都只给下载页时，页面里的 APK 直链值得再试一次。
    func testFollowsAnAPKLinkFoundOnTheDownloadPage() async throws {
        let apk = APKFixture.minimalAPK()
        let html = Data("""
        <!doctype html><html><body>
          <a href="/files/real.apk">下载 APK</a>
        </body></html>
        """.utf8)
        let pageURL = remoteURL
        let directURL = URL(string: "https://example.com/files/real.apk")!

        StubURLProtocol.handler = { request in
            switch request.url {
            case directURL?:
                return .init(status: 200, body: apk)
            case pageURL?:
                return .init(status: 200, body: html, headers: ["Content-Type": "text/html"])
            default:
                return .init(status: 404, body: Data())
            }
        }

        let acquired = try await acquirer().acquire(.remote(pageURL), policy: .scanned)

        XCTAssertEqual(acquired.fileURL.lastPathComponent, "real.apk")
        XCTAssertEqual(acquired.info.packageName, "com.example.demo")
        XCTAssertEqual(
            StubURLProtocol.requests.last?.value(forHTTPHeaderField: "Referer"),
            pageURL.absoluteString,
            "带着页面的 Referer 去取直链，避免防盗链"
        )
    }

    /// 手机页只有一句「请用电脑打开」、直链在桌面页里时，也要找得到。
    func testFallsBackToTheDesktopPageWhenTheMobilePageHasNoLink() async throws {
        let apk = APKFixture.minimalAPK()
        let desktopHTML = Data(
            "<html><body><a href=\"/files/real.apk\">下载</a></body></html>".utf8
        )
        let mobileHTML = Data("<html><body>请用电脑浏览器打开</body></html>".utf8)
        let directURL = URL(string: "https://example.com/files/real.apk")!

        StubURLProtocol.handler = { request in
            if request.url == directURL {
                return .init(status: 200, body: apk)
            }
            let ua = request.value(forHTTPHeaderField: "User-Agent") ?? ""
            return ua.contains("Android")
                ? .init(status: 200, body: mobileHTML, headers: ["Content-Type": "text/html"])
                : .init(status: 200, body: desktopHTML, headers: ["Content-Type": "text/html"])
        }

        let acquired = try await acquirer().acquire(.remote(remoteURL), policy: .scanned)

        XCTAssertEqual(acquired.fileURL.lastPathComponent, "real.apk")
        XCTAssertEqual(acquired.info.packageName, "com.example.demo")
        XCTAssertEqual(
            StubURLProtocol.requests.last?.value(forHTTPHeaderField: "Referer"),
            remoteURL.absoluteString,
            "Referer 应当是真正给出直链的桌面页"
        )
        XCTAssertFalse(
            (StubURLProtocol.requests.last?.value(forHTTPHeaderField: "User-Agent") ?? "")
                .contains("Android"),
            "取直链时沿用桌面页的 UA，别让服务器按手机 UA 又给回落地页"
        )
    }

    /// 下载页是空壳、由 JS 调详情接口拿地址时，照着页面自己的请求再问一次。
    func testAsksTheDownloadPageDetailAPIWhenThePageHasNoDirectLink() async throws {
        let apk = APKFixture.minimalAPK()
        let pageURL = URL(
            string: "https://app.push.example.com/content-web/download.html?id=abc"
        )!
        let apiURL = URL(
            string: "https://app.push.example.com/content-web/app/detail.do?id=abc"
        )!
        let apkURL = URL(string: "https://oss.example.com/app/x/demo_11.apk")!
        let html = Data(
            #"<html><body><a href="javascript:;" id="upload">下载安装</a></body></html>"#.utf8
        )
        let json = Data("""
        {"code":0,"data":{"downloadUrl":"https://oss.example.com/app/x/demo_11.apk"}}
        """.utf8)

        StubURLProtocol.handler = { request in
            switch request.url {
            case pageURL?:
                return .init(status: 200, body: html, headers: ["Content-Type": "text/html"])
            case apiURL?:
                return .init(status: 200, body: json, headers: ["Content-Type": "application/json"])
            case apkURL?:
                return .init(status: 200, body: apk)
            default:
                return .init(status: 404, body: Data())
            }
        }

        let acquired = try await acquirer().acquire(.remote(pageURL), policy: .scanned)

        XCTAssertEqual(acquired.info.packageName, "com.example.demo")
        XCTAssertEqual(acquired.fileURL.lastPathComponent, "demo_11.apk")
        XCTAssertEqual(
            StubURLProtocol.requests.first(where: { $0.url == apiURL })?
                .value(forHTTPHeaderField: "Referer"),
            pageURL.absoluteString,
            "问详情接口时带上下载页的 Referer"
        )
    }

    /// 详情接口明确说没登录时，仍然按网页提示，不要硬报解析失败。
    func testReportsAWebPageWhenTheDetailAPIReturnsAnError() async throws {
        let pageURL = URL(
            string: "https://app.push.example.com/content-web/download.html?id=abc"
        )!
        let apiURL = URL(
            string: "https://app.push.example.com/content-web/app/detail.do?id=abc"
        )!
        let html = Data("<html><body>下载安装</body></html>".utf8)
        let json = Data(#"{"code":-1,"msg":"登录已过期","data":null}"#.utf8)

        StubURLProtocol.handler = { request in
            switch request.url {
            case pageURL?:
                return .init(status: 200, body: html, headers: ["Content-Type": "text/html"])
            case apiURL?:
                return .init(status: 200, body: json, headers: ["Content-Type": "application/json"])
            default:
                return .init(status: 404, body: Data())
            }
        }

        do {
            _ = try await acquirer().acquire(.remote(pageURL), policy: .scanned)
            XCTFail("网页应当报错")
        } catch {
            guard case .webPage = error as? APKAcquisitionError else {
                return XCTFail("意外的错误：\(error)")
            }
        }
    }

    /// 页面链回自己时不能无限重试。
    func testDoesNotFollowAPageLinkBackToItself() async throws {
        let html = Data("""
        <html><body><a href="https://example.com/builds/demo.apk?token=abc">下载</a></body></html>
        """.utf8)
        StubURLProtocol.handler = { _ in
            .init(status: 200, body: html, headers: ["Content-Type": "text/html"])
        }

        do {
            _ = try await acquirer().acquire(.remote(remoteURL), policy: .scanned)
            XCTFail("网页应当报错")
        } catch {
            guard case .webPage = error as? APKAcquisitionError else {
                return XCTFail("意外的错误：\(error)")
            }
        }

        XCTAssertEqual(StubURLProtocol.requests.count, 2, "只该有桌面 UA 与手机 UA 两次请求")
    }

    /// 不是网页的普通文件直接报解析失败，不要用换 UA 掩盖真正的问题。
    func testDoesNotRetryWhenTheContentIsNotAPage() async throws {
        StubURLProtocol.handler = { _ in
            .init(
                status: 200,
                body: Data("not a zip".utf8),
                headers: ["Content-Type": "application/octet-stream"]
            )
        }

        do {
            _ = try await acquirer().acquire(.remote(remoteURL), policy: .scanned)
            XCTFail("不是 APK 应当报错")
        } catch {
            XCTAssertEqual(error as? APKAcquisitionError, .inspection(.notAZipArchive))
        }

        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    /// 扫码策略失败后，桌面页、手机页、提取出来的包都不能留在 tmp。
    func testScannedPolicyDeletesEveryDownloadedPage() async throws {
        let html = Data("<html><body>请先登录</body></html>".utf8)
        StubURLProtocol.handler = { _ in
            .init(status: 200, body: html, headers: ["Content-Type": "text/html"])
        }

        do {
            _ = try await acquirer().acquire(.remote(remoteURL), policy: .scanned)
            XCTFail("网页应当报错")
        } catch {
            guard case .webPage = error as? APKAcquisitionError else {
                return XCTFail("意外的错误：\(error)")
            }
        }

        let leftovers = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(leftovers.isEmpty, "临时目录里不应留下下载页：\(leftovers)")
    }

    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [DownloadProgress] = []

        func record(_ progress: DownloadProgress) {
            lock.lock()
            storage.append(progress)
            lock.unlock()
        }

        var values: [DownloadProgress] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }
}
