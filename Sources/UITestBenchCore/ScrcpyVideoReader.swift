import Foundation

public enum ScrcpyVideoEvent: Equatable, Sendable {
    case session(ScrcpySessionHeader)
    case media(ScrcpyMediaHeader, Data)
}

/// 从视频流里按包读取事件。握手由 `ScrcpyVideoHandshake` 负责，之后交给它。
public struct ScrcpyVideoReader {
    private let stream: ByteStream

    public init(stream: ByteStream) {
        self.stream = stream
    }

    /// 对端正常关闭返回 nil；数据不完整或包头非法则抛错。
    public func nextEvent() throws -> ScrcpyVideoEvent? {
        let header: Data
        do {
            header = try stream.readExactly(ScrcpyProtocol.mediaHeaderLength)
        } catch ScrcpyProtocolError.endOfStream {
            return nil
        }

        if let session = ScrcpyProtocol.sessionHeader(header) {
            return .session(session)
        }
        guard let media = ScrcpyProtocol.mediaHeader(header),
              media.size <= ScrcpyProtocol.maxMediaPayloadSize
        else {
            throw ScrcpyProtocolError.malformedPacket
        }

        let payload = try stream.readExactly(media.size)
        return .media(media, payload)
    }
}
