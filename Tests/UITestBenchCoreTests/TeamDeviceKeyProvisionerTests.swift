import Foundation
import XCTest
@testable import UITestBenchCore

/// 团队统一设备 ID：把模拟器的 userkey 固定成同一个值，
/// 所有电脑对同一套签名证书就会算出同一个 SSAID。
final class TeamDeviceKeyProvisionerTests: XCTestCase {
    private let serial = "emulator-5554"
    private let oldKey = "C0F8B2FAA0DA029E9AABDF6417C0961EDE427A37D3292BF8540C5170D0B6DA22"
    private let teamKey = String(repeating: "B", count: 64)
    private let target = "/data/system/users/0/settings_ssaid.xml"
    private let remoteXML = "/data/local/tmp/uitestbench-ssaid.xml"
    private let remoteABX = "/data/local/tmp/uitestbench-ssaid.abx"
    private let backup = "/data/local/tmp/uitestbench-ssaid-backup.abx"

    private var oldXML: String {
        """
        <?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
        <settings version="-1">
          <setting id="0" name="userkey" value="\(oldKey)" package="android" defaultValue="\(oldKey)" defaultSysSet="true" tag="null" />
          <setting id="5" name="10142" value="10f5f004470a2797" package="com.qsnfrkgk.vdvfeh" defaultValue="10f5f004470a2797" defaultSysSet="false" tag="null" />
        </settings>
        <namespaceHashes />
        """
    }

    private var newXML: String {
        SSAIDTable.preparedForTeamKey(teamKey, in: oldXML)!
    }

    private func makeProvisioner(
        runner: FakeCommandRunner,
        teamKey: String? = nil,
        stopTimeout: TimeInterval = 1,
        readinessTimeout: TimeInterval = 1,
        readinessDelay: TimeInterval = 0
    ) -> TeamDeviceKeyProvisioner {
        TeamDeviceKeyProvisioner(
            sdkDirectory: URL(fileURLWithPath: "/tmp/sdk", isDirectory: true),
            runner: runner,
            teamKey: teamKey ?? self.teamKey,
            temporaryDirectory: FileManager.default.temporaryDirectory,
            stopTimeout: stopTimeout,
            readinessTimeout: readinessTimeout,
            readinessDelay: readinessDelay
        )
    }

