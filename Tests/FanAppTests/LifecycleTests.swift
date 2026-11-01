import Foundation
import Observation
import Testing
import FanCore
@testable import FanAppModel

struct RequestDeadlineTests {
    @Test func timelyReplySurvivesDelayedMainThreadAndLateReplyDoesNot() {
        let timely = RequestDeadline(deadline: 5)
        #expect(timely.received(at: 4.9))
        #expect(timely.hasTimelyReply)

        let late = RequestDeadline(deadline: 5)
        #expect(!late.received(at: 5.1))
        #expect(!late.hasTimelyReply)
    }
}

struct MenuAnimationSettingsTests {
    @Test func oldSettingsDefaultToAnimationAndChoicePersists() throws {
        var settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(settings.animateMenuIcon)
        settings.animateMenuIcon = false
        let saved = try JSONEncoder().encode(settings)
        #expect(!(try JSONDecoder().decode(AppSettings.self, from: saved).animateMenuIcon))
    }
}

private final class MemoryJournal: ControlJournal {
    var fans = Set<String>()
    func load() throws -> Set<String> { fans }
    func save(_ fans: Set<String>) throws { self.fans = fans }
}

private final class MemoryDriver: FanControlDriver {
    var value: HardwareSnapshot
    var restores = 0
    var staleControlReads = 0
    var interruptedControlReads = 0
    var interruptedFanOnlyReads = 0
    var failRestore = false

    init() {
        let now = Date()
        value = HardwareSnapshot(model: "test", chip: "test", source: .live,
                                 fans: [FanReading(id: "F0", name: "Fan", rpm: 2_000, minimum: 1_200, maximum: 6_000,
                                                   mode: .automatic, sampledAt: now, controlSupported: true)],
                                 sensors: [SensorReading(id: "T0", name: "CPU", group: .cpu, celsius: 55, sampledAt: now)], timestamp: now)
    }

    func controlSnapshot(temperatureSources: [ControlTemperatureSource]) throws -> HardwareSnapshot {
        if temperatureSources.isEmpty, interruptedFanOnlyReads > 0 {
            interruptedFanOnlyReads -= 1
            throw ControlError.samplingInterrupted
        }
        if !temperatureSources.isEmpty, interruptedControlReads > 0 {
            interruptedControlReads -= 1
            throw ControlError.samplingInterrupted
        }
        if !temperatureSources.isEmpty, staleControlReads > 0 {
            staleControlReads -= 1
            var reading = value
            reading.sensors[0].celsius = nil
            reading.sensors[0].sampledAt = nil
            return reading
        }
        return value
    }
    func setTarget(fanID: String, rpm: Double) throws { value.fans[0].mode = .fixed; value.fans[0].target = rpm }
    func restoreAutomatic(fanID: String) throws {
        if failRestore { throw ControlError.invalidConfiguration }
        restores += 1; value.fans[0].mode = .automatic
    }
}

@MainActor
private final class MemoryReader: HardwareSampling {
    let driver: MemoryDriver
    var samples = 0
    var fullSamples = 0
    var selectedSources: [[ControlTemperatureSource]] = []
    var stale = false
    var holdSample = false
    var sampleContinuation: CheckedContinuation<Void, Never>?

    init(driver: MemoryDriver) { self.driver = driver }
    func reset() async {}
    func sample() async throws -> HardwareSnapshot {
        fullSamples += 1
        return try await readSnapshot()
    }
    func sample(temperatureSources: [ControlTemperatureSource]) async throws -> HardwareSnapshot {
        selectedSources.append(temperatureSources)
        var value = try await readSnapshot()
        value.sensors = value.sensors.filter { sensor in temperatureSources.contains { $0.id == sensor.id } }
        return value
    }
    private func readSnapshot() async throws -> HardwareSnapshot {
        samples += 1
        if holdSample { await withCheckedContinuation { sampleContinuation = $0 } }
        let now = Date()
        driver.value.timestamp = now
        driver.value.fans[0].sampledAt = now
        driver.value.sensors[0].sampledAt = stale ? now.addingTimeInterval(-10) : now
        return driver.value
    }
}

