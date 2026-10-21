import XCTest
@testable import UITestBenchCore

/// 用 Google 官方清单验收解析器。清单会随时间变化，所以只断言结构不变量。
///
///     SDK_REPO_DIR=/path/to/dir swift test --filter RealSdkRepositoryAcceptanceTests
///
/// 目录里需要有 repository2-3.xml 与 sys-img2-3.xml。
final class RealSdkRepositoryAcceptanceTests: XCTestCase {
    private func repository(named name: String) throws -> SdkRepository {
        guard let directory = ProcessInfo.processInfo.environment["SDK_REPO_DIR"] else {
            throw XCTSkip("未设置 SDK_REPO_DIR")
        }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        return try SdkRepository.parse(try Data(contentsOf: url))
    }

    func testFindsPlatformToolsAndEmulatorForAppleSilicon() throws {
        let repository = try repository(named: "repository2-3.xml")

        let tools = try XCTUnwrap(repository.package(atPath: "platform-tools"))
        let toolsArchive = try XCTUnwrap(tools.archive(forHostOS: "macosx", hostArch: "aarch64"))
        XCTAssertTrue(toolsArchive.url.hasSuffix(".zip"))
        XCTAssertEqual(toolsArchive.sha1.count, 40)
        XCTAssertGreaterThan(toolsArchive.size, 1_000_000)

        let emulator = try XCTUnwrap(repository.package(atPath: "emulator"))
        let emulatorArchive = try XCTUnwrap(emulator.archive(forHostOS: "macosx", hostArch: "aarch64"))
        XCTAssertTrue(emulatorArchive.url.contains("aarch64"))
        XCTAssertEqual(emulatorArchive.sha1.count, 40)
        XCTAssertGreaterThan(emulatorArchive.size, 100_000_000)
    }

    func testBuildsDownloadPlanFromRealManifests() throws {
        let plan = try SdkInstallPlan.make(
            repository: try repository(named: "repository2-3.xml"),
            systemImageRepository: try repository(named: "sys-img2-3.xml"),
            hostOS: "macosx",
            hostArch: "aarch64",
            repositoryBaseURL: URL(string: "https://dl.google.com/android/repository/")!,
            systemImageBaseURL: URL(string: "https://dl.google.com/android/repository/sys-img/android/")!,
            systemImagePackagePath: "system-images;android-34;default;arm64-v8a"
        )

        XCTAssertEqual(plan.downloads.count, 3)
        XCTAssertEqual(plan.downloads.map(\.packagePath), [
            "platform-tools", "emulator", "system-images;android-34;default;arm64-v8a"
        ])
        XCTAssertTrue(plan.downloads[1].url.absoluteString.contains("aarch64"))
        XCTAssertGreaterThan(plan.totalBytes, 500_000_000)
    }

    func testFindsAndroid14DefaultSystemImageForArm64() throws {
        let repository = try repository(named: "sys-img2-3.xml")

        let image = try XCTUnwrap(
            repository.package(atPath: "system-images;android-34;default;arm64-v8a")
        )
        let archive = try XCTUnwrap(image.archive(forHostOS: "macosx", hostArch: "aarch64"))
        XCTAssertEqual(archive.sha1.count, 40)
        XCTAssertGreaterThan(archive.size, 100_000_000)
    }
}
