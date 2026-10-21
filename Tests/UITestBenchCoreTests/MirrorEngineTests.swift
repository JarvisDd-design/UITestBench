import XCTest
import CoreMedia
@testable import UITestBenchCore

final class MirrorEngineTests: XCTestCase {
    func testReportsStreamingAndDeliversFramesInOrder() async throws {
        let source = FakeMirrorFrameSource(size: MirrorVideoSize(width: 1080, height: 2400))
        source.frames = [makeFrame(width: 320, height: 240, pts: 100),
                         makeFrame(width: 320, height: 240, pts: 200)]
        let frames = FrameRecorder()
        let states = StateRecorder()

        let engine = MirrorEngine(
            source: source,
            onFrame: { frames.record($0) },
            onState: { states.record($0) }
        )
        try await engine.start()

        let ended = expectation(description: "流结束")
        DispatchQueue.global().async {
            while states.states.last != .ended {
                usleep(20_000)
            }
            ended.fulfill()
        }
        await fulfillment(of: [ended], timeout: 5)

        XCTAssertEqual(states.states.first, .starting)
        XCTAssertEqual(states.states.dropFirst().first, .streaming(width: 1080, height: 2400))
        XCTAssertEqual(frames.frames.map { CMSampleBufferGetPresentationTimeStamp($0) },
                       [CMTime(value: 100, timescale: 1_000_000),
                        CMTime(value: 200, timescale: 1_000_000)])
        XCTAssertEqual(source.stopCount, 1)
    }

    func testReportsFailureWhenSourceCannotStart() async {
        let source = FakeMirrorFrameSource(size: MirrorVideoSize(width: 1080, height: 2400))
        source.startError = FakeFailure("设备没连上")
        let states = StateRecorder()

        let engine = MirrorEngine(
            source: source,
            onFrame: { _ in },
            onState: { states.record($0) }
        )

        do {
            try await engine.start()
            XCTFail("启动失败应当抛出")
        } catch {}

        XCTAssertEqual(states.states.first, .starting)
        guard case let .failed(message)? = states.states.last else {
            return XCTFail("应以失败收尾，实际 \(states.states)")
        }
        XCTAssertTrue(message.contains("设备没连上"), message)
        XCTAssertEqual(source.stopCount, 1)
    }

    func testReportsFailureWhenDecodingBreaksMidStream() async throws {
        let source = FakeMirrorFrameSource(size: MirrorVideoSize(width: 1080, height: 2400))
        source.frames = [makeFrame(width: 320, height: 240, pts: 100)]
        source.pumpError = FakeFailure("流断了")
        let frames = FrameRecorder()
        let states = StateRecorder()

        let engine = MirrorEngine(
            source: source,
            onFrame: { frames.record($0) },
            onState: { states.record($0) }
        )
        try await engine.start()

        let failed = expectation(description: "报错")
        DispatchQueue.global().async {
            while true {
                if case .failed = states.states.last { break }
                usleep(20_000)
            }
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 5)

        XCTAssertEqual(frames.frames.count, 1)
        guard case let .failed(message)? = states.states.last else {
            return XCTFail("应以失败收尾，实际 \(states.states)")
        }
        XCTAssertTrue(message.contains("流断了"), message)
        XCTAssertEqual(source.stopCount, 1)
    }

    /// 转屏时解码出来的画面宽高会变，界面要跟着换长宽比，否则画面会被压扁。
    func testReportsNewSizeWhenFrameDimensionsChange() async throws {
        let source = FakeMirrorFrameSource(size: MirrorVideoSize(width: 320, height: 240))
        source.frames = [makeFrame(width: 320, height: 240, pts: 100),
                         makeFrame(width: 240, height: 320, pts: 200)]
        let states = StateRecorder()
        let engine = MirrorEngine(
            source: source,
            onFrame: { _ in },
            onState: { states.record($0) }
        )
        try await engine.start()

        await waitFor(states) { $0.last == .ended }

        XCTAssertEqual(states.states, [
            .starting,
            .streaming(width: 320, height: 240),
            .streaming(width: 240, height: 320),
            .ended
        ])
    }

    /// 服务端退出或 socket 断开后不能停在最后一帧，要重新拉起会话接着播。
    func testReconnectsAfterStreamEnds() async throws {
        let source = FakeRecoveringSource(
            size: MirrorVideoSize(width: 320, height: 240),
            batches: [
                [makeFrame(width: 320, height: 240, pts: 100)],
                [makeFrame(width: 320, height: 240, pts: 200)]
            ]
        )
        let frames = FrameRecorder()
        let states = StateRecorder()
        let engine = MirrorEngine(
            source: source,
            maxReconnectAttempts: 2,
            reconnectDelay: 0,
            onFrame: { frames.record($0) },
            onState: { states.record($0) }
        )
        try await engine.start()

        await waitFor(states) { $0.last == .ended }

        XCTAssertEqual(frames.frames.map { CMSampleBufferGetPresentationTimeStamp($0) },
                       [CMTime(value: 100, timescale: 1_000_000),
                        CMTime(value: 200, timescale: 1_000_000)])
        XCTAssertEqual(source.restartCount, 2, "两次流结束都要尝试重连，第二次没数据后才放弃")
        XCTAssertEqual(states.states, [
            .starting,
            .streaming(width: 320, height: 240),
            .ended
        ], "重连成功且尺寸不变时不该让界面闪一下")
    }

