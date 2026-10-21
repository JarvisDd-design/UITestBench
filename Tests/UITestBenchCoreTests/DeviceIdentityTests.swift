import XCTest
@testable import UITestBenchCore

/// 应用看到的 Android ID 存在 `settings_ssaid.xml` 里，按 UID 一行。
/// 开发在测试环境按这个值加白名单，所以工具必须把它读准。
final class SSAIDTableTests: XCTestCase {
    private let xml = """
    <?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
    <settings version="-1">
      <setting id="0" name="userkey" value="C0F8B2FAA0DA029E9AABDF6417C0961EDE427A37D3292BF8540C5170D0B6DA22" package="android" defaultValue="C0F8B2FAA0DA029E9AABDF6417C0961EDE427A37D3292BF8540C5170D0B6DA22" defaultSysSet="true" tag="null" />
      <setting id="5" name="10142" value="10f5f004470a2797" package="com.qsnfrkgk.vdvfeh" defaultValue="10f5f004470a2797" defaultSysSet="false" tag="null" />
    </settings>
    <namespaceHashes />
    """

    func testFindsTheValueForTheGivenPackage() {
        XCTAssertEqual(
            SSAIDTable.androidID(for: "com.qsnfrkgk.vdvfeh", in: xml),
            "10f5f004470a2797"
        )
    }

    /// `userkey` 是每台设备的随机密钥，不是应用看到的 ID。把它当成设备 ID
    /// 发给开发，加白名单永远不会生效。
    func testIgnoresTheUserKeyRow() {
        XCTAssertNil(SSAIDTable.androidID(for: "android", in: xml))
    }

    /// 应用还没读过 Android ID 时表里没有它的行。
    func testReturnsNilBeforeTheAppReadsItsID() {
        XCTAssertNil(SSAIDTable.androidID(for: "com.example.other", in: xml))
    }

    func testHandlesEmptyOrMalformedOutput() {
        XCTAssertNil(SSAIDTable.androidID(for: "com.example.other", in: ""))
        XCTAssertNil(SSAIDTable.androidID(for: "com.example.other", in: "garbage"))
        XCTAssertNil(SSAIDTable.androidID(for: "com.example.other", in: "<settings><setting"))
    }

    // MARK: - 团队统一设备 ID

    private let teamKey = String(repeating: "A", count: 64)

    func testReadsTheUserKey() {
        XCTAssertEqual(
            SSAIDTable.userKey(in: xml),
            "C0F8B2FAA0DA029E9AABDF6417C0961EDE427A37D3292BF8540C5170D0B6DA22"
        )
    }

    /// 换密钥时旧的按 UID 行全部作废：留着的话，应用会继续用旧值，
    /// 团队统一 ID 就只对「还没读过 ID 的包」生效。
    func testPreparesTheTableWithTheTeamKeyAndDropsStaleAppRows() throws {
        let prepared = try XCTUnwrap(SSAIDTable.preparedForTeamKey(teamKey, in: xml))

        XCTAssertEqual(SSAIDTable.userKey(in: prepared), teamKey)
        XCTAssertNil(
            SSAIDTable.androidID(for: "com.qsnfrkgk.vdvfeh", in: prepared),
            "旧的 UID 行必须清掉，下一次读取才会按新密钥重新生成"
        )
        XCTAssertTrue(prepared.contains("defaultValue=\"\(teamKey)\""), "重置时不能回到旧密钥")
        XCTAssertTrue(prepared.contains("<namespaceHashes />"), "表尾要保留")
    }

    /// abx2xml 在 Windows 换行的输入上也要能得到干净的结果。
    func testPreparesCRLFInput() throws {
        let crlf = xml.replacingOccurrences(of: "\n", with: "\r\n")
        let prepared = try XCTUnwrap(SSAIDTable.preparedForTeamKey(teamKey, in: crlf))

        XCTAssertFalse(prepared.contains("\r"))
        XCTAssertEqual(SSAIDTable.userKey(in: prepared), teamKey)
    }

    func testRejectsMalformedKeys() {
        XCTAssertNil(SSAIDTable.preparedForTeamKey("", in: xml))
        XCTAssertNil(SSAIDTable.preparedForTeamKey("xyz", in: xml))
        XCTAssertNil(SSAIDTable.preparedForTeamKey(String(repeating: "A", count: 63), in: xml))
        XCTAssertNil(SSAIDTable.preparedForTeamKey(String(repeating: "G", count: 64), in: xml))
    }

    /// 全新设备第一次开机时表还没被系统写出来。必须能自己建一张只有
    /// userkey 的空表，否则「别的电脑第一次打开」永远拿不到团队 ID。
    func testBuildsATableFromScratchWithTheTeamKey() throws {
        let table = try XCTUnwrap(SSAIDTable.table(forTeamKey: teamKey))

        XCTAssertEqual(SSAIDTable.userKey(in: table), teamKey)
        XCTAssertTrue(table.contains("<settings version=\"-1\">"))
        XCTAssertTrue(table.hasSuffix("<namespaceHashes />"), "表尾要和系统生成的一致")
        XCTAssertNil(
            SSAIDTable.androidID(for: "com.example.other", in: table),
            "空表里不该有任何应用行"
        )
    }

