import Foundation
import IOKit
import SiliconScopeCore
#if SWIFT_PACKAGE
import FanCore
#endif

public enum HardwareError: Error, LocalizedError {
    case unavailable, connection(Int32), command(Int32, UInt8), invalidResponse
    public var errorDescription: String? {
        switch self {
        case .unavailable: "未找到 AppleSMC，当前环境可能不支持硬件监控。"
        case .connection(let code): "无法访问硬件服务（\(code)）。当前系统或权限可能限制了访问。"
        case .command(let code, let result): "硬件读取失败（\(code)/\(result)）。"
        case .invalidResponse: "硬件返回的数据格式无法识别。"
        }
    }
}

protocol SMCTransport: AnyObject {
    func read(_ key: String) throws -> (type: String, bytes: [UInt8])
    func write(_ key: String, bytes: [UInt8]) throws
}

/// 读取和控制共用消息布局。上层只读实例不开放任何写入能力。
/// 80 字节消息布局参考 SMCKit；使用显式偏移，避免 Swift 结构体布局变化。
private final class SMCConnection: SMCTransport {
    private var port: io_connect_t = 0
    private var metadata: [String: (size: Int, type: String)] = [:]
    private var unavailableKeys = Set<String>()

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw HardwareError.unavailable }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &port)
        guard result == KERN_SUCCESS else { throw HardwareError.connection(result) }
    }

    deinit { if port != 0 { IOServiceClose(port) } }

    private func call(command: UInt8, key: UInt32 = 0, size: UInt32 = 0, index: UInt32 = 0, payload: [UInt8] = []) throws -> [UInt8] {
        var input = [UInt8](repeating: 0, count: 80)
        func put(_ value: UInt32, at offset: Int) {
            for byte in 0..<4 { input[offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
        }
        put(key, at: 0); put(size, at: 28); put(index, at: 44)
        input[42] = command
        guard payload.count <= 32 else { throw HardwareError.invalidResponse }
        for (index, byte) in payload.enumerated() { input[48 + index] = byte }
        var output = [UInt8](repeating: 0, count: 80)
        var outputSize = 80
        let result = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                IOConnectCallStructMethod(port, 2, source.baseAddress, 80, destination.baseAddress, &outputSize)
            }
        }
        guard result == KERN_SUCCESS else { throw HardwareError.command(result, 0) }
        guard outputSize == 80 else { throw HardwareError.invalidResponse }
        guard output[40] == 0 else { throw HardwareError.command(result, output[40]) }
        return output
    }

    private func integer(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
    }

    func info(_ key: String) throws -> (size: Int, type: String) {
        if let cached = metadata[key] { return cached }
        guard !unavailableKeys.contains(key), let code = SMCCodec.fourCC(key) else { throw HardwareError.invalidResponse }
        do {
            let packet = try call(command: 9, key: code)
            let size = Int(integer(packet, at: 28))
            guard (1...32).contains(size) else { throw HardwareError.invalidResponse }
            let entry = (size: size, type: SMCCodec.string(integer(packet, at: 32)))
            metadata[key] = entry
            return entry
        } catch HardwareError.command(_, 132) {
            unavailableKeys.insert(key)
            throw HardwareError.invalidResponse
        }
    }

    func read(_ key: String) throws -> (type: String, bytes: [UInt8]) {
        let metadata = try info(key)
        guard let code = SMCCodec.fourCC(key) else { throw HardwareError.invalidResponse }
        let packet = try call(command: 5, key: code, size: UInt32(metadata.size))
        return (metadata.type, Array(packet[48..<(48 + metadata.size)]))
    }

    func write(_ key: String, bytes: [UInt8]) throws {
        let metadata = try info(key)
        guard let code = SMCCodec.fourCC(key), bytes.count == metadata.size else { throw HardwareError.invalidResponse }
        _ = try call(command: 6, key: code, size: UInt32(bytes.count), payload: bytes)
    }
}

extension SMCTransport {
    func number(_ key: String) -> Double? {
        guard let value = try? read(key) else { return nil }
        return SMCCodec.decode(type: value.type, bytes: value.bytes)
    }

    /// SMC 写命令返回成功不代表值已锁存：实测模式键锁存需 50~200ms、Tg 目标键约 200ms。
    /// 写后立即回读会拿到旧值造成误判，因此轮询回读，命中目标值(带容差)才算确认。
    /// 默认窗口 20×50ms=1s，远大于实测最慢 200ms，且在客户端 XPC 5s 超时内。
    func confirmValue(_ key: String, target: Double, tolerance: Double, tries: Int = 20, stepMicros: UInt32 = 50_000) -> Bool {
        for attempt in 0..<tries {
            if let value = number(key), abs(value - target) <= tolerance { return true }
            if attempt < tries - 1 { usleep(stepMicros) }
        }
        return false
    }

