import XCTest
@testable import UITestBenchCore

/// 「运行 / 保留数据重启 / 清数据重开 / 完全重装」几段固定流程，顺序错了都会在
/// 实践中出错：清数据要在启动前、卸载要重装前。
final class AppRunnerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeAPK(minSdk: Int = 24, abis: [String] = []) throws -> AcquiredAPK {
        let extra = Dictionary(uniqueKeysWithValues: abis.map {
            ("lib/\($0)/libnative.so", Data([0x7F]))
        })
        let data = APKFixture.minimalAPK(
            minSdk: minSdk,
            launcherActivity: ".MainActivity",
            extraEntries: extra
        )
        let url = directory.appendingPathComponent("demo.apk")
        try data.write(to: url)
        let info = try ApkInspector.inspect(data)
        return AcquiredAPK(
            fileURL: url,
            info: info,
            compatibility: CompatibilityChecker.check(info)
        )
    }

    /// 引导页、隐私协议这类流程只在「第一次打开」出现。设计同事每次点「运行」
    /// 都是来核对首屏的，所以运行必须先把数据清干净，否则第二次起就再也看不到。
    func testRunClearsDataSoEveryRunStartsLikeTheFirstLaunch() async throws {
        let apk = try makeAPK()
        let lifecycle = RecordingLifecycle()

        try await AppRunner(lifecycle: lifecycle).run(apk)

        XCTAssertEqual(
            lifecycle.calls,
            [
                .install(apk.fileURL),
                .clearData("com.example.demo"),
                .launch("com.example.demo", ".MainActivity")
            ]
        )
    }

    /// 反过来：想核对「非首次打开」的界面时，保留数据重启——只杀进程重新拉起。
    func testResumeKeepsDataAndRelaunches() async throws {
        let apk = try makeAPK()
        let lifecycle = RecordingLifecycle()

        try await AppRunner(lifecycle: lifecycle).resume(apk)

        XCTAssertEqual(
            lifecycle.calls,
            [
                .install(apk.fileURL),
                .forceStop("com.example.demo"),
                .launch("com.example.demo", ".MainActivity")
            ]
        )
    }

    func testRestartClearingDataClearsThenLaunches() async throws {
        let apk = try makeAPK()
        let lifecycle = RecordingLifecycle()

        try await AppRunner(lifecycle: lifecycle).restartClearingData(apk)

        XCTAssertEqual(
            lifecycle.calls,
            [
                .clearData("com.example.demo"),
                .launch("com.example.demo", ".MainActivity")
            ]
        )
    }

    func testReinstallUninstallsInstallsThenLaunches() async throws {
        let apk = try makeAPK()
        let lifecycle = RecordingLifecycle()

        try await AppRunner(lifecycle: lifecycle).reinstall(apk)

        XCTAssertEqual(
            lifecycle.calls,
            [
                .uninstall("com.example.demo"),
                .install(apk.fileURL),
                .launch("com.example.demo", ".MainActivity")
            ]
        )
    }

    /// 兼容性预检已经判了装不上，就不要再去设备上试一遍、等一条看不懂的错误。
    func testIncompatibleAPKIsBlockedBeforeTouchingADB() async throws {
        let apk = try makeAPK(minSdk: 99)
        let lifecycle = RecordingLifecycle()

        do {
            try await AppRunner(lifecycle: lifecycle).run(apk)
            XCTFail("不兼容的包应当被拦下")
        } catch {
            XCTAssertEqual(
                error as? AppRunnerError,
                .incompatible([.minSdkTooHigh(required: 99, device: 34)])
            )
        }

        XCTAssertEqual(lifecycle.calls, [])
    }

    func testRunRequiresAPackageName() async throws {
        let data = APKFixture.minimalAPK()
        let url = directory.appendingPathComponent("nameless.apk")
        try data.write(to: url)
        let info = try ApkInspector.inspect(data)
        let apk = AcquiredAPK(
            fileURL: url,
            info: ApkInfo(
                packageName: nil,
                versionCode: info.versionCode,
                versionName: info.versionName,
                minSdkVersion: info.minSdkVersion,
                targetSdkVersion: info.targetSdkVersion,
                applicationLabel: nil,
                launcherActivityName: nil,
                abis: info.abis,
                isSplitApk: false,
                byteCount: info.byteCount
            ),
            compatibility: CompatibilityReport(issues: [])
        )

        do {
            try await AppRunner(lifecycle: RecordingLifecycle()).run(apk)
            XCTFail("没有包名时不该继续")
        } catch {
            XCTAssertEqual(error as? AppRunnerError, .missingPackageName)
        }
    }

    /// 中途失败要原样抛出，界面才知道停在哪一步、为什么。
    func testFailuresPropagate() async throws {
        let apk = try makeAPK()
        let lifecycle = RecordingLifecycle()
        lifecycle.failure = .install(.noMatchingAbis)

        do {
            try await AppRunner(lifecycle: lifecycle).run(apk)
            XCTFail("安装失败应当向上抛")
        } catch {
            XCTAssertEqual(error as? AppLifecycleError, .install(.noMatchingAbis))
        }

        XCTAssertEqual(lifecycle.calls, [.install(apk.fileURL)])
    }

    // MARK: - 假件

    private final class RecordingLifecycle: AppLifecycleRunning, @unchecked Sendable {
        enum Call: Equatable {
            case install(URL)
            case launch(String, String?)
            case clearData(String)
            case uninstall(String)
            case forceStop(String)
        }

        var calls: [Call] = []
        var failure: AppLifecycleError?

        func install(apkAt url: URL) async throws {
            calls.append(.install(url))
            if case .install = failure { throw failure! }
        }

        func launch(packageName: String, activity: String?) async throws {
            calls.append(.launch(packageName, activity))
        }

        func clearData(packageName: String) async throws {
            calls.append(.clearData(packageName))
        }

        func uninstall(packageName: String) async throws {
            calls.append(.uninstall(packageName))
        }

        func forceStop(packageName: String) async throws {
            calls.append(.forceStop(packageName))
        }

        func isInstalled(packageName: String) async -> Bool { true }
    }
}
