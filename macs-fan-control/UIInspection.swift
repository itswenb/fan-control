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
    private static var cleanup: (() -> Void)?

    static func makeStore() -> AppStore {
        let suite = "FanControl.Inspection." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        if ProcessInfo.processInfo.arguments.contains("--inspect-current-settings"),
           let settings = UserDefaults.standard.data(forKey: "settings") {
            defaults.set(settings, forKey: "settings")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        cleanup = {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = AppStore(defaults: defaults,
                             storageDirectory: directory,
                             helper: InspectionService())
        store.policies = [FanPolicy(fanID: "F0", mode: .fixed, rpm: 3_000)]
        return store
    }

    var body: some View {
        Color.clear.onAppear {
            guard Self.isRequested, !Self.started else { return }
            Self.started = true
            Task { await run() }
        }
    }

    private func run() async {
        var result: [String: Any] = [:]
        let profileCPU = !ProcessInfo.processInfo.arguments.contains("--inspect-windows-only")
        result["cpuMeasured"] = profileCPU
        do {
            try await Task.sleep(for: .seconds(5))
            if profileCPU { result["openCPUPercent"] = try await measureCPU() }
            let main = try requireWindow()
            main.performClose(nil)
            try await Task.sleep(for: .seconds(1))
            result["closedDockHidden"] = NSApp.activationPolicy() == .accessory
            if profileCPU { result["closedCPUPercent"] = try await measureCPU() }
            AppLifecycle.store?.settings.menuDisplay = .none
            if profileCPU { result["iconOnlyClosedCPUPercent"] = try await measureCPU() }
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
        } catch { result["error"] = error.localizedDescription }
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--inspect-ui"),
           ProcessInfo.processInfo.arguments.indices.contains(index + 1),
           let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: ProcessInfo.processInfo.arguments[index + 1]))
        }
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

    private func measureCPU() async throws -> Double {
        func cpuTime() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        let cpu = cpuTime(), start = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .seconds(20))
        return (cpuTime() - cpu) / (ProcessInfo.processInfo.systemUptime - start) * 100
    }
}

@MainActor
private final class InspectionService: ControlServiceConnection {
    let bundled = true, signed = true, installed = true
    var onDisconnect: (() -> Void)?
    private let owner = UUID()
    func register() async throws { throw ControlError.readOnly }
    func unregister(connectionFailed: Bool) async throws { throw ControlError.readOnly }
    func disconnect() {}
    func request(_ request: HelperRequest) async throws -> HelperReply {
        guard request.operation == .status || request.operation == .heartbeat else { throw ControlError.readOnly }
        var reply = HelperReply(available: true, status: SessionStatus(owner: owner,
            policies: [FanPolicy(fanID: "F0", mode: .fixed, rpm: 3_000)], pendingRecovery: [], message: nil))
        reply.ownsSession = true
        return reply
    }
}
#endif
