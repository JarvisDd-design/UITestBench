import XCTest
@testable import UITestBenchCore

final class DownloaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        StubURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
    }

    private var destination: URL {
        directory.appendingPathComponent("platform-tools.zip")
    }

    private var partial: URL {
        FileDownloader.partialURL(for: destination)
    }

    private var url: URL {
        URL(string: "https://example.com/platform-tools.zip")!
    }

    private func downloader() -> FileDownloader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return FileDownloader(configuration: configuration)
    }

    func testDownloadsToDestinationAndReportsProgress() async throws {
        let body = Data(repeating: 0xAB, count: 300_000)
        StubURLProtocol.handler = { _ in
            .init(status: 200, body: body)
        }
        let progress = ProgressRecorder()

        try await downloader().download(url: url, to: destination) { progress.record($0) }

        XCTAssertEqual(try Data(contentsOf: destination), body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(progress.values.last?.receivedBytes, 300_000)
        XCTAssertEqual(progress.values.last?.totalBytes, 300_000)
        XCTAssertEqual(try XCTUnwrap(progress.values.last?.fraction), 1, accuracy: 0.001)
    }

    func testResumesFromExistingPartialFile() async throws {
        let body = Data(repeating: 0xCD, count: 300_000)
        try body.prefix(100_000).write(to: partial)
        StubURLProtocol.handler = { request in
            let range = request.value(forHTTPHeaderField: "Range")
            return .init(
                status: 206,
                body: Data(body.dropFirst(100_000)),
                headers: ["Content-Range": "bytes 100000-299999/300000", "Range-Seen": range ?? "none"]
            )
        }

        try await downloader().download(url: url, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), body)
        XCTAssertEqual(StubURLProtocol.requests.last?.value(forHTTPHeaderField: "Range"), "bytes=100000-")
    }

    /// 服务器不支持 Range 时会回 200 全量，必须从头写，不能在旧片段后面追加。
    func testRestartsFromScratchWhenServerIgnoresRange() async throws {
        let body = Data(repeating: 0xEF, count: 50_000)
        try Data(repeating: 0x00, count: 12_345).write(to: partial)
        StubURLProtocol.handler = { _ in
            .init(status: 200, body: body)
        }

        try await downloader().download(url: url, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), body)
    }

    func testDeletesPartialWhenChecksumDoesNotMatch() async throws {
        let body = Data("corrupted".utf8)
        StubURLProtocol.handler = { _ in
            .init(status: 200, body: body)
        }

        do {
            try await downloader().download(
                url: url,
                to: destination,
                expectedSHA1: "0000000000000000000000000000000000000000"
            )
            XCTFail("校验不一致时应当抛错")
        } catch {
            guard case let DownloadError.checksumMismatch(expected, _) = error else {
                return XCTFail("意外的错误：\(error)")
            }
            XCTAssertEqual(expected, "0000000000000000000000000000000000000000")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testAcceptsDownloadWhenChecksumMatches() async throws {
        let body = Data("abc".utf8)
        StubURLProtocol.handler = { _ in
            .init(status: 200, body: body)
        }

        try await downloader().download(
            url: url,
            to: destination,
            expectedSHA1: "a9993e364706816aba3e25717850c26c9cd0d89d"
        )

        XCTAssertEqual(try Data(contentsOf: destination), body)
    }

    func testCancellingKeepsPartialFileForResume() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowStubURLProtocol.self]
        let downloader = FileDownloader(configuration: configuration)

        let task = Task { try await downloader.download(url: url, to: destination) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()

        do {
            try await task.value
            XCTFail("取消后应当抛错")
        } catch is CancellationError {
            // 预期
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
    }

    func testThrowsOnHTTPErrorStatus() async throws {
        StubURLProtocol.handler = { _ in
            .init(status: 404, body: Data("not found".utf8))
        }

        do {
            try await downloader().download(url: url, to: destination)
            XCTFail("404 应当抛错")
        } catch {
            XCTAssertEqual(error as? DownloadError, .httpStatus(404))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}

// MARK: - 桩

private final class ProgressRecorder {
    private(set) var values: [DownloadProgress] = []
    private let lock = NSLock()

    func record(_ progress: DownloadProgress) {
        lock.lock()
        defer { lock.unlock() }
        values.append(progress)
    }
}

final class StubURLProtocol: URLProtocol {
    struct Stub {
        let status: Int
        let body: Data
        var headers: [String: String] = [:]
    }

    static var handler: ((URLRequest) -> Stub)?
    private(set) static var requests: [URLRequest] = []

    static func reset() {
        handler = nil
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let stub = handler(request)
        var headers = stub.headers
        headers["Content-Length"] = String(stub.body.count)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// 分块慢速发送，用来在中途取消。
final class SlowStubURLProtocol: URLProtocol {
    private static let chunkCount = 10
    private static let chunkSize = 10_000
    private static let delay: TimeInterval = 0.05

    private let lock = NSLock()
    private var index = 0
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let total = Self.chunkCount * Self.chunkSize
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(total)]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        schedule()
    }

    private func schedule() {
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard !self.stopped else {
                self.lock.unlock()
                return
            }
            let index = self.index
            self.index += 1
            self.lock.unlock()

            if index >= Self.chunkCount {
                self.client?.urlProtocolDidFinishLoading(self)
            } else {
                self.client?.urlProtocol(self, didLoad: Data(repeating: 0x11, count: Self.chunkSize))
                self.schedule()
            }
        }
    }

    override func stopLoading() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}
