import XCTest
@testable import UITestBenchCore

final class DeviceProfileTests: XCTestCase {
    func testPresetsMatchPlan() {
        XCTAssertEqual(
            DeviceProfile.compact,
            DeviceProfile(name: "小屏", width: 1080, height: 2340, density: 420)
        )
        XCTAssertEqual(
            DeviceProfile.standard,
            DeviceProfile(name: "主流", width: 1080, height: 2400, density: 420)
        )
        XCTAssertEqual(
            DeviceProfile.large,
            DeviceProfile(name: "大屏", width: 1440, height: 3120, density: 560)
        )
    }

    func testPresetsAreListedInDisplayOrder() {
        XCTAssertEqual(DeviceProfile.presets, [.compact, .standard, .large])
    }

    /// 磁盘上的设备规格要能找回界面上对应的预设；名字不参与匹配，
    /// 旧版本写进 config.ini 的显示名可能和现在不一样。
    func testFindsPresetByScreenSpecs() {
        XCTAssertEqual(DeviceProfile.presetIndex(matching: .compact), 0)
        XCTAssertEqual(DeviceProfile.presetIndex(matching: .standard), 1)
        XCTAssertEqual(DeviceProfile.presetIndex(matching: .large), 2)
        XCTAssertEqual(
            DeviceProfile.presetIndex(
                matching: DeviceProfile(name: "旧名字", width: 1440, height: 3120, density: 560)
            ),
            2
        )
    }

    func testCustomResolutionHasNoPreset() {
        let custom = DeviceProfile(name: "自定义", width: 1200, height: 2600, density: 480)

        XCTAssertNil(DeviceProfile.presetIndex(matching: custom))
    }
}

final class AVDConfigurationTests: XCTestCase {
    private let configuration = AVDConfiguration(
        name: "uitestbench",
        displayName: "UI验收台",
        systemImageDirectory: "system-images/android-34/default/arm64-v8a/",
        profile: .standard
    )

    func testConfigINIContainsKeysRequiredToBoot() {
        let config = configuration.configINIValues

        XCTAssertEqual(config["AvdId"], "uitestbench")
        XCTAssertEqual(config["avd.ini.displayname"], "UI验收台")
        XCTAssertEqual(config["abi.type"], "arm64-v8a")
        XCTAssertEqual(config["hw.cpu.arch"], "arm64")
        XCTAssertEqual(config["image.sysdir.1"], "system-images/android-34/default/arm64-v8a/")
        XCTAssertEqual(config["tag.id"], "default")
        XCTAssertEqual(config["hw.keyboard"], "yes")
        XCTAssertEqual(config["hw.gpu.enabled"], "yes")
        XCTAssertEqual(config["hw.gpu.mode"], "auto")
        XCTAssertEqual(config["hw.ramSize"], "2048")
    }

    /// 验收看的是应用自己的界面，模拟器底部的「返回 / 主页 / 多任务」
    /// 三键条是系统外壳：告诉框架没有实体按键时，它才会画出来。
    func testConfigINIHasNoSoftwareNavigationBar() {
        XCTAssertEqual(configuration.configINIValues["hw.mainKeys"], "yes")
    }

    func testConfigINIAppliesProfileResolution() {
        let config = configuration.configINIValues

        XCTAssertEqual(config["hw.lcd.width"], "1080")
        XCTAssertEqual(config["hw.lcd.height"], "2400")
        XCTAssertEqual(config["hw.lcd.density"], "420")
    }

    func testChangingProfileOnlyChangesLcdKeys() {
        var changed = configuration
        changed.profile = .large

        let before = configuration.configINIValues
        let after = changed.configINIValues

        XCTAssertEqual(after["hw.lcd.width"], "1440")
        XCTAssertEqual(after["hw.lcd.height"], "3120")
        XCTAssertEqual(after["hw.lcd.density"], "560")

        let changedKeys = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
        XCTAssertEqual(
            changedKeys,
            ["avd.profile.name", "hw.lcd.width", "hw.lcd.height", "hw.lcd.density"]
        )
    }

    func testDeviceINIPointsAtConfigDirectory() {
        let values = configuration.deviceINIValues(root: URL(fileURLWithPath: "/tmp/avd"))

        XCTAssertEqual(values["avd.ini.encoding"], "UTF-8")
        XCTAssertEqual(values["path"], "/tmp/avd/uitestbench.avd")
        XCTAssertEqual(values["path.rel"], "avd/uitestbench.avd")
        XCTAssertEqual(values["target"], "android-34")
    }

    func testConfigINIIsSelfConsistentWhenParsed() {
        let parsed = AVDConfiguration.parseINI(configuration.configINI)

        XCTAssertEqual(parsed, configuration.configINIValues)
    }
}

