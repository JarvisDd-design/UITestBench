import ImageIO
import XCTest
@testable import UITestBenchCore

/// 在真实模拟器上走一遍完整的应用生命周期：装 → 启 → 清数据 → 卸。
///
///     UITESTBENCH_REAL_SETUP=1 UITESTBENCH_SDK_DIR=<支持目录> \
///     APK_SAMPLE=/path/to/sample.apk swift test --filter RealAppLifecycleAcceptanceTests
///
/// 断言落在设备自己的输出上（`pm list packages`、`dumpsys activity`），
/// 不依赖我们实现里的任何状态。
@MainActor
final class RealAppLifecycleAcceptanceTests: XCTestCase {
    private var controller: EmulatorController?
    private var lifecycle: AppLifecycle?
    private var serial = ""
    private var sdkDirectory = URL(fileURLWithPath: "/nonexistent/sdk", isDirectory: true)
    private var supportDirectory = URL(fileURLWithPath: "/nonexistent/support", isDirectory: true)
    private var adb = URL(fileURLWithPath: "/nonexistent/adb")
    private let runner = ProcessCommandRunner()

    override func tearDown() async throws {
        try? await controller?.stop()
        controller = nil
        lifecycle = nil
        try await super.tearDown()
    }

    func testInstallLaunchClearDataAndUninstall() async throws {
        let apkURL = try sampleAPKURL()
        try await prepare()
        let lifecycle = try XCTUnwrap(self.lifecycle)

        let info = try ApkInspector.inspect(try Data(contentsOf: apkURL))
        let packageName = try XCTUnwrap(info.packageName, "样本包应当有包名")

        try await lifecycle.install(apkAt: apkURL)
        let installed = await lifecycle.isInstalled(packageName: packageName)
        XCTAssertTrue(installed, "装完应当能在设备上查到 \(packageName)")

        try await lifecycle.launch(
            packageName: packageName,
            activity: info.launcherActivityName
        )
        await waitUntil(timeout: 15) {
            await self.topActivity().contains(packageName)
        }
        let top = await topActivity()
        XCTAssertTrue(
            top.contains(packageName),
            "启动后前台应当是 \(packageName)，实际停留：\(top)"
        )

        try await lifecycle.clearData(packageName: packageName)
        let stillInstalled = await lifecycle.isInstalled(packageName: packageName)
        XCTAssertTrue(stillInstalled, "清数据不应当把包卸掉")

        try await lifecycle.uninstall(packageName: packageName)
        let removed = await lifecycle.isInstalled(packageName: packageName)
        XCTAssertFalse(removed, "卸载后设备上不应当再有 \(packageName)")
    }

    /// 「运行」必须是真正的第一次打开。样本应用只在数据为空时出现隐私协议/
    /// 引导页——这正是设计同事每次都要核对的首屏，不能因为上次运行过就看不到。
    func testRunStartsWithTheFirstLaunchFlow() async throws {
        let apkURL = try sampleAPKURL()
        try await prepare()
        let lifecycle = try XCTUnwrap(self.lifecycle)
        let info = try ApkInspector.inspect(try Data(contentsOf: apkURL))
        let apk = AcquiredAPK(
            fileURL: apkURL,
            info: info,
            compatibility: CompatibilityChecker.check(info)
        )
        let packageName = try XCTUnwrap(info.packageName)

        try await AppRunner(lifecycle: lifecycle).run(apk)
        await waitUntil(timeout: 20) { await self.topActivity().contains(packageName) }

        var texts: [String] = []
        await waitUntil(timeout: 20) {
            texts = (try? await self.uiTexts()) ?? []
            return texts.contains { $0.contains("隐私") || $0.contains("同意") }
        }
        print("首启文案：\(texts)")
        XCTAssertTrue(
            texts.contains { $0.contains("隐私") || $0.contains("同意") },
            "第一次打开应当出现隐私协议/引导页，实际文案：\(texts)"
        )

        try await lifecycle.uninstall(packageName: packageName)
    }

