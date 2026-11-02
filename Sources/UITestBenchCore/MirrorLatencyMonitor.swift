import Foundation

/// 一次延迟测量的快照，只给隐藏 HUD（⌥⌘L）和回归用例用。
///
/// 字段按「操作 → 画面」这条链路的顺序排列，方便直接看出时间花在哪一段：
///
/// ```
/// 用户操作 ──①──> 帧字节收齐 ──②──> 解码完成 ──③──> 入队上屏
///         inputToFrameStart      decode        latency
/// ```
///
/// ①包含本机发控制消息、adb 转发、Android 输入分发、应用重绘、合成、
/// MediaCodec 编码、回传；②是 VideoToolbox 解码；③是本机槽位等待加显示层。
public struct MirrorLatencySnapshot: Equatable, Sendable {
    /// 最近一秒实际显示出来的帧数。画面不变时 scrcpy 不产帧，这个数可以是 0。
    public let fps: Double
    /// 最近一帧从解码完成到送上屏幕的毫秒数（第③段）。
    public let latestLatencyMilliseconds: Double
    /// 最近 `windowSize` 帧第③段的 p95。
    public let latencyP95Milliseconds: Double
    /// 最近两次显示之间的间隔。
    public let displayIntervalMilliseconds: Double
    /// 最近 `windowSize` 个显示间隔的 p95。
    public let displayIntervalP95Milliseconds: Double
    /// 最近一次「操作 → 画面动」的毫秒数，也就是用户真正感觉到的跟手程度（①②之和）。
    public let inputToFrameMilliseconds: Double
    /// 最近 `windowSize` 次跟手延迟的 p95。
    public let inputToFrameP95Milliseconds: Double
    /// 最近一次「操作 → 帧字节收齐」（第①段）。
    public let inputToFrameStartMilliseconds: Double
    public let inputToFrameStartP95Milliseconds: Double
    /// 最近一次「帧字节收齐 → 解码完成」（第②段）。
    public let decodeMilliseconds: Double
    public let decodeP95Milliseconds: Double
    /// 最近一次喂帧循环把帧塞进显示层花的时间。它不在这条链路的计时里，
    /// 但一旦变大就会拖住下一帧的取用。
    public let enqueueMilliseconds: Double
    public let enqueueP95Milliseconds: Double
    /// 最近 `windowSize` 次解码完成间隔的 p95。
    public let arrivalIntervalP95Milliseconds: Double
    /// 相邻两帧解码完成间隔 < 2ms 的比例。持续偏高说明上游是一簇一簇地吐帧，
    /// 典型的反压特征。
    public let arrivalBurstRatio: Double
    /// 跟手延迟的样本数；0 表示还没有「操作 → 画面动」的记录。
    public let inputSampleCount: Int
    public let sampleCount: Int

    public static let empty = MirrorLatencySnapshot(
        fps: 0,
        latestLatencyMilliseconds: 0,
        latencyP95Milliseconds: 0,
        displayIntervalMilliseconds: 0,
        displayIntervalP95Milliseconds: 0,
        inputToFrameMilliseconds: 0,
        inputToFrameP95Milliseconds: 0,
        inputToFrameStartMilliseconds: 0,
        inputToFrameStartP95Milliseconds: 0,
        decodeMilliseconds: 0,
        decodeP95Milliseconds: 0,
        enqueueMilliseconds: 0,
        enqueueP95Milliseconds: 0,
        arrivalIntervalP95Milliseconds: 0,
        arrivalBurstRatio: 0,
        inputSampleCount: 0,
        sampleCount: 0
    )
}

/// 记录「一帧到达 → 真的送上屏幕」的延迟与显示间隔。
///
/// 只认真正被显示层取走的帧：解码出来但被槽位覆盖掉的帧不算，否则测出来的是
/// 解码速度而不是用户看到的跟手程度。
public final class MirrorLatencyMonitor {
    /// fps 与延迟窗口都按「最近 100 帧 / 1 秒」算，够看出趋势又不抖。
    public static let fpsWindow: TimeInterval = 1

