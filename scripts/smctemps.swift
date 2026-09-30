// 只读 SMC 温度测点全量枚举。用途:拿本机真实暴露的 T 前缀 sp78/flt 键清单 + 实时读数,
// 据此扩充 SensorCatalog 映射,并验证“CPU 平均温度”方案(对已知 CPU 测点取平均)。
// 复刻 SMCReader 的只读部分(命令 8=key at index,9=info,5=read),不做任何写入。
import Foundation
import IOKit

func fourCC(_ text: String) -> UInt32? {
    guard text.utf8.count == 4 else { return nil }
    return text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
}
func typeString(_ code: UInt32) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, encoding: .ascii) ?? ""
}
func keyString(_ code: UInt32) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, encoding: .ascii) ?? ""
}

final class Conn {
    var port: io_connect_t = 0
    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &port) == KERN_SUCCESS else { return nil }
    }
    deinit { if port != 0 { IOServiceClose(port) } }

    func call(command: UInt8, key: UInt32 = 0, size: UInt32 = 0, index: UInt32 = 0) -> [UInt8]? {
        var input = [UInt8](repeating: 0, count: 80)
        func put(_ v: UInt32, at o: Int) { for b in 0..<4 { input[o + b] = UInt8(truncatingIfNeeded: v >> (b * 8)) } }
        put(key, at: 0); put(size, at: 28); put(index, at: 44); input[42] = command
        var output = [UInt8](repeating: 0, count: 80)
        var outSize = 80
        let r = input.withUnsafeBytes { s in output.withUnsafeMutableBytes { d in
            IOConnectCallStructMethod(port, 2, s.baseAddress, 80, d.baseAddress, &outSize) } }
        guard r == KERN_SUCCESS, outSize == 80, output[40] == 0 else { return nil }
        return output
    }
    func integer(_ b: [UInt8], at o: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[o + $1]) << ($1 * 8) } }

    func keyAt(_ index: Int) -> String? {
        guard let p = call(command: 8, index: UInt32(index)) else { return nil }
        return keyString(integer(p, at: 0))
    }
    func info(_ key: String) -> (size: Int, type: String)? {
        guard let code = fourCC(key), let p = call(command: 9, key: code) else { return nil }
        return (Int(integer(p, at: 28)), typeString(integer(p, at: 32)))
    }
    func number(_ key: String) -> Double? {
        guard let m = info(key), let code = fourCC(key), let p = call(command: 5, key: code, size: UInt32(m.size)) else { return nil }
        let bytes = Array(p[48..<(48 + m.size)])
        switch m.type {
        case "flt ": guard bytes.count == 4 else { return nil }
            return Double(Float(bitPattern: bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }))
        case "sp78": guard bytes.count == 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        default: return nil
        }
    }
    // #KEY 是 ui32,big-endian。number() 只处理温度类型,这里单独读原始计数。
    func rawUInt32BE(_ key: String) -> UInt32? {
        guard let m = info(key), m.size == 4, let code = fourCC(key),
              let p = call(command: 5, key: code, size: 4) else { return nil }
        return (UInt32(p[48]) << 24) | (UInt32(p[49]) << 16) | (UInt32(p[50]) << 8) | UInt32(p[51])
    }
}

guard let c = Conn() else { print("无法打开 AppleSMC"); exit(1) }
var msize = 0
sysctlbyname("hw.model", nil, &msize, nil, 0)
var mbytes = [CChar](repeating: 0, count: msize)
sysctlbyname("hw.model", &mbytes, &msize, nil, 0)
print("机型: \(String(cString: mbytes))")

guard let countRaw = c.rawUInt32BE("#KEY") else { print("读 #KEY 失败"); exit(1) }
let count = Double(countRaw)
print("#KEY = \(countRaw)")
print("\n== 全部 T 前缀 sp78/flt 温度键(key type size value) ==")

struct Row { let key: String; let type: String; let value: Double? }
var rows: [Row] = []
for i in 0..<Int(count) {
    guard let key = c.keyAt(i), key.hasPrefix("T"), let m = c.info(key),
          ["sp78", "flt "].contains(m.type) else { continue }
    rows.append(Row(key: key, type: m.type, value: c.number(key)))
}
// 按 key 排序稳定输出
for r in rows.sorted(by: { $0.key < $1.key }) {
    let v = r.value.map { String(format: "%.2f", $0) } ?? "nil"
    // 标注 value 是否落在“有效温度”窗口(SMCReader 用 >0 && <150)
    let valid = (r.value.map { $0 > 0 && $0 < 150 } ?? false) ? "" : "  <- 过滤掉(0或越界)"
    print(String(format: "  %@  %@  size=?  %@%@", r.key, r.type, v, valid))
}
print("\n共 \(rows.count) 个 T 温度键")

// 验证 CPU 平均温度方案:已知 catalog 的 CPU 测点
let cpuKeys = ["Tp01","Tp05","Tp0D","Tp0H","Tp0L","Tp0P","Tp0X","Tp0b","Tp09","Tp0T"]
let cpuVals = cpuKeys.compactMap { k in c.number(k).flatMap { $0 > 0 && $0 < 150 ? $0 : nil } }
print("\n== CPU 平均温度方案验证 ==")
print("已知 CPU 键: \(cpuKeys.joined(separator: " "))")
print("有效读数: \(cpuVals.map { String(format: "%.1f", $0) }.joined(separator: " "))")
if !cpuVals.isEmpty {
    print(String(format: "平均 = %.2f°C (基于 %d 个测点)", cpuVals.reduce(0,+)/Double(cpuVals.count), cpuVals.count))
} else {
    print("无有效 CPU 读数")
}