    /// 开发要按「设备 ID」加测试白名单。这个 ID 是应用自己看到的 Android ID
    /// （SSAID），不是 `settings get secure android_id` 的设备种子；而且停掉
    /// 设备再起来也不能变，否则开发加一次白名单就只生效一次。
    func testReportsTheDeviceIDTheAppSeesAndKeepsItAcrossRestart() async throws {
        let apkURL = try sampleAPKURL()
        try await prepare()
        let lifecycle = try XCTUnwrap(self.lifecycle)
        let info = try ApkInspector.inspect(try Data(contentsOf: apkURL))
        let packageName = try XCTUnwrap(info.packageName)

        // 应用要等隐私弹窗同意之后才读 Android ID，所以必须先点掉它。
        let first = try await launchAndReadDeviceID(apkURL: apkURL)
        XCTAssertEqual(first.count, 16, "Android ID 是 16 位十六进制：\(first)")
        XCTAssertTrue(first.allSatisfy(\.isHexDigit))

        let controller = try XCTUnwrap(self.controller)
        try await controller.stop()
        try await controller.start()

        let again = try await launchAndReadDeviceID(apkURL: apkURL)
        XCTAssertEqual(again, first, "重启设备后设备 ID 不能变")

        try await lifecycle.uninstall(packageName: packageName)
    }

    /// 团队统一设备 ID 的终点：设备起来后自动写入团队密钥，
    /// 样本包读到的必须是全团队共用的那一个 ID，而且重启后不变。
    func testTeamDeviceKeyProducesTheSharedDeviceID() async throws {
        let apkURL = try sampleAPKURL()
        try await prepare()
        let controller = try XCTUnwrap(self.controller)
        XCTAssertTrue(
            controller.teamKeyActive,
            "启动时应当把团队设备密钥写好：\(controller.provisioningWarning ?? "没有警告")"
        )

        let identity = try await launchAndReadDeviceID(apkURL: apkURL)
        XCTAssertEqual(identity, "10f5f004470a2797", "团队密钥下样本包的 ID 应当固定")

        try await controller.stop()
        try await controller.start()
        XCTAssertTrue(controller.teamKeyActive)
        let again = try await launchAndReadDeviceID(apkURL: apkURL)
        XCTAssertEqual(again, identity, "停止设备再启动后，团队 ID 不能变")

        let lifecycle = try XCTUnwrap(self.lifecycle)
        let info = try ApkInspector.inspect(try Data(contentsOf: apkURL))
        if let packageName = info.packageName {
            try await lifecycle.uninstall(packageName: packageName)
        }
    }

    /// 换回团队密钥要能把 ID 变回来。这条覆盖的是「别的电脑第一次打开」：
    /// 它们的设备密钥是随机的，工具写入团队密钥后必须落到同一个 ID。
    func testWritingTheTeamKeyChangesTheDeviceIDToTheSharedOne() async throws {
        let apkURL = try sampleAPKURL()
        try await prepare(teamKey: String(repeating: "A", count: 64))
        let controller = try XCTUnwrap(self.controller)
        XCTAssertTrue(controller.teamKeyActive)

        // 先用一台「别的电脑」的随机密钥启动，读到的不是团队 ID。
        let machineID = try await launchAndReadDeviceID(apkURL: apkURL)
        XCTAssertNotEqual(machineID, "10f5f004470a2797", "非团队密钥不应当算出团队 ID")

        // 工具写入团队密钥：停一次系统框架、改表、再启。
        try await TeamDeviceKeyProvisioner(sdkDirectory: sdkDirectory)
            .provision(serial: serial)

        let teamID = try await launchAndReadDeviceID(apkURL: apkURL)
        XCTAssertEqual(teamID, "10f5f004470a2797", "写入团队密钥后应当得到团队 ID")

        let lifecycle = try XCTUnwrap(self.lifecycle)
        let info = try ApkInspector.inspect(try Data(contentsOf: apkURL))
        if let packageName = info.packageName {
            try await lifecycle.uninstall(packageName: packageName)
        }
    }