@MainActor
private final class MemoryService: ControlServiceConnection {
    let signed = true
    var bundleChecks = 0
    var installationChecks = 0
    var isInstalled = true
    var bundled: Bool { bundleChecks += 1; return true }
    var installed: Bool { installationChecks += 1; return isInstalled }
    var onDisconnect: (() -> Void)?
    let session: ControlSession
    let client = UUID()
    var requests: [HelperRequest.Operation] = []
    var holdRestore = false
    var holdStatus = false
    var failApply = false
    var timeoutsBeforeApply = 0
    var timeoutsAfterApply = 0
    var onApplyTimeout: (() -> Void)?
    var transportError = HelperClientError.timeout
    var disconnects = 0
    var restoreContinuation: CheckedContinuation<Void, Never>?
    private var statusContinuations: [CheckedContinuation<Void, Never>] = []
    var statusContinuation: CheckedContinuation<Void, Never>? {
        get { statusContinuations.last }
        set {
            if let newValue { statusContinuations.append(newValue) }
            else if !statusContinuations.isEmpty { statusContinuations.removeLast() }
        }
    }
    var applyCount: Int { requests.filter { $0 == .apply }.count }

    init(driver: MemoryDriver) throws { session = try ControlSession(driver: driver, journal: MemoryJournal()) }
    func register() async throws {}
    func unregister(connectionFailed: Bool) async throws {}
    func disconnect() { disconnects += 1; session.disconnected(client: client); onDisconnect?() }

