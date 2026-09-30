import Foundation
import Testing
@testable import FanCore

struct ControlRestoreTests {
    let now = Date(timeIntervalSince1970: 1_000)
    let curve = FanPolicy(fanID: "F0", mode: .sensor, sensorID: "T0", low: 40, high: 80)

    func snapshot() -> HardwareSnapshot {
        HardwareSnapshot(model: "MacBookPro18,3", chip: "Apple Silicon", source: .live,
                         fans: ["F0", "F1"].map { FanReading(id: $0, name: $0, rpm: 2_000, minimum: 1_200, maximum: 6_000,
                                                            mode: .automatic, sampledAt: now, controlSupported: true) },
                         sensors: [SensorReading(id: "T0", name: "CPU", group: .cpu, celsius: 55, sampledAt: now)], timestamp: now)
    }

    @Test func rememberedSensorPresetRoundTripsAndMatchesReportedRules() throws {
        let hardware = snapshot()
        let preset = FanPreset(name: "编译", model: hardware.model, source: .live,
                               policies: [curve, FanPolicy(fanID: "F1", mode: .automatic, rpm: 2_000)])
        let saved = LastControlConfiguration(model: hardware.model, policies: [curve], presetID: preset.id)
        let restored = try JSONDecoder().decode(LastControlConfiguration.self, from: JSONEncoder().encode(saved))
        #expect(restored == saved)
        try restored.validateForResume(in: hardware, at: now)
        #expect(PresetSelection.resolve(policies: restored.policies, in: hardware, presets: [preset], preferredID: restored.presetID) == .preset(preset.id))
        // 已保存的选择不能伪装成正在执行：服务报告自动时，界面必须显示自动。
        #expect(PresetSelection.resolve(policies: [], in: hardware, presets: [preset], preferredID: restored.presetID) == .automatic)
    }

    @Test func reportedPolicyOverridesAnOldSelectionAndRenamesKeepIdentity() {
        let hardware = snapshot()
        let previous = FanPreset(name: "旧策略", model: hardware.model, source: .live,
                                 policies: [FanPolicy(fanID: "F0", mode: .fixed, rpm: 3_000)])
        var current = FanPreset(name: "原名称", model: hardware.model, source: .live, policies: [curve])
        current.name = "新名称"
        #expect(PresetSelection.resolve(policies: [curve], in: hardware, presets: [previous, current], preferredID: previous.id) == .preset(current.id))
        #expect(PresetSelection.resolve(policies: [curve], in: hardware, presets: []) == .custom)
        var foreign = current
        foreign.model = "other-model"
        #expect(PresetSelection.resolve(policies: [curve], in: hardware, presets: [foreign]) == .custom)
    }

    @Test func fullSpeedAndExplicitAutomaticRemainDistinct() throws {
        let hardware = snapshot()
        let full = hardware.fans.map { FanPolicy(fanID: $0.id, mode: .fixed, rpm: 6_000) }
        let saved = LastControlConfiguration(model: hardware.model, policies: full, fullSpeed: true)
        try saved.validateForResume(in: hardware, at: now)
        #expect(PresetSelection.resolve(policies: full, in: hardware, presets: [], preferFullSpeed: saved.fullSpeed) == .fullSpeed)
        let named = FanPreset(name: "我的全速", model: hardware.model, source: .live, policies: full)
        #expect(PresetSelection.resolve(policies: full, in: hardware, presets: [named], preferredID: named.id) == .preset(named.id))
        #expect(PresetSelection.resolve(policies: full, in: hardware, presets: [named], preferFullSpeed: true) == .fullSpeed)
        #expect(PresetSelection.resolve(policies: [full[0]], in: hardware, presets: []) == .custom)
        let automatic = LastControlConfiguration(model: hardware.model, policies: [])
        #expect(automatic != saved)
        #expect(PresetSelection.resolve(policies: automatic.policies, in: hardware, presets: [], preferFullSpeed: true) == .automatic)
        let namedAutomatic = FanPreset(name: "我的自动", model: hardware.model, source: .live,
                                        policies: [FanPolicy(fanID: "F0", mode: .automatic)])
        #expect(PresetSelection.resolve(policies: [], in: hardware, presets: [namedAutomatic], preferredID: namedAutomatic.id) == .preset(namedAutomatic.id))
        #expect(PresetSelection.resolve(policies: [], in: hardware, presets: [namedAutomatic]) == .automatic)
    }

    @Test func resumeRejectsOtherDevicesExternalControlAndStaleData() {
        let saved = LastControlConfiguration(model: snapshot().model, policies: [curve])
        var hardware = snapshot()
        hardware.model = "other-model"
        #expect(throws: ControlError.wrongDevice) { try saved.validateForResume(in: hardware, at: now) }
        hardware = snapshot(); hardware.source = .demo
        #expect(throws: ControlError.wrongDevice) { try saved.validateForResume(in: hardware, at: now) }
        hardware = snapshot(); hardware.fans[0].mode = .fixed
        #expect(throws: SessionError.externallyControlled) { try saved.validateForResume(in: hardware, at: now) }
        hardware = snapshot(); hardware.sensors[0].sampledAt = now.addingTimeInterval(-4)
        #expect(throws: ControlError.staleSensor) { try saved.validateForResume(in: hardware, at: now) }
        #expect(throws: ControlError.invalidConfiguration) { try saved.validateForResume(in: snapshot(), at: now.addingTimeInterval(4)) }
    }

    @Test func resumeRevalidatesFanRangeAvailabilityAndConfigurationVersion() {
        var saved = LastControlConfiguration(model: snapshot().model, policies: [FanPolicy(fanID: "F0", mode: .fixed, rpm: 6_000)])
        var hardware = snapshot(); hardware.fans[0].maximum = 5_000
        #expect(throws: ControlError.invalidRPM) { try saved.validateForResume(in: hardware, at: now) }
        hardware = snapshot(); hardware.fans[0].controlSupported = false
        #expect(throws: ControlError.unsupportedFan) { try saved.validateForResume(in: hardware, at: now) }
        hardware = snapshot(); hardware.fans[0].rpm = nil
        #expect(throws: ControlError.invalidRPM) { try saved.validateForResume(in: hardware, at: now) }
        hardware = snapshot(); hardware.fans = []
        #expect(throws: ControlError.missingFan) { try saved.validateForResume(in: hardware, at: now) }
        saved.version = 2
        #expect(throws: ControlError.invalidConfiguration) { try saved.validateForResume(in: snapshot(), at: now) }
    }
}
