import Foundation
import Testing
@testable import FanCore
@testable import FanHardware

struct PolicyTests {
    let now = Date(timeIntervalSince1970: 1_000)

    func snapshot() -> HardwareSnapshot {
        HardwareSnapshot(model: "test", chip: "test", source: .demo,
                         fans: [FanReading(id: "F0", name: "Fan", rpm: 1_500, minimum: 1_200, maximum: 6_000, controlSupported: true)],
                         sensors: [SensorReading(id: "T0", name: "CPU", group: .cpu, celsius: 60, sampledAt: now)], timestamp: now)
    }

    @Test(arguments: ["MacBookPro18,3", "Mac14,12", "Mac16,5", "future-model"])
    func controlDependsOnCapabilityRatherThanModel(model: String) throws {
        var hardware = snapshot()
        hardware.model = model
        hardware.fans[0].minimum = 0
        let policy = FanPolicy(fanID: "F0", mode: .fixed, rpm: 0)
        try PolicyValidator.validate([policy], in: hardware, at: now)
        #expect(PolicyValidator.target(for: policy, fan: hardware.fans[0], temperature: nil) == 0)
        hardware.fans[0].controlSupported = false
        #expect(throws: ControlError.unsupportedFan) { try PolicyValidator.validate([policy], in: hardware, at: now) }
        #expect(PolicyValidator.target(for: policy, fan: hardware.fans[0], temperature: nil) == nil)
        // 恢复自动不依赖当前的调速能力，避免阻断故障恢复。
        try PolicyValidator.validate([FanPolicy(fanID: "F0", mode: .automatic)], in: hardware, at: now)
    }

    @Test func curveClampsToHardwareRangeAndInterpolates() throws {
        let policy = FanPolicy(fanID: "F0", mode: .sensor, sensorID: "T0", low: 40, high: 80)
        let hardware = snapshot()
        try PolicyValidator.validate([policy], in: hardware, at: now)
        #expect(PolicyValidator.target(for: policy, fan: hardware.fans[0], temperature: 20) == 1_200)
        #expect(PolicyValidator.target(for: policy, fan: hardware.fans[0], temperature: 60) == 3_600)
        #expect(PolicyValidator.target(for: policy, fan: hardware.fans[0], temperature: 100) == 6_000)
    }

    @Test func rejectsStaleMissingAndFutureSamples() {
        let policy = FanPolicy(fanID: "F0", mode: .sensor, sensorID: "T0", low: 40, high: 80)
        #expect(throws: ControlError.staleSensor) { try PolicyValidator.validate([policy], in: snapshot(), at: now.addingTimeInterval(3.01)) }
        #expect(throws: ControlError.staleSensor) { try PolicyValidator.validate([policy], in: snapshot(), at: now.addingTimeInterval(-1)) }
        var missing = snapshot()
        missing.sensors[0].celsius = nil
        #expect(throws: ControlError.staleSensor) { try PolicyValidator.validate([policy], in: missing, at: now) }
    }

    @Test func invalidPolicyNeverProducesAControlTarget() {
        let hardware = snapshot()
        for rpm in [-1.0, 0, 999, 6_001, .nan, .infinity] {
            let policy = FanPolicy(fanID: "F0", mode: .fixed, rpm: rpm)
            #expect(throws: ControlError.invalidRPM) { try PolicyValidator.validate([policy], in: hardware, at: now) }
            #expect(PolicyValidator.target(for: policy, fan: hardware.fans[0], temperature: nil) == nil)
        }
        let duplicate = FanPolicy(fanID: "F0", mode: .automatic)
        #expect(throws: ControlError.duplicateFan) { try PolicyValidator.validate([duplicate, duplicate], in: hardware, at: now) }
        let invalid = FanPolicy(fanID: "F0", mode: .sensor, sensorID: "T0", low: 70, high: 70)
        #expect(throws: ControlError.invalidThresholds) { try PolicyValidator.validate([invalid], in: hardware, at: now) }
    }

