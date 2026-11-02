import Foundation

/// 画面编码档位。两档都对用户可见：设计同事在大屏机型上遇到卡顿时，
/// 可以自己切到流畅档，不用等我们改代码。
public enum MirrorQualityMode: String, CaseIterable, Equatable, Sendable {
    /// 30fps：省 CPU，适合大屏机型或模拟器软编码吃紧时。
    case smooth
    /// 60fps：小屏机型的默认档，画面更跟手但更吃 CPU。
    case sharp

    public static let userDefaultsKey = "UITestBench.mirrorQuality"

    public var maxFPS: Int {
        switch self {
        case .smooth: return 30
        case .sharp: return 60
        }
    }

    /// 发给编码器的长边像素上限，是延迟最大的杠杆：模拟器是软编码，
    /// 单帧耗时基本跟像素数成正比。1.4.x 一直吃服务端默认的 1920
    /// （1080×2400 的设备出来是 864×1920），等于把最贵那档当成唯一档。
    public var maxSize: Int {
        switch self {
        case .smooth: return 1280
        case .sharp: return 1920
        }
    }

    /// 码率跟着分辨率和帧率一起降。像素少了一半还硬撑 8Mbps，只是让
    /// 编码器把时间花在没人看得见的细节上。
    public var videoBitRate: Int {
        switch self {
        case .smooth: return 4_000_000
        case .sharp: return 6_000_000
        }
    }

    /// 追加到服务端启动参数里；服务端 5.0.1 认识这三个键。
    public var startupArguments: [String] {
        ["max_size=\(maxSize)", "max_fps=\(maxFPS)", "video_bit_rate=\(videoBitRate)"]
    }

    public var title: String {
        switch self {
        case .smooth: return "流畅"
        case .sharp: return "清晰"
        }
    }

    public var detail: String {
        switch self {
        case .smooth: return "30fps · 长边 1280 · 更跟手"
        case .sharp: return "60fps · 长边 1920 · 更清楚，更吃 CPU"
        }
    }

    /// 短边 ≥ 1440 的机型（「大屏」预设）像素是主流机型的 1.7 倍，
    /// 模拟器软编码跑不满 60fps，默认给流畅档。
    public static func defaultMode(for profile: DeviceProfile) -> MirrorQualityMode {
        min(profile.width, profile.height) >= 1440 ? .smooth : .sharp
    }
}

/// 读写用户选的档位；没选过就是 nil，表示跟随当前机型的默认档。
public struct MirrorQualityPreference {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var storedMode: MirrorQualityMode? {
        get {
            defaults.string(forKey: MirrorQualityMode.userDefaultsKey)
                .flatMap(MirrorQualityMode.init(rawValue:))
        }
        nonmutating set {
            if let newValue {
                defaults.set(newValue.rawValue, forKey: MirrorQualityMode.userDefaultsKey)
            } else {
                defaults.removeObject(forKey: MirrorQualityMode.userDefaultsKey)
            }
        }
    }

    public func mode(for profile: DeviceProfile) -> MirrorQualityMode {
        storedMode ?? .defaultMode(for: profile)
    }
}
