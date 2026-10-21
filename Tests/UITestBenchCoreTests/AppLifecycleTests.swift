import XCTest
@testable import UITestBenchCore

/// 安装、启动、清数据、卸载：每一次都是「拼 adb 命令 + 读输出 + 翻译成人话」。
final class AppLifecycleTests: XCTestCase {
    private let sdk = URL(fileURLWithPath: "/tmp/fake-sdk", isDirectory: true)
    private let apk = URL(fileURLWithPath: "/tmp/demo.apk")

    private func makeLifecycle(
        outputs: [String] = [],
        statuses: [Int32] = [],
        defaultOutput: String = "Success"
    ) -> (AppLifecycle, FakeCommandRunner) {
        let runner = FakeCommandRunner(
            outputs: outputs,
            defaultOutput: defaultOutput,
            statuses: statuses
        )
        let lifecycle = AppLifecycle(
            sdkDirectory: sdk,
            serial: "emulator-5554",
            runner: runner
        )
        return (lifecycle, runner)
    }

    private var adb: URL {
        sdk.appendingPathComponent("platform-tools", isDirectory: true)
            .appendingPathComponent("adb")
    }

    // MARK: - 输出解析

    func testParsesSuccessfulInstall() {
        XCTAssertEqual(
            InstallOutputParser.parse("Performing Streamed Install\nSuccess\n", status: 0),
            .success
        )
    }

    func testTranslatesNoMatchingAbis() {
        let output = "adb: failed to install demo.apk: Failure "
            + "[INSTALL_FAILED_NO_MATCHING_ABIS: Failed to extract native libraries, res=-113]"

        XCTAssertEqual(
            InstallOutputParser.parse(output, status: 1),
            .failure(.noMatchingAbis)
        )
    }

    func testTranslatesOlderSdk() {
        let output = "Failure [INSTALL_FAILED_OLDER_SDK: Failed parse during installPackageLI: "
            + "Requires newer sdk version #99 (current version is #34)]"

        XCTAssertEqual(InstallOutputParser.parse(output, status: 1), .failure(.olderSdk))
    }

    func testTranslatesUpdateIncompatible() {
        let output = "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: Package com.example.demo "
            + "signatures do not match previously installed version; ignoring!]"

        XCTAssertEqual(
            InstallOutputParser.parse(output, status: 1),
            .failure(.updateIncompatible)
        )
    }

    func testTranslatesMissingCertificates() {
        let output = "Failure [INSTALL_PARSE_FAILED_NO_CERTIFICATES: Failed to collect "
            + "certificates from /data/app/vmdl.tmp/base.apk]"

        XCTAssertEqual(
            InstallOutputParser.parse(output, status: 1),
            .failure(.unsigned)
        )
    }

    func testTranslatesInsufficientStorage() {
        XCTAssertEqual(
            InstallOutputParser.parse("Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE]", status: 1),
            .failure(.insufficientStorage)
        )
    }

    /// 没见过的失败码也要原样留下，方便贴给开发排查。
    func testKeepsUnknownFailureCode() {
        let output = "Failure [INSTALL_FAILED_USER_RESTRICTED: Install canceled by user]"

        XCTAssertEqual(
            InstallOutputParser.parse(output, status: 1),
            .failure(.unknown("INSTALL_FAILED_USER_RESTRICTED"))
        )
    }

    func testFailureWithoutCodeKeepsRawOutput() {
        let output = "adb: failed to install demo.apk"

        XCTAssertEqual(InstallOutputParser.parse(output, status: 1), .failure(.unknown(output)))
    }

    // MARK: - 安装

    func testInstallRunsAdbWithReplaceAndTestFlags() async throws {
        let (lifecycle, runner) = makeLifecycle(outputs: ["Success"])

        try await lifecycle.install(apkAt: apk)

        let first = await runner.calls.first
        let call = try XCTUnwrap(first)
        XCTAssertEqual(call.executable, adb)
        XCTAssertEqual(
            call.arguments,
            ["-s", "emulator-5554", "install", "-r", "-t", apk.path]
        )
    }

    func testInstallThrowsTranslatedFailure() async throws {
        let (lifecycle, _) = makeLifecycle(
            outputs: ["Failure [INSTALL_FAILED_NO_MATCHING_ABIS]"],
            statuses: [1]
        )

        do {
            try await lifecycle.install(apkAt: apk)
            XCTFail("安装失败应当抛错")
        } catch {
            XCTAssertEqual(error as? AppLifecycleError, .install(.noMatchingAbis))
            XCTAssertTrue(
                (error as? AppLifecycleError)?.explanation.contains("32 位") == true
            )
        }
    }

    // MARK: - 启动

