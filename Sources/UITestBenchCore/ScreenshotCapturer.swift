import Foundation

public enum ScreenshotError: Error, Equatable {
    /// adb 自己报错，detail 是它的 stderr。
    case captureFailed(String)
    /// adb 退出码是 0，但拿到的不是 PNG——常见于设备中途掉线。
    case invalidPNG

    public var explanation: String {
        switch self {
        case let .captureFailed(detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "截图失败，设备没有给出原因。" : "截图失败：\(trimmed)"
        case .invalidPNG:
            return "截到的画面不是有效的 PNG，可能是设备连接断了，请重试。"
        }
    }
}

/// 从设备上抓一张当前画面。`exec-out` 不经过换行转换，PNG 原样回来。
public final class ScreenshotCapturer {
    private let sdkDirectory: URL
    private let serial: String
    private let runner: DataCommandRunning

    public init(
        sdkDirectory: URL,
        serial: String,
        runner: DataCommandRunning = ProcessCommandRunner()
    ) {
        self.sdkDirectory = sdkDirectory
        self.serial = serial
        self.runner = runner
    }

    private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    public func capture() async throws -> Data {
        let adb = sdkDirectory
            .appendingPathComponent("platform-tools", isDirectory: true)
            .appendingPathComponent("adb")
        let result = try await runner.runData(
            adb,
            ["-s", serial, "exec-out", "screencap", "-p"]
        )

        guard result.status == 0 else {
            throw ScreenshotError.captureFailed(result.stderr)
        }
        guard result.stdout.starts(with: Self.pngSignature) else {
            throw ScreenshotError.invalidPNG
        }
        return result.stdout
    }
}
