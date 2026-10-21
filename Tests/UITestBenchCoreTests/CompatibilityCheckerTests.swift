import XCTest
@testable import UITestBenchCore

final class CompatibilityCheckerTests: XCTestCase {
    private func apk(
        minSdk: Int? = 24,
        abis: [String] = [],
        split: Bool = false
    ) -> ApkInfo {
        ApkInfo(
            packageName: "com.example.demo",
            versionCode: 1,
            versionName: "1.0",
            minSdkVersion: minSdk,
            targetSdkVersion: 34,
            applicationLabel: nil,
            launcherActivityName: ".MainActivity",
            abis: abis,
            isSplitApk: split,
            byteCount: 1024
        )
    }

    func testAcceptsPureJavaApk() {
        let report = CompatibilityChecker.check(apk())

        XCTAssertTrue(report.isCompatible)
        XCTAssertEqual(report.issues, [])
    }

    func testAcceptsApkThatCarriesArm64AlongsideOtherAbis() {
        let report = CompatibilityChecker.check(apk(abis: ["arm64-v8a", "armeabi-v7a"]))

        XCTAssertTrue(report.isCompatible)
    }

    func testBlocksApkWithoutArm64Libraries() {
        let report = CompatibilityChecker.check(apk(abis: ["armeabi-v7a"]))

        XCTAssertEqual(report.issues, [.noMatchingAbi(apk: ["armeabi-v7a"])])
        XCTAssertTrue(report.issues[0].explanation.contains("armeabi-v7a"))
    }

    func testBlocksApkRequiringNewerApiThanDevice() {
        let report = CompatibilityChecker.check(apk(minSdk: 35))

        XCTAssertEqual(report.issues, [.minSdkTooHigh(required: 35, device: 34)])
    }

    func testAcceptsApkWhoseMinSdkEqualsDeviceApi() {
        let report = CompatibilityChecker.check(apk(minSdk: 34))

        XCTAssertTrue(report.isCompatible)
    }

    func testBlocksSplitApk() {
        let report = CompatibilityChecker.check(apk(split: true))

        XCTAssertEqual(report.issues, [.splitApkUnsupported])
    }

    /// 多个问题同时存在时全部给出，不能只报第一个。
    func testReportsEveryBlockingReasonAtOnce() {
        let report = CompatibilityChecker.check(apk(minSdk: 35, abis: ["x86"], split: true))

        XCTAssertEqual(report.issues, [
            .splitApkUnsupported,
            .minSdkTooHigh(required: 35, device: 34),
            .noMatchingAbi(apk: ["x86"])
        ])
    }

    func testBlocksWhenInspectionItselfFailed() {
        let report = CompatibilityChecker.check(.failure(.manifestUnreadable))

        XCTAssertEqual(report.issues, [.manifestUnreadable])
        XCTAssertFalse(report.isCompatible)
    }

    func testAcceptsSuccessfulInspection() throws {
        let report = CompatibilityChecker.check(.success(apk()))

        XCTAssertTrue(report.isCompatible)
    }
}
