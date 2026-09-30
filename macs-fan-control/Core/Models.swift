import Foundation

public enum DataSource: String, Codable, Sendable { case live, demo }
public enum FanMode: String, Codable, CaseIterable, Sendable { case automatic, fixed, sensor }
public enum SensorGroup: String, Codable, CaseIterable, Sendable {
    case cpu, gpu, memory, battery, storage, other
}

public struct FanReading: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var rpm: Double?
    public var minimum: Double?
    public var maximum: Double?
    public var mode: FanMode?
    public var target: Double?
    public var sampledAt: Date?
    public var controlSupported: Bool

    public init(id: String, name: String, rpm: Double?, minimum: Double?, maximum: Double?,
                mode: FanMode? = nil, target: Double? = nil, sampledAt: Date? = nil, controlSupported: Bool = false) {
        self.id = id; self.name = name; self.rpm = rpm; self.minimum = minimum
        self.maximum = maximum; self.mode = mode; self.target = target; self.sampledAt = sampledAt
        self.controlSupported = controlSupported
    }

    public var validRange: ClosedRange<Double>? {
        guard let minimum, let maximum, minimum.isFinite, maximum.isFinite,
              minimum >= 0, maximum > minimum, maximum <= 30_000 else { return nil }
        return minimum...maximum
    }

    public func isFresh(at now: Date) -> Bool {
        guard let sampledAt, let rpm, rpm.isFinite, rpm >= 0 else { return false }
        return (0...3).contains(now.timeIntervalSince(sampledAt))
    }
}

public struct SensorReading: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var group: SensorGroup
    public var celsius: Double?
    public var sampledAt: Date?

    public init(id: String, name: String, group: SensorGroup, celsius: Double?, sampledAt: Date?) {
        self.id = id; self.name = name; self.group = group
        self.celsius = celsius; self.sampledAt = sampledAt
    }

    public func isFresh(at now: Date) -> Bool {
        guard let sampledAt, let celsius, celsius.isFinite else { return false }
        return (0...3).contains(now.timeIntervalSince(sampledAt))
    }
}

public struct HardwareSnapshot: Codable, Sendable {
    public var model: String
    public var chip: String
    public var source: DataSource
    public var fans: [FanReading]
    public var sensors: [SensorReading]
    public var timestamp: Date
    public var fanCountKnown: Bool
    public var notice: String?

    public init(model: String, chip: String, source: DataSource, fans: [FanReading],
                sensors: [SensorReading], timestamp: Date, fanCountKnown: Bool = true, notice: String? = nil) {
        self.model = model; self.chip = chip; self.source = source; self.fans = fans
        self.sensors = sensors; self.timestamp = timestamp; self.fanCountKnown = fanCountKnown; self.notice = notice
    }
}

public struct FanPolicy: Codable, Sendable, Equatable, Identifiable {
    public var fanID: String
    public var mode: FanMode
    public var rpm: Double?
    public var sensorID: String?
    public var low: Double?
    public var high: Double?
    public var id: String { fanID }

    public init(fanID: String, mode: FanMode, rpm: Double? = nil,
                sensorID: String? = nil, low: Double? = nil, high: Double? = nil) {
        self.fanID = fanID; self.mode = mode; self.rpm = rpm
        self.sensorID = sensorID; self.low = low; self.high = high
    }
}

public struct FanPreset: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var model: String
    public var source: DataSource
    public var policies: [FanPolicy]

    public init(id: UUID = UUID(), name: String, model: String, source: DataSource, policies: [FanPolicy]) {
        self.id = id; self.name = name; self.model = model; self.source = source; self.policies = policies
    }
}

public enum ControlError: Error, LocalizedError, Equatable {
    case invalidRange, invalidRPM, invalidThresholds, missingSensor, staleSensor, missingFan
    case duplicateFan, wrongDevice, readOnly, unsupportedFan, invalidName, duplicateName, invalidConfiguration, invalidSignature

    public var errorDescription: String? {
        switch self {
        case .invalidRange: "风扇的可用转速范围尚未确认。"
        case .invalidRPM: "请输入硬件允许范围内的有效转速。"
        case .invalidThresholds: "请输入有效温度，开始温度必须低于最高转速温度。"
        case .missingSensor: "所选温度传感器不可用。"
        case .staleSensor: "温度数据已失效，已停止使用旧数据调速。"
        case .missingFan: "预设中的风扇在当前设备上不可用。"
        case .duplicateFan: "同一只风扇不能同时应用两条策略。"
        case .wrongDevice: "预设属于其他设备或数据源，不能在这里应用。"
        case .readOnly: "控制服务尚未就绪。请在控制设置中启用服务并完成系统授权。"
        case .unsupportedFan: "此风扇未提供可识别的调速接口或有效转速范围，目前仅支持监控。"
        case .invalidName: "预设名称需要包含 1–40 个字符。"
        case .duplicateName: "已存在同名预设，请使用其他名称。"
        case .invalidConfiguration: "配置无效或版本不受支持，原文件已保留。"
        case .invalidSignature: "应用或控制服务的签名校验失败。请重新构建完整应用包。"
        }
    }
}
