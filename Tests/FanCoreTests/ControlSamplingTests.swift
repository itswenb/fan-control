import Foundation
import Testing
import FanCore
@testable import FanHardware

private final class MemorySMC: SMCTransport {
    var values: [String: (type: String, bytes: [UInt8])] = [:]
    var reads: [String] = []
    var writes: [String] = []
    var ignoreWrites = false

    init() {
        values["FNum"] = ("ui8 ", [2])
        for id in ["F0", "F1"] {
            values[id + "md"] = ("ui8 ", [0])
            set(id + "Ac", 2_000); set(id + "Mn", 1_200)
            set(id + "Mx", 6_000); set(id + "Tg", 0)
        }
        set("Tp01", 60); set("Tp09", 50); set("Tg05", 55)
    }

    func set(_ key: String, _ value: Double) {
        let bits = Float(value).bitPattern
        values[key] = ("flt ", (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) })
    }
    func read(_ key: String) throws -> (type: String, bytes: [UInt8]) {
        reads.append(key)
        guard let value = values[key] else { throw HardwareError.invalidResponse }
        return value
    }
    func write(_ key: String, bytes: [UInt8]) throws {
        writes.append(key)
        guard let value = values[key] else { throw HardwareError.invalidResponse }
        if !ignoreWrites { values[key] = (value.type, bytes) }
    }
}

private final class SamplingJournal: ControlJournal {
    var fans = Set<String>()
    func load() throws -> Set<String> { fans }
    func save(_ fans: Set<String>) throws { self.fans = fans }
}

struct ControlSamplingTests {
    @Test func monitoringReusesLibraryCatalogAndReadsFreshValuesWithoutScanning() throws {
        let smc = MemorySMC()
        var catalogCalls = 0
        let device = SMCDevice(allowWrites: false, connection: smc, monitoringTemperatures: { date in
            catalogCalls += 1
            return [SensorReading(id: "Tp01", name: "Library P-Core 1", group: .cpu, celsius: 60, sampledAt: date)]
        })
        #expect(try device.snapshot().sensors[0].name == "Library P-Core 1")
        smc.set("Tp01", 70)
        smc.reads = []
        let next = try device.snapshot()
        #expect(catalogCalls == 1)
        #expect(next.sensors[0].name == "Library P-Core 1" && next.sensors[0].celsius == 70)
        #expect(smc.reads.filter { $0.hasPrefix("T") } == ["Tp01"])
        #expect(smc.writes.isEmpty)
        device.refreshTemperatureCatalog()
        _ = try device.snapshot()
        #expect(catalogCalls == 2)
    }

    @Test func invalidCachedSensorFallsBackToLibraryWithoutPublishingBadTemperature() throws {
        let smc = MemorySMC()
        var catalogCalls = 0
        let device = SMCDevice(allowWrites: false, connection: smc, monitoringTemperatures: { date in
            catalogCalls += 1
            return [SensorReading(id: "Tp01", name: "Library P-Core 1", group: .cpu, celsius: 60, sampledAt: date)]
        })
        _ = try device.snapshot()
        smc.set("Tp01", 6)
        let next = try device.snapshot()
        #expect(catalogCalls == 2 && next.sensors[0].celsius == 60)
        #expect(smc.writes.isEmpty)
    }

    @Test func fixedControlDoesNotInvokeMonitoringOrHIDAndDoesNotRepeatWrites() throws {
        let smc = MemorySMC()
        var monitoringCalls = 0, hidCalls = 0
        let device = SMCDevice(allowWrites: true, connection: smc,
                               monitoringTemperatures: { _ in monitoringCalls += 1; return [] },
                               hidTemperatures: { hidCalls += 1; return [] })
        let session = try ControlSession(driver: device, journal: SamplingJournal()), client = UUID()
        try session.apply([FanPolicy(fanID: "F0", mode: .fixed, rpm: 6_000)], client: client, uptime: 10, now: Date())
        let initialWrites = smc.writes
        for uptime in 11...30 {
            session.heartbeat(client: client, uptime: Double(uptime))
            session.tick(uptime: Double(uptime), now: Date())
        }
        #expect(session.status.owner == client)
        #expect(smc.writes == initialWrites)
        try session.release(client: client)
        #expect(session.status.owner == nil)
        #expect(monitoringCalls == 0 && hidCalls == 0)
        #expect(!smc.reads.contains(where: { $0.hasPrefix("T") || $0 == "#KEY" }))
        #expect(smc.values["F0md"]?.bytes == [0])
    }

