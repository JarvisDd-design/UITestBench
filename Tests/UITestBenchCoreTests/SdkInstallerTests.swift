import XCTest
@testable import UITestBenchCore

final class SdkInstallerTests: XCTestCase {
    private var root: URL!
    private var offlineDirectories: [URL] = []
    private var fileManager: FileManager { .default }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SdkInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        StubURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: root)
        for directory in offlineDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: 样本

    private func toolsZip() -> Data {
        ZipFixtureBuilder()
            .addingStoredEntry(path: "platform-tools/adb", contents: Data("adb".utf8), unixPermissions: 0o755)
            .addingStoredEntry(path: "platform-tools/source.properties", contents: Data("Pkg.Revision=37.0.1".utf8))
            .build()
    }

    private func emulatorZip() -> Data {
        ZipFixtureBuilder()
            .addingDeflatedEntry(path: "emulator/emulator", contents: Data("emulator".utf8), unixPermissions: 0o755)
            .build()
    }

    private func url(_ name: String) -> URL {
        URL(string: "https://example.com/\(name)")!
    }

    private func download(_ path: String, _ name: String, _ body: Data) -> SdkDownload {
        SdkDownload(packagePath: path, url: url(name), size: Int64(body.count), sha1: Checksum.sha1Hex(of: body))
    }

    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    private func serve(_ bodies: [String: Data]) {
        StubURLProtocol.handler = { request in
            let name = request.url!.lastPathComponent
            return .init(status: 200, body: bodies[name] ?? Data())
        }
    }

    private func install(
        _ downloads: [SdkDownload],
        offlineArchives: [String: URL] = [:],
        progress: (@Sendable (SdkInstallProgress) -> Void)? = nil
    ) async throws {
        try await SdkInstaller(root: root).install(
            SdkInstallPlan(downloads: downloads),
            downloader: FileDownloader(configuration: configuration()),
            offlineArchives: offlineArchives,
            progress: progress
        )
    }

    private func makeOfflineArchive(_ body: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SdkInstallerOffline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        offlineDirectories.append(directory)
        let url = directory.appendingPathComponent("tools.zip")
        try body.write(to: url)
        return url
    }

    // MARK: 测试

    func testInstallsPackagesIntoRootAndWritesMarkers() async throws {
        let tools = toolsZip()
        let emulator = emulatorZip()
        serve(["tools.zip": tools, "emulator.zip": emulator])

        try await install([
            download("platform-tools", "tools.zip", tools),
            download("emulator", "emulator.zip", emulator)
        ])

        let adb = root.appendingPathComponent("platform-tools/adb")
        XCTAssertEqual(try Data(contentsOf: adb), Data("adb".utf8))
        let attributes = try fileManager.attributesOfItem(atPath: adb.path)
        let mode = ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
        XCTAssertEqual(mode, 0o755)
        XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent("platform-tools/source.properties").path))
        XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent("emulator/emulator").path))

        XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent(".installed/platform-tools.json").path))
        XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent(".installed/emulator.json").path))

        // 下载缓存里的归档装完即删，暂存目录不残留。
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent(".downloads/tools.zip").path))
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent(".staging").path))
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent(".backup").path))
    }

    func testPlacesSystemImageUnderItsPackageDirectory() async throws {
        let image = ZipFixtureBuilder()
            .addingStoredEntry(path: "arm64-v8a/system.img", contents: Data("img".utf8))
            .addingStoredEntry(path: "arm64-v8a/source.properties", contents: Data("Pkg.Desc=Android SDK".utf8))
            .build()
        serve(["image.zip": image])

        try await install([
            download("system-images;android-34;default;arm64-v8a", "image.zip", image)
        ])

        let expected = root.appendingPathComponent(
            "system-images/android-34/default/arm64-v8a/system.img"
        )
        XCTAssertEqual(try Data(contentsOf: expected), Data("img".utf8))
        XCTAssertFalse(
            fileManager.fileExists(atPath: root.appendingPathComponent("arm64-v8a").path),
            "镜像内容不该直接摊在 SDK 根目录"
        )
        XCTAssertTrue(fileManager.fileExists(
            atPath: root.appendingPathComponent("system-images/android-34/default/arm64-v8a/source.properties").path
        ))
        XCTAssertTrue(try SdkInstaller(root: root)
            .isInstalled("system-images;android-34;default;arm64-v8a"))
    }

    func testSkipsPackagesAlreadyInstalledWithSameChecksum() async throws {
        let tools = toolsZip()
        serve(["tools.zip": tools])
        let downloads = [download("platform-tools", "tools.zip", tools)]

        try await install(downloads)
        let requestsAfterFirst = StubURLProtocol.requests.count
        XCTAssertEqual(requestsAfterFirst, 1)

        // 人为改动已装内容：第二次若真的跳过，这个改动会保留。
        let adb = root.appendingPathComponent("platform-tools/adb")
        try Data("tampered".utf8).write(to: adb)

        try await install(downloads)

        XCTAssertEqual(StubURLProtocol.requests.count, requestsAfterFirst, "校验值一致时不应重新下载")
        XCTAssertEqual(try Data(contentsOf: adb), Data("tampered".utf8))
    }

    func testReinstallsPackageWhenChecksumChanges() async throws {
        let v1 = toolsZip()
        serve(["tools.zip": v1])
        try await install([download("platform-tools", "tools.zip", v1)])
        XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent("platform-tools/source.properties").path))

        let v2 = ZipFixtureBuilder()
            .addingStoredEntry(path: "platform-tools/adb", contents: Data("adb v2".utf8))
            .build()
        StubURLProtocol.reset()
        serve(["tools.zip": v2])

        try await install([download("platform-tools", "tools.zip", v2)])

        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("platform-tools/adb")),
            Data("adb v2".utf8)
        )
        XCTAssertFalse(
            fileManager.fileExists(atPath: root.appendingPathComponent("platform-tools/source.properties").path),
            "整目录替换后旧文件不应残留"
        )
    }

    func testThrowsWhenArchiveIsEmpty() async throws {
        let empty = ZipFixtureBuilder().build()
        serve(["empty.zip": empty])

        do {
            try await install([download("platform-tools", "empty.zip", empty)])
            XCTFail("空归档应当抛错")
        } catch {
            XCTAssertEqual(error as? SdkInstallError, .emptyArchive("platform-tools"), "实际错误：\(error)")
        }

        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent("platform-tools").path))
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent(".installed/platform-tools.json").path))
    }

    func testFailedDownloadLeavesNoMarker() async throws {
        StubURLProtocol.handler = { _ in
            .init(status: 404, body: Data())
        }
        let tools = toolsZip()

        do {
            try await install([download("platform-tools", "tools.zip", tools)])
            XCTFail("404 应当抛错")
        } catch {
            XCTAssertEqual(error as? DownloadError, .httpStatus(404))
        }

        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent("platform-tools").path))
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent(".installed/platform-tools.json").path))
    }

    func testInstallsFromOfflineArchiveWithoutNetwork() async throws {
        let tools = toolsZip()
        let offline = try makeOfflineArchive(tools)

        try await install(
            [download("platform-tools", "tools.zip", tools)],
            offlineArchives: ["platform-tools": offline]
        )

        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "离线安装不应发起网络请求")
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("platform-tools/adb")),
            Data("adb".utf8)
        )
        XCTAssertTrue(fileManager.fileExists(atPath: offline.path), "不能删除用户的离线包")
    }

    func testRejectsOfflineArchiveWithWrongChecksum() async throws {
        let tools = toolsZip()
        let offline = try makeOfflineArchive(tools)
        let wrong = SdkDownload(
            packagePath: "platform-tools",
            url: url("tools.zip"),
            size: Int64(tools.count),
            sha1: String(repeating: "0", count: 40)
        )

        do {
            try await install([wrong], offlineArchives: ["platform-tools": offline])
            XCTFail("校验不符时应当拒绝")
        } catch {
            guard case let DownloadError.checksumMismatch(expected, _) = error else {
                return XCTFail("意外的错误：\(error)")
            }
            XCTAssertEqual(expected, String(repeating: "0", count: 40))
        }

        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent("platform-tools").path))
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent(".installed/platform-tools.json").path))
        XCTAssertTrue(fileManager.fileExists(atPath: offline.path))
    }

    func testReportsOverallProgressAndFinishesAtOne() async throws {
        let tools = toolsZip()
        let emulator = emulatorZip()
        serve(["tools.zip": tools, "emulator.zip": emulator])
        let recorder = InstallProgressRecorder()

        try await install([
            download("platform-tools", "tools.zip", tools),
            download("emulator", "emulator.zip", emulator)
        ]) { recorder.record($0) }

        XCTAssertTrue(recorder.values.contains { $0.phase == .extracting && $0.packagePath == "emulator" })
        XCTAssertEqual(recorder.values.last?.phase, .installed)
        let lastFraction = try XCTUnwrap(recorder.values.last?.overallFraction)
        XCTAssertEqual(lastFraction, 1, accuracy: 0.0001)

        // 进度整体单调不减。
        let fractions = recorder.values.compactMap(\.overallFraction)
        XCTAssertEqual(fractions, fractions.sorted())
    }
}

private final class InstallProgressRecorder {
    private(set) var values: [SdkInstallProgress] = []
    private let lock = NSLock()

    func record(_ value: SdkInstallProgress) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }
}
