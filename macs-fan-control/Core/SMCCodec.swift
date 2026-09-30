import Foundation

/// SMC 数值解码与驱动访问分离，损坏/未知类型不能被解释成 0。
public enum SMCCodec {
    public static func fourCC(_ text: String) -> UInt32? {
        guard text.utf8.count == 4 else { return nil }
        return text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    public static func string(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, encoding: .ascii) ?? ""
    }

    public static func decode(type: String, bytes: [UInt8]) -> Double? {
        let value: Double
        switch type {
        case "flt ":
            guard bytes.count == 4 else { return nil }
            let bits = bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
            value = Double(Float(bitPattern: bits))
        case "sp78":
            guard bytes.count == 2 else { return nil }
            value = Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "fpe2":
            guard bytes.count == 2 else { return nil }
            value = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "ui8 ":
            guard bytes.count == 1 else { return nil }
            value = Double(bytes[0])
        case "ui16":
            guard bytes.count == 2 else { return nil }
            value = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count == 4 else { return nil }
            value = Double(bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        default: return nil
        }
        return value.isFinite ? value : nil
    }
}
