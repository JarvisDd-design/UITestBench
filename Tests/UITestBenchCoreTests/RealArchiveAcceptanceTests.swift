import XCTest
@testable import UITestBenchCore

/// 用真实归档验收磁盘解压。样本不随仓库分发：
///
///     APK_SAMPLE=/path/to/sample.apk PLATFORM_TOOLS_ZIP=/path/to/platform-tools.zip \
///       swift test --filter RealArchiveAcceptanceTests
final class RealArchiveAcceptanceTests: XCTestCase {
    private var output: URL!

    override func setUpWithError() throws {
        output = FileManager.default.temporaryDirectory
            .appendingPathComponent("RealArchiveAcceptance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: output)
    }

    private func sampleURL(_ variable: String) throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[variable] else {
            throw XCTSkip("未设置 \(variable)")
        }
        return URL(fileURLWithPath: path)
    }

    /// 同一份数据，流式解压的结果必须与内存解析逐字节一致。
    func testStreamsManifestOutOfRealApk() throws {
        let apk = try sampleURL("APK_SAMPLE")
        let archive = try ZipArchive(url: apk)
        let entry = try XCTUnwrap(archive.entries.first { $0.path == "AndroidManifest.xml" })

        let destination = output.appendingPathComponent("AndroidManifest.xml")
        try archive.extract(entry, to: destination)

        let streamed = try Data(contentsOf: destination)
        let inMemory = try ZipReader(data: try Data(contentsOf: apk))
            .contents(ofEntryAtPath: "AndroidManifest.xml")

        XCTAssertEqual(streamed, inMemory)
        XCTAssertEqual(Checksum.sha1Hex(of: streamed), Checksum.sha1Hex(of: inMemory))
    }

    func testExtractsRealPlatformToolsArchive() throws {
        let zip = try sampleURL("PLATFORM_TOOLS_ZIP")

        // 清单里公布的 SHA-1，先校验再解压。
        XCTAssertEqual(
            try Checksum.sha1Hex(ofFileAt: zip),
            "6ae73f4de6452dc57e62ec02b68eed92a4c21661"
        )

        let archive = try ZipArchive(url: zip)
        XCTAssertTrue(archive.entries.contains { $0.path == "platform-tools/adb" })

        try archive.extractAll(to: output)

        let adb = output.appendingPathComponent("platform-tools/adb")
        let attributes = try FileManager.default.attributesOfItem(atPath: adb.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(mode & 0o111, 0o111, "adb 必须保留可执行位")

        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(size, 1_000_000)
    }
}
