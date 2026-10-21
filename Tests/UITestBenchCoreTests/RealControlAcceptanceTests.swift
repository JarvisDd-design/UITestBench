import XCTest
@testable import UITestBenchCore

/// 在真实模拟器上验证控制通道：点击、拖动、滚轮、文字输入、返回键。
///
///     UITESTBENCH_REAL_SETUP=1 UITESTBENCH_SDK_DIR=<支持目录> swift test --filter RealControlAcceptanceTests
///
/// 断言全部落在系统界面的真实变化上（`dumpsys activity`、`uiautomator dump` 的控件坐标），
/// 不依赖截图，也不依赖我们自己实现里的任何状态。
@MainActor
final class RealControlAcceptanceTests: XCTestCase {
    private var controller: EmulatorController?
    private var session: ScrcpySession?
    private var sink: MirrorInputSink?
    private var serial = ""
    private var adb = URL(fileURLWithPath: "/nonexistent/adb")
    private let runner = ProcessCommandRunner()
    /// 画面坐标 = 设备坐标 × scale（开了 max_size 之后画面比设备小）。
    private var scale: CGFloat = 1

    override func tearDown() async throws {
        await session?.stop()
        session = nil
        sink = nil
        try? await controller?.stop()
        controller = nil
        try await super.tearDown()
    }

    func testTapOpensPageAndBackKeyReturns() async throws {
        try await prepare()
        try await openSettings()
        let videoWidth = try XCTUnwrap(session?.handshake.map { Double($0.session.width) })
        XCTAssertEqual(Int(videoWidth), 864)

        let nodes = try await uiNodes()
        let row = try XCTUnwrap(nodes.first { $0.text == "Network & internet" }, "设置首页上应当有「Network & internet」")
        try sink?.tap(at: videoPoint(row.bounds.center))
        await waitUntil(timeout: 10) { await self.topActivity().contains("com.android.settings/.SubSettings") }

        var activity = await topActivity()
        XCTAssertTrue(activity.contains("com.android.settings/.SubSettings"), "点击后应当进入子页面，实际停留：\(activity)")

        try sink?.pressKey(.back)
        await waitUntil(timeout: 10) { await self.topActivity().contains("SettingsHomepageActivity") }

        activity = await topActivity()
        XCTAssertTrue(activity.contains("SettingsHomepageActivity"), "按返回应当回到设置首页，实际停留：\(activity)")
    }

    /// 按住往上拖，列表跟着走——移动事件（ACTION_MOVE）真的送达了。
    func testDragMovesTheList() async throws {
        try await prepare()
        try await openSettings()

        let before = try await rowY("Network & internet")
        try await drag(from: CGPoint(x: 540, y: 1500), to: CGPoint(x: 540, y: 1200))

        let after = try await rowY("Network & internet")
        XCTAssertLessThan(after, before - 100, "向上拖动 300px，行应当明显上移（前 \(before)，后 \(after)）")
    }