    func testLaunchStartsTheGivenActivity() async throws {
        let (lifecycle, runner) = makeLifecycle(
            outputs: ["Starting: Intent { cmp=com.example.demo/.MainActivity }\nStatus: ok"]
        )

        try await lifecycle.launch(packageName: "com.example.demo", activity: ".MainActivity")

        let first = await runner.calls.first
        let call = try XCTUnwrap(first)
        XCTAssertEqual(
            call.arguments,
            ["-s", "emulator-5554", "shell", "am", "start", "-W", "-n",
             "com.example.demo/.MainActivity"]
        )
    }

    func testLaunchFallsBackToMonkeyWhenActivityDoesNotExist() async throws {
        let (lifecycle, runner) = makeLifecycle(
            outputs: [
                "Error type 3\nError: Activity class {com.example.demo/.Missing} does not exist.",
                "Events injected: 1"
            ],
            statuses: [1, 0]
        )

        try await lifecycle.launch(packageName: "com.example.demo", activity: ".Missing")

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(
            calls.last?.arguments,
            ["-s", "emulator-5554", "shell", "monkey", "-p", "com.example.demo",
             "-c", "android.intent.category.LAUNCHER", "1"]
        )
    }

    func testLaunchWithoutKnownActivityGoesStraightToMonkey() async throws {
        let (lifecycle, runner) = makeLifecycle(outputs: ["Events injected: 1"])

        try await lifecycle.launch(packageName: "com.example.demo", activity: nil)

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(
            Array(calls.first?.arguments.prefix(5) ?? []),
            ["-s", "emulator-5554", "shell", "monkey", "-p"]
        )
    }

    func testLaunchFailureExplainsItself() async throws {
        let (lifecycle, _) = makeLifecycle(
            outputs: [
                "Error type 3\nError: Activity class {com.example.demo/.Missing} does not exist.",
                "** No activities found to run, monkey aborted."
            ],
            statuses: [1, 1]
        )

        do {
            try await lifecycle.launch(packageName: "com.example.demo", activity: ".Missing")
            XCTFail("找不到入口时应当抛错")
        } catch {
            guard case .launchFailed = error as? AppLifecycleError else {
                return XCTFail("意外的错误：\(error)")
            }
            XCTAssertTrue(
                (error as? AppLifecycleError)?.explanation.contains("没有找到") == true
            )
        }
    }

    /// 保留数据重启：先杀掉进程，再冷启；数据留在设备上。
    func testForceStopKillsTheProcess() async throws {
        let (lifecycle, runner) = makeLifecycle()

        try await lifecycle.forceStop(packageName: "com.example.demo")

        let first = await runner.calls.first
        let call = try XCTUnwrap(first)
        XCTAssertEqual(
            call.arguments,
            ["-s", "emulator-5554", "shell", "am", "force-stop", "com.example.demo"]
        )
    }

    // MARK: - 清数据与卸载

    func testClearDataRequiresSuccess() async throws {
        let (lifecycle, runner) = makeLifecycle(outputs: ["Success"])

        try await lifecycle.clearData(packageName: "com.example.demo")

        let first = await runner.calls.first
        let call = try XCTUnwrap(first)
        XCTAssertEqual(
            call.arguments,
            ["-s", "emulator-5554", "shell", "pm", "clear", "com.example.demo"]
        )
    }

    func testClearDataFailureIsReported() async throws {
        let (lifecycle, _) = makeLifecycle(outputs: ["Failed"], statuses: [1])

        do {
            try await lifecycle.clearData(packageName: "com.example.demo")
            XCTFail("清数据失败应当抛错")
        } catch {
            XCTAssertEqual(error as? AppLifecycleError, .clearDataFailed)
        }
    }

    /// 完全重装时包可能本来就不在设备上，这不算失败。
    func testUninstallIgnoresNotInstalled() async throws {
        let (lifecycle, _) = makeLifecycle(
            outputs: ["Failure [not installed for 0]"],
            statuses: [1]
        )

        try await lifecycle.uninstall(packageName: "com.example.demo")
    }

    func testUninstallFailureIsReported() async throws {
        let (lifecycle, _) = makeLifecycle(
            outputs: ["Failure [DELETE_FAILED_INTERNAL_ERROR]"],
            statuses: [1]
        )

        do {
            try await lifecycle.uninstall(packageName: "com.example.demo")
            XCTFail("卸载失败应当抛错")
        } catch {
            XCTAssertEqual(
                error as? AppLifecycleError,
                .uninstallFailed("DELETE_FAILED_INTERNAL_ERROR")
            )
        }
    }

    // MARK: - 查询

    func testIsInstalledMatchesExactPackageName() async throws {
        let (lifecycle, _) = makeLifecycle(
            outputs: ["package:com.example.demo\npackage:com.example.demo.beta"]
        )

        let installed = await lifecycle.isInstalled(packageName: "com.example.demo")

        XCTAssertTrue(installed)
    }

    func testIsInstalledDoesNotMatchPrefixes() async throws {
        let (lifecycle, _) = makeLifecycle(outputs: ["package:com.example.demo.beta"])

        let installed = await lifecycle.isInstalled(packageName: "com.example.demo")

        XCTAssertFalse(installed)
    }
}