    /// 换一台「从没配过」的设备，写入团队密钥后必须得到同一个 ID。
    /// 这是跨电脑的缩影：第二台 AVD 的 userdata 是全新的，设备密钥随机。
    ///
    ///     UITESTBENCH_TWO_AVDS=1 ... swift test --filter testAFreshDeviceGetsTheSameTeamDeviceID
    func testAFreshDeviceGetsTheSameTeamDeviceID() async throws {
        guard ProcessInfo.processInfo.environment["UITESTBENCH_TWO_AVDS"] == "1" else {
            throw XCTSkip("设置 UITESTBENCH_TWO_AVDS=1 才跑第二台虚拟设备")
        }
        let apkURL = try sampleAPKURL()
        try await prepare()
        let primary = try XCTUnwrap(self.controller)
        try await primary.stop()

        let secondRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("UITestBenchSecondDevice-\(UUID().uuidString)", isDirectory: true)
        let store = AVDStore(root: secondRoot.appendingPathComponent("avd", isDirectory: true))
        try store.create(AVDConfiguration.default)
        let second = EmulatorController(
            sdkDirectory: sdkDirectory,
            store: store,
            port: 5556,
            launcher: ProcessLauncher(
                outputURL: secondRoot.appendingPathComponent("emulator.log")
            ),
            provisioner: TeamDeviceKeyProvisioner(sdkDirectory: sdkDirectory),
            bootTimeout: 600,
            pollInterval: 2
        )
        addTeardownBlock {
            try? await second.stop()
            try? FileManager.default.removeItem(at: secondRoot)
        }

        // 全新设备：冷启动 + 随机设备密钥，写入团队密钥会重启一次系统框架。
        try await second.start(wipeData: true)
        XCTAssertTrue(
            second.teamKeyActive,
            "第二台设备也应当写入团队密钥：\(second.provisioningWarning ?? "没有警告")"
        )

        let savedSerial = serial
        let savedLifecycle = lifecycle
        defer {
            serial = savedSerial
            lifecycle = savedLifecycle
        }
        serial = second.serial
        lifecycle = AppLifecycle(
            sdkDirectory: sdkDirectory,
            serial: second.serial,
            runner: runner
        )

        let identity = try await launchAndReadDeviceID(apkURL: apkURL)
        XCTAssertEqual(
            identity,
            "10f5f004470a2797",
            "全新设备写入团队密钥后，应当和本机得到同一个 ID"
        )

        let info = try ApkInspector.inspect(try Data(contentsOf: apkURL))
        if let packageName = info.packageName {
            try await lifecycle?.uninstall(packageName: packageName)
        }
        try await second.stop()
    }

