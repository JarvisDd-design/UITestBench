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

    /// 与哪个预设的屏幕规格一致；自定义分辨率返回 nil。
    ///
    /// 只比宽高和密度，不比名字：旧版本写进 `config.ini` 的 `avd.profile.name`
    /// 可能是「主流」之外的叫法，但屏幕规格仍然是同一个预设。
    public static func presetIndex(matching profile: DeviceProfile) -> Int? {
        presets.firstIndex {
            $0.width == profile.width
                && $0.height == profile.height
                && $0.density == profile.density
        }
    }
}
