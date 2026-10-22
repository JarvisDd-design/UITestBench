public enum ActionCapsuleState: Equatable, Sendable {
    /// 不绘制胶囊内容，布局槽位仍然保留。
    case hidden
    /// 设备在跑，但没有 APK 可操作。
    case screenshotOnly
    /// 有 APK，但设备还没启动。
    case waitingForDevice
    /// 设备在跑、APK 已就绪、应用还没运行。
    case readyToRun
    /// 应用已经启动。
    case running
    /// 正在安装/重开/截图。
    case busy(String)
}

public struct ActionCapsuleInput: Equatable, Sendable {
    /// 是否已经拿到可运行的 APK；不兼容的包应传 false。
    public let hasAPK: Bool
    public let deviceRunning: Bool
    public let isRunning: Bool
    public let isBusy: Bool
    /// 仅在 isBusy 为真时读取，避免把上一次运行的失败文案当成进度。
    public let busyText: String?

    public init(
        hasAPK: Bool,
        deviceRunning: Bool,
        isRunning: Bool,
        isBusy: Bool,
        busyText: String?
    ) {
        self.hasAPK = hasAPK
        self.deviceRunning = deviceRunning
        self.isRunning = isRunning
        self.isBusy = isBusy
        self.busyText = busyText
    }
}

/// 优先级：进行中 > 设备是否运行 > 应用是否运行 > 有没有 APK。
public enum ActionCapsuleResolver {
    public static func resolve(_ input: ActionCapsuleInput) -> ActionCapsuleState {
        if input.isBusy {
            return .busy(input.busyText ?? "正在处理…")
        }
        guard input.deviceRunning else {
            return input.hasAPK ? .waitingForDevice : .hidden
        }
        if input.isRunning { return .running }
        return input.hasAPK ? .readyToRun : .screenshotOnly
    }
}
