import Foundation

public enum ActionCapsuleState: Equatable, Sendable {
    /// 没设备也没 APK：胶囊不占视觉空间。
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
    public let hasAPK: Bool
    public let deviceRunning: Bool
    public let isRunning: Bool
    public let isBusy: Bool
    public let statusText: String?

    public init(
        hasAPK: Bool,
        deviceRunning: Bool,
        isRunning: Bool,
        isBusy: Bool,
        statusText: String?
    ) {
        self.hasAPK = hasAPK
        self.deviceRunning = deviceRunning
        self.isRunning = isRunning
        self.isBusy = isBusy
        self.statusText = statusText
    }
}

public enum ActionCapsuleResolver {
    public static func resolve(_ input: ActionCapsuleInput) -> ActionCapsuleState {
        if input.isBusy {
            return .busy(input.statusText ?? "正在处理…")
        }
        guard input.deviceRunning else {
            return input.hasAPK ? .waitingForDevice : .hidden
        }
        if input.isRunning { return .running }
        return input.hasAPK ? .readyToRun : .screenshotOnly
    }
}