    func confirmMode(_ control: SMCFanControl, expected: FanMode) -> Bool {
        for attempt in 0..<20 {
            if let value = try? read(control.modeKey), control.mode(from: value) == expected { return true }
            if attempt < 19 { usleep(50_000) }
        }
        return false
    }
}

/// 不跨执行器共享。读写服务各自持有独立连接。
public final class SMCDevice: FanControlDriver {
    private var connection: (any SMCTransport)?
    private var temperatureSampler: TemperatureSampler?
    private let monitoringTemperatures: ((Date) -> [SensorReading])?
    private let hidTemperatures: () -> [(name: String, celsius: Double)]
    private let model = SMCDevice.systemString("hw.model")
    private let chip = SMCDevice.systemString("machdep.cpu.brand_string")
    private let allowWrites: Bool
    private var supportedFans = Set<String>()

    public init(allowWrites: Bool = false) {
        self.allowWrites = allowWrites
        monitoringTemperatures = nil
        hidTemperatures = { HIDSensorReader.read() }
    }

    // 测试替身必须显式传入，测试控制和恢复路径时不会打开真实 SMC。
    init(allowWrites: Bool, connection: any SMCTransport, monitoringTemperatures: @escaping (Date) -> [SensorReading],
         hidTemperatures: @escaping () -> [(name: String, celsius: Double)] = { [] }) {
        self.allowWrites = allowWrites; self.connection = connection
        self.monitoringTemperatures = monitoringTemperatures; self.hidTemperatures = hidTemperatures
    }

    public var controlAvailable: Bool {
        allowWrites && !supportedFans.isEmpty
    }

    public func reset() {
        connection = nil; temperatureSampler = nil
        supportedFans = []
    }

    public func snapshot() throws -> HardwareSnapshot {
        var snapshot = try fanSnapshot(includeNames: true)
        if let monitoringTemperatures {
            snapshot.sensors = monitoringTemperatures(Date())
        } else {
            let sampler = temperatureSampler ?? TemperatureSampler()
            temperatureSampler = sampler
            snapshot.sensors = TemperatureAdapter.readings(from: sampler.sample(), at: Date())
        }
        snapshot.timestamp = Date()
        return snapshot
    }

    public func controlSnapshot(temperatureSources: [ControlTemperatureSource]) throws -> HardwareSnapshot {
        var snapshot = try fanSnapshot(includeNames: false)
        guard !temperatureSources.isEmpty, let connection else { return snapshot }
        let keys = Set(temperatureSources.flatMap(\.keys))
        func isSMCKey(_ key: String) -> Bool { key.hasPrefix("T") && SMCCodec.fourCC(key) != nil }
        var values: [String: (celsius: Double, date: Date)] = [:]
        for key in keys where isSMCKey(key) {
            if let value = connection.number(key), value.isFinite { values[key] = (value, Date()) }
        }
        // 只有所选源含 HID 测点时才调用库；库目前按批次读取 HID，结果仅保留所需项。
        if keys.contains(where: { !isSMCKey($0) }) {
            for value in hidTemperatures() where keys.contains(value.name) && value.celsius.isFinite {
                values[value.name] = (value.celsius, Date())
            }
        }
        snapshot.sensors = temperatureSources.map { source in
            let category: SensorCategory
            switch source.group {
            case .cpu: category = .cpu
            case .gpu: category = .gpu
            case .memory: category = .memory
            case .battery: category = .battery
            case .storage, .other: category = .other
            }
            let readings = source.keys.compactMap { values[$0] }
            let valid = !readings.isEmpty && readings.count == source.keys.count && readings.allSatisfy {
                $0.celsius > category.plausibleFloorCelsius && $0.celsius < 130
            }
            // 平均值缺少任何成员都失效，不能用较冷的剩余测点降低目标转速。
            return SensorReading(id: source.id, name: source.id, group: source.group,
                                 celsius: valid ? readings.reduce(0) { $0 + $1.celsius } / Double(readings.count) : nil,
                                 sampledAt: valid ? readings.map(\.date).min() : nil)
        }
        snapshot.timestamp = Date()
        return snapshot
    }

    private func openConnection() throws -> any SMCTransport {
        if connection == nil { connection = try SMCConnection() }
        guard let connection else { throw HardwareError.unavailable }
        return connection
    }

