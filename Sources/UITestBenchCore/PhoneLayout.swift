import CoreGraphics
import Foundation

/// 手机在窗口里占多大、圆角多少。纯几何，不碰视图。
public struct PhoneLayout: Equatable, Sendable {
    public let screenSize: CGSize
    public let cornerRadius: CGFloat
    public let bezel: CGFloat

    public init(screenSize: CGSize, cornerRadius: CGFloat, bezel: CGFloat) {
        self.screenSize = screenSize
        self.cornerRadius = cornerRadius
        self.bezel = bezel
    }
}

public enum PhoneLayoutCalculator {
    public static let maxScreenWidth: CGFloat = 440
    public static let minScreenWidth: CGFloat = 240
    public static let defaultScreenWidth: CGFloat = 300
    public static let verticalPadding: CGFloat = 24
    public static let capsuleHeight: CGFloat = 48
    public static let capsuleGap: CGFloat = 12
    public static let bezel: CGFloat = 7
    public static let cornerRadiusRatio: CGFloat = 0.056

    /// 窗口内容 = 手机外框。给定屏幕宽度，返回含边框的整机尺寸。
    public static func frameSize(forScreenWidth screenWidth: CGFloat, profile: DeviceProfile) -> CGSize {
        guard screenWidth > 0, profile.width > 0, profile.height > 0 else { return .zero }
        let width = floored(screenWidth)
        // 边框是常数，整机比例会与屏幕比例略有偏差；镜像画面用 aspectRatio(.fit)
        // 自行留边，这点偏差不会把画面拉变形。
        let height = floored(screenWidth * CGFloat(profile.height) / CGFloat(profile.width))
        return CGSize(width: width + bezel * 2, height: height + bezel * 2)
    }

    /// 以窗口实际内容尺寸反推屏幕尺寸；边框之外都是屏幕。
    public static func layout(frameSize: CGSize, profile: DeviceProfile) -> PhoneLayout {
        guard frameSize.width > 0, frameSize.height > 0,
              profile.width > 0, profile.height > 0
        else {
            return PhoneLayout(screenSize: .zero, cornerRadius: 0, bezel: bezel)
        }

        let width = frameSize.width - bezel * 2
        let height = frameSize.height - bezel * 2
        guard width > 0, height > 0 else {
            return PhoneLayout(screenSize: .zero, cornerRadius: 0, bezel: bezel)
        }

        return PhoneLayout(
            screenSize: CGSize(width: width, height: height),
            cornerRadius: width * cornerRadiusRatio,
            bezel: bezel
        )
    }

    /// 可见屏幕高度扣掉底胶囊、间距和上下留白后，手机屏幕最多能有多宽。
    /// 结果不会低于可用的最小宽度。
    public static func maximumScreenWidth(
        visibleSize: CGSize,
        profile: DeviceProfile
    ) -> CGFloat {
        guard visibleSize.width > 0, visibleSize.height > 0,
              profile.width > 0, profile.height > 0
        else {
            return minScreenWidth
        }

        let usableHeight = visibleSize.height
            - verticalPadding * 2
            - capsuleHeight
            - capsuleGap
            - bezel * 2
        guard usableHeight > 0 else { return minScreenWidth }

        let heightLimited = floored(
            usableHeight * CGFloat(profile.width) / CGFloat(profile.height)
        )
        let widthLimited = min(maxScreenWidth, max(0, visibleSize.width - bezel * 2))
        return max(minScreenWidth, min(heightLimited, widthLimited))
    }

    /// 向下取整前先抹掉浮点乘除留下的一丝误差（如 439.99999999999994）：
    /// 宁可少半个点，也不能把手机挤出窗口。
    private static func floored(_ value: CGFloat) -> CGFloat {
        (value + 1e-9).rounded(.down)
    }
}
