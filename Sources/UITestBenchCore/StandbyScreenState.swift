import Foundation

public enum StandbyScreenState: Equatable, Sendable {
    case starting
    case failed(String)
    case needsAPK
    case readyToStart
    /// 设备已经起来，但画面流还没接上。
    case connecting
}

public struct StandbyScreenInput: Equatable, Sendable {
    public let isStarting: Bool
    public let failure: String?
    public let hasAPK: Bool
    public let deviceRunning: Bool

    public init(isStarting: Bool, failure: String?, hasAPK: Bool, deviceRunning: Bool) {
        self.isStarting = isStarting
        self.failure = failure
        self.hasAPK = hasAPK
        self.deviceRunning = deviceRunning
    }
}

public enum StandbyScreenStateResolver {
    public static func resolve(_ input: StandbyScreenInput) -> StandbyScreenState {
        if input.isStarting { return .starting }
        if let failure = input.failure, !input.deviceRunning { return .failed(failure) }
        if input.deviceRunning { return .connecting }
        return input.hasAPK ? .readyToStart : .needsAPK
    }
}
