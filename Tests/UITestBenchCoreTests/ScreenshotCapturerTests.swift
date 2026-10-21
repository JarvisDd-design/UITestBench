import XCTest
@testable import UITestBenchCore

final class ScreenshotCapturerTests: XCTestCase {
    private let sdk = URL(fileURLWithPath: "/tmp/fake-sdk", isDirectory: true)
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03])

    private func capturer(_ runner: FakeDataRunner) -> ScreenshotCapturer {
        ScreenshotCapturer(sdkDirectory: sdk, serial: "emulator-5554", runner: runner)
    }

    func testReturnsPNGBytesFromScreencap() async throws {
        let runner = FakeDataRunner(
            result: CommandDataResult(status: 0, stdout: png, stderr: "")
        )

        let data = try await capturer(runner).capture()

        XCTAssertEqual(data, png)
        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(call.executable, sdk.appendingPathComponent("platform-tools/adb"))
        XCTAssertEqual(
            call.arguments,
            ["-s", "emulator-5554", "exec-out", "screencap", "-p"]
        )
    }

    func testReportsAdbFailureWithDetail() async throws {
        let runner = FakeDataRunner(
            result: CommandDataResult(
                status: 1,
                stdout: Data(),
                stderr: "error: device 'emulator-5554' not found\n"
            )
        )

        do {
            _ = try await capturer(runner).capture()
            XCTFail("adb 失败时应当抛错")
        } catch {
            guard case let .captureFailed(detail) = error as? ScreenshotError else {
                return XCTFail("意外的错误：\(error)")
            }
            XCTAssertTrue(detail.contains("not found"), detail)
            XCTAssertTrue(
                (error as? ScreenshotError)?.explanation.contains("截图失败") == true
            )
        }
    }

    /// 设备掉线时 adb 会把错误写进 stdout，状态码仍是 0；只能靠 PNG 头识别。
    func testRejectsOutputWithoutPNGSignature() async throws {
        let runner = FakeDataRunner(
            result: CommandDataResult(
                status: 0,
                stdout: Data("error: closed".utf8),
                stderr: ""
            )
        )

        do {
            _ = try await capturer(runner).capture()
            XCTFail("不是 PNG 的输出应当被拒绝")
        } catch {
            XCTAssertEqual(error as? ScreenshotError, .invalidPNG)
        }
    }
}

/// 只返回预设结果、记下调用的假件。
final class FakeDataRunner: DataCommandRunning, @unchecked Sendable {
    struct Call: Equatable {
        let executable: URL
        let arguments: [String]
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private let result: CommandDataResult

    init(result: CommandDataResult) {
        self.result = result
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    func runData(_ executable: URL, _ arguments: [String]) async throws -> CommandDataResult {
        lock.lock()
        _calls.append(Call(executable: executable, arguments: arguments))
        lock.unlock()
        return result
    }
}
