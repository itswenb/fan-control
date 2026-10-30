import Foundation
import Observation
#if SWIFT_PACKAGE
import FanCore
#endif

@MainActor @Observable
final class SleepInhibitionController {
    enum Phase { case off, enabling, on, disabling, unknown }
    private(set) var phase: Phase = .off
    private(set) var status: SleepInhibitionStatus?
    private(set) var message: String?
    var onChange: (() -> Void)?
    var isOn: Bool { phase == .on || phase == .unknown }
    var pending: Bool { phase == .enabling || phase == .disabling }
    var needsRelease: Bool { phase != .off || status?.recoveryPending == true }
    @ObservationIgnored private let helper: any ControlServiceConnection
    @ObservationIgnored private let lights: any LidBacklightManaging
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private let diagnostics: SleepDiagnosticLog?
    @ObservationIgnored private var lastCheckpoint: TimeInterval = 0

    init(helper: any ControlServiceConnection, lights: any LidBacklightManaging = LidBacklightController(), diagnostics: SleepDiagnosticLog? = nil) {
        self.helper = helper; self.lights = lights; self.diagnostics = diagnostics
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if helper.installed && !pending { await refresh() }
                do { try await Task.sleep(for: .seconds(needsRelease ? 1 : 5)) }
                catch { return }
            }
        }
    }

    func stop() {
        task?.cancel(); task = nil
        revision += 1
        disconnected()
    }

    func disconnected() {
        revision += 1
        if needsRelease {
            if phase != .unknown { diagnostics?.event("app", "xpc.disconnected", "phase=\(phase)", error: true) }
            phase = .unknown
            message = "服务连接中断，等待确认睡眠设置已恢复。"
            onChange?()
        }
        Task { try? await lights.stop() }
    }

    func setEnabled(_ enabled: Bool) async throws {
        guard !pending else { return }
        revision += 1
        let expected = revision
        diagnostics?.event("app", "toggle.requested", "enabled=\(enabled) previous=\(phase) revision=\(revision)")
        phase = enabled ? .enabling : .disabling
        message = nil
        onChange?()
        var attemptedEnable = false
        do {
            if enabled { try await lights.stop(); try await lights.prepare() }
            guard expected == revision else { throw HelperClientError.disconnected }
            attemptedEnable = enabled
            let reply = try await helper.request(HelperRequest(operation: enabled ? .sleepEnable : .sleepDisable))
            guard expected == revision, let state = reply.sleepStatus,
                  !state.recoveryPending, enabled ? (reply.ownsSession && state.active) : !state.active else { throw SleepInhibitionError.unconfirmed }
            diagnostics?.event("app", "toggle.confirmed", state.diagnosticSummary)
            status = state
            phase = enabled ? .on : .off
            if enabled {
                lights.start { [weak self] detail in
                    Task { [weak self] in
                        guard let self else { return }
                        do { try await self.release() } catch { }
                        self.diagnostics?.event("app", "lighting.failure", detail, error: true)
                        self.message = detail
                    }
                }
            } else { try await lights.stop() }
            onChange?()
            // 开启后立即续约，不能等后台的五秒空闲轮询。 / Wake polling immediately before the first lease can expire.
            if enabled, task != nil {
                task?.cancel(); task = nil; start()
            }
        } catch {
            diagnostics?.event("app", "toggle.failed", "requested=\(enabled) \(SleepDiagnosticLog.describe(error))", error: true)
            // 开启结果不明时先请求补偿；不自动重开。 / Compensate an uncertain enable, never automatically re-enable.
            if enabled && attemptedEnable {
                do {
                    let reply = try await helper.request(HelperRequest(operation: .sleepDisable))
                    guard reply.sleepStatus?.active == false, reply.sleepStatus?.recoveryPending == false else { throw SleepInhibitionError.unconfirmed }
                    phase = .off; status = reply.sleepStatus
                    diagnostics?.event("app", "compensation.confirmed")
                } catch {
                    diagnostics?.event("app", "compensation.failed", SleepDiagnosticLog.describe(error), error: true)
                    phase = .unknown
                }
            } else if enabled { phase = .off }
            else if phase != .off { phase = .unknown }
            try? await lights.stop()
            message = error.localizedDescription
            onChange?()
            throw error
        }
    }

    func release() async throws {
        while pending { try await Task.sleep(for: .milliseconds(50)) }
        if needsRelease { try await setEnabled(false) }
    }

    func diagnosticDetails() async -> String {
        let helperDetails: String
        if helper.installed {
            do {
                let reply = try await helper.request(HelperRequest(operation: .sleepDiagnostics))
                helperDetails = "\(reply.sleepStatus?.diagnosticSummary ?? "status unavailable")\n\(reply.sleepDiagnostics ?? "Helper log unavailable (update service).")"
            } catch { helperDetails = "Helper diagnostics unavailable: " + SleepDiagnosticLog.describe(error) }
        } else { helperDetails = "Control service is not installed." }
        return """
        Sleep inhibition: phase=\(phase) pending=\(pending)
        Last sleep error: \(message ?? "none")
        \(status?.diagnosticSummary ?? "No confirmed sleep status")

        === App and backlight log (recent, persisted) ===
        \(diagnostics?.history() ?? "Persistent log disabled in this process.")

        === Helper log (recent, persisted) ===
        \(helperDetails)
        """
    }

    private func refresh() async {
        let expected = revision
        do {
            let reply = try await helper.request(HelperRequest(operation: phase == .on ? .sleepHeartbeat : .sleepStatus))
            guard !Task.isCancelled, expected == revision, !pending, let state = reply.sleepStatus else { return }
            let uptime = ProcessInfo.processInfo.systemUptime
            if state.diagnosticSummary != status?.diagnosticSummary || uptime - lastCheckpoint >= 60 {
                diagnostics?.event("app", "helper.status", "owns=\(reply.ownsSession) \(state.diagnosticSummary)")
                lastCheckpoint = uptime
            }
            status = state
            if state.active && !reply.ownsSession {
                phase = .off
                message = "防休眠会话由另一连接持有。"
                try await lights.stop()
                onChange?()
                return
            }
            if phase == .unknown, reply.ownsSession && state.active {
                try await setEnabled(false)
                return
            }
            if !state.active && !state.recoveryPending {
                let wasOn = phase != .off
                phase = .off
                if wasOn {
                    try await lights.stop()
                    message = state.message
                    onChange?()
                }
            } else if state.recoveryPending {
                phase = .unknown; message = state.message; onChange?()
                try? await lights.stop()
            }
        } catch {
            guard expected == revision else { return }
            if message != error.localizedDescription { diagnostics?.event("app", "helper.poll_failed", SleepDiagnosticLog.describe(error), error: true) }
            if needsRelease { disconnected() }
            message = error.localizedDescription
        }
    }
}