    func testRefusesToBuildATableWithAnInvalidKey() {
        XCTAssertNil(SSAIDTable.table(forTeamKey: "bad"))
    }

    func testReturnsNilWhenTheUserKeyRowIsMissing() {
        let withoutKey = """
        <settings version="-1">
          <setting id="5" name="10142" value="10f5f004470a2797" package="com.example" />
        </settings>
        """
        XCTAssertNil(SSAIDTable.userKey(in: withoutKey))
        XCTAssertNil(SSAIDTable.preparedForTeamKey(teamKey, in: withoutKey))
    }
}

/// 有些反馈后台不存 16 位 Android ID，而是存它的 MD5（32 位）。
/// 两边必须用同一算法：对小写 16 位 ID 的 UTF-8 文本做 MD5。
final class DeviceFingerprintTests: XCTestCase {
    func testMD5MatchesWhatTheFeedbackBackendShows() {
        XCTAssertEqual(
            DeviceFingerprint.md5(of: "10f5f004470a2797"),
            "193fd7d4b0869c1e00c1c6dae9daff6c"
        )
    }

    /// 标准测试向量，防止把编码或大小写写错。
    func testHashesTheTextAsUTF8AndUsesLowercaseHex() {
        XCTAssertEqual(
            DeviceFingerprint.md5(of: "abc"),
            "900150983cd24fb0d6963f7d28e17f72"
        )
    }
}

final class DeviceIdentityReaderTests: XCTestCase {
    private let adbSerial = "emulator-5554"
    private let packageName = "com.qsnfrkgk.vdvfeh"
    private let xml = """
    <settings version="-1">
      <setting id="0" name="userkey" value="C0F8" package="android" />
      <setting id="5" name="10142" value="10f5f004470a2797" package="com.qsnfrkgk.vdvfeh" />
    </settings>
    """

    func testReadsSerialModelAndTheAppVisibleAndroidID() async throws {
        let runner = FakeCommandRunner(outputs: [
            "EMULATOR37X3X4X0\n",
            "Android SDK built for arm64\n",
            xml,
        ])
        let reader = makeReader(runner: runner)

        let identity = try await reader.read(packageName: packageName)

        XCTAssertEqual(identity.serial, "EMULATOR37X3X4X0")
        XCTAssertEqual(identity.model, "Android SDK built for arm64")
        XCTAssertEqual(identity.androidID, "10f5f004470a2797")

        let calls = await runner.calls
        XCTAssertEqual(calls.map(\.arguments.adbTail), [
            ["shell", "getprop", "ro.serialno"],
            ["shell", "getprop", "ro.product.model"],
            ["shell", "su", "0", "abx2xml", "/data/system/users/0/settings_ssaid.xml", "-"],
        ])
    }

    /// 应用刚装好、还没读过 Android ID 时表里没有它，等一会儿再读。
    func testRetriesUntilTheAppHasReadItsID() async throws {
        let runner = FakeCommandRunner(outputs: [
            "EMULATOR37X3X4X0",
            "Android SDK built for arm64",
            xmlWithoutApp,
            xml,
        ])
        let reader = makeReader(runner: runner, attempts: 3)

        let identity = try await reader.read(packageName: packageName)

        XCTAssertEqual(identity.androidID, "10f5f004470a2797")
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 4, "第二次读到就该停，不该把剩余次数跑完")
    }

    /// 读不到 ID 不能让整次「运行」变红：序列号和机型仍然有用。
    func testStillReturnsSerialAndModelWhenTheIDCannotBeRead() async throws {
        let runner = FakeCommandRunner(
            outputs: ["EMULATOR37X3X4X0", "Android SDK built for arm64"],
            defaultOutput: "su: not found",
            statuses: [0, 0, 1, 1, 1]
        )
        let reader = makeReader(runner: runner, attempts: 2)

        let identity = try await reader.read(packageName: packageName)

        XCTAssertEqual(identity.serial, "EMULATOR37X3X4X0")
        XCTAssertNil(identity.androidID)
    }

    private var xmlWithoutApp: String {
        """
        <settings version="-1">
          <setting id="0" name="userkey" value="C0F8" package="android" />
        </settings>
        """
    }

    private func makeReader(
        runner: FakeCommandRunner,
        attempts: Int = 1
    ) -> DeviceIdentityReader {
        DeviceIdentityReader(
            sdkDirectory: URL(fileURLWithPath: "/tmp/sdk", isDirectory: true),
            serial: adbSerial,
            runner: runner,
            attempts: attempts,
            retryDelay: 0
        )
    }
}

private extension Array where Element == String {
    /// 去掉 `-s <serial>` 前缀，断言里只关心真正要执行的命令。
    var adbTail: [String] {
        Array(dropFirst(2))
    }
}
