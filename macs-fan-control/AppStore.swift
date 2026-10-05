import AppKit
import DeviceHardware
import Foundation
import Observation
import ServiceManagement
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import FanCore
import FanHardware
#endif

protocol HardwareSampling: Sendable {
    func sample() async throws -> HardwareSnapshot
    func sample(temperatureSources: [ControlTemperatureSource]) async throws -> HardwareSnapshot
    func refreshTemperatureCatalog() async
    func reset() async
}

extension HardwareSampling {
    func sample(temperatureSources: [ControlTemperatureSource]) async throws -> HardwareSnapshot { try await sample() }
    func refreshTemperatureCatalog() async {}
}

extension SMCReader: HardwareSampling {}

enum AppLanguage: String, Codable, CaseIterable { case system, chinese, english }
enum MenuDisplay: String, Codable, CaseIterable { case none, temperature, fan, both }

struct AppSettings: Codable {
    var unit: TemperatureUnit = .celsius
    var precise = true
    var language: AppLanguage = .system
    var showMenuIcon = true
    var menuDisplay: MenuDisplay = .both
    var sensorID: String = ""
    var fanID: String = ""

    init() {}

    private enum CodingKeys: String, CodingKey {
        case unit, precise, language, showMenuIcon, menuDisplay, sensorID, fanID
    }

    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        unit = try values.decodeIfPresent(TemperatureUnit.self, forKey: .unit) ?? unit
        precise = try values.decodeIfPresent(Bool.self, forKey: .precise) ?? precise
        language = try values.decodeIfPresent(AppLanguage.self, forKey: .language) ?? language
        sensorID = try values.decodeIfPresent(String.self, forKey: .sensorID) ?? sensorID
        fanID = try values.decodeIfPresent(String.self, forKey: .fanID) ?? fanID
        let savedDisplay = try values.decodeIfPresent(String.self, forKey: .menuDisplay)
        if savedDisplay == "icon" {
            // 兼容旧版“仅图标”选项，不改变用户已有的菜单栏外观。
            menuDisplay = .none
            showMenuIcon = true
        } else {
            menuDisplay = savedDisplay.flatMap(MenuDisplay.init(rawValue:)) ?? menuDisplay
            showMenuIcon = try values.decodeIfPresent(Bool.self, forKey: .showMenuIcon) ?? (savedDisplay == nil)
        }
        if menuDisplay == .none { showMenuIcon = true }
    }
}

struct DiagnosticEvent: Identifiable {
    let id = UUID()
    let date = Date()
    let message: String
    let isError: Bool
}

/// 稳定的硬件信息与实时读数分开观察，避免每次采样重建窗口和菜单。
struct HardwareOverview: Equatable {
    let model: String
    let chip: String
    let hasFans: Bool
    let fanCountKnown: Bool
    let canControlFans: Bool
    let hasManualFan: Bool
    let hasUnknownFanMode: Bool
}

struct SensorDescriptor: Identifiable, Equatable {
    let id: String
    let name: String
    let group: SensorGroup
}

struct FanDescriptor: Identifiable, Equatable {
    let id: String
    let name: String
    let minimum: Double?
    let maximum: Double?
    let controlSupported: Bool

    init(_ fan: FanReading) {
        id = fan.id
        name = fan.name
        minimum = fan.minimum
        maximum = fan.maximum
        controlSupported = fan.controlSupported
    }
}

