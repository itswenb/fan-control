// 只读 SMC 探测：读取风扇控制相关键的 type/size，定位 setTarget 的 invalidResponse。
// 复刻 SMCReader.swift 的 SMCConnection 只读部分（命令 9=info，命令 5=read），不做任何写入。
import Foundation
import IOKit

func fourCC(_ text: String) -> UInt32? {
    guard text.utf8.count == 4 else { return nil }
    return text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
}
func typeString(_ code: UInt32) -> String {
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
        guard r == KERN_SUCCESS, outSize == 80 else { return nil }
        guard output[40] == 0 else { print("  (result byte=\(output[40]))"); return nil }
        return output
    }
    func integer(_ b: [UInt8], at o: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[o + $1]) << ($1 * 8) } }

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
        case "ui8 ": return bytes.count == 1 ? Double(bytes[0]) : nil
        case "fpe2": return bytes.count == 2 ? Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4 : nil
        default: return nil
        }
    }
}

guard let c = Conn() else { print("无法打开 AppleSMC"); exit(1) }
var msize = 0
sysctlbyname("hw.model", nil, &msize, nil, 0)
var mbytes = [CChar](repeating: 0, count: msize)
sysctlbyname("hw.model", &mbytes, &msize, nil, 0)
print("机型: \(String(cString: mbytes))")
let fnum: Double? = c.number("FNum")
let fnumText: String = fnum != nil ? String(fnum!) : "nil"
print("FNum = \(fnumText)")
let count = Int(fnum ?? 0)
for i in 0..<max(count, 1) {
    let id = "F" + String(i, radix: 16, uppercase: true)
    print("--- 风扇 \(id) ---")
    for suffix in ["Ac", "md", "Md", "Tg", "Mn", "Mx"] {
        let key = id + suffix
        if let m = c.info(key) {
            let val = c.number(key)
            print("  \(key): type=\"\(m.type)\" size=\(m.size) value=\(val.map { String(format: "%.2f", $0) } ?? "nil")")
        } else {
            print("  \(key): (不存在/读取失败)")
        }
    }
}
// setTarget guard: modeInfo.size==1 && F#Tg type=="flt " && F#Tg size==4
print("\n== setTarget:184 guard 判定 ==")
for i in 0..<max(count, 1) {
    let id = "F" + String(i, radix: 16, uppercase: true)
    let modeKey = c.number(id + "md") != nil ? id + "md" : id + "Md"
    let mi = c.info(modeKey); let ti = c.info(id + "Tg")
    let pass = (mi?.size == 1) && (ti?.type == "flt ") && (ti?.size == 4)
    print("  \(id): modeKey=\(modeKey) modeSize=\(mi?.size.description ?? "nil") TgType=\"\(ti?.type ?? "nil")\" TgSize=\(ti?.size.description ?? "nil") => guard \(pass ? "通过" : "失败(→invalidResponse)")")
}