    /// 两帧解码完成的间隔小于这个值就算「同一簇」，用于算成簇率。
    public static let burstGap: TimeInterval = 0.002

    private let windowSize: Int
    private let lock = NSLock()
    private var latencies: [Double] = []
    private var intervals: [Double] = []
    private var displayTimes: [TimeInterval] = []
    private var inputToFrames: [Double] = []
    private var inputToFrameStarts: [Double] = []
    private var decodes: [Double] = []
    private var enqueues: [Double] = []
    private var arrivalIntervals: [Double] = []
    private var latestLatency = 0.0
    private var latestInterval = 0.0
    private var latestInputToFrame = 0.0
    private var latestInputToFrameStart = 0.0
    private var latestDecode = 0.0
    private var latestEnqueue = 0.0
    private var lastDisplayTime: TimeInterval?
    private var lastArrivalTime: TimeInterval?
    private var pendingInputTime: TimeInterval?
    /// 已经等到了帧头、正在等解码完成的那个输入时刻。
    private var pendingDecodeInputTime: TimeInterval?
    /// 最近一帧字节收齐的时刻，等解码完成时用来算第②段。
    private var pendingFrameStart: TimeInterval?

    public init(windowSize: Int = 100) {
        self.windowSize = max(1, windowSize)
    }

    // MARK: - 第③段：解码完成 → 上屏

    /// 显示层取走一帧时调用。`arrival` 是这帧解码完成的时刻，`displayTime` 是
    /// 现在（同一时钟）。
    public func recordDisplay(arrival: TimeInterval, at displayTime: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }

        let latency = max(0, (displayTime - arrival) * 1000)
        latencies.append(latency)
        if latencies.count > windowSize {
            latencies.removeFirst(latencies.count - windowSize)
        }
        latestLatency = latency

