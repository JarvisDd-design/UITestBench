import AppKit
import CoreGraphics

/// 屏幕录制授权的薄封装。
///
/// 系统只有「有没有」两态：第一次请求时即使立刻点了允许，本次进程也拿不到
/// 画面，必须重启应用。界面据此给用户中文解释，不把 TCC 术语甩出去。
enum ScreenCapturePermission {
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 第一次调用会弹系统授权窗；之前拒绝过就只返回 false，不再弹窗。
    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openSystemSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )!
        NSWorkspace.shared.open(url)
    }

    /// 清掉本应用在 TCC 里的屏幕录制记录。
    ///
    /// ad-hoc 重签后 cdhash 会变，系统设置里那条旧记录的开关看着是开的，
    /// 新进程却永远 preflight 不到。系统没有 API 能修这种错位，只能用
    /// `tccutil` 删掉本应用自己的记录，重启后重新授权。
    ///
    /// 只接受明确的 bundle id，绝不执行不带 id 的全量重置。
    static func reset() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "ScreenCapture", bundleID]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
