import Foundation
import Testing
@testable import FanCore

private final class MemoryJournal: ControlJournal {
    var fans = Set<String>()
    var failSave = false
    func load() throws -> Set<String> { fans }
    func save(_ fans: Set<String>) throws {
        if failSave { throw CocoaError(.fileWriteOutOfSpace) }
        self.fans = fans
    }
}

private final class FakeDriver: FanControlDriver {
    var value: HardwareSnapshot
    var failWrite: String?
    var failRestore: String?
    var writes: [String] = []
    var restores: [String] = []
    var requestedSources: [[ControlTemperatureSource]] = []
    var onWrite: ((String) -> Void)?
    var onSnapshot: (([ControlTemperatureSource]) throws -> Void)?
    init(now: Date) {
        value = HardwareSnapshot(model: "test", chip: "test", source: .live,
                                 fans: ["F0", "F1"].map { FanReading(id: $0, name: $0, rpm: 2_000, minimum: 1_200, maximum: 6_000, mode: .automatic, sampledAt: now, controlSupported: true) },
                                 sensors: [SensorReading(id: "T0", name: "T0", group: .other, celsius: 55, sampledAt: now)], timestamp: now)
    }
    func controlSnapshot(temperatureSources: [ControlTemperatureSource]) throws -> HardwareSnapshot {
        requestedSources.append(temperatureSources)
        try onSnapshot?(temperatureSources)
        return value
    }
    func setTarget(fanID: String, rpm: Double) throws {
        writes.append(fanID)
        onWrite?(fanID)
        if failWrite == fanID { throw ControlError.invalidRPM }
        if let index = value.fans.firstIndex(where: { $0.id == fanID }) {
            value.fans[index].mode = .fixed; value.fans[index].target = rpm
        }
    }
    func restoreAutomatic(fanID: String) throws {
        restores.append(fanID)
        if failRestore == fanID { throw ControlError.invalidRPM }
        if let index = value.fans.firstIndex(where: { $0.id == fanID }) { value.fans[index].mode = .automatic }
    }
}

struct SessionTests {
    @Test func externalTakeoverPreventsMaximumFallbackAndAutomaticResume() throws {
        let driver = FakeDriver(now: Date()), journal = MemoryJournal(), client = UUID()
        let session = try ControlSession(driver: driver, journal: journal)
        let policy = FanPolicy(fanID: "F0", mode: .sensor, sensorID: "T0", low: 40, high: 80)
        let sources = try ControlTemperatureSource.resolve([policy], in: driver.value)
        try session.apply([policy], temperatureSources: sources, client: client, uptime: 10, now: Date())
        driver.writes = []
        driver.onSnapshot = { sources in
            if !sources.isEmpty { throw ControlError.samplingInterrupted }
            driver.value.fans[0].target = 4_000
        }
        session.heartbeat(client: client, uptime: 11)
        session.tick(uptime: 11, now: Date())
        #expect(driver.writes.isEmpty && journal.fans.isEmpty)
        #expect(session.status.owner == nil && session.status.recoveryReason == .controlFailure)
        driver.onSnapshot = nil
    }

    @Test func failedMaximumFallbackRestoresAllFansWithoutAutomaticResume() throws {
        let driver = FakeDriver(now: Date()), journal = MemoryJournal(), client = UUID()
        let session = try ControlSession(driver: driver, journal: journal)
        let policies = ["F0", "F1"].map { FanPolicy(fanID: $0, mode: .sensor, sensorID: "T0", low: 40, high: 80) }
        let sources = try ControlTemperatureSource.resolve(policies, in: driver.value)
        try session.apply(policies, temperatureSources: sources, client: client, uptime: 10, now: Date())
        driver.writes = []
        driver.failWrite = "F1"
        driver.onSnapshot = { sources in if !sources.isEmpty { throw ControlError.samplingInterrupted } }
        session.heartbeat(client: client, uptime: 11)
        session.tick(uptime: 11, now: Date())
        #expect(driver.writes == ["F0", "F1"])
        #expect(Set(driver.restores) == ["F0", "F1"] && journal.fans.isEmpty)
        #expect(session.status.owner == nil && session.status.recoveryReason == .controlFailure)
    }