    func testDoesNothingWhenTheDeviceAlreadyUsesTheTeamKey() async throws {
        let runner = FakeCommandRunner(outputs: [
            """
            <settings version="-1">
              <setting id="0" name="userkey" value="\(teamKey)" package="android" />
            </settings>
            """,
        ])

        try await makeProvisioner(runner: runner).provision(serial: serial)

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1, "密钥已经对了就不该停系统、重启")
        XCTAssertEqual(calls[0].arguments.withoutSerial, [
            "shell", "su", "0", "abx2xml", target, "-",
        ])
    }

    func testWritesTheTeamKeyAndRestartsTheFrameworkWhenItDiffers() async throws {
        let runner = FakeCommandRunner(outputs: [
            oldXML,                                   // 第一次读：本机旧密钥
            "",                                       // su 0 stop
            "stopped",                                // 等 zygote 停
            oldXML,                                   // 停完再读一次（文件稳定）
            "1 file pushed",                          // push
            "",                                       // xml2abx
            "",                                       // 备份
            "",                                       // 写入
            newXML,                                   // 校验读回
            "",                                       // su 0 start
            "package:/system/framework/framework-res.apk",
            "1f646a861890fbdd",                       // settings 就绪
        ])

        try await makeProvisioner(runner: runner).provision(serial: serial)

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 12)
        let tails = calls.map(\.arguments.withoutSerial)

        XCTAssertEqual(tails[0], ["shell", "su", "0", "abx2xml", target, "-"])
        XCTAssertEqual(tails[1], ["shell", "su", "0", "stop"])
        XCTAssertEqual(tails[2], ["shell", "getprop", "init.svc.zygote"])
        XCTAssertEqual(tails[3], ["shell", "su", "0", "abx2xml", target, "-"])
        XCTAssertEqual(Array(calls[4].arguments.prefix(3)), ["-s", serial, "push"])
        XCTAssertEqual(calls[4].arguments.last, remoteXML)
        XCTAssertEqual(tails[5], [
            "shell", "su", "0", "xml2abx", remoteXML, remoteABX,
        ])
        XCTAssertEqual(tails[6], ["shell", "su", "0", "cp", target, backup])
        XCTAssertEqual(tails[7], ["shell", "su", "0", "cp", remoteABX, target])
        XCTAssertEqual(tails[8], ["shell", "su", "0", "abx2xml", target, "-"])
        XCTAssertEqual(tails[9], ["shell", "su", "0", "start"])
        XCTAssertEqual(tails[10], ["shell", "pm", "path", "android"])
        XCTAssertEqual(tails[11], ["shell", "settings", "get", "secure", "android_id"])

        let pushed = await runner.pushedFiles
        let pushedXML = try XCTUnwrap(pushed[remoteXML])
        XCTAssertEqual(SSAIDTable.userKey(in: pushedXML), teamKey)
        XCTAssertNil(
            SSAIDTable.androidID(for: "com.qsnfrkgk.vdvfeh", in: pushedXML),
            "推上去的表必须清掉旧的 UID 行"
        )
    }

    /// 全新设备第一次开机时表还不存在。必须从零建一张只有 userkey 的表，
    /// 并且把属主/权限/SELinux 标签改回 system 该有的样子——否则系统读不到，
    /// 应用还是会拿到随机 ID。
    func testCreatesTheTableWhenTheDeviceHasNoSSAIDTableYet() async throws {
        let newTable = try XCTUnwrap(SSAIDTable.table(forTeamKey: teamKey))
        let runner = FakeCommandRunner(
            outputs: [
                "", "", "", "stopped", "", "",   // 读表失败 → ls 失败；停系统
                "1 file pushed", "", "",          // push / xml2abx / 写入
                "", "", "",                       // chown / chmod / restorecon
                newTable,                         // 校验读回
                "",                               // start
                "package:/system/framework/framework-res.apk",
                "1f646a861890fbdd",
            ],
            statuses: [1, 1, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        )

        try await makeProvisioner(runner: runner).provision(serial: serial)

        let calls = await runner.calls
        let tails = calls.map(\.arguments.withoutSerial)
        XCTAssertFalse(
            calls.contains { $0.arguments.contains("cp") && $0.arguments.contains(backup) },
            "没有原表就没有可备份的东西"
        )
        XCTAssertEqual(tails[9], ["shell", "su", "0", "chown", "system:system", target])
        XCTAssertEqual(tails[10], ["shell", "su", "0", "chmod", "600", target])
        XCTAssertEqual(tails[11], ["shell", "su", "0", "restorecon", target])

        let pushed = await runner.pushedFiles
        let pushedXML = try XCTUnwrap(pushed[remoteXML])
        XCTAssertEqual(SSAIDTable.userKey(in: pushedXML), teamKey)
        XCTAssertNil(SSAIDTable.androidID(for: "com.qsnfrkgk.vdvfeh", in: pushedXML))
    }

    /// 写完读回来还是旧密钥，说明没有生效：必须把备份盖回去再启系统，
    /// 否则设备会停在一个半改完的状态。
    func testRestoresTheBackupWhenTheWrittenKeyDoesNotTakeEffect() async {
        let runner = FakeCommandRunner(outputs: [
            oldXML, "", "stopped", oldXML,
            "1 file pushed", "", "", "",
            oldXML,                                   // 校验失败
            "",                                       // 恢复备份
            "",                                       // 启动
        ])

        do {
            try await makeProvisioner(runner: runner).provision(serial: serial)
            XCTFail("应当报错")
        } catch {
            XCTAssertEqual(error as? TeamDeviceKeyError, .verificationFailed)
        }

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 11)
        let tails = calls.map(\.arguments.withoutSerial)
        XCTAssertEqual(tails[9], ["shell", "su", "0", "cp", backup, target])
        XCTAssertEqual(tails[10], ["shell", "su", "0", "start"])
    }

    /// 连 userkey 行都读不到时，绝不能先去停系统——那会把设备留在停止状态。
    func testDoesNotStopTheFrameworkWhenTheUserKeyRowIsMissing() async {
        let runner = FakeCommandRunner(outputs: [
            """
            <settings version="-1">
              <setting id="5" name="10142" value="10f5f004470a2797" package="com.example" />
            </settings>
            """,
        ])

        do {
            try await makeProvisioner(runner: runner).provision(serial: serial)
            XCTFail("应当报错")
        } catch {
            XCTAssertEqual(error as? TeamDeviceKeyError, .userKeyMissing)
        }

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testReportsStopFailureWithoutWriting() async {
        let runner = FakeCommandRunner(outputs: [oldXML, ""], statuses: [0, 1])

        do {
            try await makeProvisioner(runner: runner).provision(serial: serial)
            XCTFail("应当报错")
        } catch {
            guard case let TeamDeviceKeyError.commandFailed(detail) = error else {
                return XCTFail("错误类型不对：\(error)")
            }
            XCTAssertTrue(detail.contains("stop"), detail)
        }

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 2, "停不下来就不能继续写")
    }

    /// 系统一直停不下来时也不能写：SettingsProvider 可能把内存里的旧表
    /// 覆盖回去。
    func testFailsWhenTheFrameworkDoesNotStop() async {
        let runner = FakeCommandRunner(
            outputs: [oldXML, ""],
            defaultOutput: "running"
        )

        do {
            try await makeProvisioner(
                runner: runner,
                stopTimeout: 0.02,
                readinessDelay: 0.005
            ).provision(serial: serial)
            XCTFail("应当报错")
        } catch {
            guard case let TeamDeviceKeyError.commandFailed(detail) = error else {
                return XCTFail("错误类型不对：\(error)")
            }
            XCTAssertTrue(detail.contains("没有停下来"), detail)
        }

        let calls = await runner.calls
        XCTAssertFalse(calls.contains { $0.arguments.contains("push") })
    }

    func testRejectsAnInvalidTeamKeyWithoutTouchingTheDevice() async {
        let runner = FakeCommandRunner()

        do {
            try await makeProvisioner(runner: runner, teamKey: "bad")
                .provision(serial: serial)
            XCTFail("应当报错")
        } catch {
            XCTAssertEqual(error as? TeamDeviceKeyError, .invalidKey)
        }

        let calls = await runner.calls
        XCTAssertTrue(calls.isEmpty)
    }

    /// `su 0 start` 返回不代表框架已经可用：PackageManager 可能还在初始化。
    /// 必须等 `pm path` 和 SettingsProvider 都真正响应后再返回。
    func testWaitsForPackageManagerAndSettingsToComeBack() async throws {
        let runner = FakeCommandRunner(outputs: [
            oldXML, "", "stopped", oldXML,
            "1 file pushed", "", "", "", newXML,
            "",                                       // start
            "",                                       // pm 还没好
            "package:/system/framework/framework-res.apk",
            "",                                       // settings 还没好
            "package:/system/framework/framework-res.apk",
            "1f646a861890fbdd",
        ])

        try await makeProvisioner(runner: runner, readinessDelay: 0)
            .provision(serial: serial)

        let calls = await runner.calls
        XCTAssertEqual(
            calls.filter { $0.arguments.withoutSerial == ["shell", "pm", "path", "android"] }.count,
            3,
            "每轮回查一次 PackageManager，直到 SettingsProvider 也响应"
        )
        XCTAssertEqual(
            calls.filter {
                $0.arguments.withoutSerial == ["shell", "settings", "get", "secure", "android_id"]
            }.count,
            2
        )
    }

    func testFailsWhenTheFrameworkNeverComesBack() async {
        let runner = FakeCommandRunner(
            outputs: [oldXML, "", "stopped", oldXML, "1 file pushed", "", "", "", newXML, ""],
            defaultOutput: ""
        )

        do {
            try await makeProvisioner(
                runner: runner,
                readinessTimeout: 0.05,
                readinessDelay: 0.01
            ).provision(serial: serial)
            XCTFail("应当超时")
        } catch {
            XCTAssertEqual(error as? TeamDeviceKeyError, .frameworkDidNotStart)
        }
    }

    func testTheBuiltInTeamKeyIsAValidUserKey() {
        XCTAssertEqual(TeamDeviceKey.value.count, 64)
        XCTAssertTrue(SSAIDTable.isValidUserKey(TeamDeviceKey.value))
    }
}

private extension Array where Element == String {
    /// 去掉 `-s <serial>` 前缀，断言里只关心真正要执行的命令。
    var withoutSerial: [String] {
        Array(dropFirst(2))
    }
}
