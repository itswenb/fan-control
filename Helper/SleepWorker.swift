import Foundation
import FanCore
import FanHardware

/// 电源命令不占用风扇执行器。 / Power commands never block the fan-control actor.
actor SleepWorker {
    private let diagnostics: SleepDiagnosticLog
    init(diagnostics: SleepDiagnosticLog = .helper) { self.diagnostics = diagnostics }
    private var session: SleepInhibitionSession?
    private var initializationError: String?

    private func initialize() {
        guard session == nil else { return }
        do {
            session = try SleepInhibitionSession(driver: SystemSleepControl(diagnostics: diagnostics), journal: SleepRecoveryJournal(), diagnostics: diagnostics)
            initializationError = nil
        } catch {
            let detail = SleepDiagnosticLog.describe(error)
            if initializationError != error.localizedDescription { diagnostics.event("helper", "initialize.failed", detail, error: true) }
            initializationError = error.localizedDescription
        }
    }

    func request(_ operation: HelperRequest.Operation, client: UUID, isOpen: @Sendable () -> Bool) -> HelperReply {
        initialize()
        var reply = HelperReply(available: false)
        if operation == .sleepDiagnostics {
            guard isOpen() else { reply.error = SleepInhibitionError.busy.localizedDescription; return reply }
            reply.sleepDiagnostics = diagnostics.history(maximumBytes: 16_000)
            reply.sleepStatus = session?.status
            return reply
        }
        if operation != .sleepStatus && operation != .sleepHeartbeat {
            diagnostics.event("helper", "request", "operation=\(operation.rawValue) client=\(client) open=\(isOpen())")
        }
        do {
            guard isOpen(), let session else { throw SleepInhibitionError.unavailable }
            let uptime = ProcessInfo.processInfo.systemUptime
            switch operation {
            case .sleepEnable:
                let thermal = ProcessInfo.processInfo.thermalState
                guard thermal != .serious, thermal != .critical else { throw ControlError.readOnly }
                try session.enable(client: client, uptime: uptime)
                // 写入途中断连也必须回收。 / Reclaim a lease closed during the system command.
                if !isOpen() { session.disconnected(client: client); throw SleepInhibitionError.unconfirmed }
            case .sleepHeartbeat: session.heartbeat(client: client, uptime: uptime)
            case .sleepDisable: try session.release(client: client)
            case .prepareUninstall: try session.prepareRemoval(client: client)
            case .cancelUninstall: session.cancelRemoval(client: client)
            default: break
            }
        } catch {
            reply.error = initializationError ?? error.localizedDescription
            if operation != .sleepStatus && operation != .sleepHeartbeat {
                diagnostics.event("helper", "request.failed", "operation=\(operation.rawValue) \(SleepDiagnosticLog.describe(error))", error: true)
            }
        }
        reply.sleepStatus = session?.status ?? SleepInhibitionStatus(available: false, message: initializationError)
        reply.ownsSession = session?.status.owner == client
        return reply
    }

    func tick() {
        initialize()
        let state = ProcessInfo.processInfo.thermalState
        session?.tick(uptime: ProcessInfo.processInfo.systemUptime, thermalEmergency: state == .serious || state == .critical)
    }

    func disconnected(_ client: UUID) { session?.disconnected(client: client) }
}
