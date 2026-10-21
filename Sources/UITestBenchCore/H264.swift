import Foundation

/// H.264 Annex-B 与 AVCC 之间的转换。
///
/// scrcpy 下发的配置包与图像包都是 Annex-B（`00 00 01` / `00 00 00 01` 起始码），
/// 而 VideoToolbox 要 AVCC（4 字节大端长度前缀）和单独的 SPS/PPS。
public enum H264 {
    public struct ParameterSets: Equatable, Sendable {
        public let sps: Data
        public let pps: Data

        public init(sps: Data, pps: Data) {
            self.sps = sps
            self.pps = pps
        }
    }

    /// 按起始码切出 NAL 单元，不含起始码。
    public static func splitNALUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return [] }

        var units: [Data] = []
        var unitStart: Int?
        var index = 0

        while index < bytes.count {
            if index + 3 < bytes.count,
               bytes[index] == 0, bytes[index + 1] == 0,
               bytes[index + 2] == 0, bytes[index + 3] == 1 {
                if let start = unitStart {
                    units.append(Data(bytes[start..<index]))
                }
                index += 4
                unitStart = index
            } else if index + 2 < bytes.count,
                      bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                if let start = unitStart {
                    units.append(Data(bytes[start..<index]))
                }
                index += 3
                unitStart = index
            } else {
                index += 1
            }
        }

        if let start = unitStart {
            units.append(Data(bytes[start...]))
        }

        return unitStart == nil ? [data] : units
    }

    /// 每个 NAL 前加 4 字节大端长度。
    public static func avcc(fromAnnexB data: Data) -> Data {
        var output = Data()
        for unit in splitNALUnits(data) {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
            output.append(unit)
        }
        return output
    }

    /// 从配置包里取 SPS 与 PPS（NAL 类型 7 与 8）。
    public static func parameterSets(in data: Data) -> ParameterSets? {
        var sps: Data?
        var pps: Data?

        for unit in splitNALUnits(data) {
            guard let header = unit.first else { continue }
            switch header & 0x1F {
            case 7: sps = sps ?? unit
            case 8: pps = pps ?? unit
            default: break
            }
        }

        guard let sps, let pps else { return nil }
        return ParameterSets(sps: sps, pps: pps)
    }
}