final class AVDStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AVDStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var configuration: AVDConfiguration {
        AVDConfiguration(
            name: "uitestbench",
            displayName: "UI验收台",
            systemImageDirectory: "system-images/android-34/default/arm64-v8a/",
            profile: .standard
        )
    }

    func testCreateWritesBothINIFiles() throws {
        let store = AVDStore(root: root)

        try store.create(configuration)

        let deviceINI = root.appendingPathComponent("uitestbench.ini")
        let configINI = root.appendingPathComponent("uitestbench.avd/config.ini")
        XCTAssertTrue(FileManager.default.fileExists(atPath: deviceINI.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: configINI.path))

        let values = try XCTUnwrap(
            AVDConfiguration.parseINI(String(contentsOf: configINI, encoding: .utf8))
        )
        XCTAssertEqual(values["hw.lcd.width"], "1080")
    }

    func testCreateIsIdempotentAndKeepsExistingData() throws {
        let store = AVDStore(root: root)
        try store.create(configuration)

        let userData = root.appendingPathComponent("uitestbench.avd/userdata-qemu.img")
        try Data("kept".utf8).write(to: userData)

        try store.create(configuration)

        XCTAssertTrue(FileManager.default.fileExists(atPath: userData.path), "重复创建不应清掉设备数据")
    }

    func testExistsReflectsCreatedDevice() throws {
        let store = AVDStore(root: root)
        XCTAssertFalse(store.exists(named: "uitestbench"))

        try store.create(configuration)

        XCTAssertTrue(store.exists(named: "uitestbench"))
    }

    func testReadProfileReturnsCreatedResolution() throws {
        let store = AVDStore(root: root)
        try store.create(configuration)

        XCTAssertEqual(try store.profile(named: "uitestbench"), .standard)
    }

    func testUpdateProfileRewritesOnlyResolution() throws {
        let store = AVDStore(root: root)
        try store.create(configuration)

        let configURL = root.appendingPathComponent("uitestbench.avd/config.ini")
        var text = try String(contentsOf: configURL, encoding: .utf8)
        text += "custom.flag=keep-me\n"
        try text.write(to: configURL, atomically: true, encoding: .utf8)

        try store.updateProfile(named: "uitestbench", to: .large)

        let values = try XCTUnwrap(
            AVDConfiguration.parseINI(String(contentsOf: configURL, encoding: .utf8))
        )
        XCTAssertEqual(values["hw.lcd.width"], "1440")
        XCTAssertEqual(values["hw.lcd.height"], "3120")
        XCTAssertEqual(values["hw.lcd.density"], "560")
        XCTAssertEqual(values["custom.flag"], "keep-me", "不认识的键不能丢")
        XCTAssertEqual(values["hw.ramSize"], "2048")
        XCTAssertEqual(try store.profile(named: "uitestbench"), .large)
    }

    /// 已有设备的 config.ini 还是旧值（hw.mainKeys=no）。升级后要原地迁移，
    /// 不能重建 AVD，也不能丢掉用户或其它版本写进去的键。
    func testHideNavigationBarMigratesExistingConfig() throws {
        let store = AVDStore(root: root)
        try store.create(configuration)
        let configURL = root.appendingPathComponent("uitestbench.avd/config.ini")
        var values = AVDConfiguration.parseINI(
            try String(contentsOf: configURL, encoding: .utf8)
        )
        values["hw.mainKeys"] = "no"
        values["custom.flag"] = "keep-me"
        let legacy = values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: "\n") + "\n"
        try legacy.write(to: configURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(try store.hideNavigationBar(named: "uitestbench"))

        let migrated = AVDConfiguration.parseINI(
            try String(contentsOf: configURL, encoding: .utf8)
        )
        XCTAssertEqual(migrated["hw.mainKeys"], "yes")
        XCTAssertEqual(migrated["custom.flag"], "keep-me", "迁移不能丢其它键")
        XCTAssertEqual(migrated["hw.lcd.width"], "1080", "迁移只管导航栏")
        XCTAssertFalse(try store.hideNavigationBar(named: "uitestbench"), "已经是新值就不该再报变更")
    }

    func testHideNavigationBarOfMissingDeviceThrows() {
        let store = AVDStore(root: root)
        XCTAssertThrowsError(try store.hideNavigationBar(named: "missing")) { error in
            XCTAssertEqual(error as? AVDStoreError, .deviceNotFound("missing"))
        }
    }

    func testDeleteRemovesDeviceAndConfig() throws {
        let store = AVDStore(root: root)
        try store.create(configuration)

        try store.delete(named: "uitestbench")

        XCTAssertFalse(store.exists(named: "uitestbench"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("uitestbench.ini").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("uitestbench.avd").path))
    }

    func testDeleteMissingDeviceDoesNothing() throws {
        let store = AVDStore(root: root)
        XCTAssertNoThrow(try store.delete(named: "missing"))
    }

    func testProfileOfMissingDeviceThrows() {
        let store = AVDStore(root: root)
        XCTAssertThrowsError(try store.profile(named: "missing")) { error in
            XCTAssertEqual(error as? AVDStoreError, .deviceNotFound("missing"))
        }
    }
}
