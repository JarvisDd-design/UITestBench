import XCTest
@testable import UITestBenchCore

final class CommandRunnerTests: XCTestCase {
    /// 命令不能跟着应用的工作目录走：桌面/iCloud 目录下 getcwd 可能卡很久，
    /// adb 与 emulator 也从不依赖 CWD。
    func testRunsCommandFromRootRegardlessOfProcessWorkingDirectory() async throws {
        let result = try await ProcessCommandRunner().run(
            URL(fileURLWithPath: "/bin/pwd"),
            []
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "/")
    }

    func testLauncherAppliesEnvironmentAndWritesChildOutputToLog() throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("launcher-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: logURL) }

        let launcher = ProcessLauncher(outputURL: logURL)
        _ = try launcher.launch(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo avd=$ANDROID_AVD_HOME"],
            environment: ["ANDROID_AVD_HOME": "/tmp/我们的avd"]
        )

        let deadline = Date().addingTimeInterval(5)
        var text = ""
        while Date() < deadline {
            text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            if text.contains("avd=") { break }
            usleep(50_000)
        }
        XCTAssertTrue(text.contains("avd=/tmp/我们的avd"), text)
    }

    /// `screencap -p` 吐的是 PNG 原始字节，按 UTF-8 解码会在 0x89、0x00 这些
    /// 位置损坏数据。这条路径必须二进制安全，并且 stderr 不能混进 stdout。
    func testRunDataPreservesBinaryOutput() async throws {
        let result = try await ProcessCommandRunner().runData(
            URL(fileURLWithPath: "/bin/bash"),
            ["-c", "printf '\\211PNG\\r\\n\\032\\n\\000\\377'"]
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(
            [UInt8](result.stdout),
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF]
        )
    }

    func testRunDataKeepsStderrSeparate() async throws {
        let result = try await ProcessCommandRunner().runData(
            URL(fileURLWithPath: "/bin/bash"),
            ["-c", "printf out; printf '出错了' >&2"]
        )

        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "out")
        XCTAssertTrue(result.stderr.contains("出错了"), result.stderr)
    }

    /// 超过管道缓冲区（64 KB）的输出必须先被读走，否则子进程写满就卡住，
    /// 等它退出再读是死锁——打印大段 dumpsys 时就会这样。
    func testLargeOutputDoesNotDeadlock() async throws {
        let result = try await ProcessCommandRunner().run(
            URL(fileURLWithPath: "/bin/bash"),
            ["-c", "head -c 300000 /dev/zero | tr '\\0' a"]
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.count, 300_000)
    }

    func testLargeBinaryOutputDoesNotDeadlock() async throws {
        let result = try await ProcessCommandRunner().runData(
            URL(fileURLWithPath: "/bin/bash"),
            ["-c", "head -c 300000 /dev/zero"]
        )

        XCTAssertEqual(result.stdout.count, 300_000)
    }

    func testReportsExitStatusAndOutput() async throws {
        let result = try await ProcessCommandRunner().run(
            URL(fileURLWithPath: "/bin/sh"),
            ["-c", "echo 出错了; exit 3"]
        )

        XCTAssertEqual(result.status, 3)
        XCTAssertTrue(result.output.contains("出错了"), result.output)
    }
}