    func request(_ request: HelperRequest) async throws -> HelperReply {
        requests.append(request.operation)
        switch request.operation {
        case .apply:
            if failApply { throw ControlError.invalidRPM }
            if timeoutsBeforeApply > 0 {
                timeoutsBeforeApply -= 1
                onApplyTimeout?()
                throw transportError
            }
            do {
                try session.apply(request.policies, temperatureSources: request.temperatureSources,
                                  client: client, uptime: ProcessInfo.processInfo.systemUptime, now: Date())
            } catch SessionError.readingsNotReady { throw HelperClientError.readingsNotReady }
            if timeoutsAfterApply > 0 {
                timeoutsAfterApply -= 1
                onApplyTimeout?()
                throw transportError
            }
        case .restore:
            if holdRestore { await withCheckedContinuation { restoreContinuation = $0 } }
            try session.release(client: client)
        case .heartbeat: session.heartbeat(client: client, uptime: ProcessInfo.processInfo.systemUptime)
        case .status:
            if holdStatus { await withCheckedContinuation { statusContinuation = $0 } }
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

    init(controlSampleTimeout: Duration = .seconds(5)) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defaults = try #require(UserDefaults(suiteName: suite))
        reader = MemoryReader(driver: driver)
        service = try MemoryService(driver: driver)
        store = AppStore(defaults: defaults, storageDirectory: directory, reader: reader, helper: service,
                         controlSampleTimeout: controlSampleTimeout)
        store.snapshot = driver.value
        store.helperAvailable = true
    }

    func close() {
        store.stop()
        service.onApplyTimeout = nil
        reader.sampleContinuation?.resume(); reader.sampleContinuation = nil
        service.restoreContinuation?.resume(); service.restoreContinuation = nil
        while let continuation = service.statusContinuation {
            continuation.resume(); service.statusContinuation = nil
        }
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
struct LifecycleTests {
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition(), "生命周期流程未在期限内完成")
    }

    @Test func blockedControlReadTimesOutWithoutLateWriteOrUnboundedRetries() async throws {
        let f = try Fixture(controlSampleTimeout: .milliseconds(150))
        defer { f.close() }
        f.store.setDetailedMonitoring(false)
        f.store.snapshot?.fans[0].sampledAt = Date().addingTimeInterval(-10)
        f.store.snapshot?.sensors[0].sampledAt = Date().addingTimeInterval(-10)
        f.reader.holdSample = true
        let attempt = Task { try await f.store.apply([f.policy]) }
        try await waitUntil { f.reader.sampleContinuation != nil }
        do { try await attempt.value; Issue.record("A blocked hardware read must time out") }
        catch { #expect(error.localizedDescription.contains("超时")) }
        #expect(!f.store.controlPending && f.service.applyCount == 0)
        do { try await f.store.apply([f.policy]); Issue.record("A second hardware read must not be queued") }
        catch { #expect(error.localizedDescription.contains("尚未结束")) }
        #expect(f.reader.samples == 1 && f.service.applyCount == 0)
        f.reader.holdSample = false
        f.reader.sampleContinuation?.resume(); f.reader.sampleContinuation = nil
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.service.applyCount == 0, "A late reading must never apply the expired request")
        try await f.store.apply([f.policy])
        #expect(f.service.applyCount == 1)
    }

    @Test func temporaryMaximumIsDisplayedAndClearedAfterFreshSampling() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.store.apply([f.policy])
        f.driver.interruptedControlReads = 1
        f.service.session.tick(uptime: ProcessInfo.processInfo.systemUptime, now: Date())
        #expect(f.driver.value.fans[0].target == 6_000)
        f.store.start()
        try await waitUntil { f.store.fanSafetyMessage != nil }
        #expect(f.store.fanSafetyMessage?.contains("暂时全速") == true)
        f.driver.value.timestamp = Date()
        f.driver.value.fans[0].sampledAt = Date()
        f.driver.value.sensors[0].sampledAt = Date()
        f.service.session.tick(uptime: ProcessInfo.processInfo.systemUptime, now: Date())
        try await waitUntil { f.store.fanSafetyMessage == nil }
        #expect(f.service.session.status.owner == f.service.client)
    }

    @Test func liveReadingsDoNotInvalidateHardwareInformationOrSensorCatalog() throws {
        let f = try Fixture()
        defer { f.close() }
        withObservationTracking {
            _ = f.store.deviceName
            _ = f.store.hardwareOverview
            _ = f.store.currentPresets
            _ = f.store.activePresetName
            _ = f.store.sensorCatalog
            _ = f.store.fanCatalog.map { f.store.fanName($0) }
            _ = f.store.canRegisterHelper
        } onChange: {
            Issue.record("温度、转速和时间戳变化不能触发静态标题、菜单或目录刷新")
        }
        var value = f.driver.value
        value.sensors[0].celsius = 63
        value.sensors[0].sampledAt = Date()
        value.fans[0].rpm = 2_500
        value.timestamp = Date()
        f.store.snapshot = value
        f.store.now = Date()
        #expect(f.store.snapshot?.sensors[0].celsius == 63)
        #expect(f.store.snapshot?.fans[0].rpm == 2_500)
    }

    @Test func hardwareInformationTracksModeAndCatalogChanges() throws {
        let f = try Fixture()
        defer { f.close() }
        f.service.isInstalled = false
        var value = f.driver.value
        value.fans[0].mode = .fixed
        value.fans[0].name = "Exhaust fan"
        value.fans[0].maximum = 6_200
        value.sensors[0].name = "CPU Die"
        value.sensors.append(SensorReading(id: "T1", name: "Battery", group: .battery, celsius: 30, sampledAt: Date()))
        f.store.snapshot = value
        #expect(f.store.activePresetName == f.store.text("外部手动控制", "External control"))
        #expect(f.store.sensorCatalog.map(\.name) == ["CPU Die", "Battery"])
        #expect(f.store.fanCatalog.first?.name == "Exhaust fan")
        #expect(f.store.fanCatalog.first?.maximum == 6_200)
        value.fans[0].controlSupported = false
        f.store.snapshot = value
        // 无风扇控制能力仍可安装防休眠服务。 / Sleep control does not require a fan interface.
        #expect(f.store.canRegisterHelper)
        #expect(f.store.fanCatalog.first?.controlSupported == false)
        value.sensors.removeFirst()
        value.fans.removeAll()
        f.store.snapshot = value
        #expect(f.store.sensorCatalog.map(\.id) == ["T1"])
        #expect(f.store.hardwareOverview?.hasFans == false)
        #expect(f.store.fanCatalog.isEmpty)
        f.store.snapshot = nil
        #expect(f.store.hardwareOverview == nil && f.store.sensorCatalog.isEmpty)
    }

    @Test func healthyHeartbeatsDoNotPollInstallationAndReopeningChecksIt() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.store.applyFullSpeed()
        f.store.start()
        try await waitUntil { f.reader.samples >= 1 && f.service.requests.filter { $0 == .heartbeat }.count >= 1 }
        let bundleChecks = f.service.bundleChecks, installationChecks = f.service.installationChecks
        let heartbeats = f.service.requests.filter { $0 == .heartbeat }.count
        try await waitUntil { f.service.requests.filter { $0 == .heartbeat }.count >= heartbeats + 2 }
        #expect(f.service.bundleChecks == bundleChecks)
        #expect(f.service.installationChecks == installationChecks)
        #expect(f.service.applyCount == 1)
        f.service.isInstalled = false
        f.store.setDetailedMonitoring(false)
        f.store.setDetailedMonitoring(true)
        #expect(!f.store.helperRegistered && !f.store.helperAvailable)
        f.service.isInstalled = true
        f.store.setMenuPresented(true)
        #expect(f.store.helperRegistered)
    }

