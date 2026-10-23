import XCTest
@testable import UITestBenchCore

@MainActor
final class SetupModelTests: XCTestCase {
    private var support: URL!

    private lazy var toolsZip = ZipFixtureBuilder()
        .addingStoredEntry(path: "platform-tools/adb", contents: Data("adb".utf8), unixPermissions: 0o755)
        .build()
    private lazy var emulatorZip = ZipFixtureBuilder()
        .addingStoredEntry(path: "emulator/emulator", contents: Data("emulator".utf8), unixPermissions: 0o755)
        .build()
    /// Google 的系统镜像归档顶层就是 `arm64-v8a/`，安装器负责把它落到
    /// `system-images/android-34/default/arm64-v8a/`。
    private lazy var imageZip = ZipFixtureBuilder()
        .addingStoredEntry(
            path: "arm64-v8a/system.img",
            contents: Data(repeating: 0, count: 4096)
        )
        .build()

    override func setUpWithError() throws {
        support = FileManager.default.temporaryDirectory
            .appendingPathComponent("SetupModelTests-\(UUID().uuidString)", isDirectory: true)
        StubURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: support)
    }

    // MARK: 夹具

    private var configuration: SdkBootstrapConfiguration {
        SdkBootstrapConfiguration(
            repositoryURL: URL(string: "https://mirror.example.com/repo/repository2-3.xml")!,
            systemImageRepositoryURL: URL(string: "https://mirror.example.com/sys-img/sys-img2-3.xml")!,
            systemImagePackagePath: "system-images;android-34;default;arm64-v8a",
            hostOS: "macosx",
            hostArch: "aarch64"
        )
    }

    private var repositoryXML: String {
        """
        <?xml version='1.0' encoding='utf-8'?>
        <sdk:sdk-repository xmlns:sdk="http://schemas.android.com/sdk/android/repo/repository2/03">
          <remotePackage path="platform-tools">
            <revision><major>37</major></revision>
            <archives>
              <archive>
                <complete>
                  <size>\(toolsZip.count)</size>
                  <checksum type="sha1">\(Checksum.sha1Hex(of: toolsZip))</checksum>
                  <url>platform-tools_r37.0.1-darwin.zip</url>
                </complete>
                <host-os>macosx</host-os>
              </archive>
            </archives>
          </remotePackage>
          <remotePackage path="emulator">
            <revision><major>37</major></revision>
            <archives>
              <archive>
                <complete>
                  <size>\(emulatorZip.count)</size>
                  <checksum type="sha1">\(Checksum.sha1Hex(of: emulatorZip))</checksum>
                  <url>emulator-darwin_aarch64.zip</url>
                </complete>
                <host-os>macosx</host-os>
                <host-arch>aarch64</host-arch>
              </archive>
            </archives>
          </remotePackage>
        </sdk:sdk-repository>
        """
    }

    private var systemImageXML: String {
        """
        <?xml version='1.0' encoding='utf-8'?>
        <sdk:sdk-sys-img xmlns:sdk="http://schemas.android.com/sdk/android/repo/sys-img2/03">
          <remotePackage path="system-images;android-34;default;arm64-v8a">
            <revision><major>4</major></revision>
            <archives>
              <archive>
                <complete>
                  <size>\(imageZip.count)</size>
                  <checksum type="sha1">\(Checksum.sha1Hex(of: imageZip))</checksum>
                  <url>arm64-v8a-34_r04.zip</url>
                </complete>
              </archive>
            </archives>
          </remotePackage>
        </sdk:sdk-sys-img>
        """
    }

    private func serveEverything() {
        let bodies: [String: Data] = [
            "repository2-3.xml": Data(repositoryXML.utf8),
            "sys-img2-3.xml": Data(systemImageXML.utf8),
            "platform-tools_r37.0.1-darwin.zip": toolsZip,
            "emulator-darwin_aarch64.zip": emulatorZip,
            "arm64-v8a-34_r04.zip": imageZip
        ]
        StubURLProtocol.handler = { request in
            guard let body = bodies[request.url!.lastPathComponent] else {
                return .init(status: 404, body: Data())
            }
            return .init(status: 200, body: body)
        }
    }

    private func makeModel() -> SetupModel {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubURLProtocol.self]
        return SetupModel(
            paths: AppPaths(supportDirectory: support),
            configuration: configuration,
            downloader: FileDownloader(configuration: sessionConfiguration),
            session: URLSession(configuration: sessionConfiguration)
        )
    }

    // MARK: 测试

    func testInstallsEnvironmentAndBecomesReady() async {
        serveEverything()
        let model = makeModel()

        model.start()
        await model.waitForCompletion()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.progressFraction, 1)
        XCTAssertEqual(model.statusText, "环境已就绪")

        for relative in [
            "sdk/platform-tools/adb",
            "sdk/emulator/emulator",
            "sdk/system-images/android-34/default/arm64-v8a/system.img"
        ] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: support.appendingPathComponent(relative).path),
                "缺少 \(relative)"
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent("avd").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent("tmp").path))
    }

    func testReportsChineseFailureWhenManifestCannotBeFetched() async {
        StubURLProtocol.handler = { _ in
            .init(status: 503, body: Data())
        }
        let model = makeModel()

        model.start()
        await model.waitForCompletion()

        guard case let .failed(message) = model.phase else {
            return XCTFail("应当失败，实际为 \(model.phase)")
        }
        XCTAssertTrue(message.contains("503"), "错误信息里要带上状态码：\(message)")
        XCTAssertTrue(message.contains("网络") || message.contains("镜像"), message)
    }

    func testCancellingReturnsToIdle() async {
        serveEverything()
        let model = makeModel()

        model.start()
        model.cancel()
        await model.waitForCompletion()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: support.appendingPathComponent("sdk/platform-tools").path)
        )
    }

    func testCancellingWhileManifestLoadsReturnsToIdle() async {
        let started = expectation(description: "清单请求已发出")
        HangingURLProtocol.reset()
        HangingURLProtocol.onStart = { started.fulfill() }
        defer { HangingURLProtocol.reset() }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [HangingURLProtocol.self]
        let model = SetupModel(
            paths: AppPaths(supportDirectory: support),
            configuration: configuration,
            downloader: FileDownloader(configuration: sessionConfiguration),
            session: URLSession(configuration: sessionConfiguration)
        )

        model.start()
        await fulfillment(of: [started], timeout: 2)
        model.cancel()
        await model.waitForCompletion()

        XCTAssertEqual(model.phase, .idle, "用户取消不该显示成失败：\(model.phase)")
    }

    func testMarkReadyIfInstalledDetectsCompleteEnvironment() throws {
        let model = makeModel()
        XCTAssertFalse(model.markReadyIfInstalled())
        XCTAssertEqual(model.phase, .idle)

        for relative in ["sdk/platform-tools", "sdk/emulator", "sdk/system-images"] {
            try FileManager.default.createDirectory(
                at: support.appendingPathComponent(relative),
                withIntermediateDirectories: true
            )
        }

        XCTAssertTrue(model.markReadyIfInstalled())
        XCTAssertEqual(model.phase, .ready)
    }

    func testInstallsFromOfflineFolderWithoutDownloadingArchives() async throws {
        serveEverything()
        let folder = try makeOfflineFolder(archives: [
            "platform-tools_r37.0.1-darwin.zip": toolsZip,
            "emulator-darwin_aarch64.zip": emulatorZip,
            "arm64-v8a-34_r04.zip": imageZip
        ])
        let model = makeModel()

        model.start(offlineFolder: folder)
        await model.waitForCompletion()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertFalse(
            StubURLProtocol.requests.contains { $0.url!.lastPathComponent.hasSuffix(".zip") },
            "离线导入不应下载归档"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: support.appendingPathComponent("sdk/platform-tools/adb").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("platform-tools_r37.0.1-darwin.zip").path
            ),
            "不能删除用户的离线包"
        )
    }

    func testOfflineFolderMissingArchiveNamesTheFile() async throws {
        serveEverything()
        let folder = try makeOfflineFolder(archives: [
            "platform-tools_r37.0.1-darwin.zip": toolsZip
        ])
        let model = makeModel()

        model.start(offlineFolder: folder)
        await model.waitForCompletion()

        guard case let .failed(message) = model.phase else {
            return XCTFail("应当失败，实际为 \(model.phase)")
        }
        XCTAssertTrue(message.contains("emulator-darwin_aarch64.zip"), message)
        XCTAssertTrue(message.contains("离线"), message)
    }

    private func makeOfflineFolder(archives: [String: Data]) throws -> URL {
        let folder = support.appendingPathComponent("offline", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, body) in archives {
            try body.write(to: folder.appendingPathComponent(name))
        }
        return folder
    }

    func testSecondRunSkipsDownloads() async {
        serveEverything()
        let model = makeModel()
        model.start()
        await model.waitForCompletion()
        XCTAssertEqual(model.phase, .ready)

        let requestsAfterFirst = StubURLProtocol.requests.count
        model.start()
        await model.waitForCompletion()

        XCTAssertEqual(model.phase, .ready)
        let secondRunRequests = StubURLProtocol.requests.dropFirst(requestsAfterFirst)
        XCTAssertFalse(
            secondRunRequests.contains { $0.url!.lastPathComponent.hasSuffix(".zip") },
            "第二次运行不应再下载归档"
        )
    }
}
