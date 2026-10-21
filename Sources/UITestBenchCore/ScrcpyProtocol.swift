import Foundation

public enum ScrcpyProtocolError: Error, Equatable {
    case endOfStream
    case unsupportedCodec(UInt32)
    case expectedSessionPacket
    case malformedPacket
}

/// 视频流里的会话包：首字节最高位为 1，携带当前画面尺寸。
public struct ScrcpySessionHeader: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let clientResized: Bool

    public init(width: Int, height: Int, clientResized: Bool) {
        self.width = width
        self.height = height
        self.clientResized = clientResized
    }
}

/// 视频流里的媒体包：12 字节头 + 负载。
public struct ScrcpyMediaHeader: Equatable, Sendable {
    public let pts: UInt64
    public let isConfig: Bool
    public let isKeyFrame: Bool
    public let size: Int

    public init(pts: UInt64, isConfig: Bool, isKeyFrame: Bool, size: Int) {
        self.pts = pts
        self.isConfig = isConfig
        self.isKeyFrame = isKeyFrame
        self.size = size
    }
}

public enum ScrcpyVideoCodec: UInt32, Equatable, Sendable {
    case h264 = 0x6832_3634
    case h265 = 0x6832_3635
}

/// scrcpy v5.0.1 的线格式常量与包头解析。
///
/// 布局依据该版本服务端源码 `app/src/demuxer.c`：
/// 会话包 12 字节；媒体包 12 字节头（u64 PTS + 标志，u32 负载长度）。
public enum ScrcpyProtocol {
    public static let version = "5.0.1"

    public static let deviceNameLength = 64
    public static let sessionPacketLength = 12
    public static let mediaHeaderLength = 12

    /// 一帧 H.264 远小于这个值；超过就说明流已损坏，不能照着长度去读。
    public static let maxMediaPayloadSize = 32 * 1024 * 1024

    public static let codecIDH264: UInt32 = 0x6832_3634
    public static let codecIDH265: UInt32 = 0x6832_3635

    /// 鼠标指针在服务端约定的编号：`UINT64_C(-1)`。
    public static let pointerIDMouse = UInt64.max

    private static let configFlag: UInt64 = 1 << 62
    private static let keyFrameFlag: UInt64 = 1 << 61
    private static let ptsMask: UInt64 = (1 << 61) - 1

    public static func sessionHeader(_ data: Data) -> ScrcpySessionHeader? {
        let bytes = [UInt8](data)
        guard bytes.count >= sessionPacketLength else { return nil }
        guard bytes[0] & 0x80 != 0 else { return nil }
        return ScrcpySessionHeader(
            width: Int(read32be(bytes, 4)),
            height: Int(read32be(bytes, 8)),
            clientResized: bytes[3] & 0x01 != 0
        )
    }

    public static func mediaHeader(_ data: Data) -> ScrcpyMediaHeader? {
        let bytes = [UInt8](data)
        guard bytes.count >= mediaHeaderLength else { return nil }
        guard bytes[0] & 0x80 == 0 else { return nil }

        var ptsAndFlags: UInt64 = 0
        for index in 0..<8 {
            ptsAndFlags = (ptsAndFlags << 8) | UInt64(bytes[index])
        }

        return ScrcpyMediaHeader(
            pts: ptsAndFlags & ptsMask,
            isConfig: ptsAndFlags & configFlag != 0,
            isKeyFrame: ptsAndFlags & keyFrameFlag != 0,
            size: Int(read32be(bytes, 8))
        )
    }

    static func read32be(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    static func read16be(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }
}

public struct ScrcpyVideoHandshake: Equatable, Sendable {
    public let deviceName: String
    public let codec: ScrcpyVideoCodec
    public let session: ScrcpySessionHeader

    public init(deviceName: String, codec: ScrcpyVideoCodec, session: ScrcpySessionHeader) {
        self.deviceName = deviceName
        self.codec = codec
        self.session = session
    }

    /// 连上视频 socket 后依次读：
    /// 1 字节 dummy → 64 字节设备名 → 4 字节编码器 → 首个会话包。
    public static func read(from stream: ByteStream) throws -> ScrcpyVideoHandshake {
        _ = try stream.readExactly(1)

        let nameBytes = [UInt8](try stream.readExactly(ScrcpyProtocol.deviceNameLength))
        let name = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self)

        let codecBytes = [UInt8](try stream.readExactly(4))
        let codecID = ScrcpyProtocol.read32be(codecBytes, 0)
        guard let codec = ScrcpyVideoCodec(rawValue: codecID) else {
            throw ScrcpyProtocolError.unsupportedCodec(codecID)
        }

        let packet = try stream.readExactly(ScrcpyProtocol.sessionPacketLength)
        guard let session = ScrcpyProtocol.sessionHeader(packet) else {
            throw ScrcpyProtocolError.expectedSessionPacket
        }

        return ScrcpyVideoHandshake(deviceName: name, codec: codec, session: session)
    }
}