    @Test func healthySessionDoesNotReapplyPolicyWhenMonitoringRefreshes() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.store.apply([f.policy])
        f.store.start()
        try await waitUntil { f.reader.samples >= 3 }
        #expect(f.service.applyCount == 1)
        #expect(f.service.requests.filter { $0 == .heartbeat }.count >= 3)
        #expect(f.store.policies == [f.policy])
    }

    @Test func blockedTemperatureReadDoesNotBlockControlHeartbeat() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.store.apply([f.policy])
        f.reader.holdSample = true
        f.store.start()
        let time = f.store.now
        try await waitUntil { f.reader.sampleContinuation != nil }
        try await waitUntil { f.service.requests.filter { $0 == .heartbeat }.count >= 2 }
        #expect(f.reader.samples == 1)
        #expect(f.service.session.status.policies == [f.policy])
        #expect(f.service.applyCount == 1)
        #expect(f.store.now == time, "控制心跳不能重复触发整张监控表刷新")
    }

    @Test func blockedReadStillMarksOldDataStale() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.store.apply([f.policy])
        f.reader.holdSample = true
        f.store.start()
        try await waitUntil { f.store.snapshot?.sensors[0].isFresh(at: f.store.now) == false }
        #expect(f.store.menuLines[0] == "—")
        let time = f.store.now
        let heartbeats = f.service.requests.filter { $0 == .heartbeat }.count
        try await waitUntil { f.service.requests.filter { $0 == .heartbeat }.count > heartbeats }
        #expect(f.store.now == time, "读数已经失效后不需要每秒重新绘制相同的失效状态")
        #expect(f.service.applyCount == 1)
    }

    @Test func iconOnlyMenuDoesNotObserveHardwareReadings() throws {
        let f = try Fixture()
        defer { f.close() }
        f.store.settings.menuDisplay = .none
        withObservationTracking {
            #expect(f.store.menuLines.isEmpty)
        } onChange: {
            Issue.record("仅图标的菜单栏不应因硬件读数变化而刷新")
        }
        f.store.now = Date()
        f.store.snapshot = f.driver.value
    }

    @Test func closingIconOnlyWindowKeepsMonitoringAndControlHeartbeat() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.store.applyFullSpeed()
        f.store.settings.menuDisplay = .none
        f.store.start()
        try await waitUntil { f.reader.samples >= 1 }
        f.store.setDetailedMonitoring(false)
        let samples = f.reader.samples
        let heartbeats = f.service.requests.filter { $0 == .heartbeat }.count
        try await waitUntil { f.service.requests.filter { $0 == .heartbeat }.count >= heartbeats + 2 }
        #expect(f.reader.samples > samples)
        #expect(f.service.applyCount == 1)
        f.store.setDetailedMonitoring(true)
        try await waitUntil { f.reader.samples > samples }
        #expect(f.service.applyCount == 1)
    }

    @Test func hiddenWindowReadsOnlyMenuSensorAndPreservesLibraryName() async throws {
        let f = try Fixture()
        defer { f.close() }
        f.store.settings.menuDisplay = .temperature
        f.store.start()
        try await waitUntil { f.reader.fullSamples >= 1 }
        f.store.setDetailedMonitoring(false)
        let fullSamples = f.reader.fullSamples
        try await waitUntil { !f.reader.selectedSources.isEmpty }
        #expect(f.reader.fullSamples == fullSamples)
        #expect(f.reader.selectedSources.last == [ControlTemperatureSource(id: "T0", group: .cpu, keys: ["T0"])])
        #expect(f.store.snapshot?.sensors[0].name == "CPU")
        f.store.setDetailedMonitoring(true)
        try await waitUntil { f.reader.fullSamples > fullSamples }
    }

    @Test func backgroundAutomaticKeepsMonitoringAndControlSelectionRestartsHeartbeat() async throws {
        let f = try Fixture()
        defer { f.close() }
        f.store.settings.menuDisplay = .none
        f.store.start()
        try await waitUntil { f.reader.samples >= 1 && f.service.requests.contains(.status) }
        f.store.setDetailedMonitoring(false)
        try await Task.sleep(for: .milliseconds(100))
        let samples = f.reader.samples, requests = f.service.requests.count
        try await Task.sleep(for: .milliseconds(2_100))
        #expect(f.reader.samples > samples && f.service.requests.count == requests)
        try await f.store.applyFullSpeed()
        try await waitUntil { f.service.requests.filter { $0 == .heartbeat }.count >= 2 }
        #expect(f.service.applyCount == 1)
        #expect(f.reader.samples > samples)
    }

    @Test func backgroundPresetRefreshesItsStaleSensorOnDemand() async throws {
        let f = try Fixture()
        defer { f.close() }
        f.store.settings.menuDisplay = .none
        f.store.setDetailedMonitoring(false)
        f.store.snapshot?.sensors[0].sampledAt = Date().addingTimeInterval(-10)
        f.store.snapshot?.fans[0].sampledAt = Date().addingTimeInterval(-10)
        try await f.store.apply([f.policy])
        #expect(f.reader.fullSamples == 0)
        let source = ControlTemperatureSource(id: "T0", group: .cpu, keys: ["T0"])
        #expect(f.reader.selectedSources == [[source]])
        #expect(f.service.applyCount == 1)
    }

    @Test func iconOnlyBackgroundRecoveryKeepsMonitoringAfterResume() async throws {
        let f = try Fixture()
        defer { f.close() }
        f.store.settings.menuDisplay = .none
        try await f.store.applyFullSpeed()
        f.store.start()
        try await waitUntil { f.reader.samples >= 1 }
        f.store.setDetailedMonitoring(false)
        f.store.snapshot?.fans[0].sampledAt = Date().addingTimeInterval(-10)
        f.service.disconnect()
        try await waitUntil { f.service.applyCount == 2 && !f.store.controlPending }
        let samples = f.reader.samples
        let heartbeats = f.service.requests.filter { $0 == .heartbeat }.count
        try await waitUntil { f.service.requests.filter { $0 == .heartbeat }.count >= heartbeats + 2 }
        #expect(f.reader.samples > samples)
        #expect(f.store.activeBuiltIn == "full")
    }

    @Test func heartbeatRecoveryResumesPresetWithoutSleep() async throws {
        let f = try Fixture()
        defer { f.close() }
        let preset = FanPreset(name: "编译", model: "test", source: .live, policies: [f.policy])
        f.store.presets = [preset]
        try await f.store.apply([f.policy], presetID: preset.id)
        let uptime = ProcessInfo.processInfo.systemUptime + 6
        f.service.session.tick(uptime: uptime, now: Date())
        #expect(f.driver.value.fans[0].mode == .automatic)
        f.store.start()
        try await waitUntil { f.service.applyCount == 2 && !f.store.controlPending }
        #expect(f.store.activePresetName == "编译")
        #expect(f.store.displayPolicies == [f.policy])
        #expect(f.service.session.status.policies == [f.policy])
    }

    @Test func repeatedSlowSamplingRestoresAutomaticThenResumesAfterFreshReadings() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.store.apply([f.policy])
        f.driver.interruptedControlReads = 1
        f.driver.interruptedFanOnlyReads = 1
        f.service.session.tick(uptime: ProcessInfo.processInfo.systemUptime, now: Date())
        #expect(f.service.session.status.recoveryReason == .samplingInterrupted)
        #expect(f.driver.value.fans[0].mode == .automatic)
        f.store.start()
        try await waitUntil { f.service.applyCount == 2 && !f.store.controlPending }
        #expect(f.service.session.status.policies == [f.policy])
        #expect(f.driver.value.fans[0].mode == .fixed)
    }

    @Test func delayedFullSpeedCheckDoesNotRestoreAutomaticOrReapply() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.store.applyFullSpeed()
        let uptime = ProcessInfo.processInfo.systemUptime + 3.001
        f.service.session.heartbeat(client: f.service.client, uptime: uptime)
        f.service.session.tick(uptime: uptime, now: Date())
        f.store.start()
        try await waitUntil { f.reader.samples >= 2 && f.service.requests.filter { $0 == .heartbeat }.count >= 2 }
        #expect(f.service.applyCount == 1)
        #expect(f.driver.restores == 0)
        #expect(f.driver.value.fans[0].mode == .fixed && f.driver.value.fans[0].target == 6_000)
        #expect(f.store.activeBuiltIn == "full")
    }

    @Test func connectionLossResumesFullSpeedAfterRecoveryIsConfirmed() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.store.applyFullSpeed()
        f.service.disconnect()
        #expect(f.store.recoveryUnconfirmed)
        f.store.start()
        try await waitUntil { f.service.applyCount == 2 && !f.store.controlPending }
        #expect(!f.store.recoveryUnconfirmed)
        #expect(f.store.activeBuiltIn == "full")
        #expect(f.driver.value.fans[0].target == 6_000)
    }

    @Test(arguments: [true, false])
    func thermalOrExternalControlDoesNotResumeAutomatically(thermal: Bool) async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.store.apply([f.policy])
        if !thermal { f.driver.value.fans[0].target = 5_000 }
        f.service.session.tick(uptime: ProcessInfo.processInfo.systemUptime, now: Date(), thermalEmergency: thermal)
        f.store.start()
        try await waitUntil { f.reader.samples >= 2 && f.service.requests.contains(.status) }
        #expect(f.service.applyCount == 1)
        #expect(f.store.displayPolicies.isEmpty)
        #expect(f.driver.value.fans[0].mode == .automatic)
    }

    @Test func explicitAutomaticAfterTimeoutDoesNotResumePreviousPolicy() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.store.apply([f.policy])
        f.service.session.tick(uptime: ProcessInfo.processInfo.systemUptime + 6, now: Date())
        f.store.restoreAutomatic()
        try await waitUntil { f.store.displayPolicies.isEmpty && !f.store.controlPending }
        f.store.start()
        try await waitUntil { f.reader.samples >= 2 && f.service.requests.contains(.status) }
        #expect(f.service.applyCount == 1)
        #expect(f.driver.value.fans[0].mode == .automatic)
    }

    @Test func failedTimeoutResumeIsNotRepeated() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.store.apply([f.policy])
        f.service.session.tick(uptime: ProcessInfo.processInfo.systemUptime + 6, now: Date())
        f.service.failApply = true
        f.store.start()
        try await waitUntil { f.store.alertMessage != nil }
        try await waitUntil { f.reader.samples >= 2 }
        #expect(f.service.applyCount == 2)
        #expect(f.driver.value.fans[0].mode == .automatic)
        #expect(f.store.displayPolicies.isEmpty)
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
        try await waitUntil(timeout: 8) { f.store.alertMessage != nil }
        #expect(f.service.applyCount == 1)
        #expect(f.driver.value.fans[0].mode == .automatic)
        f.reader.stale = false
        f.store.suspend(); f.store.resume()
        try await waitUntil { f.service.applyCount == 2 && !f.store.controlPending }
        #expect(f.service.session.status.policies == [f.policy])
    }

    @Test func wakeRetriesPreflightRejectionWithoutDisconnectingOrReapplyingSuccessfulPolicy() async throws {
        let f = try Fixture()
        defer { f.close() }
        let preset = FanPreset(name: "CPU 50–65", model: "test", source: .live, policies: [f.policy])
        f.store.presets = [preset]
        try await f.store.apply([f.policy], presetID: preset.id)
        f.driver.staleControlReads = 1
        f.store.suspend(); f.store.resume()
        try await waitUntil { f.service.applyCount == 3 && !f.store.controlPending }
        #expect(f.service.disconnects == 0)
        #expect(f.store.alertMessage == nil && !f.store.recoveryUnconfirmed)
        #expect(f.store.activePresetName == preset.name)
        #expect(f.service.session.status.policies == [f.policy])
        try await waitUntil { f.service.requests.filter { $0 == .heartbeat }.count >= 2 }
        #expect(f.service.applyCount == 3)
    }

    @Test func persistentServiceReadFailureStopsAfterThreePreflightAttempts() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.store.apply([f.policy])
        f.driver.staleControlReads = 100
        f.store.suspend(); f.store.resume()
        try await waitUntil(timeout: 8) { f.store.alertMessage != nil }
        #expect(f.service.applyCount == 4, "原策略一次，唤醒后写入前校验最多三次")
        #expect(f.driver.value.fans[0].mode == .automatic)
        #expect(f.service.session.status.policies.isEmpty)
        #expect(f.service.disconnects == 0)
        let samples = f.reader.samples
        try await waitUntil { f.reader.samples > samples }
        #expect(f.service.applyCount == 4)
    }

    @Test func repeatedHeartbeatDoesNotExhaustWakeReadinessOnTheSameStaleSample() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.store.apply([f.policy])
        f.reader.stale = true
        f.store.suspend(); f.store.resume()
        try await waitUntil { f.reader.samples >= 1 }
        f.reader.holdSample = true
        try await waitUntil(timeout: 8) { f.service.requests.filter { $0 == .status }.count >= 3 }
        #expect(f.store.alertMessage == nil)
        #expect(f.service.applyCount == 1)
        #expect(f.driver.value.fans[0].mode == .automatic)
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

    @Test(arguments: [false, true], [HelperClientError.timeout, .disconnected])
    func wakeTransportTimeoutResumesOnlyAfterStatusConfirmation(appliedBeforeTimeout: Bool, failure: HelperClientError) async throws {
        let f = try Fixture()
        defer { f.close() }
        let preset = FanPreset(name: "CPU 45–65", model: "test", source: .live, policies: [f.policy])
        f.store.presets = [preset]
        try await f.store.apply([f.policy], presetID: preset.id)
        f.service.transportError = failure
        if appliedBeforeTimeout { f.service.timeoutsAfterApply = 1 }
        else { f.service.timeoutsBeforeApply = 1 }
        f.store.suspend(); f.store.resume()
        try await waitUntil(timeout: 8) { f.service.applyCount == 3 && !f.store.controlPending }
        let applies = f.service.requests.indices.filter { f.service.requests[$0] == .apply }
        #expect(f.service.requests[(applies[1] + 1)..<applies[2]].contains(.status))
        #expect(f.service.disconnects == 1)
        #expect(f.driver.restores == (appliedBeforeTimeout ? 2 : 1))
        #expect(f.store.alertMessage == nil && !f.store.recoveryUnconfirmed)
        #expect(f.store.activePresetName == preset.name)
        #expect(f.store.displayPolicies == [f.policy])
        #expect(f.service.session.status.policies == [f.policy])
        try await waitUntil { f.service.requests.filter { $0 == .heartbeat }.count >= 2 }
        #expect(f.service.applyCount == 3)
    }

    @Test func wakeTransportTimeoutStopsAfterThreeAttempts() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.store.apply([f.policy])
        f.service.timeoutsBeforeApply = 100
        f.store.suspend(); f.store.resume()
        try await waitUntil(timeout: 10) { f.store.alertMessage != nil && !f.store.recoveryUnconfirmed }
        #expect(f.service.applyCount == 4)
        #expect(f.store.displayPolicies.isEmpty)
        let samples = f.reader.samples
        try await waitUntil { f.reader.samples > samples }
        #expect(f.service.applyCount == 4)
    }

    @Test func wakeTimeoutWaitsForPendingHardwareRecovery() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.store.apply([f.policy])
        f.service.timeoutsAfterApply = 1
        f.service.onApplyTimeout = { f.driver.failRestore = true }
        f.store.suspend(); f.store.resume()
        try await waitUntil { f.service.session.status.recoveryBlocked }
        let checks = f.service.requests.filter { $0 == .status }.count
        try await waitUntil { f.service.requests.filter { $0 == .status }.count > checks }
        #expect(f.service.applyCount == 2)
        #expect(f.store.recoveryUnconfirmed)
        f.driver.failRestore = false
        f.service.session.tick(uptime: ProcessInfo.processInfo.systemUptime, now: Date())
        try await waitUntil(timeout: 8) { f.service.applyCount == 3 && !f.store.controlPending }
        #expect(!f.store.recoveryUnconfirmed)
        #expect(f.store.displayPolicies == [f.policy])
    }

    @Test(arguments: [false, true], [false, true])
    func wakeTimeoutDoesNotRetryConfirmedSafetyRecovery(thermalEmergency: Bool, blockedRecovery: Bool) async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.store.apply([f.policy])
        f.service.timeoutsAfterApply = 1
        f.service.onApplyTimeout = {
            f.driver.failRestore = blockedRecovery
            if !thermalEmergency { f.driver.value.sensors[0].celsius = nil }
            f.service.session.tick(uptime: ProcessInfo.processInfo.systemUptime, now: Date(), thermalEmergency: thermalEmergency)
            f.driver.value.sensors[0].celsius = 55
        }
        f.store.suspend(); f.store.resume()
        if blockedRecovery {
            try await waitUntil { f.service.disconnects == 1 }
            #expect(f.service.session.status.recoveryBlocked)
            f.driver.failRestore = false
            f.service.session.tick(uptime: ProcessInfo.processInfo.systemUptime, now: Date())
        }
        try await waitUntil(timeout: 8) { f.service.applyCount == 2 && !f.store.recoveryUnconfirmed && f.store.alertMessage != nil }
        let samples = f.reader.samples
        try await waitUntil { f.reader.samples > samples }
        #expect(f.service.applyCount == 2)
        #expect(f.store.displayPolicies.isEmpty)
        #expect(f.service.session.status.recoveryReason == (thermalEmergency ? .thermalEmergency : .controlFailure))
    }

    @Test func explicitAutomaticCancelsPendingTransportResume() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.store.apply([f.policy])
        f.service.timeoutsBeforeApply = 1
        f.service.onApplyTimeout = { f.service.holdStatus = true }
        f.store.suspend(); f.store.resume()
        try await waitUntil { f.service.statusContinuation != nil }
        f.store.restoreAutomatic()
        try await waitUntil { !f.store.controlPending && !f.store.recoveryUnconfirmed }
        f.service.holdStatus = false
        f.service.statusContinuation?.resume(); f.service.statusContinuation = nil
        try await waitUntil { f.reader.samples >= 3 }
        #expect(f.service.applyCount == 2)
        #expect(f.store.displayPolicies.isEmpty)
        #expect(f.driver.value.fans[0].mode == .automatic)
    }

    @Test func wakeTimeoutDoesNotTakeOverAnotherConnection() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.store.apply([f.policy])
        let other = UUID()
        let externalPolicy = FanPolicy(fanID: "F0", mode: .fixed, rpm: 4_500)
        f.service.timeoutsBeforeApply = 1
        f.service.onApplyTimeout = {
            do {
                try f.service.session.apply([externalPolicy], client: other,
                                            uptime: ProcessInfo.processInfo.systemUptime, now: Date())
            } catch { Issue.record(error) }
        }
        f.store.suspend(); f.store.resume()
        try await waitUntil { f.service.requests.filter { $0 == .status }.count >= 3 }
        #expect(f.service.applyCount == 2)
        #expect(f.service.session.status.owner == other)
        #expect(f.service.session.status.policies == [externalPolicy])
        #expect(f.store.recoveryUnconfirmed)
    }
}
