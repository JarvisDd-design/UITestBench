import CoreGraphics
import Foundation

/// 从多个二维码里选出「离取景框中心最近」的那个。
///
/// 取景框是用户亲手对准的，中心点最能代表「我想扫的是这个」。
/// 距离相同的情况必须给出稳定结果，否则相邻两帧会在两个码之间来回跳。
public enum ScanCandidateSelector {
    public static func choose(from candidates: [BarcodeCandidate]) -> BarcodeCandidate? {
        ranked(from: candidates).first
    }

    /// 按离画面中心的距离从近到远排列；平局依次比 minY、minX，都取较小者。
    public static func ranked(from candidates: [BarcodeCandidate]) -> [BarcodeCandidate] {
        candidates.sorted { lhs, rhs in
            let left = (distanceToCenter(lhs), lhs.boundingBox.minY, lhs.boundingBox.minX)
            let right = (distanceToCenter(rhs), rhs.boundingBox.minY, rhs.boundingBox.minX)
            if left.0 != right.0 { return left.0 < right.0 }
            if left.1 != right.1 { return left.1 < right.1 }
            return left.2 < right.2
        }
    }

    private static func distanceToCenter(_ candidate: BarcodeCandidate) -> CGFloat {
        let box = candidate.boundingBox
        return hypot(box.midX - 0.5, box.midY - 0.5)
    }
}
