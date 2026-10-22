import CoreGraphics
import Foundation
import ImageIO

/// 把图片文件读成「方向已经摆正」的 CGImage。
///
/// iPhone 截图和部分 HEIC 带 EXIF 方向；只读像素不应用方向会让二维码
/// 被当成横躺的，检测器直接漏掉。ImageIO 的 thumbnail + transform 一次完成
/// 方向归一化和缩放，比手写旋转可靠。
public enum OrientedImage {
    public static func cgImage(from data: Data, maxPixel: CGFloat = 4096) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