@MainActor @Observable
final class AppStore {
    var snapshot: HardwareSnapshot? {
        didSet {
            let overview = snapshot.map {
                HardwareOverview(model: $0.model, chip: $0.chip, hasFans: !$0.fans.isEmpty,
                                 fanCountKnown: $0.fanCountKnown, canControlFans: $0.fans.contains { $0.controlSupported },
                                 hasManualFan: $0.fans.contains { $0.mode == .fixed },
                                 hasUnknownFanMode: $0.fans.contains { $0.mode == nil })
            }
            if hardwareOverview != overview {
                hardwareOverview = overview
                refreshHelperRegistration()
            }
            let catalog = (snapshot?.sensors ?? []).map { SensorDescriptor(id: $0.id, name: $0.name, group: $0.group) }
            if sensorCatalog != catalog { sensorCatalog = catalog }
            let fans = (snapshot?.fans ?? []).map(FanDescriptor.init)
            if fanCatalog != fans { fanCatalog = fans }
        }
    }
    private(set) var hardwareOverview: HardwareOverview?
    private(set) var sensorCatalog: [SensorDescriptor] = []
    private(set) var fanCatalog: [FanDescriptor] = []
    private(set) var menuPresented = false
    var now = Date()
    var isLoading = true
    var isSuspended = false { didSet { updateControlActivity() } }
    var connectionError: String?
    var alertMessage: String?
    var presets: [FanPreset] = []
    var policies: [FanPolicy] = [] {
        didSet {
            updateControlActivity()
            if oldValue.contains(where: { $0.mode != .automatic }) != hasCustomControl { restartHelperPolling() }
        }
    }
    private(set) var displayPolicies: [FanPolicy] = []
    private var helperSessionKnown = false
    var activePresetID: UUID?
    var activeBuiltIn = "automatic"
    var events: [DiagnosticEvent] = []
    var showSavePreset = false
    var showFullSpeed = false
    var showPresets = false
    var showDiagnostics = false
    var showControlSetup = false
    var configurationError: String?
    var loginEnabled = false
    var loginNeedsApproval = false
    var helperAvailable = false
    var helperMessage = ""
    var controlPending = false
    var recoveryUnconfirmed = false {
        didSet {
            if oldValue != recoveryUnconfirmed { restartMonitoring(); restartHelperPolling() }
        }
    }
    var helperRegistered = false
    var helperInstalling = false
    var helperConnectionFailed = false
    var settings: AppSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "settings") }
            if oldValue.language != settings.language { refreshHelperRegistration() }
            if oldValue.menuDisplay != settings.menuDisplay || oldValue.sensorID != settings.sensorID {
                restartMonitoring()
            }
        }
    }

    @ObservationIgnored private let reader: any HardwareSampling
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var helperPollingTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var controlActivity: NSObjectProtocol?
    @ObservationIgnored private var sleepRestoreTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var monitoringGeneration = 0
    @ObservationIgnored private var detailedMonitoring = true
    @ObservationIgnored private let deviceIdentity = MacDeviceHardware.deviceHardware.modelIdentifier
    @ObservationIgnored private let deviceModelName = MacDeviceHardware.deviceHardware.modelName
    @ObservationIgnored private var controlRevision = 0
    @ObservationIgnored private var helperStatusCheck = 0
    @ObservationIgnored private var helperConnectedThisLaunch = false
    @ObservationIgnored private var lastControl: LastControlConfiguration?
    @ObservationIgnored private var startupRestorePending = true {
        didSet { if oldValue != startupRestorePending { restartMonitoring() } }
    }
    @ObservationIgnored private var startupRestoreAttempts = 0
    @ObservationIgnored private let repository: PresetRepository
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let helper: any ControlServiceConnection

    init(defaults: UserDefaults = .standard, storageDirectory: URL? = nil,
         reader: any HardwareSampling = SMCReader(), helper: any ControlServiceConnection = HelperClient()) {
        self.defaults = defaults
        self.reader = reader
        self.helper = helper
        settings = defaults.data(forKey: "settings").flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()
        lastControl = defaults.data(forKey: "lastControlConfiguration").flatMap {
            try? JSONDecoder().decode(LastControlConfiguration.self, from: $0)
        }
        let directory = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FanControl", isDirectory: true)
        repository = PresetRepository(url: directory.appendingPathComponent("presets.json"))
        do { presets = try repository.load() }
        catch { configurationError = error.localizedDescription }
        refreshLoginStatus()
        refreshHelperRegistration()
        helper.onDisconnect = { [weak self] in
            guard let self else { return }
            self.controlRevision += 1
            self.helperAvailable = false
            self.helperSessionKnown = false
            self.displayPolicies = []; self.activePresetID = nil; self.activeBuiltIn = "automatic"
            if self.hasCustomControl || self.controlPending { self.recoveryUnconfirmed = true }
            self.refreshHelperRegistration()
        }
    }

    var english: Bool {
        settings.language == .english || (settings.language == .system && !(Locale.preferredLanguages.first ?? "en").hasPrefix("zh"))
    }
    func text(_ chinese: String, _ english: String) -> String { self.english ? english : chinese }
    var canControl: Bool { helperAvailable && snapshot != nil && !isSuspended && connectionError == nil && !controlPending && !recoveryUnconfirmed }
    var canRegisterHelper: Bool {
        helper.bundled && helper.signed && (hardwareOverview == nil || hardwareOverview?.canControlFans == true)
    }
    var currentPresets: [FanPreset] { presets.filter { $0.source == .live && $0.model == hardwareOverview?.model } }
    var hasCustomControl: Bool { policies.contains { $0.mode != .automatic } }
    var activePresetName: String {
        if recoveryUnconfirmed { return text("恢复未确认", "Recovery unconfirmed") }
        if helperRegistered && !helperSessionKnown { return text("控制状态未确认", "Control state unconfirmed") }
        if let activePresetID, let preset = presets.first(where: { $0.id == activePresetID }) { return preset.name }
        if activeBuiltIn == "full" { return text("全速散热", "Full speed") }
        if displayPolicies.contains(where: { $0.mode != .automatic }) { return text("自定义 · 未保存", "Custom · Unsaved") }
        if hardwareOverview?.hasManualFan == true { return text("外部手动控制", "External control") }
        if hardwareOverview == nil || hardwareOverview?.hasUnknownFanMode == true { return text("模式未确认", "Mode unconfirmed") }
        return text("系统自动", "System automatic")
    }
    var deviceName: String {
        guard let hardwareOverview else { return text("这台 Mac", "This Mac") }
        return deviceIdentity == hardwareOverview.model && deviceModelName != "Unknown" && !deviceModelName.isEmpty ? deviceModelName : hardwareOverview.model
    }
    var selectedSensor: SensorReading? {
        guard let sensors = snapshot?.sensors else { return nil }
        return settings.sensorID.isEmpty ? (sensors.first(where: { $0.group == .cpu && $0.isFresh(at: now) }) ?? sensors.first(where: { $0.isFresh(at: now) })) : sensors.first(where: { $0.id == settings.sensorID })
    }
    var selectedFan: FanReading? {
        guard let fans = snapshot?.fans else { return nil }
        return settings.fanID.isEmpty ? fans.first : fans.first(where: { $0.id == settings.fanID })
    }
    var menuLines: [String] {
        func temperature() -> String { selectedSensor.map { formattedTemperature($0.celsius, fresh: $0.isFresh(at: now)) } ?? "—" }
        func rpm() -> String { (selectedFan.map { formattedRPM($0.rpm, fresh: $0.isFresh(at: now)) } ?? "—") + " RPM" }
        switch settings.menuDisplay {
        case .none: return []
        case .temperature: return [temperature()]
        case .fan: return [rpm()]
        case .both: return [temperature(), rpm()]
        }
    }
    var menuTitle: String { menuLines.joined(separator: "\n") }

    func formattedTemperature(_ value: Double?, fresh: Bool = true) -> String {
        guard fresh, let value, value.isFinite else { return "—" }
        return String(format: settings.precise ? "%.1f%@" : "%.0f%@", settings.unit.display(value), settings.unit.symbol)
    }
    func formattedRPM(_ value: Double?, fresh: Bool = true) -> String {
        guard fresh, let value, value.isFinite else { return "—" }
        return String(format: "%.0f", value)
    }
    func modeName(_ mode: FanMode?) -> String {
        switch mode {
        case .automatic: text("系统自动", "System automatic")
        case .fixed: text("固定转速", "Fixed speed")
        case .sensor: text("温度调速", "Sensor based")
        case nil: text("模式未确认", "Mode unconfirmed")
        }
    }
    func groupName(_ group: SensorGroup) -> String {
        switch group {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: text("内存", "Memory")
        case .battery: text("电池", "Battery")
        case .storage: text("存储", "Storage")
        case .other: text("其他传感器", "Other sensors")
        }
    }
    func fanName(_ fan: FanReading) -> String {
        fanName(FanDescriptor(fan))
    }

    func fanName(_ fan: FanDescriptor) -> String {
        if let name = SensorCatalog.fanName(id: fan.id, model: hardwareOverview?.model ?? "", english: english) { return name }
        guard english else { return fan.name }
        if fan.name == "左侧风扇" { return "Left fan" }
        if fan.name == "右侧风扇" { return "Right fan" }
        return fan.name.replacingOccurrences(of: "风扇 ", with: "Fan ")
    }
    func sensorName(_ sensor: SensorReading) -> String {
        SensorCatalog.syntheticName(key: sensor.id, english: english) ?? sensor.name
    }

    func sensorName(_ sensor: SensorDescriptor) -> String {
        SensorCatalog.syntheticName(key: sensor.id, english: english) ?? sensor.name
    }

    func start() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--capture-preview") { return }
        #endif
        guard !started else { return }
        started = true
        beginPolling()
    }

    private func beginPolling(resetReader: Bool = false) {
        refreshHelperRegistration()
        helperPollingTask?.cancel()
        generation += 1
        restartMonitoring(resetReader: resetReader)
        restartHelperPolling()
    }

    private func restartHelperPolling() {
        guard started, !isSuspended, sleepRestoreTask == nil else { return }
        helperPollingTask?.cancel()
        let expectedGeneration = generation
        // 监控读取可能较慢或失败；控制租约的心跳必须独立于界面采样。
        helperPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.isSuspended, self.generation == expectedGeneration else { return }
                self.updateReadingFreshness()
                if self.helperRegistered && !self.helperInstalling { await self.refreshHelperSession() }
                // 后台系统自动状态不轮询；打开窗口/菜单、切换策略或连接失效时再唤醒。
                guard self.detailedMonitoring || self.menuPresented || self.hasCustomControl || self.recoveryUnconfirmed
                        || (self.helperRegistered && self.startupRestorePending) || self.helperInstalling else { return }
                let interval = self.hasCustomControl || self.recoveryUnconfirmed ? 1 : 2
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func setDetailedMonitoring(_ visible: Bool) {
        guard detailedMonitoring != visible else { return }
        detailedMonitoring = visible
        if visible { refreshHelperRegistration() }
        restartMonitoring()
        restartHelperPolling()
    }

    func setMenuPresented(_ presented: Bool) {
        guard menuPresented != presented else { return }
        menuPresented = presented
        if presented { refreshHelperRegistration() }
        restartMonitoring()
        restartHelperPolling()
    }

    private var needsMonitoring: Bool {
        detailedMonitoring || menuPresented || settings.menuDisplay != .none || needsResumeReadings
    }

    private var needsResumeReadings: Bool {
        recoveryUnconfirmed || (startupRestorePending && lastControl?.policies.contains { $0.mode != .automatic } == true)
    }

    private func restartMonitoring(resetReader: Bool = false) {
        guard started, !isSuspended, sleepRestoreTask == nil else { return }
        pollingTask?.cancel()
        monitoringGeneration += 1
        let expectedGeneration = generation, expectedMonitoring = monitoringGeneration
        guard needsMonitoring || snapshot == nil else { pollingTask = nil; return }
        pollingTask = Task { [weak self] in
            if resetReader { await self?.reader.reset() }
            if self?.detailedMonitoring == true { await self?.reader.refreshTemperatureCatalog() }
            while !Task.isCancelled {
                guard let self, !self.isSuspended, self.generation == expectedGeneration,
                      self.monitoringGeneration == expectedMonitoring else { return }
                let full = self.detailedMonitoring || self.snapshot == nil || self.needsResumeReadings
                do {
                    var value: HardwareSnapshot
                    if full {
                        value = try await self.reader.sample()
                    } else {
                        let needsTemperature = self.menuPresented || self.settings.menuDisplay == .temperature || self.settings.menuDisplay == .both
                        let sensor = self.selectedSensor ?? self.snapshot?.sensors.first(where: { self.settings.sensorID.isEmpty ? $0.group == .cpu : $0.id == self.settings.sensorID })
                        let sources: [ControlTemperatureSource]
                        if needsTemperature, let snapshot = self.snapshot, let sensor {
                            sources = (try? ControlTemperatureSource.resolve([FanPolicy(fanID: "", mode: .sensor, sensorID: sensor.id)], in: snapshot)) ?? []
                        } else { sources = [] }
                        value = try await self.reader.sample(temperatureSources: sources)
                        value = self.mergeMonitoringReadings(value)
                    }
                    guard !Task.isCancelled, self.generation == expectedGeneration,
                          self.monitoringGeneration == expectedMonitoring else { return }
                    self.snapshot = value
                    self.now = Date()
                    self.connectionError = nil
                    self.isLoading = false
                } catch {
                    guard !Task.isCancelled, self.generation == expectedGeneration,
                          self.monitoringGeneration == expectedMonitoring else { return }
                    if self.connectionError != error.localizedDescription { self.record(error.localizedDescription, error: true) }
                    self.connectionError = error.localizedDescription
                    self.isLoading = false
                }
                guard self.needsMonitoring else { return }
                try? await Task.sleep(for: .seconds(self.connectionError == nil ? 2 : 5))
            }
        }
    }

    private func updateReadingFreshness() {
        guard let snapshot else { return }
        let date = Date()
        if snapshot.fans.contains(where: { $0.isFresh(at: now) != $0.isFresh(at: date) })
            || snapshot.sensors.contains(where: { $0.isFresh(at: now) != $0.isFresh(at: date) }) { now = date }
    }

    private func mergeMonitoringReadings(_ reading: HardwareSnapshot) -> HardwareSnapshot {
        var value = reading
        // 名称始终沿用库返回的目录；未采样的测点保持旧时间，不能伪装成新读数。
        let updates = Dictionary(value.sensors.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        value.sensors = (snapshot?.sensors ?? []).map { previous in
            guard var update = updates[previous.id] else { return previous }
            update.name = previous.name
            return update
        }
        for index in value.fans.indices {
            if let previous = snapshot?.fans.first(where: { $0.id == value.fans[index].id }) { value.fans[index].name = previous.name }
        }
        return value
    }

    func retry() {
        isLoading = true
        guard !isSuspended else { return }
        started = true
        beginPolling(resetReader: true)
    }

    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        helperSessionKnown = false
        startupRestorePending = false
        pollingTask?.cancel(); helperPollingTask?.cancel(); generation += 1
        if hasCustomControl || controlPending || recoveryUnconfirmed {
            recoveryUnconfirmed = true
            if sleepRestoreTask == nil {
                sleepRestoreTask = Task { do { try await restoreHardware() } catch { record(error.localizedDescription, error: true) } }
            }
        } else {
            policies = []; activePresetID = nil; activeBuiltIn = "automatic"
        }
        record(text("系统睡眠，暂停采样。", "System sleeping. Sampling paused."))
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        snapshot = nil
        startupRestorePending = true
        startupRestoreAttempts = 0
        record(text("系统已唤醒，等待最新读数后恢复上次策略。", "System awake. Waiting for fresh readings to resume the last policy."))
        let expectedGeneration = generation
        Task {
            // 快速唤醒时，睡眠前的恢复请求可能仍在进行；先完成交接，避免随后清除新策略。
            await sleepRestoreTask?.value
            guard generation == expectedGeneration, !isSuspended else { return }
            sleepRestoreTask = nil
            retry()
        }
    }

    func stop() {
        pollingTask?.cancel(); helperPollingTask?.cancel(); generation += 1
        started = false
        startupRestorePending = false
        helper.disconnect()
        endControlActivity()
    }

    private func updateControlActivity() {
        guard hasCustomControl, !isSuspended else { endControlActivity(); return }
        if controlActivity == nil {
            // 维持用户主动选择的持续控制；仍允许熄屏、合盖和系统正常睡眠。
            controlActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                                   reason: "维持用户选择的风扇策略及控制服务心跳")
        }
    }

    private func endControlActivity() {
        if let controlActivity { ProcessInfo.processInfo.endActivity(controlActivity) }
        controlActivity = nil
    }

    func apply(_ newPolicies: [FanPolicy], presetID: UUID? = nil, builtIn: String = "custom") async throws {
        guard canControl, var snapshot else { throw ControlError.readOnly }
        controlPending = true
        defer { controlPending = false }
        let expectedGeneration = generation
        let temperatureSources = try ControlTemperatureSource.resolve(newPolicies, in: snapshot)
        let date = Date()
        let needsFreshFans = newPolicies.contains { policy in
            policy.mode != .automatic && snapshot.fans.first(where: { $0.id == policy.fanID })?.isFresh(at: date) != true
        }
        let needsFreshSensors = temperatureSources.contains { source in snapshot.sensors.first(where: { $0.id == source.id })?.isFresh(at: date) != true }
        if !detailedMonitoring && (needsFreshFans || needsFreshSensors) {
            // 后台按用户操作补读所选策略需要的数据，不恢复完整持续采样。
            let reading = try await reader.sample(temperatureSources: temperatureSources)
            guard generation == expectedGeneration, !isSuspended, helperAvailable, !recoveryUnconfirmed else { throw ControlError.readOnly }
            snapshot = mergeMonitoringReadings(reading)
            self.snapshot = snapshot
            now = Date()
        }
        try PolicyValidator.validate(newPolicies, in: snapshot, at: Date())
        startupRestorePending = false
        controlRevision += 1
        let expected = newPolicies.contains(where: { $0.mode != .automatic }) ? newPolicies : []
        do {
            let reply = try await helper.request(HelperRequest(operation: .apply, policies: newPolicies,
                                                             temperatureSources: temperatureSources))
            guard reply.status?.recoveryBlocked == false, reply.status?.policies == expected else { throw SessionError.recoveryRequired }
        } catch {
            helper.disconnect()
            recoveryUnconfirmed = true
            helperAvailable = false
            throw error
        }
        policies = newPolicies
        displayPolicies = expected
        helperSessionKnown = true
        activePresetID = presetID; activeBuiltIn = builtIn
        syncActivePreset()
        rememberControl()
        record(text("策略已应用：", "Policy applied: ") + activePresetName)
    }

    func applyFan(_ policy: FanPolicy) async throws {
        var updated = policies.filter { $0.fanID != policy.fanID }
        updated.append(policy)
        try await apply(updated)
    }

    func applyPreset(_ preset: FanPreset) {
        guard canControl else { showControlSetup = true; return }
        Task {
            do {
                guard preset.source == .live, preset.model == snapshot?.model else { throw ControlError.wrongDevice }
                try await apply(preset.policies, presetID: preset.id)
            } catch { alertMessage = error.localizedDescription; record(error.localizedDescription, error: true) }
        }
    }

    func applyFullSpeed() async throws {
        guard let snapshot, !snapshot.fans.isEmpty else { throw ControlError.missingFan }
        let controllable = snapshot.fans.filter(\.controlSupported)
        guard !controllable.isEmpty else { throw ControlError.unsupportedFan }
        let full = try controllable.map { fan -> FanPolicy in
            guard let range = fan.validRange else { throw ControlError.invalidRange }
            return FanPolicy(fanID: fan.id, mode: .fixed, rpm: range.upperBound)
        }
        try await apply(full, builtIn: "full")
    }

    func restoreAutomatic() {
        guard !controlPending else { return }
        guard helperAvailable || recoveryUnconfirmed else { showControlSetup = true; return }
        if !hasCustomControl && !recoveryUnconfirmed && snapshot?.fans.contains(where: { $0.mode == .fixed }) == true {
            alertMessage = text("请先在其他风扇工具中恢复自动并退出该工具，再使用 Fan Control 调速。", "Restore automatic mode in the other fan utility and quit it before using Fan Control.")
            return
        }
        startupRestorePending = false
        Task { do { try await restoreHardware(rememberSelection: true) } catch { alertMessage = error.localizedDescription } }
    }

    func savePreset(name: String, customPolicies: [FanPolicy]? = nil) throws {
        guard let snapshot else { throw ControlError.missingFan }
        let name = try PresetRepository.validatedName(name)
        try PresetRepository.checkUnique(name, in: currentPresets)
        let values = try snapshot.fans.map { fan in
            if let policy = (customPolicies ?? displayPolicies).first(where: { $0.fanID == fan.id }) { return policy }
            guard let mode = fan.mode else { throw ControlError.invalidConfiguration }
            // 保存本机实际观测的配置，不能把外部手动控制误记为系统自动。
            return FanPolicy(fanID: fan.id, mode: mode, rpm: mode == .fixed ? fan.target : nil)
        }
        guard !values.isEmpty else { throw ControlError.missingFan }
        try PolicyValidator.validate(values, in: snapshot, at: Date())
        let preset = FanPreset(name: name, model: snapshot.model, source: .live, policies: values)
        let updated = presets + [preset]
        try repository.save(updated)
        presets = updated
        if customPolicies == nil && hasCustomControl { activePresetID = preset.id; rememberControl() }
        record(text("已保存预设：", "Preset saved: ") + name)
    }

    func renamePreset(_ preset: FanPreset, name: String) throws {
        let name = try PresetRepository.validatedName(name)
        try PresetRepository.checkUnique(name, in: currentPresets, excluding: preset.id)
        var updated = presets
        guard let index = updated.firstIndex(where: { $0.id == preset.id }) else { return }
        updated[index].name = name
        try repository.save(updated); presets = updated
    }

    func deletePreset(_ preset: FanPreset) {
        perform {
            let updated = presets.filter { $0.id != preset.id }
            try repository.save(updated); presets = updated
            if activePresetID == preset.id { activePresetID = nil; activeBuiltIn = "custom" }
            if lastControl?.presetID == preset.id {
                lastControl?.presetID = nil
                saveLastControl()
            }
        }
    }

    func refreshLoginStatus() {
        loginEnabled = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }

    func refreshHelperRegistration() {
        helperRegistered = helper.installed
        if !helper.bundled { helperMessage = text("当前构建未包含控制服务", "This build does not include the control service") }
        else if !helper.signed { helperMessage = text("控制服务签名无效，请重新构建应用", "The control service signature is invalid. Rebuild the app.") }
        else if let snapshot, snapshot.fanCountKnown, snapshot.fans.isEmpty { helperMessage = text("此设备没有风扇，仅提供温度监控。", "This device has no fans. Temperature monitoring is available.") }
        else if let snapshot, !snapshot.fans.contains(where: { $0.controlSupported }) { helperMessage = text("未检测到可用的调速接口或有效转速范围，目前仅支持监控。", "No compatible fan control interface or valid speed range was detected. Monitoring is available.") }
        else if !helperRegistered { helperMessage = text("启用控制服务后，即可切换预设和调节风扇。", "Enable the control service to switch presets and adjust fan speeds.") }
        else if helperMessage.isEmpty { helperMessage = text("控制服务已安装，正在连接…", "Control service installed. Connecting…") }
        if !helperRegistered { helperAvailable = false; helperConnectionFailed = false }
    }

    func registerHelper(automatic: Bool = false) {
        guard !helperInstalling else { return }
        if helperRegistered, let identity = helperBuildIdentity {
            defaults.set(identity, forKey: "automaticHelperRepairAttemptedBuild")
        }
        helperStatusCheck += 1
        helperInstalling = true
        if automatic {
            helperMessage = text("控制服务连接失效，正在更新；请完成管理员授权。", "The control service connection is outdated. Updating; please complete administrator approval.")
        }
        Task {
            defer { helperInstalling = false }
            do {
                try await helper.register()
                refreshHelperRegistration()
                await refreshHelperSession()
            } catch {
                helperMessage = error.localizedDescription
                if !automatic { alertMessage = error.localizedDescription }
            }
        }
    }

    func removeHelper() {
        guard !helperInstalling else { return }
        helperStatusCheck += 1
        helperInstalling = true
        Task {
            defer { helperInstalling = false }
            do {
                if hasCustomControl || recoveryUnconfirmed { try await restoreHardware() }
                try await helper.unregister(connectionFailed: helperConnectionFailed)
                lastControl = nil
                defaults.removeObject(forKey: "lastControlConfiguration")
                startupRestorePending = false
                displayPolicies = []; policies = []; activePresetID = nil; activeBuiltIn = "automatic"
                refreshHelperRegistration()
            } catch { helperMessage = error.localizedDescription; alertMessage = error.localizedDescription }
        }
    }

    private func refreshHelperSession() async {
        guard !controlPending else { return }
        helperStatusCheck += 1
        let check = helperStatusCheck
        let revision = controlRevision, expectedGeneration = generation
        do {
            let reply = try await helper.request(HelperRequest(operation: hasCustomControl && !recoveryUnconfirmed ? .heartbeat : .status))
            guard !controlPending, check == helperStatusCheck, revision == controlRevision, expectedGeneration == generation else { return }
            guard let status = reply.status else { throw SessionError.recoveryRequired }
            helperConnectedThisLaunch = true
            helperSessionKnown = true
            helperConnectionFailed = false
            recoveryUnconfirmed = status.recoveryBlocked || (recoveryUnconfirmed && status.owner != nil)
            helperAvailable = reply.available && !recoveryUnconfirmed
            helperMessage = reply.available ? text("控制服务已连接", "Control service connected") : (status.message ?? text("控制暂不可用：未检测到可用的调速接口，或另一连接正在使用服务。", "Control unavailable: no compatible fan control interface or another active connection."))
            if displayPolicies != status.policies { displayPolicies = status.policies }
            if !recoveryUnconfirmed {
                let wasControlling = hasCustomControl
                if wasControlling, !reply.ownsSession, status.owner == nil,
                   status.recoveryReason?.permitsAutomaticResume == true {
                    startupRestorePending = true
                    startupRestoreAttempts = 0
                }
                let ownedPolicies = reply.ownsSession ? status.policies : []
                if policies != ownedPolicies { policies = ownedPolicies }
                syncActivePreset()
                if wasControlling && !reply.ownsSession, let message = status.message { record(message) }
                if reply.ownsSession {
                    startupRestorePending = false
                    rememberControl()
                } else if status.owner != nil {
                    // 另一连接拥有会话时只同步显示，不接管、不发送其心跳。
                    startupRestorePending = false
                    if lastControl == nil { rememberControl() }
                } else {
                    await restoreLastControlIfNeeded()
                }
            } else {
                activePresetID = nil; activeBuiltIn = "automatic"
            }
        } catch {
            guard !controlPending, check == helperStatusCheck, expectedGeneration == generation else { return }
            helperAvailable = false
            helperSessionKnown = false
            helperConnectionFailed = true
            helperMessage = text("控制服务无法连接。请在设置中更新服务。", "Unable to connect to the control service. Update it in Settings.") + " " + error.localizedDescription
            if hasCustomControl { recoveryUnconfirmed = true }
            automaticallyRepairHelper(after: error)
        }
    }

    private var helperBuildIdentity: String? {
        let app = Bundle.main.bundleURL
        let bundledHelper = app.appendingPathComponent("Contents/Library/HelperTools/FanControlHelper")
        guard let client = try? CodeIdentity.read(at: app, identifier: HelperConstants.appIdentifier),
              let service = try? CodeIdentity.read(at: bundledHelper, identifier: HelperConstants.machService) else { return nil }
        return client.hash + ":" + service.hash
    }

    private func automaticallyRepairHelper(after error: any Error) {
        guard !helperConnectedThisLaunch, helperRegistered, !helperInstalling,
              !hasCustomControl, !recoveryUnconfirmed, canRegisterHelper,
              let identity = helperBuildIdentity,
              defaults.string(forKey: "automaticHelperRepairAttemptedBuild") != identity else { return }
        if let clientError = error as? HelperClientError {
            switch clientError {
            case .timeout, .remote: return
            case .disconnected: break
            }
        }
        registerHelper(automatic: true)
    }

    func restoreHardware(rememberSelection: Bool = false) async throws {
        // 退出或睡眠可能发生在一次 apply 中间；先让该请求结束，再恢复。
        while controlPending { try await Task.sleep(for: .milliseconds(100)) }
        controlPending = true
        controlRevision += 1
        defer { controlPending = false }
        do {
            let reply = try await helper.request(HelperRequest(operation: .restore))
            guard reply.status?.recoveryBlocked == false else { throw SessionError.recoveryRequired }
            policies = []; activePresetID = nil; activeBuiltIn = "automatic"; recoveryUnconfirmed = false
            displayPolicies = []; helperSessionKnown = true
            if rememberSelection { rememberControl() }
            record(text("已确认恢复系统自动。", "Restored to automatic mode."))
        } catch { helper.disconnect(); recoveryUnconfirmed = true; throw error }
    }

    func setLoginEnabled(_ enabled: Bool) {
        perform {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        }
        refreshLoginStatus()
    }

    private func syncActivePreset() {
        guard let snapshot else { return }
        let useLastSelection = activePresetID == nil && activeBuiltIn == "automatic"
        switch PresetSelection.resolve(policies: displayPolicies, in: snapshot, presets: presets,
                                       preferredID: activePresetID ?? (useLastSelection ? lastControl?.presetID : nil),
                                       preferFullSpeed: activeBuiltIn == "full" || (useLastSelection && lastControl?.fullSpeed == true)) {
        case .preset(let id): activePresetID = id; activeBuiltIn = "custom"
        case .automatic: activePresetID = nil; activeBuiltIn = "automatic"
        case .fullSpeed: activePresetID = nil; activeBuiltIn = "full"
        case .custom: activePresetID = nil; activeBuiltIn = "custom"
        }
    }

    private func rememberControl() {
        guard let snapshot else { return }
        let configuration = LastControlConfiguration(model: snapshot.model, policies: displayPolicies,
                                                       presetID: activePresetID, fullSpeed: activeBuiltIn == "full")
        guard lastControl != configuration else { return }
        lastControl = configuration
        saveLastControl()
    }

    private func saveLastControl() {
        guard let lastControl, let data = try? JSONEncoder().encode(lastControl) else { return }
        defaults.set(data, forKey: "lastControlConfiguration")
    }

    private func restoreLastControlIfNeeded() async {
        guard startupRestorePending, canControl, let snapshot else { return }
        guard let lastControl, lastControl.policies.contains(where: { $0.mode != .automatic }) else {
            startupRestorePending = false
            return
        }
        do {
            try lastControl.validateForResume(in: snapshot, at: Date())
        } catch {
            startupRestoreAttempts += 1
            if startupRestoreAttempts >= 3 {
                startupRestorePending = false
                let message = text("上次策略未自动恢复：", "Last policy was not resumed: ") + error.localizedDescription
                alertMessage = message
                record(message, error: true)
            }
            return
        }
        // 实际写入只尝试一次；失败后交给现有恢复流程，不循环重新应用。
        startupRestorePending = false
        let selection = PresetSelection.resolve(policies: lastControl.policies, in: snapshot, presets: presets,
                                                preferredID: lastControl.presetID, preferFullSpeed: lastControl.fullSpeed)
        let id: UUID? = if case .preset(let id) = selection { id } else { nil }
        do {
            try await apply(lastControl.policies, presetID: id, builtIn: selection == .fullSpeed ? "full" : "custom")
            record(text("已恢复上次使用的策略。", "Resumed the last selected policy."))
        } catch {
            let message = text("上次策略恢复失败：", "Unable to resume the last policy: ") + error.localizedDescription
            alertMessage = message
            record(message, error: true)
        }
    }

    func record(_ message: String, error: Bool = false) {
        events.insert(DiagnosticEvent(message: message, isError: error), at: 0)
        if events.count > 100 { events.removeLast(events.count - 100) }
    }

    func perform(_ action: () throws -> Void) {
        do { try action() }
        catch { alertMessage = error.localizedDescription; record(error.localizedDescription, error: true) }
    }

    var diagnosticReport: String {
        let readings = snapshot?.sensors.map { "\($0.id): \($0.celsius.map(String.init(describing:)) ?? "unavailable") °C" }.joined(separator: "\n") ?? "unavailable"
        let log = events.map { "\($0.date.ISO8601Format()) \($0.isError ? "ERROR" : "INFO") \($0.message)" }.joined(separator: "\n")
        return """
        Fan Control · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")
        OS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Model: \(snapshot?.model ?? "unknown")
        Source: AppleSMC
        Hardware control: \(helperAvailable ? "available" : "unavailable")
        Helper: \(helperMessage)
        Recovery unconfirmed: \(recoveryUnconfirmed)
        Fans: \(snapshot?.fans.count ?? 0)
        Sensors: \(snapshot?.sensors.count ?? 0)

        \(readings)

        \(log)
        """
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "FanControl-diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try diagnosticReport.write(to: url, atomically: true, encoding: .utf8) }
    }
}
