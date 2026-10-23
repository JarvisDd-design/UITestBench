import Foundation

public struct DownloadProgress: Equatable, Sendable {
    /// 已落盘的总字节数（续传时包含断点前的部分）。
    public let receivedBytes: Int64
    public let totalBytes: Int64?

    public init(receivedBytes: Int64, totalBytes: Int64?) {
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
    }

    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(receivedBytes) / Double(totalBytes)))
    }
}

/// 下载完成后拿到的响应信息。URL 可能经过重定向，MIME 用来判断
/// 服务器到底给了文件还是登录 / 下载页。
public struct DownloadedFile: Equatable, Sendable {
    public let url: URL
    public let finalURL: URL
    public let mimeType: String?
    public let statusCode: Int
    public let byteCount: Int64

    public init(
        url: URL,
        finalURL: URL,
        mimeType: String?,
        statusCode: Int,
        byteCount: Int64
    ) {
        self.url = url
        self.finalURL = finalURL
        self.mimeType = mimeType
        self.statusCode = statusCode
        self.byteCount = byteCount
    }
}

/// 下载 APK 时使用的 UA。
///
/// 很多二维码是发给手机扫的：桌面 UA 可能拿到「用手机打开」的落地页，
/// 手机 UA 才会直接给 APK。先用桌面 UA（更通用），遇到网页再换手机 UA。
public enum DownloadUserAgent {
    public static let desktop = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    public static let android = "Mozilla/5.0 (Linux; Android 14; Pixel 8) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36"
}

public enum DownloadError: Error, Equatable {
    case httpStatus(Int)
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch(expected: String, actual: String)
}

/// 支持 Range 续传的文件下载器。
///
/// 下载过程中内容写在 `<destination>.part`，校验通过后才原子换入目标路径；
/// 失败或取消时保留 `.part`，下次调用自动带 `Range` 头接着下。
public final class FileDownloader: @unchecked Sendable {
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    public static func partialURL(for destination: URL) -> URL {
        destination
            .deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + ".part")
    }

    @discardableResult
    public func download(
        url: URL,
        to destination: URL,
        expectedSHA1: String? = nil,
        userAgent: String = DownloadUserAgent.desktop,
        referer: URL? = nil,
        progress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws -> DownloadedFile {
        let transfer = Transfer(
            destination: destination,
            partialURL: Self.partialURL(for: destination),
            expectedSHA1: expectedSHA1,
            userAgent: userAgent,
            referer: referer,
            progress: progress
        )
        let handle = TransferHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DownloadedFile, Error>) in
                transfer.continuation = continuation
                transfer.handle = handle
                transfer.start(configuration: configuration, url: url)
            }
        } onCancel: {
            handle.cancel()
        }
    }
}

// MARK: - 传输

