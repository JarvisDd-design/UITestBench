import CoreImage
import CoreVideo
import Foundation
import Vision

/// 用 Vision 找二维码。
///
/// 优先走系统默认 revision；本帧一个都没找到时，再试一次反色画面，
/// 覆盖暗色主题里「白模块黑底」的码。倒置只发生在没结果的帧上，
/// 正常画面不会多付一次检测成本。
public struct VisionBarcodeDetector: BarcodeDetecting {
    /// 每次反色都新建 `CIContext` 会拖慢实时扫描；同一个 context 可以跨线程复用。
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    public init() {}

    public func detect(in image: ScanImage) throws -> [BarcodeCandidate] {
        if let candidates = try detectOnce(in: image), !candidates.isEmpty {
            return candidates
        }
        guard let inverted = invertedImage(from: image),
              let candidates = try detectOnce(in: .cgImage(inverted))
        else {
            return []
        }
        return candidates
    }

    private func detectOnce(in image: ScanImage) throws -> [BarcodeCandidate]? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]

        let handler: VNImageRequestHandler
        switch image {
        case let .pixelBuffer(buffer):
            handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        case let .cgImage(cgImage):
            handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        }

        try handler.perform([request])

        return (request.results ?? []).compactMap { observation in
            guard let payload = observation.payloadStringValue else { return nil }
            return BarcodeCandidate(
                payload: payload,
                boundingBox: observation.boundingBox
            )
        }
    }

    private func invertedImage(from image: ScanImage) -> CGImage? {
        let ciImage: CIImage
        switch image {
        case let .pixelBuffer(buffer):
            ciImage = CIImage(cvPixelBuffer: buffer)
        case let .cgImage(cgImage):
            ciImage = CIImage(cgImage: cgImage)
        }

        let inverted = ciImage.applyingFilter("CIColorInvert")
        return Self.ciContext.createCGImage(inverted, from: inverted.extent)
    }
}
