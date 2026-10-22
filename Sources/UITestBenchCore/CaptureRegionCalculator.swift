import CoreGraphics
import Foundation

/// 要交给 ScreenCaptureKit 的捕获区域。
///
/// `sourceRect` 是显示器本地坐标（点，原点在左上），`pixelWidth/pixelHeight`
/// 是实际输出缓冲区的像素尺寸。Retina 下两者是 2 倍关系。
public struct CaptureRegion: Equatable, Sendable {
    public let sourceRect: CGRect
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(sourceRect: CGRect, pixelWidth: Int, pixelHeight: Int) {
        self.sourceRect = sourceRect
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// AppKit 的屏幕坐标原点在左下，ScreenCaptureKit 用显示器本地、左上原点。
/// 副屏还可能带负坐标或位于主屏上方，所以必须相对「取景框所在的那块屏」翻转。
public enum CaptureRegionCalculator {
    public static func region(
        panelFrame: CGRect,
        screenFrame: CGRect,
        backingScale: CGFloat
    ) -> CaptureRegion? {
        let visible = panelFrame.intersection(screenFrame)
        guard !visible.isNull, visible.width >= 1, visible.height >= 1 else {
            return nil
        }

        let scale = backingScale > 0 ? backingScale : 1
        return CaptureRegion(
            sourceRect: CGRect(
                x: visible.minX - screenFrame.minX,
                y: screenFrame.maxY - visible.maxY,
                width: visible.width,
                height: visible.height
            ),
            pixelWidth: Int((visible.width * scale).rounded()),
            pixelHeight: Int((visible.height * scale).rounded())
        )
    }
}
