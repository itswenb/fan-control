import Darwin
import Foundation
import Testing
import FanCore
import FanHardware

private final class SleepDriver: SleepInhibitionDriver {
    var state = SleepPowerState(disabled: false, lidClosed: false, onBattery: true, batteryPercent: 80)
    var writes: [Bool] = []
    var failEnableAfterWrite = false
    var failRestore = false
    var beforeWrite: ((Bool) -> Void)?
    func read() throws -> SleepPowerState { state }
    func setDisabled(_ disabled: Bool) throws {
        beforeWrite?(disabled)
        writes.append(disabled)
        if !disabled && failRestore { throw SleepInhibitionError.unconfirmed }
        state.disabled = disabled
        if disabled && failEnableAfterWrite { throw SleepInhibitionError.unconfirmed }
    }
}

private final class SleepJournal: SleepInhibitionJournal {
    var pending = false
    var failSave = false
    func load() throws -> Bool { pending }
    func save(needsRecovery: Bool) throws {
        if failSave { throw SleepInhibitionError.recoveryRequired }
        pending = needsRecovery
    }
}

struct SleepInhibitionTests {
    @Test func queuedOlderHeartbeatDoesNotUndoNewerArrivalOrPreventExpiry() throws {
        let driver = SleepDriver(), client = UUID(), inbox = LeaseHeartbeatInbox()
        let session = try SleepInhibitionSession(driver: driver, journal: SleepJournal())
        try session.enable(client: client, uptime: 10)
        inbox.record(.sleep, at: 14)
        session.heartbeat(client: client, uptime: try #require(inbox.latest(.sleep)))
        session.heartbeat(client: client, uptime: 11)
        session.tick(uptime: 18.9)
        #expect(session.status.active)
        session.tick(uptime: 19.1)
        #expect(!session.status.active && !driver.state.disabled)
    }

    @Test func partialWriteAndRecoveryFailureLeaveActionablePersistentDiagnostics() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = SleepDiagnosticLog(url: directory.appendingPathComponent("sleep.log"))
        let driver = SleepDriver(), journal = SleepJournal()
        let session = try SleepInhibitionSession(driver: driver, journal: journal, diagnostics: diagnostics)
        driver.failEnableAfterWrite = true; driver.failRestore = true
        #expect(throws: SleepInhibitionError.self) { try session.enable(client: UUID(), uptime: 0) }
        let history = diagnostics.history()
        #expect(history.contains("enable.preflight") && history.contains("journal.armed"))
        #expect(history.contains("enable.failed") && history.contains("restore.failed"))
        #expect(history.contains("journal retained") && history.contains("domain=") && history.contains("code="))
        #expect(journal.pending && session.status.recoveryPending)
    }