    /// 截图这条链路的真实终点：adb 回来的字节必须是一张能解码的 PNG，
    /// 尺寸与当前机型一致。
    func testScreenshotCapturesTheCurrentFrame() async throws {
        try await prepare()

        let data = try await ScreenshotCapturer(
            sdkDirectory: sdkDirectory,
            serial: serial
        ).capture()

        XCTAssertGreaterThan(data.count, 10_000, "截图不应当是一张空图")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 1080)
        XCTAssertEqual(image.height, 2400)
    }

    /// 截图 → 标注 → 导出这条链路的终点：导出的仍是一张原尺寸 PNG。
    /// 预览写进 /tmp，肉眼确认箭头、文字、画笔都落在人看得懂的位置。
    func testScreenshotCanBeAnnotatedAndExported() async throws {
        try await prepare()

        let data = try await ScreenshotCapturer(
            sdkDirectory: sdkDirectory,
            serial: serial
        ).capture()
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

        var document = AnnotationDocument()
        document.add(Annotation(
            shape: .rectangle(CGRect(x: 80, y: 400, width: 920, height: 360))
        ))
        document.add(Annotation(
            shape: .arrow(from: CGPoint(x: 980, y: 980), to: CGPoint(x: 620, y: 800)),
            color: .blue
        ))
        document.add(Annotation(
            shape: .freehand([
                CGPoint(x: 120, y: 1400), CGPoint(x: 260, y: 1330),
                CGPoint(x: 400, y: 1430), CGPoint(x: 540, y: 1340)
            ]),
            color: .green
        ))
        document.add(Annotation(
            shape: .text(origin: CGPoint(x: 120, y: 1560), content: "这里间距少了 8pt"),
            color: .red,
            fontSize: 56
        ))

        let png = try XCTUnwrap(AnnotationRenderer.pngData(document.annotations, over: image))

        let outSource = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let out = try XCTUnwrap(CGImageSourceCreateImageAtIndex(outSource, 0, nil))
        XCTAssertEqual(out.width, image.width)
        XCTAssertEqual(out.height, image.height)

        let previewURL = URL(fileURLWithPath: "/tmp/uitestbench-annotation-preview.png")
        try png.write(to: previewURL)
        print("标注预览：\(previewURL.path)")
    }

    /// 退出清理的验收：设备上真的查不到那个包，`tmp/` 与记录也都清空。
    func testShutdownLeavesNothingOnTheDeviceOrDisk() async throws {
        let apkURL = try sampleAPKURL()
        try await prepare()
        let lifecycle = try XCTUnwrap(self.lifecycle)
        let info = try ApkInspector.inspect(try Data(contentsOf: apkURL))
        let packageName = try XCTUnwrap(info.packageName, "样本包应当有包名")

        try await lifecycle.install(apkAt: apkURL)
        let cleaner = SessionCleaner(supportDirectory: supportDirectory)
        try cleaner.remember(packageName: packageName)
        let paths = AppPaths(supportDirectory: supportDirectory)
        try paths.createDirectories()
        try Data("临时".utf8).write(to: paths.apkDirectory.appendingPathComponent("left.apk"))

        await SessionShutdown(
            cleaner: cleaner,
            lifecycle: lifecycle,
            packageName: packageName
        ).run()

        let removed = await lifecycle.isInstalled(packageName: packageName)
        XCTAssertFalse(removed, "退出清理后设备上不应当再有 \(packageName)")
        XCTAssertNil(try cleaner.pendingPackageName(), "清理成功后不应当留下待卸记录")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: paths.temporaryRoot.path)) ?? []
        XCTAssertEqual(leftovers, [], "tmp 不应当留下文件")
    }

    // MARK: - 环境

    private func sampleAPKURL() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["APK_SAMPLE"] else {
            throw XCTSkip("未设置 APK_SAMPLE")
        }
        return URL(fileURLWithPath: path)
    }

    private func prepare(teamKey: String = TeamDeviceKey.value) async throws {
        guard RealEnvironment.isEnabled else {
            throw XCTSkip("未设置 UITESTBENCH_REAL_SETUP=1")
        }
        let support = try RealEnvironment.supportDirectory(purpose: "RealAppLifecycle")
        if support.isTemporary {
            addTeardownBlock { try? FileManager.default.removeItem(at: support.url) }
        }
        let paths = AppPaths(supportDirectory: support.url)

        let setup = SetupModel(paths: paths)
        setup.start()
        await setup.waitForCompletion()
        XCTAssertEqual(setup.phase, .ready, "安装失败：\(setup.statusText)")

        let store = AVDStore(root: paths.avdDirectory)
        let configuration = AVDConfiguration.default
        if store.exists(named: configuration.name) {
            try store.updateProfile(named: configuration.name, to: .standard)
        } else {
            try store.create(configuration)
        }

        let controller = EmulatorController(
            sdkDirectory: paths.sdkDirectory,
            store: store,
            launcher: ProcessLauncher(outputURL: paths.emulatorLogURL),
            provisioner: TeamDeviceKeyProvisioner(
                sdkDirectory: paths.sdkDirectory,
                teamKey: teamKey
            ),
            bootTimeout: 600,
            pollInterval: 2
        )
        try await controller.start()
        self.controller = controller
        serial = controller.serial
        sdkDirectory = paths.sdkDirectory
        supportDirectory = support.url
        adb = paths.sdkDirectory.appendingPathComponent("platform-tools", isDirectory: true)
            .appendingPathComponent("adb")
        lifecycle = AppLifecycle(
            sdkDirectory: paths.sdkDirectory,
            serial: serial,
            runner: runner
        )
    }

    /// 装包 → 启动 → 点掉隐私弹窗 → 读应用看到的 Android ID。
    /// 每次调用都等同于「第一次打开」，上一个包的数据不会带进来。
    private func launchAndReadDeviceID(apkURL: URL) async throws -> String {
        let lifecycle = try XCTUnwrap(self.lifecycle)
        let info = try ApkInspector.inspect(try Data(contentsOf: apkURL))
        let packageName = try XCTUnwrap(info.packageName)
        let apk = AcquiredAPK(
            fileURL: apkURL,
            info: info,
            compatibility: CompatibilityChecker.check(info)
        )

        try await AppRunner(lifecycle: lifecycle).run(apk)
        try await tapAgreeButton()

        let reader = DeviceIdentityReader(
            sdkDirectory: sdkDirectory,
            serial: serial,
            attempts: 20,
            retryDelay: 0.5
        )
        let identity = try await reader.read(packageName: packageName)
        return try XCTUnwrap(
            identity.androidID,
            "应用启动后应当能读到它看到的 Android ID"
        )
    }

    /// 点隐私弹窗里的「同意」。按 resource-id 找控件、取 bounds 中心，
    /// 不写死坐标——换机型后坐标就不对了。
    private func tapAgreeButton() async throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let point = try await agreeButtonCenter() {
                _ = try await shell(["input", "tap", "\(point.x)", "\(point.y)"])
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTFail("30 秒内没有找到隐私协议的同意按钮")
    }

    private func agreeButtonCenter() async throws -> (x: Int, y: Int)? {
        _ = try await shell(["rm", "-f", "/sdcard/ui.xml"])
        _ = try await shell(["uiautomator", "dump", "/sdcard/ui.xml"])
        let xml = try await shell(["cat", "/sdcard/ui.xml"])
        return Self.center(ofResourceIDSuffix: ":id/btn_agree", in: xml)
    }

    /// 从 uiautomator 的 dump 里按 resource-id 后缀找控件，返回 bounds 中心。
    /// resource-id 带包名前缀，所以只比后缀。
    nonisolated static func center(
        ofResourceIDSuffix suffix: String,
        in xml: String
    ) -> (x: Int, y: Int)? {
        let escaped = NSRegularExpression.escapedPattern(for: suffix)
        let pattern = "resource-id=\"[^\"]*\(escaped)\""
            + "[^>]*bounds=\"\\[(\\d+),(\\d+)\\]\\[(\\d+),(\\d+)\\]\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        guard let match = regex.firstMatch(in: xml, range: range) else { return nil }

        let values = (1...4).compactMap { index -> Int? in
            let matchRange = match.range(at: index)
            guard matchRange.location != NSNotFound,
                  let swiftRange = Range(matchRange, in: xml)
            else { return nil }
            return Int(xml[swiftRange])
        }
        guard values.count == 4 else { return nil }
        return ((values[0] + values[2]) / 2, (values[1] + values[3]) / 2)
    }

    private func shell(_ arguments: [String]) async throws -> String {
        let result = try await runner.run(adb, ["-s", serial, "shell"] + arguments)
        XCTAssertEqual(result.status, 0, "adb shell \(arguments.joined(separator: " ")) 失败：\(result.output)")
        return result.output
    }

    /// 当前界面所有控件上的文字。先删旧文件：dump 失败时不能拿上一次的结果充数。
    private func uiTexts() async throws -> [String] {
        _ = try await shell(["rm", "-f", "/sdcard/ui.xml"])
        _ = try await shell(["uiautomator", "dump", "/sdcard/ui.xml"])
        let xml = try await shell(["cat", "/sdcard/ui.xml"])
        let regex = try NSRegularExpression(pattern: #"text="([^"]*)""#)
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        return regex.matches(in: xml, range: range).compactMap { match in
            guard let textRange = Range(match.range(at: 1), in: xml) else { return nil }
            return String(xml[textRange]).trimmingCharacters(in: .whitespaces)
        }
    }

    private func topActivity() async -> String {
        let output = try? await shell(["dumpsys", "activity", "activities"])
        return output?
            .split(separator: "\n")
            .first { $0.contains("topResumedActivity") }?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    private func waitUntil(
        timeout: TimeInterval,
        _ condition: @escaping () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }
}

final class AgreeButtonLocatorTests: XCTestCase {
    func testFindsTheCenterOfTheAgreeButtonByIDSuffix() {
        let xml = """
        <node index="0" text="同意并继续" resource-id="com.qsnfrkgk.vdvfeh:id/btn_agree" \
        class="android.widget.FrameLayout" clickable="true" bounds="[180,1571][900,1703]" />
        """

        let center = RealAppLifecycleAcceptanceTests.center(
            ofResourceIDSuffix: ":id/btn_agree",
            in: xml
        )

        XCTAssertEqual(center?.x, 540)
        XCTAssertEqual(center?.y, 1637)
    }

    func testDoesNotMatchAControlWhoseIDStartsWithTheSameText() {
        let xml = #"<node resource-id="com.example:id/btn_agree_other" bounds="[0,0][100,100]" />"#

        XCTAssertNil(
            RealAppLifecycleAcceptanceTests.center(
                ofResourceIDSuffix: ":id/btn_agree",
                in: xml
            )
        )
    }
}