    /// 滚轮不走 INJECT_SCROLL_EVENT，而是被翻译成一次短拖动——这台 AOSP 14 镜像上
    /// 注入的 ACTION_SCROLL 应用层不响应，同坐标拖动却立刻生效。
    func testScrollWheelMovesTheList() async throws {
        try await prepare()
        try await openSettings()

        let before = try await rowY("Network & internet")
        for _ in 0..<3 {
            // 与 scrcpy 的约定一致：负数是向下滚，列表内容往上走。
            try sink?.scroll(at: videoPoint(CGPoint(x: 540, y: 1500)), horizontal: 0, vertical: -1)
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        // 手势在串行队列上按节拍执行（每格约 0.2 秒），等这一段跑完再量。
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let after = try await rowY("Network & internet")
        XCTAssertLessThan(after, before - 100, "三格滚轮应当让列表明显上移（前 \(before)，后 \(after)）")
    }

    /// 诊断探针：量「发出输入 → 解码出新画面」的耗时。
    ///
    ///     PROBE_LATENCY=1 swift test --filter RealControlAcceptanceTests/testProbeInputToFrameLatency
    ///
    /// 只在改画面链路时手动跑，平时 skip——它比功能用例更依赖机器负载，适合看趋势。
    /// 当前基线（宿主机 GPU、1920 高）：中位数约 50 ms，等编码器约 44 ms，
    /// 我们自己的解码约 2 ms——瓶颈在模拟器的软件编码器，不在客户端。
    func testProbeInputToFrameLatency() async throws {
        guard ProcessInfo.processInfo.environment["PROBE_LATENCY"] != nil else {
            throw XCTSkip("设置 PROBE_LATENCY=1 才跑延迟探针")
        }
        try await prepare()
        // 样本应用的广告页会自己弹回前台，先按死它，别抢走设置页。
        try await shell(["am", "force-stop", "com.qsnfrkgk.vdvfeh"])
        try await openSettings()

        let session = try XCTUnwrap(self.session)
        // 直接拆开「等编码器」与「我们解码」两段：读事件会阻塞到下一帧到齐，
        // 解码是同步的。哪一段占大头，优化方向完全不同。
        let videoReader = try session.videoReader()
        let decoder = ScrcpyDecoder()

        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var _signature: Int = 0
            private var _readTimes: [Double] = []
            private var _decodeTimes: [Double] = []
            private var _arrivals: [Date] = []
            func update(_ value: Int, readMilliseconds: Double, decodeMilliseconds: Double) {
                lock.lock()
                _signature = value
                _readTimes.append(readMilliseconds)
                _decodeTimes.append(decodeMilliseconds)
                _arrivals.append(Date())
                lock.unlock()
            }
            var value: Int { lock.lock(); defer { lock.unlock() }; return _signature }
            var readAverage: Double {
                lock.lock(); defer { lock.unlock() }
                return _readTimes.isEmpty ? 0 : _readTimes.reduce(0, +) / Double(_readTimes.count)
            }
            var decodeStatistics: (average: Double, max: Double) {
                lock.lock(); defer { lock.unlock() }
                let average = _decodeTimes.isEmpty ? 0 : _decodeTimes.reduce(0, +) / Double(_decodeTimes.count)
                return (average, _decodeTimes.max() ?? 0)
            }
            var frameStatistics: (count: Int, intervals: [Double]) {
                lock.lock(); defer { lock.unlock() }
                return (_decodeTimes.count, zip(_arrivals.dropFirst(), _arrivals).map { $0.timeIntervalSince($1) * 1000 })
            }
        }
        let box = Box()
        let thread = Thread {
            while true {
                let readBegan = Date()
                guard let event = try? videoReader.nextEvent() else { break }
                let read = Date().timeIntervalSince(readBegan) * 1000

                let decodeBegan = Date()
                guard let frame = try? decoder.consume(event) else { continue }
                let decode = Date().timeIntervalSince(decodeBegan) * 1000
                box.update(
                    Self.signature(of: frame.pixelBuffer),
                    readMilliseconds: read,
                    decodeMilliseconds: decode
                )
            }
        }
        thread.start()

        // 让画面进入搜索页并聚焦输入框，键盘动画归零后再量。
        let homepage = try await uiNodes()
        let searchEntry = try XCTUnwrap(homepage.first { $0.text == "Search settings" })
        try sink?.tap(at: videoPoint(searchEntry.bounds.center))
        await waitUntil(timeout: 10) { await self.topActivity().contains("SearchActivity") }
        let page = try await uiNodes()
        let field = try XCTUnwrap(page.first { $0.text == "Search…" })
        try sink?.tap(at: videoPoint(field.bounds.center))
        try await Task.sleep(nanoseconds: 1_500_000_000)

        // 连打 8 个字符，每个字符都会立刻改变输入框——比切页动画稳定得多。
        var samples: [Double] = []
        for character in "abcdefgh" {
            let baseline = box.value
            let start = Date()
            try sink?.sendText(String(character))
            while Date().timeIntervalSince(start) < 2 {
                if box.value != baseline {
                    samples.append(Date().timeIntervalSince(start) * 1000)
                    break
                }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        let sorted = samples.sorted()
        let median = sorted.isEmpty ? Double.nan : sorted[sorted.count / 2]
        let frames = box.frameStatistics
        let decode = box.decodeStatistics
        let avgInterval = frames.intervals.isEmpty ? 0 : frames.intervals.reduce(0, +) / Double(frames.intervals.count)
        print(String(format: "LATENCY 中位数 %.0f ms（样本 %@）", median, sorted.map { String(format: "%.0f", $0) }.joined(separator: ",")))
        print(String(format: "FRAMES %d 帧，平均间隔 %.1f ms（%.0f fps）", frames.count, avgInterval, avgInterval > 0 ? 1000 / avgInterval : 0))
        print(String(format: "READ 等编码器 平均 %.1f ms；DECODE 我们的解码 平均 %.1f ms，最长 %.1f ms", box.readAverage, decode.average, decode.max))
        XCTAssertGreaterThanOrEqual(samples.count, 6, "绝大多数字符都应当很快出现新画面")
    }

    /// 稀疏采样：只取像素缓冲里均匀分布的若干字节，够判断画面变没变。
    private static func signature(of buffer: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let bytes = CVPixelBufferGetDataSize(buffer)
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0
        var index = 0
        while index < bytes {
            sum = sum &* 31 &+ Int(pointer[index])
            index += 997
        }
        return sum
    }

    /// 键盘输入走 `INJECT_TEXT`：焦点在搜索框里时，敲的字应当原样出现在设备上。
    /// 这是键盘接线唯一能证明「真的到了应用层」的检查——单测只能证明消息发出去了。
    func testTypingTextReachesTheSearchField() async throws {
        try await prepare()
        try await openSettings()

        let homepage = try await uiNodes()
        let searchEntry = try XCTUnwrap(
            homepage.first { $0.text == "Search settings" },
            "设置首页上应当有搜索入口"
        )
        try sink?.tap(at: videoPoint(searchEntry.bounds.center))
        await waitUntil(timeout: 10) { await self.topActivity().contains("SearchActivity") }
        let activity = await topActivity()
        XCTAssertTrue(activity.contains("SearchActivity"), "点搜索入口应当进入搜索页，实际停留：\(activity)")

        // 搜索页的输入框初始是提示文字「Search…」，先点它把焦点拿过来。
        let searchPage = try await uiNodes()
        let field = try XCTUnwrap(
            searchPage.first { $0.text == "Search…" },
            "搜索页上应当有输入框"
        )
        try sink?.tap(at: videoPoint(field.bounds.center))
        try await Task.sleep(nanoseconds: 300_000_000)

        try sink?.sendText("wifi")
        await waitUntil(timeout: 5) {
            (try? await self.uiNodes())?.contains { $0.text == "wifi" } ?? false
        }

        let typed = try await uiNodes()
        XCTAssertTrue(
            typed.contains { $0.text == "wifi" },
            "输入的 wifi 应当出现在搜索框里"
        )
    }

    /// 主页键：从设置退回桌面。键码错一位就会变成别的系统键，这里一并锁住。
    func testHomeKeyReturnsToLauncher() async throws {
        try await prepare()
        try await openSettings()

        try sink?.pressKey(.home)
        await waitUntil(timeout: 10) { await self.topActivity().lowercased().contains("launcher") }
        let activity = await topActivity()
        XCTAssertTrue(
            activity.lowercased().contains("launcher"),
            "按主页应当回到桌面，实际停留：\(activity)"
        )
    }

    // MARK: - 环境

    private func prepare() async throws {
        guard RealEnvironment.isEnabled else {
            throw XCTSkip("未设置 UITESTBENCH_REAL_SETUP=1")
        }
        let (paths, controller) = try await prepareEnvironment(purpose: "RealControl")
        self.controller = controller
        serial = controller.serial
        adb = paths.sdkDirectory.appendingPathComponent("platform-tools/adb")

        let jar = RealEnvironment.scrcpyJarURL()
        try ScrcpyServerJar.validate(jar)
        let session = ScrcpySession(
            adb: adb,
            jar: jar,
            serial: serial,
            // 连续起停模拟器时机器很忙，服务端冷启动可能超过 10 秒。
            configuration: ScrcpySessionConfiguration(
                maxSize: Int(ProcessInfo.processInfo.environment["PROBE_MAX_SIZE"] ?? "") ?? 1920,
                maxFPS: Int(ProcessInfo.processInfo.environment["PROBE_MAX_FPS"] ?? "") ?? 60,
                connectTimeout: 30,
                retryInterval: 0.2
            ),
            // 服务端自己的输出要能看到，否则它起不来时只有一句 EOF。
            launcher: ProcessLauncher(
                outputURL: paths.logsDirectory.appendingPathComponent("scrcpy-server.log")
            )
        )
        self.session = session
        let handshake = try await session.start()
        // 与 App 里接线一致：滚轮那一层包在真正的控制通道外面。
        let sink = DragScrollSink(base: ScrcpyInputSink(stream: try session.openControlChannel()))
        sink.updateScreenSize(
            width: Int(handshake.session.width),
            height: Int(handshake.session.height)
        )
        self.sink = sink

        let physical = try await shell(["wm", "size"])
        let physicalWidth = try XCTUnwrap(Self.firstNumber(after: "Physical size:", in: physical))
        scale = CGFloat(handshake.session.width) / CGFloat(physicalWidth)
        if Int(ProcessInfo.processInfo.environment["PROBE_MAX_SIZE"] ?? "") ?? 1920 == 1920 {
            XCTAssertEqual(scale, 0.8, accuracy: 0.001, "标准机型 1080 宽，画面限到 1920 高后是 0.8 倍")
        }
    }

    private func prepareEnvironment(purpose: String) async throws -> (AppPaths, EmulatorController) {
        let support = try RealEnvironment.supportDirectory(purpose: purpose)
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
            bootTimeout: 600,
            pollInterval: 2
        )
        try await controller.start()
        return (paths, controller)
    }

    // MARK: - 设备操作与断言工具

    @discardableResult
    private func shell(_ arguments: [String]) async throws -> String {
        let result = try await runner.run(adb, ["-s", serial, "shell"] + arguments)
        XCTAssertEqual(result.status, 0, "adb shell \(arguments.joined(separator: " ")) 失败：\(result.output)")
        return result.output
    }

    private func openSettings() async throws {
        // 设置如果还停在上次的子页面，`am start` 只会把整个任务提到前台，
        // 不会回到首页。先杀掉再冷启，保证每次都从首页开始。
        try await shell(["am", "force-stop", "com.android.settings"])
        try await shell(["am", "start", "-a", "android.settings.SETTINGS"])
        await waitUntil(timeout: 15) { await self.topActivity().contains("SettingsHomepageActivity") }
        let activity = await topActivity()
        XCTAssertTrue(activity.contains("SettingsHomepageActivity"), "设置没打开：\(activity)")
    }

    private func topActivity() async -> String {
        let output = try? await shell(["dumpsys", "activity", "activities"])
        return output?
            .split(separator: "\n")
            .first { $0.contains("topResumedActivity") }?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    private func rowY(_ text: String) async throws -> Int {
        let nodes = try await uiNodes()
        let node = try XCTUnwrap(nodes.first { $0.text == text }, "界面上找不到「\(text)」")
        return Int(node.bounds.midY)
    }

    private struct UINode {
        let text: String
        let bounds: CGRect
    }

    /// 当前界面的原始 XML。`rotation` 属性给出系统的显示方向（0 竖、1 横）。
    private func dumpHierarchy() async throws -> String {
        // 先删掉旧文件：dump 偶尔会失败（比如界面还在滚动），此时 cat 会把上一次的
        // 内容原样读回来，断言就会对着旧画面做，怎么都过不去。删掉后失败就是失败。
        try await shell(["rm", "-f", "/sdcard/ui.xml"])
        try await shell(["uiautomator", "dump", "/sdcard/ui.xml"])
        return try await shell(["cat", "/sdcard/ui.xml"])
    }

    private func uiNodes() async throws -> [UINode] {
        let xml = try await dumpHierarchy()
        let regex = try NSRegularExpression(
            pattern: #"text="([^"]*)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]""#
        )
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        return regex.matches(in: xml, range: range).compactMap { match in
            guard let textRange = Range(match.range(at: 1), in: xml) else { return nil }
            let numbers = (2...5).compactMap { index -> Double? in
                Range(match.range(at: index), in: xml).flatMap { Double(xml[$0]) }
            }
            guard numbers.count == 4 else { return nil }
            let text = String(xml[textRange])
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespaces)
            return UINode(
                text: text,
                bounds: CGRect(
                    x: numbers[0],
                    y: numbers[1],
                    width: numbers[2] - numbers[0],
                    height: numbers[3] - numbers[1]
                )
            )
        }
    }

    /// 设备坐标 → 画面坐标。
    private func videoPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * scale, y: point.y * scale)
    }

    private func drag(from start: CGPoint, to end: CGPoint) async throws {
        try sink?.touchDown(at: videoPoint(start))
        for step in 1...8 {
            let t = CGFloat(step) / 8
            let point = CGPoint(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t
            )
            try sink?.touchMove(to: videoPoint(point))
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try sink?.touchUp(at: videoPoint(end))
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private static func firstNumber(after prefix: String, in text: String) -> Int? {
        guard let line = text.split(separator: "\n").first(where: { $0.contains(prefix) }) else {
            return nil
        }
        return line.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.first
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
