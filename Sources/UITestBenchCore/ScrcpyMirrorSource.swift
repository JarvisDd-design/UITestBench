import Foundation

/// 把 scrcpy 会话接到通用画面来源上：握手拿设备尺寸，之后逐帧解码。
public final class ScrcpyMirrorSource: MirrorFrameSource {
    private let session: ScrcpySession
    private var pump: ScrcpyFramePump?

    public init(session: ScrcpySession) {
        self.session = session
    }

    /// 图像包字节收齐时回调，延迟诊断用。重连后依然有效（pump 换了也要重新挂）。
    public var onMediaPacket: (() -> Void)? {
        didSet { pump?.onMediaPacket = onMediaPacket }
    }

    public func start() async throws -> MirrorVideoSize {
        try await attachPump()
    }

    /// 断流重连：收掉旧服务端与端口转发，重新推 jar、开转发、拉起服务端。
    public func restart() async throws -> MirrorVideoSize {
        await session.stop()
        pump = nil
        return try await attachPump()
    }

    private func attachPump() async throws -> MirrorVideoSize {
        let handshake = try await session.start()
        let pump = ScrcpyFramePump(reader: try session.videoReader())
        pump.onMediaPacket = onMediaPacket
        self.pump = pump
        return MirrorVideoSize(
            width: Int(handshake.session.width),
            height: Int(handshake.session.height)
        )
    }

    public func nextFrame() throws -> DecodedFrame? {
        try pump?.nextFrame()
    }

    /// 只停会话，不动 `pump`：读取线程可能正卡在 socket 上，
    /// 关闭会话里的 socket 就足以让它退出，避免两边同时改这个字段。
    public func stop() async {
        await session.stop()
    }
}

extension ScrcpyMirrorSource: MirrorRecoveringFrameSource {}
