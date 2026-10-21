import Foundation
import CoreMedia

public enum ScrcpyDecodeError: Error, Equatable {
    case missingConfiguration
    case missingParameterSets
}

public struct DecodedFrame {
    public let pixelBuffer: CVPixelBuffer
    public let pts: CMTime

    public init(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        self.pixelBuffer = pixelBuffer
        self.pts = pts
    }

    public var width: Int { CVPixelBufferGetWidth(pixelBuffer) }
    public var height: Int { CVPixelBufferGetHeight(pixelBuffer) }
}

/// 吃 scrcpy 的协议事件，产出解码后的帧。
///
/// 会话包只记录尺寸；配置包建/重建解码会话；图像包解码。
/// 转屏时服务端会先发会话包再发配置包，这里自然重建。
public final class ScrcpyDecoder {
    private let decoder = H264Decoder()
    private var isConfigured = false
    private(set) var session: ScrcpySessionHeader?

    public init() {}

    public func consume(_ event: ScrcpyVideoEvent) throws -> DecodedFrame? {
        switch event {
        case .session(let header):
            session = header
            return nil

        case .media(let header, let payload):
            if header.isConfig {
                guard let parameterSets = H264.parameterSets(in: payload) else {
                    throw ScrcpyDecodeError.missingParameterSets
                }
                try decoder.configure(sps: parameterSets.sps, pps: parameterSets.pps)
                isConfigured = true
                return nil
            }

            guard isConfigured else {
                throw ScrcpyDecodeError.missingConfiguration
            }

            let pts = CMTime(value: Int64(header.pts), timescale: 1_000_000)
            guard let pixelBuffer = try decoder.decode(
                payload,
                pts: pts,
                isKeyFrame: header.isKeyFrame
            ) else {
                return nil
            }
            return DecodedFrame(pixelBuffer: pixelBuffer, pts: pts)
        }
    }
}
