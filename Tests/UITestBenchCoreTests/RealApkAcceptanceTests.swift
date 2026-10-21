import XCTest
@testable import UITestBenchCore

/// 用真实 APK 做验收。样本不随仓库分发，通过环境变量指定：
///
///     APK_SAMPLE=/path/to/sample.apk swift test --filter RealApkAcceptanceTests
///
/// 没有设置时跳过，不影响日常测试。
final class RealApkAcceptanceTests: XCTestCase {
    private func sampleData() throws -> Data {
        guard let path = ProcessInfo.processInfo.environment["APK_SAMPLE"] else {
            throw XCTSkip("未设置 APK_SAMPLE")
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// 基准值来自发布方接口返回：应用名 5闲置二手市场交易快，1.1.0 (11)。
    func testParsesRealManifest() throws {
        let zip = try ZipReader(data: try sampleData())
        let manifestBytes = try zip.contents(ofEntryAtPath: "AndroidManifest.xml")
        let manifest = try AndroidManifestParser.parse(manifestBytes)

        XCTAssertEqual(manifest.packageName, "com.qsnfrkgk.vdvfeh")
        XCTAssertEqual(manifest.versionName, "1.1.0")
        XCTAssertEqual(manifest.versionCode, 11)
        XCTAssertNotNil(manifest.launcherActivityName)
    }

    func testRealApkCarriesOnlyArm64Libraries() throws {
        let zip = try ZipReader(data: try sampleData())
        let abis = Set(
            zip.entries
                .map(\.path)
                .filter { $0.hasPrefix("lib/") }
                .compactMap { $0.split(separator: "/").dropFirst().first.map(String.init) }
        )

        XCTAssertEqual(abis, ["arm64-v8a"])
    }

    func testInspectsRealApkInOnePass() throws {
        let info = try ApkInspector.inspect(try sampleData())

        XCTAssertEqual(info.packageName, "com.qsnfrkgk.vdvfeh")
        XCTAssertEqual(info.versionName, "1.1.0")
        XCTAssertEqual(info.versionCode, 11)
        XCTAssertEqual(info.minSdkVersion, 26)
        XCTAssertEqual(info.targetSdkVersion, 34)
        XCTAssertEqual(info.launcherActivityName, "com.qsnfrkgk.vdvfeh.splash.SplashActivity")
        XCTAssertEqual(info.abis, ["arm64-v8a"])
        XCTAssertFalse(info.isSplitApk)
    }
}
