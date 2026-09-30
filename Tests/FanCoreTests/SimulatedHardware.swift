import Foundation
#if SWIFT_PACKAGE
import FanCore
#endif

/// 演示源只在内存中工作，不持有任何 SMC 连接。
struct SimulatedHardware: Sendable {
    public private(set) var policies: [FanPolicy] = []
    private var actual = ["F0": 1_820.0, "F1": 1_760.0]
    private var ramps: [String: RampState] = [:]
    public private(set) var lastFailure: String?
    public init() {}

    public mutating func apply(_ policies: [FanPolicy], snapshot: HardwareSnapshot, at now: Date) throws {
        guard snapshot.source == .demo else { throw ControlError.wrongDevice }
        try PolicyValidator.validate(policies, in: snapshot, at: now)
        self.policies = policies
        ramps = [:]
        lastFailure = nil
    }

    public mutating func restore() { policies = []; ramps = [:] }

    public mutating func sample(at now: Date = Date()) -> HardwareSnapshot {
        let wave = sin(now.timeIntervalSinceReferenceDate / 18)
        let definitions: [(String, String, SensorGroup, Double)] = [
            ("demo.cpu", "CPU · 平均温度", .cpu, 48 + wave * 2),
            ("demo.performance", "CPU · 性能核心", .cpu, 52 + wave * 3),
            ("demo.efficiency", "CPU · 能效核心", .cpu, 42 + wave),
            ("demo.gpu", "GPU · 平均温度", .gpu, 44 + wave * 1.5),
            ("demo.battery", "电池", .battery, 31 + wave * 0.2),
            ("demo.ssd", "SSD", .storage, 36 + wave * 0.4),
            ("demo.ambient", "机身内部", .other, 29 + wave * 0.2)
        ]
        let sensors = definitions.map { SensorReading(id: $0.0, name: $0.1, group: $0.2, celsius: $0.3, sampledAt: now) }
        var fans = [
            FanReading(id: "F0", name: "左侧风扇", rpm: actual["F0"], minimum: 1_200, maximum: 5_800, mode: .automatic, sampledAt: now, controlSupported: true),
            FanReading(id: "F1", name: "右侧风扇", rpm: actual["F1"], minimum: 1_200, maximum: 6_200, mode: .automatic, sampledAt: now, controlSupported: true)
        ]
        let baseline = HardwareSnapshot(model: "演示 MacBook Pro", chip: "Apple Silicon · 模拟设备", source: .demo,
                                        fans: fans, sensors: sensors, timestamp: now)
        do { try PolicyValidator.validate(policies, in: baseline, at: now) }
        catch { restore(); lastFailure = error.localizedDescription }
        for index in fans.indices {
            let fan = fans[index]
            let policy = policies.first { $0.fanID == fan.id }
            let temperature = sensors.first { $0.id == policy?.sensorID }?.celsius
            var target = 1_800 + wave * 120
            if let policy, policy.mode != .automatic,
               let requested = PolicyValidator.target(for: policy, fan: fan, temperature: temperature) {
                var ramp = ramps[fan.id] ?? RampState()
                target = ramp.update(target: requested, sampleTime: now)
                ramps[fan.id] = ramp
                fans[index].mode = policy.mode
                fans[index].target = target
            }
            let value = (actual[fan.id] ?? target) + (target - (actual[fan.id] ?? target)) * 0.3
            actual[fan.id] = value
            fans[index].rpm = value.rounded()
        }
        return HardwareSnapshot(model: baseline.model, chip: baseline.chip, source: .demo,
                                fans: fans, sensors: sensors, timestamp: now)
    }
}
