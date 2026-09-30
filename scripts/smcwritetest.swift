// 受控 SMC 写延迟测试：测 F0Md 写入后锁存需多久，定 setTarget/restoreAutomatic 轮询回读参数。
// 安全：只操作 F0，目标取 F0Mn(最低档)，defer 无条件轮询写回 Md=0 恢复自动。需 sudo。
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

    func call(command: UInt8, key: UInt32 = 0, size: UInt32 = 0, payload: [UInt8] = []) -> (ok: Bool, result: UInt8, out: [UInt8]) {
        var input = [UInt8](repeating: 0, count: 80)
        func put(_ v: UInt32, at o: Int) { for b in 0..<4 { input[o + b] = UInt8(truncatingIfNeeded: v >> (b * 8)) } }
        put(key, at: 0); put(size, at: 28); input[42] = command
        for (i, byte) in payload.enumerated() { input[48 + i] = byte }
        var output = [UInt8](repeating: 0, count: 80)
        var outSize = 80
        let r = input.withUnsafeBytes { s in output.withUnsafeMutableBytes { d in
            IOConnectCallStructMethod(port, 2, s.baseAddress, 80, d.baseAddress, &outSize) } }
        guard r == KERN_SUCCESS, outSize == 80 else { return (false, 255, output) }
        return (output[40] == 0, output[40], output)
    }
    func integer(_ b: [UInt8], at o: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[o + $1]) << ($1 * 8) } }
    func info(_ key: String) -> (size: Int, type: String)? {
        guard let code = fourCC(key) else { return nil }
        let r = call(command: 9, key: code)
        guard r.ok else { return nil }
        return (Int(integer(r.out, at: 28)), typeString(integer(r.out, at: 32)))
    }
    func read(_ key: String) -> [UInt8]? {
        guard let m = info(key), let code = fourCC(key) else { return nil }
        let r = call(command: 5, key: code, size: UInt32(m.size))
        guard r.ok else { return nil }
        return Array(r.out[48..<(48 + m.size)])
    }
    func number(_ key: String) -> Double? {
        guard let m = info(key), let b = read(key) else { return nil }
        switch m.type {
        case "flt ": guard b.count == 4 else { return nil }
            return Double(Float(bitPattern: b.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }))
        case "ui8 ": return b.count == 1 ? Double(b[0]) : nil
        default: return nil
        }
    }
    @discardableResult
    func write(_ key: String, bytes: [UInt8]) -> UInt8 {
        guard let m = info(key), let code = fourCC(key), bytes.count == m.size else { return 254 }
        return call(command: 6, key: code, size: UInt32(bytes.count), payload: bytes).result
    }
}

guard let c = Conn() else { print("无法打开 AppleSMC(需 sudo)"); exit(1) }
let id = "F0"
let modeKey = c.number(id + "md") != nil ? id + "md" : id + "Md"
let target = c.number(id + "Mn") ?? 1200

// 轮询回读：每 step 毫秒读一次，最多 tries 次，返回首次命中 want 的耗时(ms)，未命中返回 -1
func pollMode(want: Double, tries: Int, stepMs: UInt32) -> (hitMs: Int, values: [Int]) {
    var vals: [Int] = []
    for i in 0..<tries {
        let v = c.number(modeKey)
        vals.append(v.map { Int($0) } ?? -99)
        if v == want { return (i * Int(stepMs), vals) }
        usleep(stepMs * 1000)
    }
    return (-1, vals)
}

print("写前: mode=\(c.number(modeKey).map { String(format: "%.0f", $0) } ?? "nil") Tg=\(c.number(id + "Tg").map { String(format: "%.2f", $0) } ?? "nil")")

// defer 无条件恢复：轮询写回 Md=0
defer {
    _ = c.write(modeKey, bytes: [0])
    let r = pollMode(want: 0, tries: 20, stepMs: 50)
    print("== 恢复自动: write Md=0, 轮询 mode 序列=\(r.values) 命中0@\(r.hitMs)ms ==")
}

print("\n== 测试A: write \(modeKey)=1，轮询回读 (每50ms×20次=1s窗口) ==")
let wa = c.write(modeKey, bytes: [1])
print("  write result=\(wa)")
let ra = pollMode(want: 1, tries: 20, stepMs: 50)
print("  mode 序列=\(ra.values)")
print("  => mode=1 首次命中 @ \(ra.hitMs)ms" + (ra.hitMs < 0 ? " (1秒内未生效!)" : ""))

print("\n== 测试B: write \(id)Tg=\(target)，轮询回读 ==")
let bits = Float(target).bitPattern
let wb = c.write(id + "Tg", bytes: (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) })
print("  write result=\(wb)")
var tgHit = -1
for i in 0..<20 {
    if let t = c.number(id + "Tg"), abs(t - target) <= 1 { tgHit = i * 50; break }
    usleep(50_000)
}
print("  => Tg 命中 @ \(tgHit)ms")

// 复刻修复后 SMCReader.confirmValue：命中目标(带容差)才算确认
func confirmValue(_ key: String, target want: Double, tolerance: Double, tries: Int = 20, stepMicros: UInt32 = 50_000) -> Bool {
    for attempt in 0..<tries {
        if let v = c.number(key), abs(v - want) <= tolerance { return true }
        if attempt < tries - 1 { usleep(stepMicros) }
    }
    return false
}
print("\n== 测试C: 复刻修复后 setTarget:189-192 判定 ==")
let modeConfirmed = confirmValue(modeKey, target: 1, tolerance: 0)
let tgConfirmed = confirmValue(id + "Tg", target: target, tolerance: 1)
print("  confirmValue(\(modeKey),1,0)=\(modeConfirmed)")
print("  confirmValue(\(id)Tg,\(target),1)=\(tgConfirmed)")
print("  => setTarget \(modeConfirmed && tgConfirmed ? "成功(修复生效!)" : "仍抛 invalidResponse")")
