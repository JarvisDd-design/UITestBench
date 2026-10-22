import CoreImage
import Foundation

public enum QRCodeDecodingError: Error, Equatable, Sendable {
    /// 数据不是能解出来的图片。
    case unreadableImage
}

/// 从一张图片里取出二维码，并按离画面中心从近到远排列。
///
/// 只负责「读出来」，不判断内容是不是下载地址；链接校验交给
/// `DownloadLinkParser`，这样静态截图和实时屏幕扫描能共用同一套规则。
public enum QRCodeDecoder {
    public static func payloads(from imageData: Data) throws -> [String] {
        try candidates(from: imageData).map(\.payload)
    }

    /// 兼容旧调用：取离画面中心最近、且能解析成下载链接的二维码。
    public static func downloadURL(from imageData: Data) -> URL? {
        guard let candidates = try? candidates(from: imageData) else { return nil }
        return candidates.lazy.compactMap { DownloadLinkParser.parse($0.payload)?.url }.first
    }

    static func candidates(from imageData: Data) throws -> [BarcodeCandidate] {
        guard let cgImage = OrientedImage.cgImage(from: imageData) else {
            throw QRCodeDecodingError.unreadableImage
        }

        let prepared = upscaledIfNeeded(cgImage)
        let detector = VisionBarcodeDetector()
        var candidates = (try? detector.detect(in: .cgImage(prepared))) ?? []

        // Vision 偶尔会漏掉特别规整/特别小的静态码，CIDetector 作为第二意见。
        if candidates.isEmpty {
            candidates = cidDetectorCandidates(in: prepared)
        }

        return ScanCandidateSelector.ranked(from: candidates)
    }

    /// 静态截图里二维码常常只占一小块；短边偏小时先放大再识别。
    private static func upscaledIfNeeded(_ image: CGImage) -> CGImage {
        let shortest = min(image.width, image.height)
        guard shortest < 600 else { return image }

        let source = CIImage(cgImage: image)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: 2, y: 2))
        return CIContext().createCGImage(scaled, from: scaled.extent) ?? image
    }

    private static func cidDetectorCandidates(in image: CGImage) -> [BarcodeCandidate] {
        let ciImage = CIImage(cgImage: image)
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return [] }

        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        guard let features = detector?.features(in: ciImage) as? [CIQRCodeFeature] else {
            return []
        }

        return features.compactMap { feature in
            guard let payload = feature.messageString else { return nil }
            let box = feature.bounds
            return BarcodeCandidate(
                payload: payload,
                boundingBox: CGRect(
                    x: (box.minX - extent.minX) / extent.width,
                    y: (box.minY - extent.minY) / extent.height,
                    width: box.width / extent.width,
                    height: box.height / extent.height
                )
            )
        }
    }
}
