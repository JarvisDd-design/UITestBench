public enum StandbyScreenState: Equatable, Sendable {
    case starting
    case failed(String)
    case needsAPK
    case readyToStart
    /// 设备已经起来，但画面流还没接上。
    case connecting
}

public struct StandbyScreenInput: Equatable, Sendable {
    /// 设备正在启动或停止；两种过渡都先显示进度。
    public let isStarting: Bool
    /// 当前失败原因，设备运行时的画面失败也算；失败清除后必须传 nil。
    public let failure: String?
    /// 是否已经拿到可运行的 APK；不兼容的包应传 false。
    public let hasAPK: Bool
    /// 模拟器是否已经进入运行状态（启动中不算）。
    public let deviceRunning: Bool

    public init(isStarting: Bool, failure: String?, hasAPK: Bool, deviceRunning: Bool) {
        self.isStarting = isStarting
        self.failure = failure
        self.hasAPK = hasAPK
        self.deviceRunning = deviceRunning
    }
}

/// 优先级：启动/停止中 > 当前失败 > 设备已运行（等画面）> 有没有可运行的 APK。
public enum StandbyScreenStateResolver {
    public static func resolve(_ input: StandbyScreenInput) -> StandbyScreenState {
        if input.isStarting { return .starting }
        if let failure = input.failure { return .failed(failure) }
        if input.deviceRunning { return .connecting }
        return input.hasAPK ? .readyToStart : .needsAPK
    }
}
