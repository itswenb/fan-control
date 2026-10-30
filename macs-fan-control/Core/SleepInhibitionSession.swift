import Foundation

public struct SleepPowerState: Sendable {
    public var disabled: Bool
    public var lidClosed: Bool?
    public var onBattery: Bool
    public var batteryPercent: Double?

    public init(disabled: Bool, lidClosed: Bool?, onBattery: Bool = false, batteryPercent: Double? = nil) {
        self.disabled = disabled; self.lidClosed = lidClosed
        self.onBattery = onBattery; self.batteryPercent = batteryPercent
    }

    public var diagnosticSummary: String {
        "SleepDisabled=\(disabled) lidClosed=\(lidClosed.map(String.init) ?? "unknown") onBattery=\(onBattery) battery=\(batteryPercent.map { String(format: "%.1f", $0) } ?? "unknown")"
    }
}

public protocol SleepInhibitionDriver: AnyObject {
    func read() throws -> SleepPowerState
    func setDisabled(_ disabled: Bool) throws
}

public protocol SleepInhibitionJournal: AnyObject {
    func load() throws -> Bool
    func save(needsRecovery: Bool) throws
}

public struct SleepInhibitionStatus: Codable, Sendable {
    public var available: Bool
    public var owner: UUID?
    public var active: Bool
    public var recoveryPending: Bool
    public var externallyDisabled: Bool
    public var message: String?

    public init(available: Bool, owner: UUID? = nil, active: Bool = false, recoveryPending: Bool = false,
                externallyDisabled: Bool = false, message: String? = nil) {
        self.available = available; self.owner = owner; self.active = active
        self.recoveryPending = recoveryPending; self.externallyDisabled = externallyDisabled; self.message = message
    }

    public var diagnosticSummary: String {
        "available=\(available) active=\(active) pending=\(recoveryPending) owner=\(owner?.uuidString ?? "none") external=\(externallyDisabled) message=\(message ?? "none")"
    }
}

public enum SleepInhibitionError: Error, LocalizedError {
    case unavailable, busy, recoveryRequired, externallyDisabled, unsafePower, unconfirmed
    public var errorDescription: String? {
        switch self {
        case .unavailable: "此设备不支持合盖防休眠，或电源状态无法读取。"
        case .busy: "防休眠会话正在由另一连接使用，或服务正在移除。"
        case .recoveryRequired: "睡眠设置恢复尚未确认，请先重试关闭。"
        case .externallyDisabled: "系统已由其他工具禁止休眠，请先在该工具中关闭。"
        case .unsafePower: "电量不高于 20% 或电池状态无法确认，不能开启防休眠。"
        case .unconfirmed: "系统电源设置未确认生效。"
        }
    }
}

/// 在独立执行器中串行使用，完全不依赖 SMC。 / Serialize independently of SMC control.
public final class SleepInhibitionSession {
    private let driver: any SleepInhibitionDriver
    private let journal: any SleepInhibitionJournal
    private let diagnostics: SleepDiagnosticLog?
    private var lastCheckpoint: TimeInterval = 0
    private var owner: UUID?
    private var active = false
    private var pending = false
    private var removalOwner: UUID?
    private var lastHeartbeat: TimeInterval = 0
    private var nextRetry: TimeInterval = 0
    private var message: String?
    private var latest: SleepPowerState?

    public var status: SleepInhibitionStatus {
        SleepInhibitionStatus(available: latest?.lidClosed != nil && !pending && removalOwner == nil,
                              owner: owner, active: active, recoveryPending: pending,
                              externallyDisabled: latest?.disabled == true && owner == nil && !pending, message: message)
    }

    public init(driver: any SleepInhibitionDriver, journal: any SleepInhibitionJournal, diagnostics: SleepDiagnosticLog? = nil) throws {
        self.driver = driver; self.journal = journal
        self.diagnostics = diagnostics
        pending = try journal.load()
        diagnostics?.event("lease", "startup", "journalPending=\(pending)")
        if pending { recover(reason: "服务重新启动，恢复上次睡眠设置。") }
        latest = try? driver.read()
    }

