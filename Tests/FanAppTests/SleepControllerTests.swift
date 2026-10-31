import Foundation
import Testing
import FanCore
@testable import FanAppModel

@MainActor
private final class FakeSleepLights: LidBacklightManaging {
    var failPreparation = false
    var failure: (@MainActor (String) -> Void)?
    func prepare() async throws { if failPreparation { throw SleepLightingError.unavailable } }
    func start(onFailure: @escaping @MainActor (String) -> Void) { failure = onFailure }
    func stop() async throws { failure = nil }
}

@MainActor
private final class FakeSleepService: ControlServiceConnection {
    var bundled = true
    var signed = true
    var installed = true
    var onDisconnect: (() -> Void)?
    var active = false
    var ownedByAnotherClient = false
    var failAfterEnable = false
    var failDisable = false
    var heartbeats = 0
    var operations: [HelperRequest.Operation] = []
    let client = UUID()
    func register() async throws { installed = true }
    func unregister(connectionFailed: Bool) async throws { installed = false }
    func disconnect() { active = false; onDisconnect?() }
    func request(_ request: HelperRequest) async throws -> HelperReply {
        operations.append(request.operation)
        switch request.operation {
        case .sleepEnable:
            if ownedByAnotherClient { throw SleepInhibitionError.busy }
            active = true
            if failAfterEnable { throw HelperClientError.timeout }
        case .sleepDisable:
            if ownedByAnotherClient { throw SleepInhibitionError.busy }
            if failDisable { throw HelperClientError.timeout }
            active = false
        case .sleepHeartbeat: heartbeats += 1
        default: break
        }
        var reply = HelperReply(available: false)
        reply.sleepStatus = SleepInhibitionStatus(available: true, owner: active ? client : nil, active: active)
        if request.operation == .sleepDiagnostics { reply.sleepDiagnostics = "persisted helper: restore.failed code=42" }
        reply.ownsSession = active && !ownedByAnotherClient
        return reply
    }
}

private actor EmptyHardware: HardwareSampling {
    func sample() async throws -> HardwareSnapshot {
        HardwareSnapshot(model: "NoFans", chip: "test", source: .live, fans: [], sensors: [], timestamp: Date())
    }
    func reset() async {}
}

