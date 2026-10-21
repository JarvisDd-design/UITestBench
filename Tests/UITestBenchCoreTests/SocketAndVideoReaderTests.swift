import XCTest
@testable import UITestBenchCore

final class ScrcpyVideoReaderTests: XCTestCase {
    func testReadsSessionThenMediaPackets() throws {
        var bytes = Data([0x80, 0, 0, 0])
        bytes.appendBE32(1080)
        bytes.appendBE32(2400)
        bytes.append(mediaPacket(pts: 7, keyFrame: true, payload: Data([0xAA, 0xBB])))

        let reader = ScrcpyVideoReader(stream: FakeByteStream(bytes: bytes))

        XCTAssertEqual(
            try reader.nextEvent(),
            .session(ScrcpySessionHeader(width: 1080, height: 2400, clientResized: false))
        )
        XCTAssertEqual(
            try reader.nextEvent(),
            .media(ScrcpyMediaHeader(pts: 7, isConfig: false, isKeyFrame: true, size: 2), Data([0xAA, 0xBB]))
        )
        XCTAssertNil(try reader.nextEvent())
    }

    func testCleanEndOfStreamReturnsNil() throws {
        let reader = ScrcpyVideoReader(stream: FakeByteStream(bytes: Data()))

        XCTAssertNil(try reader.nextEvent())
    }

    func testTruncatedPayloadPropagatesEndOfStream() {
        var bytes = Data()
        var ptsAndFlags = UInt64(1) << 61
        withUnsafeBytes(of: &ptsAndFlags) { bytes.append(contentsOf: $0.reversed()) }
        bytes.appendBE32(10)
        bytes.append(contentsOf: [0x01, 0x02])

        let reader = ScrcpyVideoReader(stream: FakeByteStream(bytes: bytes))

        XCTAssertThrowsError(try reader.nextEvent()) { error in
            XCTAssertEqual(error as? ScrcpyProtocolError, .endOfStream)
        }
    }

    func testRejectsAbsurdPayloadSize() {
        var bytes = Data(repeating: 0, count: 12)
        bytes[8] = 0xFF
        bytes[9] = 0xFF
        bytes[10] = 0xFF
        bytes[11] = 0xFF

        let reader = ScrcpyVideoReader(stream: FakeByteStream(bytes: bytes))

        XCTAssertThrowsError(try reader.nextEvent()) { error in
            XCTAssertEqual(error as? ScrcpyProtocolError, .malformedPacket)
        }
    }

    private func mediaPacket(pts: UInt64, keyFrame: Bool, payload: Data) -> Data {
        var ptsAndFlags = pts | (keyFrame ? (UInt64(1) << 61) : 0)
        var data = Data()
        withUnsafeBytes(of: &ptsAndFlags) { data.append(contentsOf: $0.reversed()) }
        data.appendBE32(UInt32(payload.count))
        data.append(payload)
        return data
    }
}

final class SocketByteStreamTests: XCTestCase {
    func testReadsAcrossSplitWritesAndWritesBack() throws {
        let server = try TestTCPServer()
        defer { server.close() }

        let stream = try SocketByteStream.connect(port: server.port, timeout: 2)
        defer { stream.close() }
        let peer = try server.accept()

        try TestSocket.write(peer, Data("ab".utf8))
        try TestSocket.write(peer, Data("cde".utf8))

        XCTAssertEqual(try stream.readExactly(5), Data("abcde".utf8))

        try stream.write(Data("hello".utf8))
        XCTAssertEqual(try TestSocket.readExactly(peer, 5), Data("hello".utf8))

        close(peer)
    }

    func testEndOfStreamWhenPeerCloses() throws {
        let server = try TestTCPServer()
        defer { server.close() }

        let stream = try SocketByteStream.connect(port: server.port, timeout: 2)
        defer { stream.close() }
        let peer = try server.accept()
        close(peer)

        XCTAssertThrowsError(try stream.readExactly(1)) { error in
            XCTAssertEqual(error as? ScrcpyProtocolError, .endOfStream)
        }
    }

    func testConnectToClosedPortFails() throws {
        let port: UInt16
        do {
            let temporary = try TestTCPServer()
            port = temporary.port
            temporary.close()
        }

        XCTAssertThrowsError(try SocketByteStream.connect(port: port, timeout: 1)) { error in
            guard case .connectFailed = error as? SocketError else {
                return XCTFail("应报连接失败，实际 \(error)")
            }
        }
    }
}

// MARK: - 测试用 TCP 服务端

final class TestTCPServer {
    private let listenFD: Int32
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.connectFailed("socket") }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw SocketError.connectFailed("bind/listen")
        }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(fd)
            throw SocketError.connectFailed("getsockname")
        }

        listenFD = fd
        port = UInt16(bigEndian: bound.sin_port)
    }

    func accept() throws -> Int32 {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else { throw SocketError.connectFailed("accept") }
        return fd
    }

    func close() {
        Darwin.close(listenFD)
    }
}

enum TestSocket {
    static func readExactly(_ fd: Int32, _ count: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: count)
        while data.count < count {
            let want = count - data.count
            let readCount = buffer.withUnsafeMutableBytes { pointer in
                Darwin.read(fd, pointer.baseAddress, want)
            }
            if readCount <= 0 { throw SocketError.readFailed("read \(readCount)") }
            data.append(contentsOf: buffer[0..<readCount])
        }
        return data
    }

    static func write(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { pointer in
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(
                    fd,
                    pointer.baseAddress!.advanced(by: offset),
                    data.count - offset
                )
                if written <= 0 { throw SocketError.writeFailed("write \(written)") }
                offset += written
            }
        }
    }
}
