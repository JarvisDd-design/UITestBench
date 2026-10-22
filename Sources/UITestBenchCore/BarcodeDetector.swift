import CoreGraphics
import CoreVideo
import Foundation

/// 检测器要处理的两种画面：静态图片给 `CGImage`，实时帧给 `CVPixelBuffer`。
public enum ScanImage {
    case pixelBuffer(CVPixelBuffer)
    case cgImage(CGImage)
}

/// 一个二维码在画面里的位置与内容。
///
/// `boundingBox` 是归一化坐标（0…1），原点在左下，和 Vision 的输出一致；
/// 上层用它算「离取景框中心最近」。
public struct BarcodeCandidate: Equatable, Sendable {
    public let payload: String
    public let boundingBox: CGRect

    public init(payload: String, boundingBox: CGRect) {
        self.payload = payload
        self.boundingBox = boundingBox
    }
}

public protocol BarcodeDetecting {
    func detect(in image: ScanImage) throws -> [BarcodeCandidate]
}
