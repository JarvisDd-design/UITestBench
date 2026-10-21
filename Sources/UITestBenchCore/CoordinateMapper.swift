import CoreGraphics

/// 视图坐标 ↔ 设备坐标。
///
/// 画面等比缩放、居中，四周留黑边；点的位置落在黑边上时不产生点击。
public struct CoordinateMapper: Equatable {
    public let viewSize: CGSize
    public let deviceSize: CGSize

    public init(viewSize: CGSize, deviceSize: CGSize) {
        self.viewSize = viewSize
        self.deviceSize = deviceSize
    }

    /// 画面在视图里的实际显示区域，用于画手机外框、定位冻结截图。
    public var contentRect: CGRect {
        guard scale > 0 else { return .zero }
        let size = CGSize(width: deviceSize.width * scale, height: deviceSize.height * scale)
        return CGRect(
            x: (viewSize.width - size.width) / 2,
            y: (viewSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// 视图点 → 设备点；落在黑边上返回 nil。
    public func devicePoint(from viewPoint: CGPoint) -> CGPoint? {
        guard scale > 0 else { return nil }
        let rect = contentRect
        // 用闭区间判断：点正好压在画面边缘时仍然算有效。
        guard viewPoint.x >= rect.minX, viewPoint.x <= rect.maxX,
              viewPoint.y >= rect.minY, viewPoint.y <= rect.maxY
        else { return nil }

        return CGPoint(
            x: (viewPoint.x - rect.minX) / scale,
            y: (viewPoint.y - rect.minY) / scale
        )
    }

    /// 设备点 → 视图点，用于把标注坐标贴回画面。
    public func viewPoint(from devicePoint: CGPoint) -> CGPoint? {
        guard scale > 0 else { return nil }
        let rect = contentRect
        guard devicePoint.x >= 0, devicePoint.x <= deviceSize.width,
              devicePoint.y >= 0, devicePoint.y <= deviceSize.height
        else { return nil }

        return CGPoint(
            x: rect.minX + devicePoint.x * scale,
            y: rect.minY + devicePoint.y * scale
        )
    }

    /// 转屏：交换设备宽高，重新按视图计算缩放与留白。
    public func rotated() -> CoordinateMapper {
        CoordinateMapper(
            viewSize: viewSize,
            deviceSize: CGSize(width: deviceSize.height, height: deviceSize.width)
        )
    }

    /// 等比缩放系数；视图或设备尺寸非法时为 0，表示「还不能映射」。
    public var scale: CGFloat {
        guard viewSize.width > 0, viewSize.height > 0,
              deviceSize.width > 0, deviceSize.height > 0
        else { return 0 }
        return min(viewSize.width / deviceSize.width, viewSize.height / deviceSize.height)
    }
}
