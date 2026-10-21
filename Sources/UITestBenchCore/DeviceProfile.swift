import Foundation

/// 一台虚拟设备的屏幕规格。
public struct DeviceProfile: Equatable, Sendable {
    public let name: String
    public let width: Int
    public let height: Int
    public let density: Int

    public init(name: String, width: Int, height: Int, density: Int) {
        self.name = name
        self.width = width
        self.height = height
        self.density = density
    }

    public static let compact = DeviceProfile(name: "小屏", width: 1080, height: 2340, density: 420)
    public static let standard = DeviceProfile(name: "主流", width: 1080, height: 2400, density: 420)
    public static let large = DeviceProfile(name: "大屏", width: 1440, height: 3120, density: 560)

    public static let presets: [DeviceProfile] = [compact, standard, large]
}
