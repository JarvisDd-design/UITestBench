import Foundation

public struct CommandResult: Equatable, Sendable {
    public let status: Int32
    public let output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}

/// 跑一次性命令（adb、emulator -version 等），返回退出码与合并后的输出。
public protocol CommandRunning: Sendable {
    func run(_ executable: URL, _ arguments: [String]) async throws -> CommandResult
}

/// 二进制输出（截图、jar 传输等）。stdout 与 stderr 必须分开：
/// 合并后 stderr 的一行警告就会把 PNG 弄坏。
public struct CommandDataResult: Equatable, Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: String

    public init(status: Int32, stdout: Data, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol DataCommandRunning: Sendable {
    func runData(_ executable: URL, _ arguments: [String]) async throws -> CommandDataResult
}

public struct ProcessCommandRunner: CommandRunning {
    private let currentDirectory: URL

    /// 固定工作目录：`Process.run()` 会读进程的 CWD，而桌面/iCloud 目录下
    /// 这一步可能卡住几十秒；adb 与 emulator 也从不依赖调用方的 CWD。
    public init(currentDirectory: URL = URL(fileURLWithPath: "/", isDirectory: true)) {
        self.currentDirectory = currentDirectory
    }

    public func run(_ executable: URL, _ arguments: [String]) async throws -> CommandResult {
        let currentDirectory = self.currentDirectory
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectory

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            // 必须先开始读，再等进程退出：输出超过管道缓冲区（64 KB）时，
            // 子进程会卡在写上，等它退出再读就是死锁（dumpsys 很容易超过）。
            let outputBox = LockedData()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                outputBox.set(pipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }

            process.terminationHandler = { process in
                group.wait()
                continuation.resume(
                    returning: CommandResult(
                        status: process.terminationStatus,
                        output: String(decoding: outputBox.value, as: UTF8.self)
                    )
                )
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

extension ProcessCommandRunner: DataCommandRunning {
    public func runData(_ executable: URL, _ arguments: [String]) async throws -> CommandDataResult {
        let currentDirectory = self.currentDirectory
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectory

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // stdout 与 stderr 必须并发读：任一边写满 64 KB 的管道缓冲区，
            // 进程就会卡住，而另一边的读取还没开始。截图动辄几百 KB，
            // 只在退出后读 stdout 会直接死锁。
            let stdoutBox = LockedData()
            let stderrBox = LockedData()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                stdoutBox.set(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                stderrBox.set(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }

            process.terminationHandler = { process in
                group.wait()
                continuation.resume(
                    returning: CommandDataResult(
                        status: process.terminationStatus,
                        stdout: stdoutBox.value,
                        stderr: String(decoding: stderrBox.value, as: UTF8.self)
                    )
                )
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForWriting.closeFile()
                stderrPipe.fileHandleForWriting.closeFile()
                continuation.resume(throwing: error)
            }
        }
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func set(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