    @Test func rampOnlyCountsNewSamplesAndAcceleratesImmediately() {
        var ramp = RampState()
        #expect(ramp.update(target: 4_000, sampleTime: now) == 4_000)
        #expect(ramp.update(target: 2_000, sampleTime: now.addingTimeInterval(1)) == 4_000)
        #expect(ramp.update(target: 2_000, sampleTime: now.addingTimeInterval(1)) == 4_000)
        #expect(ramp.update(target: 2_000, sampleTime: now.addingTimeInterval(2)) == 4_000)
        #expect(ramp.update(target: 2_000, sampleTime: now.addingTimeInterval(3)) == 2_000)
        #expect(ramp.update(target: 6_000, sampleTime: now.addingTimeInterval(4)) == 6_000)
    }

    @Test func unitRoundTripPreservesPhysicalTemperature() {
        let celsius = 62.375
        #expect(abs(TemperatureUnit.fahrenheit.celsius(from: TemperatureUnit.fahrenheit.display(celsius)) - celsius) < 0.000001)
    }

    @Test func demoChangesTargetsAndRestoresWithoutReplaying() throws {
        var demo = SimulatedHardware()
        let baseline = demo.sample(at: now)
        try demo.apply([FanPolicy(fanID: "F0", mode: .fixed, rpm: 4_000)], snapshot: baseline, at: now)
        let controlled = demo.sample(at: now.addingTimeInterval(1))
        #expect(controlled.fans[0].target == 4_000)
        #expect(controlled.fans[0].rpm != 4_000)
        #expect(controlled.fans[1].mode == .automatic)
        demo.restore()
        #expect(demo.sample(at: now.addingTimeInterval(2)).fans.allSatisfy { $0.mode == .automatic && $0.target == nil })
        var live = baseline
        live.source = .live
        #expect(throws: ControlError.wrongDevice) { try demo.apply([], snapshot: live, at: now) }
    }
}

struct CodecTests {
    @Test func decodesSignedFractionalTemperatureAndFanRPM() {
        #expect(SMCCodec.decode(type: "sp78", bytes: [0x2a, 0x80]) == 42.5)
        #expect(SMCCodec.decode(type: "sp78", bytes: [0xff, 0x80]) == -0.5)
        #expect(SMCCodec.decode(type: "fpe2", bytes: [0x1f, 0x40]) == 2_000)
        #expect(SMCCodec.decode(type: "fpe2", bytes: [0, 0]) == 0)
        #expect(SMCCodec.decode(type: "flt ", bytes: [0, 0, 0x28, 0x42]) == 42)
    }

    @Test func rejectsUnknownTypesTruncatedPayloadsAndNonFiniteValues() {
        #expect(SMCCodec.decode(type: "sp78", bytes: [42]) == nil)
        #expect(SMCCodec.decode(type: "abcd", bytes: [0, 0]) == nil)
        #expect(SMCCodec.decode(type: "flt ", bytes: [0, 0, 0x80, 0x7f]) == nil)
        #expect(SMCCodec.decode(type: "flt ", bytes: [0, 0, 0xc0, 0x7f]) == nil)
        #expect(SMCCodec.fourCC("too-long") == nil)
    }
}

struct PersistenceTests {
    @Test func presetsRoundTripAndCorruptionIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = PresetRepository(url: root.appendingPathComponent("presets.json"))
        #expect(try repository.load().isEmpty)
        let preset = FanPreset(name: "编译", model: "test", source: .demo, policies: [.init(fanID: "F0", mode: .fixed, rpm: 2_000)])
        try repository.save([preset])
        #expect(try repository.load() == [preset])
        let broken = Data("{broken".utf8)
        try broken.write(to: repository.url)
        #expect(throws: ControlError.invalidConfiguration) { try repository.save([]) }
        #expect(try Data(contentsOf: repository.url) == broken)
    }

    @Test func namesRejectEmptyAndCaseInsensitiveDuplicates() throws {
        #expect(try PresetRepository.validatedName("  编译  ") == "编译")
        #expect(throws: ControlError.invalidName) { try PresetRepository.validatedName(" \n ") }
        #expect(throws: ControlError.invalidName) { try PresetRepository.validatedName(String(repeating: "a", count: 41)) }
        let preset = FanPreset(name: "Work", model: "test", source: .demo, policies: [])
        #expect(throws: ControlError.duplicateName) { try PresetRepository.checkUnique("work", in: [preset]) }
    }
}
