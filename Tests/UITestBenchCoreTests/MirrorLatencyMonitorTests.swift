import XCTest
@testable import UITestBenchCore

final class MirrorLatencyMonitorTests: XCTestCase {
    func testComputesFpsFromDisplaysWithinOneSecond() {
        let monitor = MirrorLatencyMonitor()
        for index in 0..<5 {
            let time = Double(index) * 0.2
            monitor.recordDisplay(arrival: time, at: time)
        }

        let snapshot = monitor.snapshot(now: 1.0)
        XCTAssertEqual(snapshot.fps, 5, accuracy: 0.001)
        XCTAssertEqual(monitor.snapshot(now: 2.0).fps, 0, accuracy: 0.001)
    }

    func testPercentilesUseNearestRank() {
        let monitor = MirrorLatencyMonitor(windowSize: 100)
        for index in 1...100 {
            // 帧在显示时刻之前的 index 毫秒到达。
            monitor.recordDisplay(arrival: -Double(index) / 1000, at: 0)
        }

        let snapshot = monitor.snapshot(now: 0)
        XCTAssertEqual(snapshot.latestLatencyMilliseconds, 100, accuracy: 0.001)
        XCTAssertEqual(snapshot.latencyP95Milliseconds, 95, accuracy: 0.001)
        XCTAssertEqual(snapshot.sampleCount, 100)
    }

    func testLatencyWindowSlides() {
        let monitor = MirrorLatencyMonitor(windowSize: 10)
        for index in 1...25 {
            monitor.recordDisplay(arrival: -Double(index) / 1000, at: 0)
        }

        let snapshot = monitor.snapshot(now: 0)
        XCTAssertEqual(snapshot.sampleCount, 10)
        // 最近 10 个样本是 16…25，p95 落在 25。
        XCTAssertEqual(snapshot.latencyP95Milliseconds, 25, accuracy: 0.001)
    }

    func testDisplayIntervalUsesGapsBetweenDisplays() {
        let monitor = MirrorLatencyMonitor()
        for time in [0.0, 0.2, 0.5, 0.8] {
            monitor.recordDisplay(arrival: time, at: time)
        }

        let snapshot = monitor.snapshot(now: 1.0)
        XCTAssertEqual(snapshot.displayIntervalP95Milliseconds, 300, accuracy: 0.001)
        XCTAssertEqual(snapshot.displayIntervalMilliseconds, 300, accuracy: 0.001)
    }

    func testResetClearsHistory() {
        let monitor = MirrorLatencyMonitor()
        monitor.recordDisplay(arrival: 0, at: 0.05)
        monitor.reset()

        let snapshot = monitor.snapshot(now: 1)
        XCTAssertEqual(snapshot.sampleCount, 0)
        XCTAssertEqual(snapshot.fps, 0, accuracy: 0.001)
        XCTAssertEqual(snapshot.latencyP95Milliseconds, 0, accuracy: 0.001)
    }
}

final class MirrorLatencyMonitorInputTests: XCTestCase {
    func testMeasuresFromInputToTheFirstFrameAfterIt() {
        let monitor = MirrorLatencyMonitor()
        monitor.recordInput(at: 100)
        monitor.recordArrival(at: 100.058)

        let snapshot = monitor.snapshot(now: 101)
        XCTAssertEqual(snapshot.inputToFrameMilliseconds, 58, accuracy: 0.5)
    }

    func testOnlyTheFirstFrameAfterInputCounts() {
        let monitor = MirrorLatencyMonitor()
        monitor.recordInput(at: 100)
        monitor.recordArrival(at: 100.050)
        monitor.recordArrival(at: 100.090)

        let snapshot = monitor.snapshot(now: 101)
        XCTAssertEqual(snapshot.inputToFrameMilliseconds, 50, accuracy: 0.5)
        XCTAssertEqual(snapshot.inputToFrameP95Milliseconds, 50, accuracy: 0.5)
    }

    func testIgnoresFramesThatArriveWithoutInput() {
        let monitor = MirrorLatencyMonitor()
        monitor.recordArrival(at: 100.040)

        XCTAssertEqual(monitor.snapshot(now: 101).inputToFrameMilliseconds, 0)
    }

    func testP95CoversTheRecentInputs() {
        let monitor = MirrorLatencyMonitor()
        for index in 0..<10 {
            monitor.recordInput(at: Double(index) * 10)
            monitor.recordArrival(at: Double(index) * 10 + Double(index + 1) / 100)
        }

        // 十次分别是 10…100 ms，p95 落在最大那一档。
        let snapshot = monitor.snapshot(now: 1000)
        XCTAssertEqual(snapshot.inputToFrameMilliseconds, 100, accuracy: 0.5)
        XCTAssertEqual(snapshot.inputToFrameP95Milliseconds, 100, accuracy: 0.5)
    }