    private func fanSnapshot(includeNames: Bool) throws -> HardwareSnapshot {
        let connection = try openConnection()
        let now = Date()
        let countValue = connection.number("FNum")
        let fanCountKnown = countValue.map { (0...16).contains($0) && $0.rounded() == $0 } ?? false
        supportedFans = []
        let fans = (0..<(fanCountKnown ? Int(countValue ?? 0) : 0)).map { index in
            let id = "F" + String(index, radix: 16, uppercase: true)
            let fan = readFan(id: id, connection: connection, at: now, includeName: includeNames)
            if fan.controlSupported { supportedFans.insert(id) }
            return fan
        }
        let notice = !fanCountKnown ? "无法确认风扇数量；这不代表设备没有风扇。" : nil
        return HardwareSnapshot(model: model, chip: chip, source: .live, fans: fans,
                                sensors: [], timestamp: now, fanCountKnown: fanCountKnown, notice: notice)
    }

    private func readFan(id: String, connection: any SMCTransport, at now: Date, includeName: Bool = false) -> FanReading {
        let rpm = connection.number(id + "Ac").flatMap { (0...30_000).contains($0) ? $0 : nil }
        var modeValue: SMCFanControl.Value?, targetValue: SMCFanControl.Value?
        let control = SMCFanControl.discover(fanID: id) { key in
            let value = try? connection.read(key)
            if key == id + "Tg" { targetValue = value } else { modeValue = value }
            return value
        }
        let mode = control.flatMap { control in
            modeValue.flatMap { control.mode(from: $0) }
        }
        var name = id
        if includeName {
            name = SensorCatalog.fanName(id: id, model: model, english: false) ?? "风扇 \((SMCFanControl.fanIndex(id) ?? 0) + 1)"
            if let data = try? connection.read(id + "ID") {
                let bytes = data.type == "{fds" ? Array(data.bytes.dropFirst(4)) : data.bytes
                let text = String(bytes: bytes.prefix(while: { $0 != 0 }), encoding: .utf8)?.trimmingCharacters(in: .whitespaces)
                if let text, !text.isEmpty { name = text }
            }
        }
        var fan = FanReading(id: id, name: name, rpm: rpm, minimum: connection.number(id + "Mn"),
                             maximum: connection.number(id + "Mx"), mode: mode,
                             target: mode == .fixed ? targetValue.flatMap { SMCCodec.decode(type: $0.type, bytes: $0.bytes) } : nil,
                             sampledAt: rpm == nil ? nil : now)
        if let control, let range = fan.validRange, control.supports(range: range) { fan.controlSupported = true }
        return fan
    }

    private static func systemString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return "Mac" }
        return String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public func setTarget(fanID: String, rpm: Double) throws {
        guard allowWrites else { throw ControlError.readOnly }
        guard SMCFanControl.fanIndex(fanID) != nil else { throw ControlError.missingFan }
        let connection = try openConnection()
        let fan = readFan(id: fanID, connection: connection, at: Date())
        guard fan.controlSupported, let control = SMCFanControl.discover(fanID: fanID, read: { try? connection.read($0) }) else {
            throw ControlError.unsupportedFan
        }
        guard let range = fan.validRange, rpm.isFinite, range.contains(rpm),
              let payload = control.targetBytes(rpm: rpm) else { throw ControlError.invalidRPM }
        let current = try connection.read(control.modeKey)
        guard let modeBytes = control.modeBytes(manual: true, current: current) else { throw HardwareError.invalidResponse }
        // 不修改 Ftst，不绕过系统热管理，只修改当前风扇的直接控制接口。
        if control.mode(from: current) != .fixed { try connection.write(control.modeKey, bytes: modeBytes) }
        try connection.write(control.targetKey, bytes: payload)
        guard connection.confirmMode(control, expected: .fixed),
              connection.confirmValue(control.targetKey, target: rpm, tolerance: 1) else {
            throw HardwareError.invalidResponse
        }
    }

    public func restoreAutomatic(fanID: String) throws {
        guard allowWrites else { throw ControlError.readOnly }
        guard SMCFanControl.fanIndex(fanID) != nil else { throw ControlError.missingFan }
        let connection = try openConnection()
        guard let control = SMCFanControl.discover(fanID: fanID, read: { try? connection.read($0) }),
              let modeBytes = control.modeBytes(manual: false, current: try connection.read(control.modeKey)) else {
            throw ControlError.unsupportedFan
        }
        try connection.write(control.modeKey, bytes: modeBytes)
        // Apple Silicon 的直接模式恢复沿用目标归零。
        if let zero = control.targetBytes(rpm: 0) {
            try connection.write(control.targetKey, bytes: zero)
        }
        guard connection.confirmMode(control, expected: .automatic) else { throw HardwareError.invalidResponse }
    }
}

public actor SMCReader {
    private let device = SMCDevice()
    public init() {}
    public func reset() { device.reset() }
    public func sample() throws -> HardwareSnapshot { try device.snapshot() }
}
