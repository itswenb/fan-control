import Foundation
import Testing
import FanCore
@testable import FanAppModel

private final class MemoryJournal: ControlJournal {
    var fans = Set<String>()
    func load() throws -> Set<String> { fans }
    func save(_ fans: Set<String>) throws { self.fans = fans }
}

private final class MemoryDriver: FanControlDriver {
    var value: HardwareSnapshot
    var restores = 0

    init() {
        let now = Date()
        value = HardwareSnapshot(model: "test", chip: "test", source: .live,
                                 fans: [FanReading(id: "F0", name: "Fan", rpm: 2_000, minimum: 1_200, maximum: 6_000,
                                                   mode: .automatic, sampledAt: now, controlSupported: true)],
                                 sensors: [SensorReading(id: "T0", name: "CPU", group: .cpu, celsius: 55, sampledAt: now)], timestamp: now)
    }

    func snapshot() throws -> HardwareSnapshot { value }
    func setTarget(fanID: String, rpm: Double) throws { value.fans[0].mode = .fixed; value.fans[0].target = rpm }
    func restoreAutomatic(fanID: String) throws { restores += 1; value.fans[0].mode = .automatic }
}

@MainActor
private final class MemoryReader: HardwareSampling {
    let driver: MemoryDriver
    var samples = 0
    var stale = false

    init(driver: MemoryDriver) { self.driver = driver }
    func reset() async {}
    func sample() async throws -> HardwareSnapshot {
        samples += 1
        let now = Date()
        driver.value.timestamp = now
        driver.value.fans[0].sampledAt = now
        driver.value.sensors[0].sampledAt = stale ? now.addingTimeInterval(-10) : now
        return driver.value
    }
}

@MainActor
private final class MemoryService: ControlServiceConnection {
    let bundled = true, signed = true, installed = true
    var onDisconnect: (() -> Void)?
    let session: ControlSession
    let client = UUID()
    var requests: [HelperRequest.Operation] = []
    var holdRestore = false
    var failApply = false
    var restoreContinuation: CheckedContinuation<Void, Never>?
    var applyCount: Int { requests.filter { $0 == .apply }.count }

    init(driver: MemoryDriver) throws { session = try ControlSession(driver: driver, journal: MemoryJournal()) }
    func register() async throws {}
    func unregister(connectionFailed: Bool) async throws {}
    func disconnect() { session.disconnected(client: client); onDisconnect?() }

    func request(_ request: HelperRequest) async throws -> HelperReply {
        requests.append(request.operation)
        switch request.operation {
        case .apply:
            if failApply { throw ControlError.invalidRPM }
            try session.apply(request.policies, client: client, uptime: ProcessInfo.processInfo.systemUptime, now: Date())
        case .restore:
            if holdRestore { await withCheckedContinuation { restoreContinuation = $0 } }
            try session.release(client: client)
        case .heartbeat: session.heartbeat(client: client, uptime: ProcessInfo.processInfo.systemUptime)
        default: break
        }
        var reply = HelperReply(available: true, status: session.status)
        reply.ownsSession = session.status.owner == client
        return reply
    }
}

@MainActor
private final class Fixture {
    let driver = MemoryDriver()
    let reader: MemoryReader
    let service: MemoryService
    let store: AppStore
    let directory: URL
    let defaults: UserDefaults
    let suite = "FanControlLifecycleTests." + UUID().uuidString
    let policy = FanPolicy(fanID: "F0", mode: .sensor, sensorID: "T0", low: 40, high: 80)

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defaults = try #require(UserDefaults(suiteName: suite))
        reader = MemoryReader(driver: driver)
        service = try MemoryService(driver: driver)
        store = AppStore(defaults: defaults, storageDirectory: directory, reader: reader, helper: service)
        store.snapshot = driver.value
        store.helperAvailable = true
    }

    func close() {
        service.restoreContinuation?.resume(); service.restoreContinuation = nil
        store.stop()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
struct LifecycleTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition(), "生命周期流程未在期限内完成")
    }

    @Test(arguments: [FanMode.fixed, .sensor])
    func wakeRestoresPresetAndDuplicateWakeDoesNotReapply(mode: FanMode) async throws {
        let f = try Fixture()
        defer { f.close() }
        let policy = mode == .fixed ? FanPolicy(fanID: "F0", mode: .fixed, rpm: 3_000) : f.policy
        let preset = FanPreset(name: "编译", model: "test", source: .live, policies: [policy])
        f.store.presets = [preset]
        try await f.store.apply([policy], presetID: preset.id)
        f.store.suspend()
        f.store.resume()
        try await waitUntil { f.service.applyCount == 2 && !f.store.controlPending }
        #expect(f.driver.restores == 1)
        #expect(f.store.displayPolicies == [policy])
        #expect(f.store.activePresetName == "编译")
        #expect(f.service.session.status.policies == [policy])
        f.store.resume()
        #expect(f.store.snapshot != nil)
        #expect(f.service.applyCount == 2)
    }

    @Test func quickWakeWaitsForSleepRecoveryBeforeReadingAndApplying() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.store.apply([f.policy])
        f.service.holdRestore = true
        f.store.suspend()
        try await waitUntil { f.service.restoreContinuation != nil }
        f.store.resume()
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.reader.samples == 0)
        #expect(f.service.applyCount == 1)
        f.service.restoreContinuation?.resume(); f.service.restoreContinuation = nil
        try await waitUntil { f.service.applyCount == 2 && !f.store.controlPending }
        #expect(f.driver.value.fans[0].mode == .fixed)
        #expect(f.store.displayPolicies == [f.policy])
    }

    @Test func explicitAutomaticStaysAutomaticAfterWake() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.store.apply([f.policy])
        f.store.restoreAutomatic()
        try await waitUntil { f.store.displayPolicies.isEmpty && !f.store.controlPending }
        f.store.suspend(); f.store.resume()
        try await waitUntil { f.reader.samples > 0 && f.store.helperAvailable }
        #expect(f.service.applyCount == 1)
        #expect(f.service.session.status.policies.isEmpty)
        #expect(f.driver.value.fans[0].mode == .automatic)
    }

    @Test func staleWakeDataStopsResumeAndNextWakeCanTryAgain() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.store.apply([f.policy])
        f.reader.stale = true
        f.store.suspend(); f.store.resume()
        try await waitUntil { f.store.alertMessage != nil }
        #expect(f.service.applyCount == 1)
        #expect(f.driver.value.fans[0].mode == .automatic)
        f.reader.stale = false
        f.store.suspend(); f.store.resume()
        try await waitUntil { f.service.applyCount == 2 && !f.store.controlPending }
        #expect(f.service.session.status.policies == [f.policy])
    }

    @Test func failedWakeApplyIsNotRepeatedByPolling() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.store.apply([f.policy])
        f.service.failApply = true
        f.store.suspend(); f.store.resume()
        try await waitUntil { f.store.alertMessage != nil }
        try await waitUntil { f.reader.samples >= 2 }
        #expect(f.service.applyCount == 2)
        #expect(f.driver.value.fans[0].mode == .automatic)
        #expect(f.store.displayPolicies.isEmpty)
    }
}