    func testReportsFailureWhenReconnectKeepsFailing() async throws {
        let source = FakeRecoveringSource(
            size: MirrorVideoSize(width: 320, height: 240),
            batches: [[]]
        )
        source.restartError = FakeFailure("设备掉了")
        let states = StateRecorder()
        let engine = MirrorEngine(
            source: source,
            maxReconnectAttempts: 2,
            reconnectDelay: 0,
            onFrame: { _ in },
            onState: { states.record($0) }
        )
        try await engine.start()

        await waitFor(states) { if case .failed = $0.last { return true } else { return false } }

        XCTAssertEqual(source.restartCount, 2, "重连次数要有上限，不能无限重试")
        guard case let .failed(message)? = states.states.last else {
            return XCTFail("应以失败收尾，实际 \(states.states)")
        }
        XCTAssertTrue(message.contains("设备掉了"), message)
    }

    func testStopDuringStreamEndsWithoutReportingFailure() async throws {
        let source = FakeMirrorFrameSource(size: MirrorVideoSize(width: 1080, height: 2400))
        source.blocksUntilStopped = true
        let states = StateRecorder()
        let engine = MirrorEngine(
            source: source,
            onFrame: { _ in },
            onState: { states.record($0) }
        )
        try await engine.start()
        source.waitUntilBlocked(timeout: 5)

        await engine.stop()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(source.stopCount, 1, "停止只该把 source 停一次")
        XCTAssertFalse(states.states.contains { if case .failed = $0 { return true } else { return false } },
                       "主动停止不应报失败：\(states.states)")
    }

    // MARK: - Helpers

    private func waitFor(
        _ states: StateRecorder,
        timeout: TimeInterval = 5,
        until condition: ([MirrorState]) -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(states.states) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func makeFrame(width: Int, height: Int, pts: Int64) -> DecodedFrame {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            nil, &pixelBuffer
        )
        return DecodedFrame(
            pixelBuffer: pixelBuffer!,
            pts: CMTime(value: pts, timescale: 1_000_000)
        )
    }
}

private struct FakeFailure: Error, LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

private final class StateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MirrorState] = []

    var states: [MirrorState] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func record(_ state: MirrorState) {
        lock.lock(); defer { lock.unlock() }
        storage.append(state)
    }
}

private final class FrameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CMSampleBuffer] = []

    var frames: [CMSampleBuffer] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func record(_ sample: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        storage.append(sample)
    }
}

final class FakeMirrorFrameSource: MirrorFrameSource, @unchecked Sendable {
    let size: MirrorVideoSize
    var frames: [DecodedFrame] = []
    var startError: Error?
    var pumpError: Error?
    var blocksUntilStopped = false
    private(set) var stopCount = 0

    private let lock = NSLock()
    private let blocked = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    init(size: MirrorVideoSize) {
        self.size = size
    }

    func start() async throws -> MirrorVideoSize {
        if let startError { throw startError }
        return size
    }

    func nextFrame() throws -> DecodedFrame? {
        lock.lock()
        if !frames.isEmpty {
            let frame = frames.removeFirst()
            lock.unlock()
            return frame
        }
        if let pumpError { lock.unlock(); throw pumpError }
        if blocksUntilStopped {
            lock.unlock()
            blocked.signal()
            release.wait()
            return nil
        }
        lock.unlock()
        return nil
    }

    func stop() async {
        lock.lock()
        stopCount += 1
        lock.unlock()
        release.signal()
    }

    func waitUntilBlocked(timeout: TimeInterval) {
        _ = blocked.wait(timeout: .now() + timeout)
    }
}

/// 每批帧代表一次会话；一批发完返回 nil，引擎应当在这里重连并切到下一批。
final class FakeRecoveringSource: MirrorRecoveringFrameSource, @unchecked Sendable {
    let size: MirrorVideoSize
    private var batches: [[DecodedFrame]]
    private var batchIndex = 0
    private var pending: [DecodedFrame] = []
    private(set) var restartCount = 0
    private(set) var stopCount = 0
    var restartError: Error?

    private let lock = NSLock()

    init(size: MirrorVideoSize, batches: [[DecodedFrame]]) {
        self.size = size
        self.batches = batches
    }

    func start() async throws -> MirrorVideoSize {
        lock.lock()
        pending = batches.isEmpty ? [] : batches[0]
        lock.unlock()
        return size
    }

    func nextFrame() throws -> DecodedFrame? {
        lock.lock()
        defer { lock.unlock() }
        return pending.isEmpty ? nil : pending.removeFirst()
    }

    func restart() async throws -> MirrorVideoSize {
        lock.lock()
        restartCount += 1
        let error = restartError
        lock.unlock()
        if let error { throw error }

        lock.lock()
        batchIndex += 1
        pending = batchIndex < batches.count ? batches[batchIndex] : []
        lock.unlock()
        return size
    }

    func stop() async {
        lock.lock()
        stopCount += 1
        lock.unlock()
    }
}
