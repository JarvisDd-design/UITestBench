import Foundation
import Darwin

public enum SocketError: Error, Equatable {
    case connectFailed(String)
    case readFailed(String)
    case writeFailed(String)
}

/// 阻塞式 TCP 字节流，只连本机（adb forward 的端点）。
/// 读必须固定在一个线程上调用，写可并发（内部加锁）。
public final class SocketByteStream: ByteStream, @unchecked Sendable {
    private let fd: Int32
    private let writeLock = NSLock()
    private var isClosed = false

    init(fileDescriptor: Int32) {
        fd = fileDescriptor
    }

    public static func connect(
        host: String = "127.0.0.1",
        port: UInt16,
        timeout: TimeInterval = 5
    ) throws -> SocketByteStream {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketError.connectFailed(String(cString: strerror(errno)))
        }

        do {
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

            let originalFlags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK)

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
                throw SocketError.connectFailed("地址无效：\(host)")
            }

            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            if result != 0 {
                guard errno == EINPROGRESS else {
                    throw SocketError.connectFailed(String(cString: strerror(errno)))
                }

                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&descriptor, 1, Int32(timeout * 1000))
                if ready == 0 {
                    throw SocketError.connectFailed("连接超时（\(Int(timeout)) 秒）")
                }
                if ready < 0 {
                    throw SocketError.connectFailed(String(cString: strerror(errno)))
                }

                var socketError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
                guard socketError == 0 else {
                    throw SocketError.connectFailed(String(cString: strerror(socketError)))
                }
            }

            _ = fcntl(fd, F_SETFL, originalFlags)
            return SocketByteStream(fileDescriptor: fd)
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    public func readExactly(_ count: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        var buffer = [UInt8](repeating: 0, count: max(1, min(count, 65_536)))

        while data.count < count {
            let wanted = min(buffer.count, count - data.count)
            let received = buffer.withUnsafeMutableBytes { pointer in
                Darwin.read(fd, pointer.baseAddress, wanted)
            }
            if received < 0 {
                if errno == EINTR { continue }
                throw SocketError.readFailed(String(cString: strerror(errno)))
            }
            if received == 0 {
                throw ScrcpyProtocolError.endOfStream
            }
            data.append(contentsOf: buffer[0..<received])
        }
        return data
    }

    public func write(_ data: Data) throws {
        try writeLock.lock()
        defer { writeLock.unlock() }

        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let sent = Darwin.send(fd, base.advanced(by: offset), data.count - offset, 0)
                if sent < 0 {
                    if errno == EINTR { continue }
                    throw SocketError.writeFailed(String(cString: strerror(errno)))
                }
                offset += sent
            }
        }
    }

    public func close() {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}
