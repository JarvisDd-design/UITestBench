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
    public static let verticalPadding: CGFloat = 24
    public static let capsuleHeight: CGFloat = 48
    public static let capsuleGap: CGFloat = 12
    public static let bezel: CGFloat = 7
    public static let cornerRadiusRatio: CGFloat = 0.056

    public static func layout(available: CGSize, profile: DeviceProfile) -> PhoneLayout {
        // 屏幕左右各有一条边框，可用宽度里先把它们扣掉，再与设计上限取小。
        let widthBudget = min(maxScreenWidth, max(0, available.width - bezel * 2))
        guard available.width > 0, available.height > 0,
              profile.width > 0, profile.height > 0,
              widthBudget > 0
        else {
            return PhoneLayout(screenSize: .zero, cornerRadius: 0, bezel: bezel)
        }

        // 胶囊、间距、上下留白和边框都要先扣掉，剩下的才是屏幕能用的高度。
        let usableHeight = max(
            0,
            available.height
                - verticalPadding * 2
                - capsuleHeight
                - capsuleGap
                - bezel * 2
        )
        let heightScale = usableHeight / CGFloat(profile.height)
        let widthScale = widthBudget / CGFloat(profile.width)
        let scale = min(heightScale, widthScale)

        let screenWidth = floored(CGFloat(profile.width) * scale)
        let screenHeight = floored(CGFloat(profile.height) * scale)
        return PhoneLayout(
            screenSize: CGSize(width: screenWidth, height: screenHeight),
            cornerRadius: screenWidth * cornerRadiusRatio,
            bezel: bezel
        )
    }

    /// 向下取整前先抹掉浮点乘除留下的一丝误差（如 439.99999999999994）：
    /// 宁可少半个点，也不能把手机挤出窗口。
    private static func floored(_ value: CGFloat) -> CGFloat {
        (value + 1e-9).rounded(.down)
    }
}
