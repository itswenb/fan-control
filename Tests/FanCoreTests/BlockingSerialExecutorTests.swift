import Foundation
import Testing
import FanCore

private actor BlockingProbe {
    private let executor = BlockingSerialExecutor(label: "fancontrol.test.blocked")
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    func wait(started: DispatchSemaphore, release: DispatchSemaphore) {
        started.signal()
        _ = release.wait(timeout: .now() + 8)
    }
}

private actor IndependentProbe {
    private let executor = BlockingSerialExecutor(label: "fancontrol.test.independent")
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    func respond() -> Bool { true }
}

private final class DelayedFanDriver: FanControlDriver {
    let now = Date()
    var mode = FanMode.automatic
    var target: Double?
    func controlSnapshot(temperatureSources: [ControlTemperatureSource]) throws -> HardwareSnapshot {
        HardwareSnapshot(model: "test", chip: "test", source: .live,
            fans: [FanReading(id: "F0", name: "F0", rpm: 2_000, minimum: 1_000, maximum: 6_000,
                              mode: mode, target: target, sampledAt: now, controlSupported: true)],
            sensors: [], timestamp: now)
    }
    func setTarget(fanID: String, rpm: Double) throws { mode = .fixed; target = rpm }
    func restoreAutomatic(fanID: String) throws { mode = .automatic; target = nil }
}

private final class DelayedFanJournal: ControlJournal {
    private var fans = Set<String>()
    func load() throws -> Set<String> { fans }
    func save(_ fans: Set<String>) throws { self.fans = fans }
}

private actor FanLeaseProbe {
    private let executor = BlockingSerialExecutor(label: "fancontrol.test.fan-lease")
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private let client = UUID()
    private let inbox: LeaseHeartbeatInbox
    private let session: ControlSession

    init(inbox: LeaseHeartbeatInbox) throws {
        self.inbox = inbox
        session = try ControlSession(driver: DelayedFanDriver(), journal: DelayedFanJournal())
        try session.apply([FanPolicy(fanID: "F0", mode: .fixed, rpm: 2_000)], client: client, uptime: 10, now: Date())
    }

    func delayedTick(started: DispatchSemaphore, release: DispatchSemaphore) -> Bool {
        started.signal()
        _ = release.wait(timeout: .now() + 3)
        if let received = inbox.latest(.fan) { session.heartbeat(client: client, uptime: received) }
        session.tick(uptime: 18.9, now: Date())
        return session.status.owner == client
    }

    func expire() -> Bool {
        session.tick(uptime: 19.1, now: Date())
        return session.status.owner == nil && session.status.recoveryReason == .heartbeatExpired
    }
}

struct BlockingSerialExecutorTests {
    @Test func blockedHardwareWorkDoesNotBlockIndependentWorker() async {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let blocked = BlockingProbe(), independent = IndependentProbe()
        let operation = Task { await blocked.wait(started: started, release: release) }
        let entered = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: started.wait(timeout: .now() + 2) == .success) }
        }
        guard entered else { release.signal(); await operation.value; Issue.record("The blocked worker did not start"); return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { release.signal() }
        let begin = ProcessInfo.processInfo.systemUptime
        let response = await independent.respond()
        let elapsed = ProcessInfo.processInfo.systemUptime - begin
        release.signal()
        await operation.value
        #expect(response && elapsed < 1, "Independent power work must respond before the blocked fan operation is released")
    }

    @Test func heartbeatArrivingDuringBlockedFanWorkIsNotLost() async throws {
        let inbox = LeaseHeartbeatInbox(), started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let worker = try FanLeaseProbe(inbox: inbox)
        let operation = Task { await worker.delayedTick(started: started, release: release) }
        let entered = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: started.wait(timeout: .now() + 2) == .success) }
        }
        guard entered else { release.signal(); _ = await operation.value; Issue.record("The fan worker did not start"); return }
        inbox.record(.fan, at: 14)
        release.signal()
        #expect(await operation.value)
        inbox.close()
        #expect(await worker.expire())
    }

    @Test func recentHeartbeatReplyRemainsAvailableDuringLongHardwareStall() async throws {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let blocked = BlockingProbe(), inbox = LeaseHeartbeatInbox(), client = UUID()
        var reply = HelperReply(available: true, status: SessionStatus(owner: client, policies: [], pendingRecovery: [], message: nil))
        reply.ownsSession = true
        inbox.publishFanReply(reply, at: ProcessInfo.processInfo.systemUptime)
        let operation = Task { await blocked.wait(started: started, release: release) }
        let entered = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: started.wait(timeout: .now() + 2) == .success) }
        }
        guard entered else { release.signal(); await operation.value; Issue.record("The blocked worker did not start"); return }
        try await Task.sleep(for: .seconds(5.2))
        let now = ProcessInfo.processInfo.systemUptime
        inbox.record(.fan, at: now)
        #expect(inbox.recentFanReply(at: now)?.ownsSession == true)
        #expect(inbox.latest(.fan) == now)
        release.signal()
        await operation.value
    }
}
