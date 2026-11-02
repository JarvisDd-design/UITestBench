import Foundation

/// 字节流：测试用假件，运行时由 socket 实现。
public protocol ByteStream: AnyObject {
    /// 读满 `count` 字节，读不到就抛错，绝不返回短数据。
    func readExactly(_ count: Int) throws -> Data
    func write(_ data: Data) throws
    func close()

    /// 还没被读走的字节数，只给延迟诊断用。不知道的实现返回 0。
    var unreadByteCount: Int { get }
}

extension ByteStream {
    public var unreadByteCount: Int { 0 }
}