    public func enable(client: UUID, uptime: TimeInterval) throws {
        guard removalOwner == nil, owner == nil || owner == client else { throw SleepInhibitionError.busy }
        guard !pending else { throw SleepInhibitionError.recoveryRequired }
        let state = try driver.read()
        latest = state
        diagnostics?.event("lease", "enable.preflight", "client=\(client) \(state.diagnosticSummary)")
        guard state.lidClosed != nil else { throw SleepInhibitionError.unavailable }
        guard !Self.unsafeBattery(state) else { throw SleepInhibitionError.unsafePower }
        if active {
            guard state.disabled else {
                recover(reason: "系统睡眠设置被外部修改，已结束防休眠。")
                throw SleepInhibitionError.unconfirmed
            }
            lastHeartbeat = uptime
            return
        }
        guard !state.disabled else { throw SleepInhibitionError.externallyDisabled }
        // 只接管原先允许睡眠的状态，写之前落盘。 / Journal before the first system mutation.
        try journal.save(needsRecovery: true)
        diagnostics?.event("lease", "journal.armed", "client=\(client)")
        pending = true
        owner = client
        do {
            try driver.setDisabled(true)
            let confirmed = try driver.read()
            guard confirmed.disabled else { throw SleepInhibitionError.unconfirmed }
            latest = confirmed
            active = true; pending = false; lastHeartbeat = uptime; message = nil
            diagnostics?.event("lease", "enable.confirmed", confirmed.diagnosticSummary)
        } catch {
            diagnostics?.event("lease", "enable.failed", SleepDiagnosticLog.describe(error), error: true)
            recover(reason: error.localizedDescription)
            throw error
        }
    }

    public func heartbeat(client: UUID, uptime: TimeInterval) {
        if owner == client && active { lastHeartbeat = uptime }
    }

    public func release(client: UUID) throws {
        guard owner == nil || owner == client || pending else { throw SleepInhibitionError.busy }
        if owner != nil || pending { recover(reason: "已恢复正常睡眠设置。") }
        guard !pending else { throw SleepInhibitionError.recoveryRequired }
    }

    public func tick(uptime: TimeInterval, thermalEmergency: Bool = false) {
        if pending {
            if uptime >= nextRetry { nextRetry = uptime + 5; recover(reason: message ?? "正在重试恢复睡眠设置。") }
            return
        }
        guard active else { latest = try? driver.read(); return }
        if thermalEmergency { recover(reason: "系统热压力过高，已结束防休眠。"); return }
        if uptime - lastHeartbeat > 5 {
            diagnostics?.event("lease", "heartbeat.expired", "gap=\(uptime - lastHeartbeat)", error: true)
            recover(reason: "客户端心跳超时，已结束防休眠。"); return
        }
        do {
            let state = try driver.read()
            if state.diagnosticSummary != latest?.diagnosticSummary || uptime - lastCheckpoint >= 60 {
                diagnostics?.event("lease", "power.checkpoint", "\(state.diagnosticSummary) heartbeatAge=\(uptime - lastHeartbeat) thermalEmergency=\(thermalEmergency)")
                lastCheckpoint = uptime
            }
            latest = state
            if !state.disabled { recover(reason: "系统睡眠设置被外部修改，已结束防休眠。"); return }
            if Self.unsafeBattery(state) { recover(reason: "电池电量过低或状态无法确认，已结束防休眠。") }
        } catch {
            diagnostics?.event("lease", "power.read_failed", SleepDiagnosticLog.describe(error), error: true)
            recover(reason: "电源状态读取失败，已结束防休眠。")
        }
    }

    public func disconnected(client: UUID) {
        if owner == client { recover(reason: "客户端断开，已结束防休眠。") }
        if removalOwner == client { removalOwner = nil }
    }

    public func prepareRemoval(client: UUID) throws {
        guard removalOwner == nil || removalOwner == client else { throw SleepInhibitionError.busy }
        try release(client: client)
        removalOwner = client
    }

    public func cancelRemoval(client: UUID) { if removalOwner == client { removalOwner = nil } }

    private static func unsafeBattery(_ state: SleepPowerState) -> Bool {
        state.onBattery && (state.batteryPercent.map { !$0.isFinite || $0 <= 20 } ?? true)
    }

    private func recover(reason: String) {
        diagnostics?.event("lease", "restore.begin", "client=\(owner?.uuidString ?? "none") reason=\(reason)")
        active = false; pending = true; message = reason
        do {
            try driver.setDisabled(false)
            let state = try driver.read()
            guard !state.disabled else { throw SleepInhibitionError.unconfirmed }
            latest = state
            try journal.save(needsRecovery: false)
            pending = false; owner = nil
            diagnostics?.event("lease", "restore.confirmed", state.diagnosticSummary)
        } catch {
            message = "睡眠设置恢复未确认：\(error.localizedDescription)"
            diagnostics?.event("lease", "restore.failed", "journal retained; \(SleepDiagnosticLog.describe(error))", error: true)
        }
    }
}
