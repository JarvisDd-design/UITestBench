import Foundation
import SwiftUI
import UITestBenchCore

/// 设备起来之后「把包跑起来」这一层：运行、清数据重开、完全重装。
/// 命令顺序全部在 `AppRunner` 里，这里只管界面状态与动作互斥。
@MainActor
final class RunModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working(String)
        case running
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// 应用看到的设备 ID 等身份信息。应用启动后才有，停了就清掉。
    @Published private(set) var identity: DeviceIdentity?

    private var runner: AppRunner?
    private var identityReader: DeviceIdentityReader?
    private var currentTask: Task<Void, Never>?
    private var identityTask: Task<Void, Never>?

    var isBusy: Bool {
        if case .working = phase { return true }
        return false
    }

    var isRunning: Bool {
        phase == .running
    }

    var statusText: String? {
        switch phase {
        case let .working(text): return text
        case let .failed(text): return text
        default: return nil
        }
    }

    var failureText: String? {
        if case let .failed(text) = phase { return text }
        return nil
    }

    func attach(serial: String, sdkDirectory: URL) {
        runner = AppRunner(
            lifecycle: AppLifecycle(sdkDirectory: sdkDirectory, serial: serial)
        )
        identityReader = DeviceIdentityReader(
            sdkDirectory: sdkDirectory,
            serial: serial
        )
        phase = .idle
        identity = nil
    }

    func detach() {
        currentTask?.cancel()
        currentTask = nil
        identityTask?.cancel()
        identityTask = nil
        runner = nil
        identityReader = nil
        identity = nil
        phase = .idle
    }

    /// 手动重新读一次。应用可能在看隐私协议之后才读取 Android ID。
    func refreshIdentity(packageName: String?) {
        guard let packageName else { return }
        loadIdentity(packageName: packageName)
    }

    private func loadIdentity(packageName: String) {
        guard let identityReader else { return }
        identityTask?.cancel()
        identityTask = Task {
            let value = try? await identityReader.read(packageName: packageName)
            guard !Task.isCancelled else { return }
            identity = value
        }
    }

    func reset() {
        guard !isBusy else { return }
        phase = .idle
        identityTask?.cancel()
        identity = nil
    }

    /// 运行 = 装包 + 清数据 + 启动。每次都是真正的「第一次打开」，引导页不会漏。
    func run(_ apk: AcquiredAPK) {
        perform(text: "正在安装、清数据并启动…", packageName: apk.info.packageName) {
            try await $0.run(apk)
        }
    }

    /// 保留数据重启：核对「非首次打开」的界面时用。
    func resume(_ apk: AcquiredAPK) {
        perform(text: "正在保留数据重启…", packageName: apk.info.packageName) {
            try await $0.resume(apk)
        }
    }

    func restartClearingData(_ apk: AcquiredAPK) {
        perform(text: "正在清数据并重新启动…", packageName: apk.info.packageName) {
            try await $0.restartClearingData(apk)
        }
    }

    func reinstall(_ apk: AcquiredAPK) {
        perform(text: "正在完全重装…", packageName: apk.info.packageName) {
            try await $0.reinstall(apk)
        }
    }

    private func perform(
        text: String,
        packageName: String?,
        _ body: @escaping (AppRunner) async throws -> Void
    ) {
        guard let runner, !isBusy else { return }
        phase = .working(text)
        currentTask = Task {
            do {
                try await body(runner)
                guard !Task.isCancelled else { return }
                phase = .running
                if let packageName { loadIdentity(packageName: packageName) }
            } catch is CancellationError {
                // 设备停了，界面状态由 detach() 负责。
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(Self.message(for: error))
            }
        }
    }

    private static func message(for error: Error) -> String {
        if let error = error as? AppRunnerError { return error.explanation }
        if let error = error as? AppLifecycleError { return error.explanation }
        return error.localizedDescription
    }
}
