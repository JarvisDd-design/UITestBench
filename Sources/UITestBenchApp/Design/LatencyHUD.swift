import SwiftUI
import UITestBenchCore

/// 隐藏的诊断浮层：⌥⌘L 开合，只看延迟与丢帧，不进正式界面。
///
/// 布局按链路顺序排，一行一段，方便一眼看出时间花在哪：
///
/// ```
/// 用户操作 ──①──> 帧字节收齐 ──②──> 解码完成 ──③──> 上屏
///           编码前           解码          上屏
/// ```
struct LatencyHUD: View {
    let report: MirrorHUDReport

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("fps \(Self.number(snapshot.fps, decimals: 1)) · 间隔 p95 \(ms(snapshot.displayIntervalP95Milliseconds, samples: snapshot.sampleCount))")
            Text("跟手 \(ms(snapshot.inputToFrameMilliseconds, samples: inputSamples)) p95 \(ms(snapshot.inputToFrameP95Milliseconds, samples: inputSamples))\(breakdown)")
            Text("编码前 \(ms(snapshot.inputToFrameStartMilliseconds, samples: startSamples)) p95 \(ms(snapshot.inputToFrameStartP95Milliseconds, samples: startSamples)) · 解码 \(ms(snapshot.decodeMilliseconds, samples: decodeSamples))")
            Text("上屏 \(ms(snapshot.latestLatencyMilliseconds, samples: snapshot.sampleCount)) · 入队 \(ms(snapshot.enqueueMilliseconds, samples: snapshot.sampleCount))")
            Text("到达 p95 \(ms(snapshot.arrivalIntervalP95Milliseconds, samples: snapshot.sampleCount)) · 成簇 \(percent(snapshot.arrivalBurstRatio)) · 缓冲 \(backlog)")
            Text("丢帧 \(report.droppedFrames) · \(report.quality.title) \(report.quality.maxFPS)fps")
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(Color.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
        .padding(6)
        .allowsHitTesting(false)
    }

    private var snapshot: MirrorLatencySnapshot { report.snapshot }

    /// 跟手 = 编码前 + 解码，把两端的小数一起摊到同一格显示，省一行。
    private var breakdown: String {
        guard inputSamples > 0 else { return "" }
        let head = Int(snapshot.inputToFrameStartMilliseconds.rounded())
        let decode = Int(snapshot.decodeMilliseconds.rounded())
        return " (=\(head)+\(decode))"
    }

    private var inputSamples: Int { snapshot.inputSampleCount }

    /// 编码前 / 解码两段跟「操作」同源，样本数不到就没有意义；这里用跟手样本数兜底，
    /// 因为三段是同一个输入触发的。
    private var startSamples: Int {
        snapshot.inputToFrameStartMilliseconds > 0 ? inputSamples : 0
    }

    private var decodeSamples: Int {
        snapshot.decodeMilliseconds > 0 ? max(inputSamples, 1) : 0
    }

    private var backlog: String {
        let kilobytes = Double(report.backlogBytes) / 1024
        return kilobytes < 1 ? "\(report.backlogBytes)B" : String(format: "%.0fK", kilobytes)
    }

    private static func number(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }

    /// 还没有样本时显示「—」，别报一个假的 0ms。
    private func ms(_ value: Double, samples: Int) -> String {
        samples == 0 ? "—" : "\(Int(value.rounded()))ms"
    }

    private func percent(_ value: Double) -> String {
        report.snapshot.sampleCount < 2 ? "—" : "\(Int((value * 100).rounded()))%"
    }
}
