import Foundation

public enum PolicyValidator {
    public static func validate(_ policies: [FanPolicy], in snapshot: HardwareSnapshot, at now: Date) throws {
        guard Set(policies.map(\.fanID)).count == policies.count else { throw ControlError.duplicateFan }
        for policy in policies {
            guard let fan = snapshot.fans.first(where: { $0.id == policy.fanID }) else { throw ControlError.missingFan }
            guard policy.mode != .automatic else { continue }
            guard fan.controlSupported else { throw ControlError.unsupportedFan }
            guard let range = fan.validRange else { throw ControlError.invalidRange }
            switch policy.mode {
            case .automatic: break
            case .fixed:
                guard let rpm = policy.rpm, rpm.isFinite, range.contains(rpm) else { throw ControlError.invalidRPM }
            case .sensor:
                guard let low = policy.low, let high = policy.high,
                      low.isFinite, high.isFinite, low < high,
                      (-20...150).contains(low), (-20...150).contains(high) else { throw ControlError.invalidThresholds }
                guard let sensor = snapshot.sensors.first(where: { $0.id == policy.sensorID }) else { throw ControlError.missingSensor }
                guard sensor.isFresh(at: now) else { throw ControlError.staleSensor }
            }
        }
    }

    public static func target(for policy: FanPolicy, fan: FanReading, temperature: Double?) -> Double? {
        guard fan.controlSupported, let range = fan.validRange else { return nil }
        switch policy.mode {
        case .automatic: return nil
        case .fixed:
            guard let rpm = policy.rpm, rpm.isFinite, range.contains(rpm) else { return nil }
            return rpm
        case .sensor:
            guard let temperature, temperature.isFinite, let low = policy.low, let high = policy.high,
                  low.isFinite, high.isFinite, high > low else { return nil }
            let ratio = min(1, max(0, (temperature - low) / (high - low)))
            return range.lowerBound + ratio * (range.upperBound - range.lowerBound)
        }
    }
}

/// 每个控制会话单独持有；降速需三个连续新样本，升速即时响应。
public struct RampState: Sendable {
    private var previous: Double?
    private var lowerSamples = 0
    private var lastSample: Date?
    public init() {}

    public mutating func update(target: Double, sampleTime: Date) -> Double {
        guard target.isFinite else { return previous ?? 0 }
        guard lastSample != sampleTime else { return previous ?? target }
        lastSample = sampleTime
        if let previous, target < previous {
            lowerSamples += 1
            if lowerSamples < 3 { return previous }
        }
        lowerSamples = 0
        previous = target
        return target
    }
}

public enum TemperatureUnit: String, Codable, CaseIterable, Sendable {
    case celsius, fahrenheit
    public var symbol: String { self == .celsius ? "°C" : "°F" }
    public func display(_ celsius: Double) -> Double { self == .celsius ? celsius : celsius * 1.8 + 32 }
    public func celsius(from value: Double) -> Double { self == .celsius ? value : (value - 32) / 1.8 }
}
