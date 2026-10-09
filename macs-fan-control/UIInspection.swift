#if DEBUG
import AppKit
import Darwin
import SwiftUI

/// 独立配置和只读 SMC 采样；模拟控制心跳，禁止连接真实服务或写硬件。
@MainActor
struct UIInspection: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("--inspect-ui") }
    private static var started = false
    private static var fanPanelAppearances = 0

    static func recordFanPanelAppearance() {
        if isRequested { fanPanelAppearances += 1 }
    }
    private static var cleanup: (() -> Void)?
    private let isMenu: Bool

    init(isMenu: Bool = false) { self.isMenu = isMenu }

    static func describeWindowsIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard isRequested, let index = args.firstIndex(of: "--inspect-ui"), args.indices.contains(index + 1) else { return }
        let windows = NSApp.windows.map {
            ["number": $0.windowNumber, "class": NSStringFromClass(type(of: $0)),
             "visible": $0.isVisible, "title": $0.title] as [String: Any]
        }
        if let data = try? JSONSerialization.data(withJSONObject: windows, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: args[index + 1] + ".windows.json"))
        }
    }

    static func makeStore() -> AppStore {
        let suite = "FanControl.Inspection." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        if ProcessInfo.processInfo.arguments.contains("--inspect-current-settings"),
           let settings = UserDefaults(suiteName: "com.itswenb.fancontrol")?.data(forKey: "settings") {
            defaults.set(settings, forKey: "settings")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        cleanup = {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let helper = InspectionService()
        let store = AppStore(defaults: defaults, storageDirectory: directory, helper: helper)
        store.policies = helper.policies
        return store
    }

    var body: some View {
        Color.clear.onAppear {
            guard Self.isRequested, !Self.started,
                  isMenu == ProcessInfo.processInfo.arguments.contains("--inspect-menu-only") else { return }
            Self.started = true
            Task { await run() }
        }
    }

    private func run() async {
        var result: [String: Any] = [:]
        let profileCPU = !ProcessInfo.processInfo.arguments.contains("--inspect-windows-only")
        result["cpuMeasured"] = profileCPU
        result["version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        result["pid"] = ProcessInfo.processInfo.processIdentifier
        func save() {
            if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--inspect-ui"),
               ProcessInfo.processInfo.arguments.indices.contains(index + 1),
               let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: ProcessInfo.processInfo.arguments[index + 1]))
            }
        }
        do {
            if isMenu {
                try await Task.sleep(for: .seconds(5))
                result["nativeMenuPresented"] = AppLifecycle.store?.menuPresented == true
                if profileCPU { result["menuOpenCPU"] = try await measureCPU() }
                result["awaitingMenuClose"] = true
                save()
                let deadline = ProcessInfo.processInfo.systemUptime + 45
                while AppLifecycle.store?.menuPresented == true, ProcessInfo.processInfo.systemUptime < deadline {
                    try await Task.sleep(for: .milliseconds(200))
                }
                result["menuClosed"] = AppLifecycle.store?.menuPresented == false
                guard AppLifecycle.store?.menuPresented == false else { throw CocoaError(.validationMissingMandatoryProperty) }
                try await Task.sleep(for: .seconds(3))
                if profileCPU { result["afterMenuClosedCPU"] = try await measureCPU() }
            } else {
                AppWindowVisibility.prepareToOpen()
                openWindow(id: "main")
                try await Task.sleep(for: .seconds(5))
                let main = try requireWindow()
                main.collectionBehavior.insert(.moveToActiveSpace)
                main.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                try await Task.sleep(for: .seconds(3))
                result["mainVisible"] = main.occlusionState.contains(.visible)
                if ProcessInfo.processInfo.arguments.contains("--inspect-render-stress") {
                    var current = main
                    var completed = 0
                    for cycle in 0..<36 {
                        NSApp.appearance = NSAppearance(named: cycle.isMultiple(of: 2) ? .aqua : .darkAqua)
                        current.appearance = NSApp.appearance
                        AppLifecycle.store?.settings.language = cycle.isMultiple(of: 3) ? .chinese : .english
                        current.setContentSize(NSSize(width: cycle.isMultiple(of: 2) ? 900 : 860,
                                                      height: cycle.isMultiple(of: 2) ? 560 : 480))
                        if cycle.isMultiple(of: 3) {
                            current.performMiniaturize(nil)
                            try await Task.sleep(for: .milliseconds(150))
                            current.deminiaturize(nil)
                        } else {
                            current.orderOut(nil)
                            try await Task.sleep(for: .milliseconds(150))
                            current.makeKeyAndOrderFront(nil)
                        }
                        if cycle.isMultiple(of: 6) {
                            current.close()
                            AppWindowVisibility.prepareToOpen()
                            openWindow(id: "main")
                            try await Task.sleep(for: .milliseconds(300))
                            current = try requireWindow()
                            current.collectionBehavior.insert(.moveToActiveSpace)
                        }
                        NSApp.activate(ignoringOtherApps: true)
                        try await Task.sleep(for: .milliseconds(500))
                        guard current.isVisible, !current.isMiniaturized else { throw CocoaError(.validationMissingMandatoryProperty) }
                        let appearances = Self.fanPanelAppearances
                        let policies = AppLifecycle.store?.policies
                        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
                        try await Task.sleep(for: .milliseconds(300))
                        guard Self.fanPanelAppearances == appearances + 1,
                              AppLifecycle.store?.policies == policies,
                              AppLifecycle.store?.alertMessage == nil else { throw CocoaError(.validationMissingMandatoryProperty) }
                        completed += 1
                        result["renderCycles"] = completed
                        result["renderWindow"] = current.windowNumber
                        save()
                        if completed.isMultiple(of: 12) { try await Task.sleep(for: .seconds(2)) }
                    }
                    AppLifecycle.store?.settings.language = .english
                    NSApp.appearance = NSAppearance(named: .aqua)
                    current.appearance = NSApp.appearance
                    current.setContentSize(NSSize(width: 900, height: 560))
                    try await Task.sleep(for: .seconds(1))
                    result["wakeRebuilds"] = completed
                    result["renderStressPassed"] = true
                    save()
                    try await Task.sleep(for: .seconds(15))
                    AppLifecycle.store?.stop()
                    Self.cleanup?()
                    NSApp.terminate(nil)
                    return
                }
                if profileCPU { result["openCPU"] = try await measureCPU() }
                save()
                openSettings()
                try await Task.sleep(for: .seconds(3))
                let settings = NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) && $0 !== main }
                guard let settings else { throw CocoaError(.validationMissingMandatoryProperty) }
                settings.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                try await Task.sleep(for: .seconds(2))
                result["settingsVisible"] = settings.occlusionState.contains(.visible)
                if profileCPU { result["mainAndSettingsCPU"] = try await measureCPU() }
                save()
                main.performClose(nil)
                try await Task.sleep(for: .seconds(3))
                if profileCPU { result["settingsOnlyCPU"] = try await measureCPU() }
                save()
                settings.close()
                try await Task.sleep(for: .seconds(3))
                result["closedDockHidden"] = NSApp.activationPolicy() == .accessory
                if profileCPU { result["closedCPU"] = try await measureCPU() }
                save()
                AppLifecycle.store?.settings.menuDisplay = .none
                try await Task.sleep(for: .seconds(3))
                if profileCPU { result["iconOnlyClosedCPU"] = try await measureCPU() }
                save()
                AppWindowVisibility.prepareToOpen()
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                try await Task.sleep(for: .seconds(1))
                let reopened = try requireWindow()
                result["reopened"] = reopened.isVisible && NSApp.activationPolicy() == .regular
                let canMinimize = reopened.styleMask.contains(.miniaturizable)
                    && reopened.standardWindowButton(.miniaturizeButton)?.isEnabled == true
                result["supportsMinimize"] = canMinimize
                if canMinimize {
                    reopened.performMiniaturize(nil)
                    try await Task.sleep(for: .seconds(1))
                    result["minimized"] = reopened.isMiniaturized
                    result["activeBeforeRestore"] = NSApp.isActive
                    result["minimizeActionKeepsDock"] = NSApp.activationPolicy() == .regular
                    reopened.deminiaturize(nil)
                    try await Task.sleep(for: .seconds(1))
                    result["visibleAfterRestoreAction"] = !reopened.isMiniaturized && reopened.isVisible
                }
                openSettings()
                try await Task.sleep(for: .seconds(1))
                reopened.close()
                try await Task.sleep(for: .seconds(1))
                result["settingsKeepsDock"] = NSApp.activationPolicy() == .regular
                for window in NSApp.windows where window.styleMask.contains(.titled) { window.close() }
                try await Task.sleep(for: .seconds(1))
                result["allClosedDockHidden"] = NSApp.activationPolicy() == .accessory
            }
        } catch { result["error"] = error.localizedDescription }
        save()
        AppLifecycle.store?.stop()
        Self.cleanup?()
        NSApp.terminate(nil)
    }

    private func requireWindow() throws -> NSWindow {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && $0.title == "Fan Control" }) else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        return window
    }

    private func measureCPU() async throws -> [String: Any] {
        func cpuTime() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        let args = ProcessInfo.processInfo.arguments
        let seconds = args.firstIndex(of: "--inspect-seconds").flatMap {
            args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil
        } ?? 40
        let cpu = cpuTime(), start = ProcessInfo.processInfo.systemUptime
        var previousCPU = cpu, previousTime = start, samples: [Double] = []
        while ProcessInfo.processInfo.systemUptime - start < seconds {
            try await Task.sleep(for: .seconds(2))
            let currentCPU = cpuTime(), currentTime = ProcessInfo.processInfo.systemUptime
            samples.append((currentCPU - previousCPU) / (currentTime - previousTime) * 100)
            previousCPU = currentCPU
            previousTime = currentTime
        }
        return ["averagePercent": (previousCPU - cpu) / (previousTime - start) * 100,
                "seconds": previousTime - start, "twoSecondPercent": samples,
                "maximumPercent": samples.max() ?? 0]
    }
}

@MainActor
private final class InspectionService: ControlServiceConnection {
    let bundled = true, signed = true, installed = true
    var onDisconnect: (() -> Void)?
    private let owner = UUID()
    let policies: [FanPolicy] = ProcessInfo.processInfo.arguments.contains("--inspect-render-stress")
        ? ["F0", "F1"].map { FanPolicy(fanID: $0, mode: .sensor, sensorID: SensorCatalog.cpuAverageKey, low: 50, high: 65) }
        : [FanPolicy(fanID: "F0", mode: .fixed, rpm: 3_000)]
    func register() async throws { throw ControlError.readOnly }
    func unregister(connectionFailed: Bool) async throws { throw ControlError.readOnly }
    func disconnect() {}
    func request(_ request: HelperRequest) async throws -> HelperReply {
        guard request.operation == .status || request.operation == .heartbeat else { throw ControlError.readOnly }
        var reply = HelperReply(available: true, status: SessionStatus(owner: owner,
            policies: policies, pendingRecovery: [], message: nil))
        reply.ownsSession = true
        return reply
    }
}
#endif
