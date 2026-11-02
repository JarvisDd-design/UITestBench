import CoreMedia
import XCTest
@testable import UITestBenchCore

/// 真机（模拟器）延迟冒烟：连跑 60 秒，看帧间隔有没有崩、会不会越跑越慢。
///
///     UITESTBENCH_LATENCY_ACCEPTANCE=1 UITESTBENCH_SERIAL=emulator-5554 \
///     swift test --filter MirrorLatencyAcceptanceTests
///
/// 默认 skip：要一台已开机的模拟器和一分钟时间。10 分钟长测、以及「肉眼看到的手感」
/// 仍由人工在发版前跑，这个用例只保证「跑一分钟不退化」。
///
/// 绝对帧间隔（D2 的 p95 ≤ 33ms）只在显式给出 `UITESTBENCH_LATENCY_TARGET_P95_MS` 时断言：
/// 开发机上的 AOSP 模拟器本身合成/编码只有 12–15 fps（`adb shell screenrecord` 同样只有
/// 81 帧/6.6 秒），在这个环境里 33ms 永远达不到，把绝对阈值写死只会变成一个长期红的用例。
/// 换到真机或更快的设备时传 `UITESTBENCH_LATENCY_TARGET_P95_MS=33` 即可恢复强断言。
/// 环境实测数字见 docs/superpowers/plans/2026-11-02-mirror-latency-and-ime.md 的「基线」。
final class MirrorLatencyAcceptanceTests: XCTestCase {
    /// onFrame 在解码线程上回调，收集时间戳要自己加锁。
    private final class Timestamps: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [TimeInterval] = []

        func append(_ value: TimeInterval) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        var all: [TimeInterval] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private final class SizeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: MirrorVideoSize?

        func set(_ size: MirrorVideoSize) {
            lock.lock()
            value = size
            lock.unlock()
        }

        var current: MirrorVideoSize? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    func testMirrorKeepsUpForAMinute() async throws {
        guard ProcessInfo.processInfo.environment["UITESTBENCH_LATENCY_ACCEPTANCE"] == "1" else {
            throw XCTSkip("需要一台已开机的模拟器，默认跳过")
        }

        let support = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/UI验收台")
        let adb = support.appendingPathComponent("sdk/platform-tools/adb")
        let jar = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/UITestBenchApp/Resources/scrcpy-server.jar")
        let serial = ProcessInfo.processInfo.environment["UITESTBENCH_SERIAL"] ?? "emulator-5554"

        // 画面不动就没有新帧，帧间隔无从谈起：先开一个能滚的页面（设置首页）。
        runAndWait(adb, ["shell", "am", "start", "-n", "com.android.settings/.Settings"], seconds: 2)

        var configuration = ScrcpySessionConfiguration()
        configuration.maxFPS = 60
        configuration.videoBitRate = 8_000_000
        let session = ScrcpySession(adb: adb, jar: jar, serial: serial, configuration: configuration)

        let stamps = Timestamps()
        let size = SizeBox()
        let engine = MirrorEngine(
            source: ScrcpyMirrorSource(session: session),
            onFrame: { _ in stamps.append(ProcessInfo.processInfo.systemUptime) },
            onState: { state in
                if case let .streaming(width, height) = state {
                    size.set(MirrorVideoSize(width: width, height: height))
                }
            }
        )
        try await engine.start()

        // 合成一次持续的拖动：`adb shell input swipe` 每条命令之间都有空档，
        // 静止期间服务端不发帧，量出来的帧间隔全是假的。走控制通道才连续。
        let sink = ScrcpyInputSink(stream: try session.openControlChannel())
        var resolved = size.current
        if resolved == nil {
            resolved = await waitForSize(size)
        }
        guard let video = resolved else {
            XCTFail("没拿到画面尺寸")
            return
        }
        sink.updateScreenSize(width: video.width, height: video.height)

        let width = CGFloat(video.width)
        let height = CGFloat(video.height)
        let motionEnd = ProcessInfo.processInfo.systemUptime + 60
        try? sink.touchDown(at: CGPoint(x: width / 2, y: height * 0.8))
        let motionStart = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime < motionEnd {
            let elapsed = ProcessInfo.processInfo.systemUptime - motionStart
            // 1 秒一个来回：向上滑到 1/5 高度，再滑回来。
            let phase = (elapsed.truncatingRemainder(dividingBy: 2)) / 2
            let progress = phase < 0.5 ? phase * 2 : (1 - phase) * 2
            let y = height * (0.8 - 0.6 * progress)
            try? sink.touchMove(to: CGPoint(x: width / 2, y: y))
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        try? sink.touchUp(at: CGPoint(x: width / 2, y: height * 0.8))
        await engine.stop()
        await session.stop()

        let times = stamps.all
        XCTAssertGreaterThan(times.count, 400, "60 秒内只有 \(times.count) 帧，画面基本没动")

        let intervals = zip(times.dropFirst(), times).map { ($0 - $1) * 1000 }
        let p50 = MirrorLatencyMonitor.percentile(intervals, 0.5)
        let p95 = MirrorLatencyMonitor.percentile(intervals, 0.95)
        let fps = Double(times.count) / 60
        print("延迟冒烟：帧数 \(times.count)，平均 \(String(format: "%.1f", fps)) fps，帧间隔 p50 \(String(format: "%.1f", p50)) ms / p95 \(String(format: "%.1f", p95)) ms")
        if let rawTarget = ProcessInfo.processInfo.environment["UITESTBENCH_LATENCY_TARGET_P95_MS"],
           let target = Double(rawTarget) {
            XCTAssertLessThanOrEqual(p95, target, "p95 帧间隔 \(p95) ms，超出 \(target) ms")
        }

        // 不漂移：后段不能比前段明显更慢（队列堆积的特征就是越跑越慢）。
        let window = 10.0
        let origin = times[0]
        let end = times.last ?? origin
        let head = zip(times.dropFirst(), times).filter { $0.1 - origin < window }.map { ($0 - $1) * 1000 }
        let tail = zip(times.dropFirst(), times).filter { $0.1 - origin > end - origin - window }.map { ($0 - $1) * 1000 }
        let headP95 = MirrorLatencyMonitor.percentile(head, 0.95)
        let tailP95 = MirrorLatencyMonitor.percentile(tail, 0.95)
        print("不漂移：前 10 秒 p95 \(String(format: "%.1f", headP95)) ms，后 10 秒 p95 \(String(format: "%.1f", tailP95)) ms")
        XCTAssertLessThanOrEqual(
            tailP95,
            max(headP95 * 1.5, 34),
            "帧间隔越跑越慢：前 10 秒 p95 \(headP95) ms，后 10 秒 p95 \(tailP95) ms"
        )
    }

    private func runAndWait(_ executable: URL, _ arguments: [String], seconds: TimeInterval) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        _ = seconds
    }

    private func waitForSize(_ box: SizeBox) async -> MirrorVideoSize? {
        for _ in 0..<50 {
            if let size = box.current { return size }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return box.current
    }
}
