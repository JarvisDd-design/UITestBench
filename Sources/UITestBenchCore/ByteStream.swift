import Foundation

/// 字节流：测试用假件，运行时由 socket 实现。
public protocol ByteStream: AnyObject {
    /// 读满 `count` 字节，读不到就抛错，绝不返回短数据。
    func readExactly(_ count: Int) throws -> Data
    func write(_ data: Data) throws
    func close()
}