        if let last = lastDisplayTime {
            let interval = max(0, (displayTime - last) * 1000)
            intervals.append(interval)
            if intervals.count > windowSize {
                intervals.removeFirst(intervals.count - windowSize)
            }
            latestInterval = interval
        }
        lastDisplayTime = displayTime
        displayTimes.append(displayTime)
    }

    /// 喂帧循环把帧交给显示层花的时间。不进链路计时，只用来排查显示层是否在拖后腿。
    public func recordEnqueue(_ duration: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        let milliseconds = max(0, duration * 1000)
        latestEnqueue = milliseconds
        enqueues.append(milliseconds)
        if enqueues.count > windowSize {
            enqueues.removeFirst(enqueues.count - windowSize)
        }
    }

    // MARK: - 第①②段：操作 → 帧头 → 解码完成

    /// 画面静止这么久之后的第一下操作才算「跟手」样本：连续拖动时每帧都紧跟
    /// 着上一条输入，量出来的是帧间隔，不是用户等的时间。
    public static let idleBeforeInput: TimeInterval = 0.15

    /// 用户按下/拖动/滚动的那一刻调用。静止之后的第一下会等下一帧到达算出延迟。
    public func recordInput(at inputTime: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard pendingInputTime == nil, pendingDecodeInputTime == nil else { return }
        guard inputTime - (lastArrivalTime ?? -.greatestFiniteMagnitude) >= Self.idleBeforeInput else {
            return
        }
        pendingInputTime = inputTime
    }

    /// 一帧的字节全部收齐、准备开始解码时调用。
    public func recordFrameStart(at frameStart: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        pendingFrameStart = frameStart
        guard let input = pendingInputTime else { return }
        pendingInputTime = nil
        pendingDecodeInputTime = input
        let latency = max(0, (frameStart - input) * 1000)
        latestInputToFrameStart = latency
        inputToFrameStarts.append(latency)
        if inputToFrameStarts.count > windowSize {
            inputToFrameStarts.removeFirst(inputToFrameStarts.count - windowSize)
        }
    }

    /// 一帧解码完成时调用。只记输入之后的第一帧：后面的帧是这次操作的
    /// 后续动画，再算一遍只会把数字越摊越小。
    public func recordArrival(at arrival: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }

        if let start = pendingFrameStart {
            let decode = max(0, (arrival - start) * 1000)
            latestDecode = decode
            decodes.append(decode)
            if decodes.count > windowSize {
                decodes.removeFirst(decodes.count - windowSize)
            }
            pendingFrameStart = nil
        }

        if let last = lastArrivalTime {
            let gap = max(0, arrival - last)
            arrivalIntervals.append(gap * 1000)
            if arrivalIntervals.count > windowSize {
                arrivalIntervals.removeFirst(arrivalIntervals.count - windowSize)
            }
            if gap < Self.burstGap {
                burstCount += 1
            }
            gapCount += 1
        }
        lastArrivalTime = arrival

        // 没收到帧头打点就直接来了解码完成（比如假件、或者诊断钩子没挂上），
        // 仍然记一次跟手，只是分不出解码那一段。
        if pendingDecodeInputTime == nil, let inlineInput = pendingInputTime {
            pendingInputTime = nil
            pendingDecodeInputTime = inlineInput
        }

        guard let input = pendingDecodeInputTime else { return }
        pendingDecodeInputTime = nil
        let latency = max(0, (arrival - input) * 1000)
        latestInputToFrame = latency
        inputToFrames.append(latency)
        if inputToFrames.count > windowSize {
            inputToFrames.removeFirst(inputToFrames.count - windowSize)
        }
    }

    private var burstCount = 0
    private var gapCount = 0

    public func reset() {
        lock.lock()
        latencies.removeAll()
        intervals.removeAll()
        displayTimes.removeAll()
        inputToFrames.removeAll()
        inputToFrameStarts.removeAll()
        decodes.removeAll()
        enqueues.removeAll()
        arrivalIntervals.removeAll()
        latestLatency = 0
        latestInterval = 0
        latestInputToFrame = 0
        latestInputToFrameStart = 0
        latestDecode = 0
        latestEnqueue = 0
        lastDisplayTime = nil
        lastArrivalTime = nil
        pendingInputTime = nil
        pendingDecodeInputTime = nil
        pendingFrameStart = nil
        burstCount = 0
        gapCount = 0
        lock.unlock()
    }

    public func snapshot(now: TimeInterval) -> MirrorLatencySnapshot {
        lock.lock()
        defer { lock.unlock() }

        displayTimes.removeAll { $0 < now - Self.fpsWindow }
        return MirrorLatencySnapshot(
            fps: Double(displayTimes.filter { $0 >= now - Self.fpsWindow && $0 <= now }.count),
            latestLatencyMilliseconds: latestLatency,
            latencyP95Milliseconds: Self.percentile(latencies, 0.95),
            displayIntervalMilliseconds: latestInterval,
            displayIntervalP95Milliseconds: Self.percentile(intervals, 0.95),
            inputToFrameMilliseconds: latestInputToFrame,
            inputToFrameP95Milliseconds: Self.percentile(inputToFrames, 0.95),
            inputToFrameStartMilliseconds: latestInputToFrameStart,
            inputToFrameStartP95Milliseconds: Self.percentile(inputToFrameStarts, 0.95),
            decodeMilliseconds: latestDecode,
            decodeP95Milliseconds: Self.percentile(decodes, 0.95),
            enqueueMilliseconds: latestEnqueue,
            enqueueP95Milliseconds: Self.percentile(enqueues, 0.95),
            arrivalIntervalP95Milliseconds: Self.percentile(arrivalIntervals, 0.95),
            arrivalBurstRatio: gapCount == 0 ? 0 : Double(burstCount) / Double(gapCount),
            inputSampleCount: inputToFrames.count,
            sampleCount: latencies.count
        )
    }

    /// 最近秩（nearest-rank）分位数：样本少的时候也不会被插值抹平。
    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }
}