    @Test func writesAndRecoveryOnlyReadTheAffectedFanEvenWhenMonitoringIsUnavailable() throws {
        let smc = MemorySMC()
        var monitoringCalls = 0
        let device = SMCDevice(allowWrites: true, connection: smc,
                               monitoringTemperatures: { _ in monitoringCalls += 1; return [] })
        try device.setTarget(fanID: "F0", rpm: 3_000)
        #expect(smc.reads.allSatisfy { $0.hasPrefix("F0") })
        // 恢复不依赖温度、风扇数量、当前转速或转速范围。
        for key in ["FNum", "F0Ac", "F0Mn", "F0Mx"] { smc.values.removeValue(forKey: key) }
        smc.reads = []
        try device.restoreAutomatic(fanID: "F0")
        #expect(smc.reads.allSatisfy { ["F0Tg", "F0md"].contains($0) })
        #expect(monitoringCalls == 0)
        #expect(smc.values["F0md"]?.bytes == [0])
    }

    @Test func selectedAverageSharesReadsAndSkipsUnrelatedTemperatures() throws {
        let smc = MemorySMC()
        var hidCalls = 0
        let device = SMCDevice(allowWrites: true, connection: smc, monitoringTemperatures: { _ in [] },
                               hidTemperatures: { hidCalls += 1; return [] })
        let sources = [ControlTemperatureSource(id: SensorCatalog.cpuAverageKey, group: .cpu, keys: ["Tp01", "Tp09"]),
                       ControlTemperatureSource(id: "Tp01", group: .cpu, keys: ["Tp01"])]
        let snapshot = try device.controlSnapshot(temperatureSources: sources)
        #expect(snapshot.sensors.map(\.celsius) == [55, 60])
        #expect(smc.reads.filter { $0 == "Tp01" }.count == 1)
        #expect(smc.reads.filter { $0 == "Tp09" }.count == 1)
        #expect(!smc.reads.contains("Tg05"))
        #expect(hidCalls == 0)
    }

    @Test func libraryIOFTTemperatureKeysRemainUsableForControl() throws {
        let smc = MemorySMC()
        // 上游在 Apple Silicon 上确认的 ioft 温度格式，34.20°C。
        smc.values["TG0B"] = ("ioft", [0x33, 0x33, 0x22, 0, 0, 0, 0, 0])
        let device = SMCDevice(allowWrites: true, connection: smc, monitoringTemperatures: { _ in [] })
        let sources = [ControlTemperatureSource(id: "TG0B", group: .other, keys: ["TG0B"])]
        let snapshot = try device.controlSnapshot(temperatureSources: sources)
        #expect(abs((snapshot.sensors[0].celsius ?? 0) - 34.2) < 0.001)
        #expect(SMCCodec.decode(type: "ioft", bytes: [0, 0]) == nil)
        let session = try ControlSession(driver: device, journal: SamplingJournal())
        try session.apply([FanPolicy(fanID: "F0", mode: .sensor, sensorID: "TG0B", low: 30, high: 50)],
                          temperatureSources: sources, client: UUID(), uptime: 10, now: Date())
        #expect(!session.status.policies.isEmpty)
    }

