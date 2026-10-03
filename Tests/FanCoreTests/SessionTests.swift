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
    init(now: Date) {
        value = HardwareSnapshot(model: "test", chip: "test", source: .live,
                                 fans: ["F0", "F1"].map { FanReading(id: $0, name: $0, rpm: 2_000, minimum: 1_200, maximum: 6_000, mode: .automatic, sampledAt: now, controlSupported: true) },
                                 sensors: [SensorReading(id: "T0", name: "T0", group: .other, celsius: 55, sampledAt: now)], timestamp: now)
    }
    func snapshot() throws -> HardwareSnapshot { value }
    func setTarget(fanID: String, rpm: Double) throws {
        writes.append(fanID)
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

    @Test func samplingTimeoutHasItsOwnRecoveryReason() throws {
        let now = Date(), driver = FakeDriver(now: Date()), client = UUID()
        let session = try ControlSession(driver: driver, journal: MemoryJournal())
        try session.apply([FanPolicy(fanID: "F0", mode: .fixed, rpm: 3_000)], client: client, uptime: 10, now: now)
        session.heartbeat(client: client, uptime: 13.5)
        session.tick(uptime: 13.5, now: now.addingTimeInterval(3.5))
        #expect(session.status.recoveryReason == .samplingInterrupted)
        #expect(session.status.message?.contains("3.5 秒") == true)
        #expect(session.status.owner == nil)
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
        try session.apply([policy], client: client, uptime: 10, now: now)
        session.heartbeat(client: client, uptime: 12)
        session.tick(uptime: 12, now: now.addingTimeInterval(4))
        #expect(session.status.owner == nil)
        #expect(driver.restores.last == "F0")
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
