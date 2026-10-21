import XCTest
@testable import UITestBenchCore

final class SdkInstallPlanTests: XCTestCase {
    private let tools = SdkPackage(
        path: "platform-tools",
        revision: SdkRevision(major: 37, minor: 0, micro: 1),
        displayName: "Android SDK Platform-Tools",
        licenseID: "android-sdk-license",
        archives: [
            SdkArchive(url: "platform-tools_r37.0.1-darwin.zip", size: 16_110_554,
                       sha1: "bb73f4de6452dc57e62ec02b68eed92a4c21661", hostOS: "macosx")
        ],
        dependencyMinimumRevisions: [:]
    )

    private let emulator = SdkPackage(
        path: "emulator",
        revision: SdkRevision(major: 37, minor: 3, micro: 4),
        displayName: "Android Emulator",
        licenseID: "android-sdk-preview-license",
        archives: [
            SdkArchive(url: "emulator-darwin_x64.zip", size: 493_505_602,
                       sha1: "155220398c3537b5a5fed77d7678619840293cb4",
                       hostOS: "macosx", hostArch: "x64"),
            SdkArchive(url: "emulator-darwin_aarch64.zip", size: 420_504_752,
                       sha1: "4cd3b6f14336a0085b8992eeffe637864839b4ce",
                       hostOS: "macosx", hostArch: "aarch64")
        ],
        dependencyMinimumRevisions: [:]
    )

    private let systemImage = SdkPackage(
        path: "system-images;android-34;default;arm64-v8a",
        revision: SdkRevision(major: 4),
        displayName: "ARM 64 v8a System Image",
        licenseID: "android-sdk-license",
        archives: [
            SdkArchive(url: "arm64-v8a-34_r04.zip", size: 705_115_396,
                       sha1: "d9f2011131919abe952814e041f16f317242c3fa", hostOS: nil)
        ],
        dependencyMinimumRevisions: [:]
    )

    private func plan() throws -> SdkInstallPlan {
        try SdkInstallPlan.make(
            repository: SdkRepository(packages: [tools, emulator]),
            systemImageRepository: SdkRepository(packages: [systemImage]),
            hostOS: "macosx",
            hostArch: "aarch64",
            repositoryBaseURL: URL(string: "https://dl.google.com/android/repository/")!,
            systemImageBaseURL: URL(string: "https://dl.google.com/android/repository/sys-img/android/")!,
            systemImagePackagePath: "system-images;android-34;default;arm64-v8a"
        )
    }

    func testBuildsDownloadsInDependencyOrder() throws {
        let downloads = try plan().downloads

        XCTAssertEqual(downloads.map(\.packagePath), [
            "platform-tools",
            "emulator",
            "system-images;android-34;default;arm64-v8a"
        ])
    }

    func testResolvesAbsoluteURLsAgainstTheirOwnBase() throws {
        let downloads = try plan().downloads

        XCTAssertEqual(
            downloads[0].url.absoluteString,
            "https://dl.google.com/android/repository/platform-tools_r37.0.1-darwin.zip"
        )
        XCTAssertEqual(
            downloads[1].url.absoluteString,
            "https://dl.google.com/android/repository/emulator-darwin_aarch64.zip"
        )
        XCTAssertEqual(
            downloads[2].url.absoluteString,
            "https://dl.google.com/android/repository/sys-img/android/arm64-v8a-34_r04.zip"
        )
    }

    func testSumsTotalBytes() throws {
        XCTAssertEqual(try plan().totalBytes, 16_110_554 + 420_504_752 + 705_115_396)
    }

    func testThrowsWhenPackageIsMissing() {
        XCTAssertThrowsError(
            try SdkInstallPlan.make(
                repository: SdkRepository(packages: [tools]),
                systemImageRepository: SdkRepository(packages: [systemImage]),
                hostOS: "macosx",
                hostArch: "aarch64",
                repositoryBaseURL: URL(string: "https://example.com/")!,
                systemImageBaseURL: URL(string: "https://example.com/")!,
                systemImagePackagePath: "system-images;android-34;default;arm64-v8a"
            )
        ) { error in
            XCTAssertEqual(error as? SdkInstallPlanError, .missingPackage("emulator"))
        }
    }

    func testThrowsWhenNoArchiveMatchesHost() {
        XCTAssertThrowsError(
            try SdkInstallPlan.make(
                repository: SdkRepository(packages: [tools, emulator]),
                systemImageRepository: SdkRepository(packages: [systemImage]),
                hostOS: "windows",
                hostArch: "aarch64",
                repositoryBaseURL: URL(string: "https://example.com/")!,
                systemImageBaseURL: URL(string: "https://example.com/")!,
                systemImagePackagePath: "system-images;android-34;default;arm64-v8a"
            )
        ) { error in
            XCTAssertEqual(error as? SdkInstallPlanError, .missingArchive("platform-tools"))
        }
    }
}