    @Test func disconnectDuringMaximumFallbackStopsFurtherWritesAndRestoresAllFans() throws {
        let driver = FakeDriver(now: Date()), journal = MemoryJournal(), client = UUID()
        let session = try ControlSession(driver: driver, journal: journal)
        let policies = ["F0", "F1"].map { FanPolicy(fanID: $0, mode: .sensor, sensorID: "T0", low: 40, high: 80) }
        let sources = try ControlTemperatureSource.resolve(policies, in: driver.value)
        try session.apply(policies, temperatureSources: sources, client: client, uptime: 10, now: Date())
        var connected = true
        driver.writes = []
        driver.onSnapshot = { sources in if !sources.isEmpty { throw ControlError.samplingInterrupted } }
        driver.onWrite = { _ in connected = false }
        session.heartbeat(client: client, uptime: 11)
        session.tick(uptime: 11, now: Date(), ownerConnected: { connected })
        #expect(driver.writes == ["F0"])
        #expect(Set(driver.restores) == ["F0", "F1"] && journal.fans.isEmpty)
        #expect(session.status.owner == nil && session.status.recoveryReason == .disconnected)
    }

    @Test func queuedOlderHeartbeatDoesNotUndoNewerArrivalOrPreventExpiry() throws {
        let driver = FakeDriver(now: Date()), client = UUID(), inbox = LeaseHeartbeatInbox()
        let session = try ControlSession(driver: driver, journal: MemoryJournal())
        try session.apply([FanPolicy(fanID: "F0", mode: .fixed, rpm: 2_000)], client: client, uptime: 10, now: Date())
        inbox.record(.fan, at: 14)
        session.heartbeat(client: client, uptime: try #require(inbox.latest(.fan)))
        session.heartbeat(client: client, uptime: 11)
        session.tick(uptime: 18.9, now: Date())
        #expect(session.status.owner == client)
        session.tick(uptime: 19.1, now: Date())
        #expect(session.status.owner == nil && session.status.recoveryReason == .heartbeatExpired)
    }

    @Test func slowWriteNeverAppliesAnotherFansStaleTemperature() async throws {
        let result: (Bool, [String], Set<String>, Bool, Bool) = try await withCheckedThrowingContinuation { continuation in
            // 在独立线程模拟阻塞，避免饿死其他并发测试。 / Simulate blocking on a separate thread without starving concurrent tests.
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let now = Date(), driver = FakeDriver(now: Date()), journal = MemoryJournal(), client = UUID()
                    let session = try ControlSession(driver: driver, journal: journal)
                    let policies = ["F0", "F1"].map { FanPolicy(fanID: $0, mode: .sensor, sensorID: "T0", low: 40, high: 80) }
                    let sources = try ControlTemperatureSource.resolve(policies, in: driver.value)
                    driver.onWrite = { id in if id == "F0" { Thread.sleep(forTimeInterval: 3.1) } }
                    var stale = false
                    do { try session.apply(policies, temperatureSources: sources, client: client, uptime: 10, now: now) }
                    catch ControlError.staleSensor { stale = true }
                    continuation.resume(returning: (stale, driver.writes, Set(driver.restores), journal.fans.isEmpty,
                                                    session.status.owner == nil && session.status.recoveryReason == .controlFailure))
                } catch { continuation.resume(throwing: error) }
            }
        }
        #expect(result.0)
        #expect(result.1 == ["F0"])
        #expect(result.2 == ["F0", "F1"] && result.3)
        #expect(result.4)
    }

    @Test func sensorPolicyKeepsOnlySelectedSourcesAndRejectsUnrelatedSourcesBeforeReading() throws {
        let now = Date(), driver = FakeDriver(now: Date()), client = UUID()
        let session = try ControlSession(driver: driver, journal: MemoryJournal())
        let policy = FanPolicy(fanID: "F0", mode: .sensor, sensorID: "T0", low: 40, high: 80)
        let sources = try ControlTemperatureSource.resolve([policy], in: driver.value)
        #expect(throws: ControlError.missingSensor) { try session.apply([policy], client: client, uptime: 10, now: now) }
        #expect(driver.requestedSources.isEmpty && driver.writes.isEmpty)
        try session.apply([policy], temperatureSources: sources, client: client, uptime: 10, now: now)
        session.heartbeat(client: client, uptime: 11)
        session.tick(uptime: 11, now: now.addingTimeInterval(1))
        #expect(driver.requestedSources == [sources, sources])
        #expect(driver.writes == ["F0"])
        try session.apply([FanPolicy(fanID: "F0", mode: .fixed, rpm: 3_000)], client: client, uptime: 12, now: now)
        #expect(driver.requestedSources.last?.isEmpty == true)
    }

    @Test func unsupportedFanIsRejectedBeforeAnyWriteOrJournalChange() throws {
        let now = Date(), driver = FakeDriver(now: Date()), journal = MemoryJournal()
        driver.value.fans[1].controlSupported = false
        let session = try ControlSession(driver: driver, journal: journal)
        let policies = ["F0", "F1"].map { FanPolicy(fanID: $0, mode: .fixed, rpm: 3_000) }
        #expect(throws: ControlError.unsupportedFan) { try session.apply(policies, client: UUID(), uptime: 10, now: now) }
        #expect(driver.writes.isEmpty)
        #expect(driver.restores.isEmpty)
        #expect(journal.fans.isEmpty)
        #expect(session.status.owner == nil)
    }

    @Test func thirdFanCanBeControlledAndRecoveredAfterRestart() throws {
        let now = Date(), driver = FakeDriver(now: Date()), journal = MemoryJournal(), client = UUID()
        driver.value.fans.append(FanReading(id: "F2", name: "Fan 3", rpm: 2_000, minimum: 0, maximum: 6_000,
                                           mode: .automatic, sampledAt: now, controlSupported: true))
        let session = try ControlSession(driver: driver, journal: journal)
        try session.apply([FanPolicy(fanID: "F2", mode: .fixed, rpm: 3_000)], client: client, uptime: 10, now: now)
        #expect(driver.writes == ["F2"])
        #expect(journal.fans == ["F2"])
        // 重新启动服务时即使转速范围暂时丢失，也必须尝试恢复已接管的风扇。
        driver.value.fans[2].maximum = nil
        driver.value.fans[2].controlSupported = false
        let restarted = try ControlSession(driver: driver, journal: journal)
        #expect(driver.restores == ["F2"])
        #expect(journal.fans.isEmpty)
        #expect(!restarted.status.recoveryBlocked)
    }

    @Test func cancelledRemovalReenablesControlWithoutLettingAnotherClientCancelIt() throws {
        let now = Date(), driver = FakeDriver(now: Date()), journal = MemoryJournal(), client = UUID()
        let session = try ControlSession(driver: driver, journal: journal)
        let policies = [FanPolicy(fanID: "F0", mode: .fixed, rpm: 3_000)]
        try session.apply(policies, client: client, uptime: 10, now: now)
        try session.prepareRemoval(client: client)
        #expect(driver.value.fans[0].mode == .automatic)
        #expect(session.preparingRemoval)
        #expect(throws: (any Error).self) { try session.apply(policies, client: client, uptime: 11, now: now) }
        #expect(throws: (any Error).self) { try session.cancelRemoval(client: UUID()) }
        try session.cancelRemoval(client: client)
        try session.apply(policies, client: client, uptime: 12, now: now)
        #expect(driver.value.fans[0].mode == .fixed)
        try session.prepareRemoval(client: client)
        session.disconnected(client: client)
        #expect(!session.preparingRemoval)
        try session.apply(policies, client: UUID(), uptime: 13, now: now)
    }

    @Test func secondFanFailureRestoresAllTouchedFans() throws {
        let now = Date(), driver = FakeDriver(now: Date()), journal = MemoryJournal()
        let session = try ControlSession(driver: driver, journal: journal)
        driver.failWrite = "F1"
        let policies = ["F0", "F1"].map { FanPolicy(fanID: $0, mode: .fixed, rpm: 3_000) }
        #expect(throws: ControlError.invalidRPM) { try session.apply(policies, client: UUID(), uptime: 10, now: now) }
        #expect(Set(driver.restores) == ["F0", "F1"])
        #expect(session.status.policies.isEmpty)
        #expect(journal.fans.isEmpty)
    }

    @Test func lostClientRestoresAndRejectsConcurrentOwner() throws {
        let now = Date(), driver = FakeDriver(now: Date()), journal = MemoryJournal(), client = UUID()
        let session = try ControlSession(driver: driver, journal: journal)
        let policies = [FanPolicy(fanID: "F0", mode: .fixed, rpm: 3_000)]
        try session.apply(policies, client: client, uptime: 10, now: now)
        #expect(throws: (any Error).self) { try session.apply(policies, client: UUID(), uptime: 11, now: now) }
        session.tick(uptime: 16, now: now.addingTimeInterval(6))
        #expect(session.status.owner == nil)
        #expect(driver.restores == ["F0"])
        #expect(session.status.recoveryReason == .heartbeatExpired)
    }

    @Test(arguments: [3.001, 3.5, 10.0])
    func delayedFixedCheckKeepsConfirmedPolicyWhenHeartbeatIsAlive(gap: Double) throws {
        let now = Date(), driver = FakeDriver(now: Date()), client = UUID()
        let session = try ControlSession(driver: driver, journal: MemoryJournal())
        try session.apply([FanPolicy(fanID: "F0", mode: .fixed, rpm: 3_000)], client: client, uptime: 10, now: now)
        session.heartbeat(client: client, uptime: 10 + gap)
        session.tick(uptime: 10 + gap, now: now.addingTimeInterval(gap))
        #expect(session.status.recoveryReason == nil)
        #expect(session.status.owner == client)
        #expect(driver.restores.isEmpty)
        #expect(driver.writes == ["F0"])
    }

    @Test func delayedTemperatureCheckUsesFreshSampleWithoutRestoringOrReapplying() throws {
        let now = Date(), driver = FakeDriver(now: Date()), client = UUID()
        let session = try ControlSession(driver: driver, journal: MemoryJournal())
        let policy = FanPolicy(fanID: "F0", mode: .sensor, sensorID: "T0", low: 40, high: 80)
        let sources = try ControlTemperatureSource.resolve([policy], in: driver.value)
        try session.apply([policy], temperatureSources: sources, client: client, uptime: 10, now: now)
        let resumedAt = now.addingTimeInterval(3.5)
        driver.value.sensors[0].celsius = 75
        driver.value.sensors[0].sampledAt = resumedAt
        driver.value.timestamp = resumedAt
        session.heartbeat(client: client, uptime: 13.5)
        session.tick(uptime: 13.5, now: resumedAt)
        #expect(session.status.owner == client)
        #expect(session.status.recoveryReason == nil)
        #expect(driver.restores.isEmpty)
        #expect(driver.value.fans[0].target == 5_400)
    }

    @Test(arguments: [true, false])
    func delayedCheckStillStopsOnThermalPressureOrExternalControl(thermal: Bool) throws {
        let now = Date(), driver = FakeDriver(now: Date()), client = UUID()
        let session = try ControlSession(driver: driver, journal: MemoryJournal())
        try session.apply([FanPolicy(fanID: "F0", mode: .fixed, rpm: 3_000)], client: client, uptime: 10, now: now)
        if !thermal { driver.value.fans[0].target = 4_000 }
        session.heartbeat(client: client, uptime: 13.5)
        session.tick(uptime: 13.5, now: now.addingTimeInterval(3.5), thermalEmergency: thermal)
        #expect(session.status.owner == nil)
        #expect(session.status.recoveryReason == (thermal ? .thermalEmergency : .controlFailure))
        #expect(driver.restores == ["F0"])
        #expect(driver.writes == ["F0"])
    }

    @Test func unchangedTargetsStillDetectExternalChangesWithoutRepeatedWrites() throws {
        let now = Date(), driver = FakeDriver(now: Date()), client = UUID()
        let session = try ControlSession(driver: driver, journal: MemoryJournal())
        try session.apply([FanPolicy(fanID: "F0", mode: .fixed, rpm: 3_000)], client: client, uptime: 10, now: now)
        session.heartbeat(client: client, uptime: 11)
        session.tick(uptime: 11, now: now.addingTimeInterval(1))
        #expect(driver.writes == ["F0"])
        driver.value.fans[0].target = 4_000
        session.heartbeat(client: client, uptime: 12)
        session.tick(uptime: 12, now: now.addingTimeInterval(2))
        #expect(driver.writes == ["F0"])
        #expect(driver.restores == ["F0"])
        #expect(session.status.recoveryReason == .controlFailure)
    }

    @Test(arguments: [true, false])
    func disconnectDuringSafetyRecoveryPreservesOriginalReason(thermal: Bool) throws {
        let now = Date(), driver = FakeDriver(now: Date()), journal = MemoryJournal(), client = UUID()
        let session = try ControlSession(driver: driver, journal: journal)
        try session.apply([FanPolicy(fanID: "F0", mode: .fixed, rpm: 3_000)], client: client, uptime: 10, now: now)
        driver.failRestore = "F0"
        if !thermal { driver.value.fans[0].target = 4_000 }
        session.tick(uptime: 11, now: now, thermalEmergency: thermal)
        #expect(session.status.recoveryBlocked)
        session.disconnected(client: client)
        #expect(session.status.recoveryReason == (thermal ? .thermalEmergency : .controlFailure))
        #expect(driver.restores == ["F0"])
        driver.failRestore = nil
        session.tick(uptime: 12, now: now)
        #expect(!session.status.recoveryBlocked && session.status.owner == nil)
        #expect(session.status.recoveryReason?.permitsAutomaticResume == false)
        #expect(journal.fans.isEmpty)
    }

    @Test func sameTargetIsWrittenAgainAfterExplicitAutomatic() throws {
        let now = Date(), driver = FakeDriver(now: Date()), client = UUID()
        let session = try ControlSession(driver: driver, journal: MemoryJournal())
        let fixed = FanPolicy(fanID: "F0", mode: .fixed, rpm: 3_000)
        try session.apply([fixed], client: client, uptime: 10, now: now)
        try session.apply([FanPolicy(fanID: "F0", mode: .automatic)], client: client, uptime: 11, now: now.addingTimeInterval(1))
        try session.apply([fixed], client: client, uptime: 12, now: now.addingTimeInterval(2))
        #expect(driver.writes == ["F0", "F0"])
        #expect(driver.value.fans[0].mode == .fixed)
        #expect(driver.value.fans[0].target == 3_000)
    }

    @Test func recoveryFailureBlocksNewControlAndRetainsJournal() throws {
        let now = Date(), driver = FakeDriver(now: Date()), journal = MemoryJournal(), client = UUID()
        let session = try ControlSession(driver: driver, journal: journal)
        let policies = [FanPolicy(fanID: "F0", mode: .fixed, rpm: 3_000)]
        try session.apply(policies, client: client, uptime: 10, now: now)
        driver.failRestore = "F0"
        session.disconnected(client: client)
        #expect(session.status.pendingRecovery == ["F0"])
        #expect(journal.fans == ["F0"])
        #expect(throws: (any Error).self) { try session.apply(policies, client: client, uptime: 11, now: now) }
        driver.failRestore = nil
        session.tick(uptime: 12, now: now.addingTimeInterval(2))
        #expect(session.status.pendingRecovery.isEmpty)
        #expect(journal.fans.isEmpty)
    }

    @Test func restartRecoversJournalAndStaleSensorStopsPolicy() throws {
        let now = Date(), driver = FakeDriver(now: Date()), journal = MemoryJournal(), client = UUID()
        journal.fans = ["F1"]
        let session = try ControlSession(driver: driver, journal: journal)
        #expect(driver.restores == ["F1"])
        let policy = FanPolicy(fanID: "F0", mode: .sensor, sensorID: "T0", low: 40, high: 80)
        try session.apply([policy], temperatureSources: ControlTemperatureSource.resolve([policy], in: driver.value),
                          client: client, uptime: 10, now: now)
        session.heartbeat(client: client, uptime: 12)
        session.tick(uptime: 12, now: now.addingTimeInterval(4))
        #expect(session.status.owner == nil)
        #expect(driver.restores.last == "F0")
        #expect(session.status.recoveryReason == .controlFailure)
        #expect(session.status.message == ControlError.staleSensor.localizedDescription)
    }

    @Test func externalControllerIsNotTakenOver() throws {
        let now = Date(), driver = FakeDriver(now: Date()), journal = MemoryJournal()
        driver.value.fans[0].mode = .fixed
        let session = try ControlSession(driver: driver, journal: journal)
        #expect(throws: (any Error).self) {
            try session.apply([FanPolicy(fanID: "F0", mode: .fixed, rpm: 3_000)], client: UUID(), uptime: 0, now: now)
        }
        #expect(driver.writes.isEmpty)
        #expect(driver.restores.isEmpty)
    }

    @Test func automaticPresetCannotClaimToRestoreAnExternalController() throws {
        let now = Date(), driver = FakeDriver(now: Date()), journal = MemoryJournal()
        driver.value.fans[0].mode = .fixed
        let session = try ControlSession(driver: driver, journal: journal)
        #expect(throws: (any Error).self) {
            try session.apply([FanPolicy(fanID: "F0", mode: .automatic)], client: UUID(), uptime: 0, now: now)
        }
        #expect(driver.restores.isEmpty)
        #expect(driver.value.fans[0].mode == .fixed)
        #expect(session.status.owner == nil)
    }

    @Test func externalTargetChangeStopsWritingEvenWhenModeStaysFixed() throws {
        let now = Date(), driver = FakeDriver(now: Date()), journal = MemoryJournal(), client = UUID()
        let session = try ControlSession(driver: driver, journal: journal)
        try session.apply([FanPolicy(fanID: "F0", mode: .fixed, rpm: 3_000)], client: client, uptime: 10, now: now)
        driver.value.fans[0].target = 4_000
        session.heartbeat(client: client, uptime: 11)
        session.tick(uptime: 11, now: now.addingTimeInterval(1))
        #expect(driver.writes == ["F0"])
        #expect(driver.restores == ["F0"])
        #expect(session.status.owner == nil)
    }

    @Test func fullDiskPreventsControlAndBlocksUntilRecoveryJournalIsCleared() throws {
        let now = Date(), driver = FakeDriver(now: Date()), journal = MemoryJournal(), client = UUID()
        let session = try ControlSession(driver: driver, journal: journal)
        let policies = [FanPolicy(fanID: "F0", mode: .fixed, rpm: 3_000)]
        journal.failSave = true
        #expect(throws: (any Error).self) { try session.apply(policies, client: client, uptime: 10, now: now) }
        #expect(driver.writes.isEmpty)
        journal.failSave = false
        try session.apply(policies, client: client, uptime: 10, now: now)
        journal.failSave = true
        session.disconnected(client: client)
        #expect(driver.restores == ["F0"])
        #expect(session.status.recoveryBlocked)
        #expect(journal.fans == ["F0"])
        #expect(throws: (any Error).self) { try session.apply(policies, client: client, uptime: 11, now: now) }
        journal.failSave = false
        try session.release(client: UUID())
        #expect(!session.status.recoveryBlocked)
        #expect(journal.fans.isEmpty)
    }

    @Test func expiredConnectionCannotRenewAnotherConnectionsLease() throws {
        let now = Date(), driver = FakeDriver(now: Date()), journal = MemoryJournal(), first = UUID(), second = UUID()
        let session = try ControlSession(driver: driver, journal: journal)
        let policies = [FanPolicy(fanID: "F0", mode: .fixed, rpm: 3_000)]
        try session.apply(policies, client: first, uptime: 10, now: now)
        session.disconnected(client: first)
        try session.apply(policies, client: second, uptime: 11, now: now)
        session.heartbeat(client: first, uptime: 20)
        session.disconnected(client: first)
        #expect(session.status.owner == second)
        session.tick(uptime: 20, now: now.addingTimeInterval(9))
        #expect(session.status.owner == nil)
    }
}
