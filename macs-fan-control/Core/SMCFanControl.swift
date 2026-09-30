import Foundation

/// 根据实际键值识别控制接口，不依赖机型名单，也不通过试写探测能力。
public struct SMCFanControl: Sendable {
    public typealias Value = (type: String, bytes: [UInt8])
    public let modeKey: String
    public let targetKey: String
    private let targetType: String

    public static func fanIndex(_ id: String) -> Int? {
        let bytes = Array(id.utf8)
        guard bytes.count == 2, bytes[0] == 70,
              "0123456789ABCDEF".utf8.contains(bytes[1]) else { return nil }
        return Int(String(id.suffix(1)), radix: 16)
    }

    public static func discover(fanID: String, read: (String) -> Value?) -> SMCFanControl? {
        guard fanIndex(fanID) != nil, let target = read(fanID + "Tg"),
              encodeTarget(0, type: target.type)?.count == target.bytes.count,
              let rpm = SMCCodec.decode(type: target.type, bytes: target.bytes),
              (0...30_000).contains(rpm) else { return nil }
        for key in [fanID + "md", fanID + "Md"] {
            let descriptor = SMCFanControl(modeKey: key, targetKey: fanID + "Tg",
                                           targetType: target.type)
            if let value = read(key), descriptor.mode(from: value) != nil { return descriptor }
        }
        return nil
    }

    public func mode(from value: Value) -> FanMode? {
        guard value.type == "ui8 ", value.bytes.count == 1 else { return nil }
        switch value.bytes[0] {
        case 0, 3: return .automatic
        case 1: return .fixed
        default: return nil
        }
    }

    public func modeBytes(manual: Bool, current: Value) -> [UInt8]? {
        guard mode(from: current) != nil else { return nil }
        return [manual ? 1 : 0]
    }

    public func targetBytes(rpm: Double) -> [UInt8]? { Self.encodeTarget(rpm, type: targetType) }

    public func supports(range: ClosedRange<Double>) -> Bool {
        targetBytes(rpm: range.lowerBound) != nil && targetBytes(rpm: range.upperBound) != nil
    }

    private static func encodeTarget(_ rpm: Double, type: String) -> [UInt8]? {
        guard rpm.isFinite, (0...30_000).contains(rpm) else { return nil }
        switch type {
        case "flt ":
            let bits = Float(rpm).bitPattern
            return (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
        case "fpe2":
            guard rpm <= Double(UInt16.max) / 4 else { return nil }
            let value = UInt16((rpm * 4).rounded())
            return [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
        default: return nil
        }
    }
}