@MainActor
struct SleepControllerTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }

    @Test func exportIncludesPersistedAppEventsAndHelperFailureDetails() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = SleepDiagnosticLog(url: directory.appendingPathComponent("sleep.log"))
        let service = FakeSleepService(), lights = FakeSleepLights()
        let controller = SleepInhibitionController(helper: service, lights: lights, diagnostics: log)
        try await controller.setEnabled(true)
        try await controller.setEnabled(false)
        let report = await controller.diagnosticDetails()
        #expect(report.contains("phase=off") && report.contains("toggle.requested"))
        #expect(report.contains("toggle.confirmed") && report.contains("restore.failed code=42"))
        #expect(service.operations.contains(.sleepDiagnostics))
    }

    @Test func unavailableLightsNeverChangeSystemPower() async throws {
        let service = FakeSleepService(), lights = FakeSleepLights()
        lights.failPreparation = true
        let controller = SleepInhibitionController(helper: service, lights: lights)
        await #expect(throws: SleepLightingError.self) { try await controller.setEnabled(true) }
        #expect(!service.active && service.operations.isEmpty)
        #expect(controller.phase == .off && controller.message != nil)
    }

    @Test func uncertainEnableIsCompensatedWithoutAutomaticallyReenabling() async throws {
        let service = FakeSleepService(), lights = FakeSleepLights()
        service.failAfterEnable = true
        let controller = SleepInhibitionController(helper: service, lights: lights)
        await #expect(throws: HelperClientError.self) { try await controller.setEnabled(true) }
        #expect(!service.active && controller.phase == .off)
        #expect(service.operations == [.sleepEnable, .sleepDisable])
    }

    @Test func failedRestoreRemainsUnknownUntilExplicitRetry() async throws {
        let service = FakeSleepService(), lights = FakeSleepLights()
        let controller = SleepInhibitionController(helper: service, lights: lights)
        try await controller.setEnabled(true)
        service.failDisable = true
        await #expect(throws: HelperClientError.self) { try await controller.release() }
        #expect(controller.phase == .unknown && controller.needsRelease && service.active)
        service.failDisable = false
        try await controller.release()
        #expect(controller.phase == .off && !service.active)
    }

    @Test func lightingFailureReleasesSystemOverride() async throws {
        let service = FakeSleepService(), lights = FakeSleepLights()
        let controller = SleepInhibitionController(helper: service, lights: lights)
        try await controller.setEnabled(true)
        lights.failure?("test lighting failure")
        try await waitUntil { !service.active && controller.message != nil }
        #expect(controller.phase == .off)
    }

    @Test func backgroundAutomaticFanModeStillRenewsSleepLeaseAndQuitReleasesIt() async throws {
        let service = FakeSleepService(), lights = FakeSleepLights()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "SleepControllerTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = AppStore(defaults: defaults, storageDirectory: directory, reader: EmptyHardware(), helper: service, sleepLights: lights)
        defer {
            store.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        store.settings.menuDisplay = .none
        store.setDetailedMonitoring(false)
        store.start()
        try await waitUntil { service.operations.contains(.sleepStatus) }
        try await store.sleepControl.setEnabled(true)
        try await waitUntil { service.heartbeats > 0 }
        #expect(!store.hasCustomControl && service.active && store.canRegisterHelper)
        store.settings = AppSettings()
        #expect(store.sleepControl.isOn)
        try await store.restoreForTermination()
        #expect(!service.active && !store.sleepControl.needsRelease)
        #expect(!service.operations.contains(.restore))
    }

    @Test func anotherClientsLeaseIsDisplayedWithoutClaimingOrReleasingIt() async throws {
        let service = FakeSleepService(), lights = FakeSleepLights()
        service.active = true; service.ownedByAnotherClient = true
        let controller = SleepInhibitionController(helper: service, lights: lights)
        await #expect(throws: SleepInhibitionError.self) { try await controller.setEnabled(true) }
        controller.start()
        defer { controller.stop() }
        try await waitUntil { controller.phase == .off }
        #expect(service.active && !controller.isOn)
        #expect(controller.message != nil)
    }

    @Test func disconnectReconcilesWithoutReacquiringLease() async throws {
        let service = FakeSleepService(), lights = FakeSleepLights()
        let controller = SleepInhibitionController(helper: service, lights: lights)
        service.onDisconnect = { controller.disconnected() }
        try await controller.setEnabled(true)
        service.disconnect()
        #expect(controller.phase == .unknown)
        controller.start()
        defer { controller.stop() }
        try await waitUntil { controller.phase == .off }
        #expect(service.operations.filter { $0 == .sleepEnable }.count == 1)
    }

    @Test func fanDisconnectDoesNotEndIndependentSleepLease() async throws {
        let fanService = FakeSleepService(), sleepService = FakeSleepService(), lights = FakeSleepLights()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "SleepControllerTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = AppStore(defaults: defaults, storageDirectory: directory, reader: EmptyHardware(),
                             helper: fanService, sleepLights: lights, sleepHelper: sleepService)
        defer {
            store.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        store.start()
        try await store.sleepControl.setEnabled(true)
        fanService.disconnect()
        try await waitUntil { sleepService.heartbeats > 0 }
        #expect(sleepService.active && store.sleepControl.phase == .on && lights.failure != nil)
        sleepService.disconnect()
        #expect(store.sleepControl.phase == .unknown)
        try await waitUntil { store.sleepControl.phase == .off }
        #expect(sleepService.operations.filter { $0 == .sleepEnable }.count == 1)
    }
}