    @Test(arguments: [Double.nan, 6, 130])
    func missingOrInvalidAverageMemberReturnsControlToAutomatic(value: Double) throws {
        let smc = MemorySMC(), journal = SamplingJournal(), client = UUID()
        let device = SMCDevice(allowWrites: true, connection: smc, monitoringTemperatures: { _ in [] })
        let session = try ControlSession(driver: device, journal: journal)
        let sources = [ControlTemperatureSource(id: SensorCatalog.cpuAverageKey, group: .cpu, keys: ["Tp01", "Tp09"])]
        try session.apply([FanPolicy(fanID: "F0", mode: .sensor, sensorID: SensorCatalog.cpuAverageKey, low: 40, high: 80)],
                          temperatureSources: sources, client: client, uptime: 10, now: Date())
        smc.set("Tp09", value)
        session.heartbeat(client: client, uptime: 11)
        session.tick(uptime: 11, now: Date())
        #expect(session.status.owner == nil)
        #expect(session.status.recoveryReason == .controlFailure)
        #expect(journal.fans.isEmpty)
        #expect(smc.values["F0md"]?.bytes == [0])
    }

    @Test func HIDIsReadOnceOnlyWhenSelectedAndNeverAcceptsMissingMembers() throws {
        let smc = MemorySMC()
        var hidCalls = 0
        let device = SMCDevice(allowWrites: false, connection: smc, monitoringTemperatures: { _ in [] },
                               hidTemperatures: { hidCalls += 1; return [("pACC MTR Temp Sensor1", 65), ("GPU MTR Temp Sensor1", 55)] })
        let sources = [ControlTemperatureSource(id: "pACC MTR Temp Sensor1", group: .cpu, keys: ["pACC MTR Temp Sensor1"])]
        let snapshot = try device.controlSnapshot(temperatureSources: sources)
        #expect(snapshot.sensors.count == 1 && snapshot.sensors[0].celsius == 65)
        #expect(hidCalls == 1)
        let missing = ControlTemperatureSource(id: SensorCatalog.cpuAverageKey, group: .cpu,
                                               keys: ["pACC MTR Temp Sensor1", "missing HID sensor"])
        let invalid = try device.controlSnapshot(temperatureSources: [missing])
        #expect(invalid.sensors[0].celsius == nil && invalid.sensors[0].sampledAt == nil)
    }

    @Test func unconfirmedWritesStillFailAndReadOnlyDriverCannotWrite() throws {
        let smc = MemorySMC()
        let readOnly = SMCDevice(allowWrites: false, connection: smc, monitoringTemperatures: { _ in [] })
        #expect(throws: ControlError.readOnly) { try readOnly.setTarget(fanID: "F0", rpm: 3_000) }
        #expect(smc.reads.isEmpty && smc.writes.isEmpty)
        smc.ignoreWrites = true
        let writable = SMCDevice(allowWrites: true, connection: smc, monitoringTemperatures: { _ in [] })
        #expect(throws: HardwareError.self) { try writable.setTarget(fanID: "F0", rpm: 3_000) }
    }

    @Test(arguments: [(SensorCatalog.cpuAverageKey, SensorGroup.cpu), (SensorCatalog.gpuAverageKey, .gpu),
                      (SensorCatalog.memoryAverageKey, .memory), (SensorCatalog.batteryAverageKey, .battery)])
    func averageSourcesUseLibraryGroupMembersOnly(id: String, group: SensorGroup) throws {
        let now = Date()
        let sensors = [SensorReading(id: id, name: "Average", group: group, celsius: 50, sampledAt: now),
                       SensorReading(id: "T001", name: "Library label", group: group, celsius: 45, sampledAt: now),
                       SensorReading(id: "T002", name: "Library label 2", group: group, celsius: 55, sampledAt: now),
                       SensorReading(id: "T003", name: "Other group", group: .other, celsius: 30, sampledAt: now)]
        let snapshot = HardwareSnapshot(model: "test", chip: "test", source: .live, fans: [], sensors: sensors, timestamp: now)
        let policies = ["F0", "F1"].map { FanPolicy(fanID: $0, mode: .sensor, sensorID: id, low: 40, high: 80) }
        let sources = try ControlTemperatureSource.resolve(policies, in: snapshot)
        #expect(sources == [ControlTemperatureSource(id: id, group: group, keys: ["T001", "T002"])])
        try ControlTemperatureSource.validate(sources, for: policies)
    }
}