    func testResetClearsPendingInput() {
        let monitor = MirrorLatencyMonitor()
        monitor.recordInput(at: 100)
        monitor.reset()
        monitor.recordArrival(at: 100.080)

        XCTAssertEqual(monitor.snapshot(now: 101).inputToFrameMilliseconds, 0)
    }
}

final class MirrorLatencyMonitorBreakdownTests: XCTestCase {
    func testSplitsInputIntoEncodeAndDecodeSegments() {
        let monitor = MirrorLatencyMonitor()
        monitor.recordInput(at: 100)
        monitor.recordFrameStart(at: 100.140)
        monitor.recordArrival(at: 100.165)

        let snapshot = monitor.snapshot(now: 101)
        XCTAssertEqual(snapshot.inputToFrameStartMilliseconds, 140, accuracy: 0.5)
        XCTAssertEqual(snapshot.decodeMilliseconds, 25, accuracy: 0.5)
        XCTAssertEqual(snapshot.inputToFrameMilliseconds, 165, accuracy: 0.5)
        XCTAssertEqual(
            snapshot.inputToFrameStartMilliseconds + snapshot.decodeMilliseconds,
            snapshot.inputToFrameMilliseconds,
            accuracy: 0.5,
            "三段必须能对上，否则 HUD 会自相矛盾"
        )
    }

    func testDecodeIsMeasuredEvenWithoutPendingInput() {
        let monitor = MirrorLatencyMonitor()
        monitor.recordFrameStart(at: 10)
        monitor.recordArrival(at: 10.012)

        let snapshot = monitor.snapshot(now: 11)
        XCTAssertEqual(snapshot.decodeMilliseconds, 12, accuracy: 0.5)
        XCTAssertEqual(snapshot.inputToFrameMilliseconds, 0, "没有操作就不该有跟手样本")
    }

    func testOnlyTheFirstFrameStartAfterInputCounts() {
        let monitor = MirrorLatencyMonitor()
        monitor.recordInput(at: 100)
        monitor.recordFrameStart(at: 100.040)
        monitor.recordArrival(at: 100.060)
        monitor.recordFrameStart(at: 100.100)
        monitor.recordArrival(at: 100.120)

        let snapshot = monitor.snapshot(now: 101)
        XCTAssertEqual(snapshot.inputToFrameStartMilliseconds, 40, accuracy: 0.5)
        XCTAssertEqual(snapshot.inputToFrameMilliseconds, 60, accuracy: 0.5)
        XCTAssertEqual(snapshot.inputSampleCount, 1)
    }

    func testArrivalBurstRatioSeparatesEvenFromClusteredFrames() {
        let even = MirrorLatencyMonitor()
        for index in 0..<10 {
            even.recordArrival(at: Double(index) * 0.016)
        }
        XCTAssertEqual(even.snapshot(now: 10).arrivalBurstRatio, 0, accuracy: 0.001)

        // 8 帧挤在 8ms 里，然后停 60ms 再来 2 帧：簇状吐帧。
        let clustered = MirrorLatencyMonitor()
        for index in 0..<8 {
            clustered.recordArrival(at: Double(index) * 0.001)
        }
        clustered.recordArrival(at: 0.068)
        clustered.recordArrival(at: 0.069)

        let ratio = clustered.snapshot(now: 10).arrivalBurstRatio
        XCTAssertGreaterThan(ratio, 0.6)
    }

    func testArrivalIntervalP95UsesGapsBetweenDecodedFrames() {
        let monitor = MirrorLatencyMonitor()
        for time in [0.0, 0.1, 0.3, 0.6, 1.0] {
            monitor.recordArrival(at: time)
        }

        XCTAssertEqual(
            monitor.snapshot(now: 2).arrivalIntervalP95Milliseconds,
            400,
            accuracy: 0.5
        )
    }

    func testEnqueueDurationsAreTracked() {
        let monitor = MirrorLatencyMonitor()
        monitor.recordEnqueue(0.001)
        monitor.recordEnqueue(0.012)

        let snapshot = monitor.snapshot(now: 1)
        XCTAssertEqual(snapshot.enqueueMilliseconds, 12, accuracy: 0.5)
        XCTAssertEqual(snapshot.enqueueP95Milliseconds, 12, accuracy: 0.5)
    }

    func testResetClearsBreakdownState() {
        let monitor = MirrorLatencyMonitor()
        monitor.recordInput(at: 100)
        monitor.recordFrameStart(at: 100.140)
        monitor.recordArrival(at: 100.165)
        monitor.recordEnqueue(0.01)
        monitor.reset()

        let snapshot = monitor.snapshot(now: 101)
        XCTAssertEqual(snapshot.inputToFrameStartMilliseconds, 0)
        XCTAssertEqual(snapshot.decodeMilliseconds, 0)
        XCTAssertEqual(snapshot.enqueueMilliseconds, 0)
        XCTAssertEqual(snapshot.arrivalBurstRatio, 0)
        XCTAssertEqual(snapshot.inputSampleCount, 0)
    }
}

