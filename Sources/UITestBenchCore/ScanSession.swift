import Foundation

public enum ScanOutcome: Equatable, Sendable {
    case none
    case notALink(String)
    case hit(DownloadLink)
}

/// 一帧画面 → 一个明确的结论。
///
/// 检测、选码、去重都在这里完成，App 层只负责把帧送进来、把结果画出来。
public final class ScanSession {
    private let detector: BarcodeDetecting
    private let gate: ScanHitGate
    /// 这一刻之前的帧只预热、不判定。取景框刚出现时用户还没对准，
    /// 屏幕上碰巧有码不能立刻替他做决定。
    private let startAt: TimeInterval

    public init(
        detector: BarcodeDetecting,
        gate: ScanHitGate = ScanHitGate(),
        startAt: TimeInterval = 0
    ) {
        self.detector = detector
        self.gate = gate
        self.startAt = startAt
    }

    public func process(_ image: ScanImage, at timestamp: TimeInterval) -> ScanOutcome {
        // 准备期只收帧、不检测：既省 CPU，也保证用户有完整时间判断框对准了没有。
        guard timestamp >= startAt else { return .none }

        let candidates: [BarcodeCandidate]
        do {
            candidates = try detector.detect(in: image)
        } catch {
            gate.registerNoCode()
            return .none
        }

        guard let nearest = ScanCandidateSelector.choose(from: candidates) else {
            gate.registerNoCode()
            return .none
        }

        guard let link = DownloadLinkParser.parse(nearest.payload) else {
            return gate.registerNotALink(at: timestamp) ? .notALink(nearest.payload) : .none
        }

        return gate.register(link: link, at: timestamp) ? .hit(link) : .none
    }

    public func reset() {
        gate.reset()
    }
}
