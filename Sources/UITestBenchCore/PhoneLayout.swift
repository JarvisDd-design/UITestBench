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
        guard available.width > 0, available.height > 0,
              profile.width > 0, profile.height > 0
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
        let widthScale = maxScreenWidth / CGFloat(profile.width)
        let scale = min(heightScale, widthScale)

        let screenWidth = (CGFloat(profile.width) * scale).rounded()
        let screenHeight = (CGFloat(profile.height) * scale).rounded()
        return PhoneLayout(
            screenSize: CGSize(width: screenWidth, height: screenHeight),
            cornerRadius: (screenWidth * cornerRadiusRatio).rounded(),
            bezel: bezel
        )
    }
}
