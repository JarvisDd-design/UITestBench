import Foundation
import CoreMedia

/// 按「一帧一取」的方式驱动解码：阻塞读到有帧为止，流结束返回 nil。
/// 播放线程循环调用即可，测试里也能逐个断言。
public final class ScrcpyFramePump {
    private let reader: ScrcpyVideoReader
    private let decoder: ScrcpyDecoder

    public init(reader: ScrcpyVideoReader, decoder: ScrcpyDecoder = ScrcpyDecoder()) {
        self.reader = reader
        self.decoder = decoder
    }

    public func nextFrame() throws -> DecodedFrame? {
        while let event = try reader.nextEvent() {
            if let frame = try decoder.consume(event) {
                return frame
            }
        }
        return nil
    }
}
