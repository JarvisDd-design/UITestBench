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