private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let destination: URL
    let partialURL: URL
    let expectedSHA1: String?
    let userAgent: String
    let referer: URL?
    let progress: (@Sendable (DownloadProgress) -> Void)?

    var continuation: CheckedContinuation<DownloadedFile, Error>?
    weak var handle: TransferHandle?

    private let stateLock = NSLock()
    private var finished = false
    private var session: URLSession?
    private var fileHandle: FileHandle?
    private var resumeOffset: Int64 = 0
    private var receivedNewBytes: Int64 = 0
    private var totalBytes: Int64?
    private var writeError: Error?
    private var finalURL: URL?
    private var mimeType: String?
    private var statusCode: Int?

    init(
        destination: URL,
        partialURL: URL,
        expectedSHA1: String?,
        userAgent: String,
        referer: URL?,
        progress: (@Sendable (DownloadProgress) -> Void)?
    ) {
        self.destination = destination
        self.partialURL = partialURL
        self.expectedSHA1 = expectedSHA1
        self.userAgent = userAgent
        self.referer = referer
        self.progress = progress
    }

    func start(configuration: URLSessionConfiguration, url: URL) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if let size = Self.fileSize(at: partialURL), size > 0 {
            resumeOffset = size
        } else {
            fileManager.createFile(atPath: partialURL.path, contents: nil)
            resumeOffset = 0
        }

        var request = URLRequest(url: url)
        // 没有 UA 的请求在下载页 / 防盗链前面经常拿到一页 HTML。默认就装成桌面浏览器。
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,"
                + "application/vnd.android.package-archive;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        if resumeOffset > 0 {
            request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
        }

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        handle?.attach(task: task)
        task.resume()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(URLError(.badServerResponse)))
            return
        }

        finalURL = http.url ?? dataTask.originalRequest?.url
        mimeType = http.mimeType
        statusCode = http.statusCode

        switch http.statusCode {
        case 200:
            // 服务器忽略了 Range，之前那截作废，从头写。
            resumeOffset = 0
            do {
                try Self.truncate(at: partialURL)
            } catch {
                completionHandler(.cancel)
                finish(.failure(error))
                return
            }
            totalBytes = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
        case 206:
            if let text = http.value(forHTTPHeaderField: "Content-Range"),
               let total = Self.totalBytes(fromContentRange: text) {
                totalBytes = total
            } else if http.expectedContentLength >= 0 {
                totalBytes = resumeOffset + http.expectedContentLength
            }
        default:
            completionHandler(.cancel)
            finish(.failure(DownloadError.httpStatus(http.statusCode)))
            return
        }

        do {
            let handle = try FileHandle(forWritingTo: partialURL)
            try handle.seekToEnd()
            fileHandle = handle
        } catch {
            completionHandler(.cancel)
            finish(.failure(error))
            return
        }
        completionHandler(.allow)
        reportProgress()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard !isFinished else { return }
        do {
            try fileHandle?.write(contentsOf: data)
        } catch {
            writeError = error
            dataTask.cancel()
            finish(.failure(error))
            return
        }
        receivedNewBytes += Int64(data.count)
        reportProgress()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        try? fileHandle?.close()
        fileHandle = nil

        if let writeError {
            finish(.failure(writeError))
            invalidateSession()
            return
        }
        if handle?.isCancelled == true {
            finish(.failure(CancellationError()))
            invalidateSession(immediately: true)
            return
        }
        if let error {
            finish(.failure(error))
            invalidateSession()
            return
        }

        let actual = Self.fileSize(at: partialURL) ?? 0
        if let totalBytes, actual != totalBytes {
            finish(.failure(DownloadError.sizeMismatch(expected: totalBytes, actual: actual)))
            invalidateSession()
            return
        }

        if let expectedSHA1 {
            do {
                let actualHash = try Checksum.sha1Hex(ofFileAt: partialURL)
                guard actualHash.caseInsensitiveCompare(expectedSHA1) == .orderedSame else {
                    // 内容已损坏，留着重试只会一直失败，直接丢掉。
                    try? FileManager.default.removeItem(at: partialURL)
                    finish(.failure(DownloadError.checksumMismatch(expected: expectedSHA1, actual: actualHash)))
                    invalidateSession()
                    return
                }
            } catch {
                finish(.failure(error))
                invalidateSession()
                return
            }
        }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: partialURL, to: destination)
            finish(.success(DownloadedFile(
                url: destination,
                finalURL: finalURL ?? destination,
                mimeType: mimeType,
                statusCode: statusCode ?? 200,
                byteCount: actual
            )))
        } catch {
            finish(.failure(error))
        }
        invalidateSession()
    }

    // MARK: 状态

    private var isFinished: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return finished
    }

    private func finish(_ result: Result<DownloadedFile, Error>) {
        stateLock.lock()
        if finished {
            stateLock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        stateLock.unlock()

        switch result {
        case let .success(file):
            continuation?.resume(returning: file)
        case let .failure(error):
            continuation?.resume(throwing: error)
        }
    }

    private func invalidateSession(immediately: Bool = false) {
        guard let session else { return }
        self.session = nil
        if immediately {
            session.invalidateAndCancel()
        } else {
            session.finishTasksAndInvalidate()
        }
    }

    private func reportProgress() {
        progress?(DownloadProgress(
            receivedBytes: resumeOffset + receivedNewBytes,
            totalBytes: totalBytes
        ))
    }

    // MARK: 文件

    private static func fileSize(at url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }

    private static func truncate(at url: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        fileManager.createFile(atPath: url.path, contents: nil)
    }

    /// `Content-Range: bytes 100000-299999/300000` → 300000
    private static func totalBytes(fromContentRange text: String) -> Int64? {
        guard let slash = text.lastIndex(of: "/") else { return nil }
        let suffix = text[text.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        return Int64(suffix)
    }
}

// MARK: - 取消句柄

private final class TransferHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func attach(task: URLSessionDataTask) {
        lock.lock()
        self.task = task
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}