    @Test func writesJournalBeforeSystemMutationAndRequiresOwnerHeartbeat() throws {
        let driver = SleepDriver(), journal = SleepJournal(), owner = UUID(), stranger = UUID()
        let session = try SleepInhibitionSession(driver: driver, journal: journal)
        driver.beforeWrite = { disabled in if disabled { #expect(journal.pending) } }
        try session.enable(client: owner, uptime: 10)
        #expect(session.status.active && journal.pending && driver.state.disabled)
        #expect(throws: SleepInhibitionError.self) { try session.enable(client: stranger, uptime: 11) }
        #expect(throws: SleepInhibitionError.self) { try session.release(client: stranger) }
        session.heartbeat(client: stranger, uptime: 15)
        session.tick(uptime: 15.1)
        #expect(!session.status.active && !journal.pending && !driver.state.disabled)
        #expect(driver.writes == [true, false])
    }

    @Test func healthyHeartbeatKeepsLeaseWithoutRepeatedWrites() throws {
        let driver = SleepDriver(), journal = SleepJournal(), client = UUID()
        let session = try SleepInhibitionSession(driver: driver, journal: journal)
        try session.enable(client: client, uptime: 0)
        session.heartbeat(client: client, uptime: 10)
        session.tick(uptime: 10)
        #expect(session.status.active && driver.writes == [true])
        session.disconnected(client: client)
        #expect(!driver.state.disabled && !journal.pending)
    }

    @Test func existingExternalSettingAndDesktopAreNeverModified() throws {
        let driver = SleepDriver(), journal = SleepJournal()
        driver.state.disabled = true
        let session = try SleepInhibitionSession(driver: driver, journal: journal)
        #expect(throws: SleepInhibitionError.self) { try session.enable(client: UUID(), uptime: 0) }
        try session.release(client: UUID())
        #expect(driver.writes.isEmpty && driver.state.disabled && session.status.externallyDisabled)
        driver.state.disabled = false; driver.state.lidClosed = nil
        #expect(throws: SleepInhibitionError.self) { try session.enable(client: UUID(), uptime: 1) }
        #expect(driver.writes.isEmpty && !journal.pending)
    }

    @Test func journalFailurePreventsEnableAndPartialEnableRollsBack() throws {
        let driver = SleepDriver(), journal = SleepJournal()
        let session = try SleepInhibitionSession(driver: driver, journal: journal)
        journal.failSave = true
        #expect(throws: SleepInhibitionError.self) { try session.enable(client: UUID(), uptime: 0) }
        #expect(driver.writes.isEmpty)
        journal.failSave = false; driver.failEnableAfterWrite = true
        #expect(throws: SleepInhibitionError.self) { try session.enable(client: UUID(), uptime: 1) }
        #expect(!driver.state.disabled && !journal.pending && !session.status.recoveryPending)
        #expect(driver.writes == [true, false])
    }

    @Test func failedRecoveryBlocksRemovalAndRetriesFromJournalAfterRestart() throws {
        let driver = SleepDriver(), journal = SleepJournal(), client = UUID()
        let session = try SleepInhibitionSession(driver: driver, journal: journal)
        try session.enable(client: client, uptime: 0)
        driver.failRestore = true
        #expect(throws: SleepInhibitionError.self) { try session.prepareRemoval(client: client) }
        #expect(session.status.recoveryPending && journal.pending)
        #expect(throws: SleepInhibitionError.self) { try session.enable(client: client, uptime: 1) }
        let restarted = try SleepInhibitionSession(driver: driver, journal: journal)
        #expect(restarted.status.recoveryPending && journal.pending)
        driver.failRestore = false
        restarted.tick(uptime: 20)
        #expect(!restarted.status.active && !restarted.status.recoveryPending && !journal.pending && !driver.state.disabled)
        #expect(restarted.status.message == "已恢复正常睡眠设置。")
    }

    @Test(arguments: [true, false]) func batteryOrThermalProtectionEndsSession(thermal: Bool) throws {
        let driver = SleepDriver(), journal = SleepJournal(), client = UUID()
        let session = try SleepInhibitionSession(driver: driver, journal: journal)
        try session.enable(client: client, uptime: 0)
        if !thermal { driver.state.batteryPercent = 20 }
        session.tick(uptime: 1, thermalEmergency: thermal)
        #expect(!driver.state.disabled && !session.status.active && !journal.pending)
        #expect(session.status.message != nil)
    }

    @Test func missingBatteryFailsClosedButACDoesNotRequireCapacity() throws {
        let driver = SleepDriver(), journal = SleepJournal(), client = UUID()
        driver.state.batteryPercent = nil
        let session = try SleepInhibitionSession(driver: driver, journal: journal)
        #expect(throws: SleepInhibitionError.self) { try session.enable(client: client, uptime: 0) }
        #expect(driver.writes.isEmpty)
        driver.state.onBattery = false
        try session.enable(client: client, uptime: 1)
        driver.state.onBattery = true
        session.tick(uptime: 2)
        #expect(!driver.state.disabled && !journal.pending)
    }

    @Test func removalAndExternalChangesNeverReenableTheOverride() throws {
        let driver = SleepDriver(), journal = SleepJournal(), client = UUID()
        let session = try SleepInhibitionSession(driver: driver, journal: journal)
        try session.enable(client: client, uptime: 0)
        driver.state.disabled = false
        session.tick(uptime: 1)
        #expect(!session.status.active && driver.writes == [true, false])
        try session.prepareRemoval(client: client)
        #expect(throws: SleepInhibitionError.self) { try session.enable(client: client, uptime: 2) }
        session.cancelRemoval(client: UUID())
        #expect(!session.status.available)
        session.cancelRemoval(client: client)
        try session.enable(client: client, uptime: 3)
        #expect(session.status.active)
    }

    @Test func secureJournalRoundTripsAndRejectsCorruptionAndSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sleep.json")
        let journal = SleepRecoveryJournal(url: url)
        #expect(try !journal.load())
        try journal.save(needsRecovery: true)
        #expect(try journal.load())
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try journal.save(needsRecovery: false)
        #expect(try !journal.load())
        try Data("invalid".utf8).write(to: url)
        #expect(throws: (any Error).self) { try journal.load() }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "/dev/null")
        #expect(throws: (any Error).self) { try journal.load() }
    }
}
