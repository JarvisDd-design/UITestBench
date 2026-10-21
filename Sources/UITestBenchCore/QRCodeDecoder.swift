import CoreImage
import Foundation

/// 从一张图片里取出二维码中的下载链接。
///
/// 只接受 http / https：二维码里也可能是普通文字或别的应用配置，那些都不该被
/// 当成「要安装的包」。
public enum QRCodeDecoder {
    public static func downloadURL(from imageData: Data) -> URL? {
        guard let image = CIImage(data: imageData) else { return nil }

        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        guard let features = detector?.features(in: image) as? [CIQRCodeFeature] else {
            return nil
        }

        // 一张图里可能有多个码；取第一个能用的。
        for feature in features {
            guard let payload = feature.messageString,
                  let url = URL(string: payload),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host?.isEmpty == false
            else {
                continue
            }
            return url
        }
        return nil
    }
}
