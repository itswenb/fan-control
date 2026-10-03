import Foundation

/// 由独立服务在单一执行器中调用。所有写入、确认和租约回收均发生在服务端。
public protocol FanControlDriver: AnyObject {
    func controlSnapshot(temperatureSources: [ControlTemperatureSource]) throws -> HardwareSnapshot
    func setTarget(fanID: String, rpm: Double) throws
    func restoreAutomatic(fanID: String) throws
}

public protocol ControlJournal: AnyObject {
    func load() throws -> Set<String>
    func save(_ fans: Set<String>) throws
}

public enum RecoveryReason: String, Codable, Sendable {
    case requested, heartbeatExpired, samplingInterrupted, disconnected, serviceRestarted, thermalEmergency, controlFailure

    public var permitsAutomaticResume: Bool {
        switch self {
        case .heartbeatExpired, .samplingInterrupted, .disconnected, .serviceRestarted: true
        case .requested, .thermalEmergency, .controlFailure: false
        }
    }
}

public struct SessionStatus: Codable, Sendable {
    public var owner: UUID?
    public var policies: [FanPolicy]
    public var pendingRecovery: [String]
    public var message: String?
    public var recoveryBlocked: Bool
    public var recoveryReason: RecoveryReason?
    public init(owner: UUID?, policies: [FanPolicy], pendingRecovery: [String], message: String?, recoveryBlocked: Bool = false,
                recoveryReason: RecoveryReason? = nil) {
        self.owner = owner; self.policies = policies; self.pendingRecovery = pendingRecovery; self.message = message
        self.recoveryBlocked = recoveryBlocked
        self.recoveryReason = recoveryReason
    }
}

public enum SessionError: Error, LocalizedError {
    case busy, recoveryRequired, externallyControlled, notOwner
    public var errorDescription: String? {
        switch self {
        case .busy: "另一个会话正在控制风扇。"
        case .recoveryRequired: "上次控制尚未确认恢复，暂时不能应用新策略。"
        case .externallyControlled: "风扇正在被其他控制器接管，或模式无法确认。请先恢复系统自动。"
        case .notOwner: "当前连接不是风扇控制会话的所有者。"
        }
    }
}

public final class ControlSession {
    private let driver: any FanControlDriver
    private let journal: any ControlJournal
    private var owner: UUID?
    private var policies: [FanPolicy] = []
    private var temperatureSources: [ControlTemperatureSource] = []
    private var pending = Set<String>()
    private var touched = Set<String>()
    private var ramps: [String: RampState] = [:]
    private var confirmedTargets: [String: Double] = [:]
    private var lastHeartbeat: TimeInterval = 0
    private var message: String?
    private var recoveryReason: RecoveryReason?
    private var retriesRemaining = 0
    private var journalFailure = false
    private var removalOwner: UUID?
    public var preparingRemoval: Bool { removalOwner != nil }
    public var status: SessionStatus {
        SessionStatus(owner: owner, policies: policies, pendingRecovery: pending.sorted(), message: message,
                      recoveryBlocked: !pending.isEmpty || journalFailure, recoveryReason: recoveryReason)
    }

    public init(driver: any FanControlDriver, journal: any ControlJournal) throws {
        self.driver = driver; self.journal = journal
        touched = try journal.load()
        if !touched.isEmpty { recover(reason: "控制服务重新启动，恢复上次接管的风扇。", cause: .serviceRestarted) }
    }

    public func heartbeat(client: UUID, uptime: TimeInterval) {
        guard client == owner else { return }
        lastHeartbeat = uptime
    }

    public func apply(_ requested: [FanPolicy], temperatureSources: [ControlTemperatureSource] = [],
                      client: UUID, uptime: TimeInterval, now: Date) throws {
        guard removalOwner == nil else { throw SessionError.busy }
        guard owner == nil || owner == client else { throw SessionError.busy }
        guard pending.isEmpty, !journalFailure else { throw SessionError.recoveryRequired }
        try ControlTemperatureSource.validate(temperatureSources, for: requested)
        let snapshot = try driver.controlSnapshot(temperatureSources: temperatureSources)
        try PolicyValidator.validate(requested, in: snapshot, at: max(now, snapshot.timestamp))
        do { try verifyOwnership(in: snapshot) }
        catch { recover(reason: error.localizedDescription); throw error }
        for policy in requested where !touched.contains(policy.fanID) {
            guard snapshot.fans.first(where: { $0.id == policy.fanID })?.mode == .automatic else { throw SessionError.externallyControlled }
        }
        let toControl = Set(requested.filter { $0.mode != .automatic }.map(\.fanID))
        // 在第一次写入前持久化完整恢复集合，防止第二只风扇失败或进程中途终止。
        let recoverySet = touched.union(toControl)
        try journal.save(recoverySet)
        touched = recoverySet
        owner = client
        policies = requested
        self.temperatureSources = temperatureSources
        ramps = [:]
        confirmedTargets = [:]
        lastHeartbeat = uptime
        message = nil
        recoveryReason = nil
        do {
            for id in touched.subtracting(toControl) { try driver.restoreAutomatic(fanID: id) }
            touched = toControl
            try update(snapshot: snapshot, now: now)
            try journal.save(touched)
            if touched.isEmpty { owner = nil; policies = []; self.temperatureSources = [] }
        } catch {
            // 包含本次所有可能触达的风扇，不能只回滚最后一次成功写入。
            touched = recoverySet
            recover(reason: error.localizedDescription)
            throw error
        }
    }

    public func tick(uptime: TimeInterval, now: Date, thermalEmergency: Bool = false) {
        if !pending.isEmpty || journalFailure {
            if retriesRemaining > 0 { retriesRemaining -= 1; retryRecovery() }
            return
        }
        guard owner != nil else { return }
        if thermalEmergency {
            recover(reason: "系统热压力过高，恢复系统控制。", cause: .thermalEmergency)
            return
        }
        if uptime - lastHeartbeat > 5 {
            let gap = String(format: "%.1f", uptime - lastHeartbeat)
            recover(reason: "客户端心跳超时（\(gap) 秒），恢复系统控制。", cause: .heartbeatExpired)
            return
        }
        do {
            // 定时任务的调度间隔不能证明硬件或采样失效。延迟后读取当前状态，
            // 再验证温度新鲜度及控制权，避免健康会话先恢复自动再重新应用策略。
            let snapshot = try driver.controlSnapshot(temperatureSources: temperatureSources)
            try PolicyValidator.validate(policies, in: snapshot, at: max(now, snapshot.timestamp))
            try verifyOwnership(in: snapshot)
            try update(snapshot: snapshot, now: now)
        } catch { recover(reason: error.localizedDescription) }
    }

    public func release(client: UUID) throws {
        guard owner == nil || owner == client || !pending.isEmpty || journalFailure else { throw SessionError.notOwner }
        recover(reason: "已请求恢复系统自动。", cause: .requested)
        guard pending.isEmpty, !journalFailure else { throw SessionError.recoveryRequired }
    }

    public func disconnected(client: UUID) {
        if owner == client { recover(reason: "客户端连接中断，恢复系统自动。", cause: .disconnected) }
        if removalOwner == client { removalOwner = nil }
    }

    public func prepareRemoval(client: UUID) throws {
        guard removalOwner == nil || removalOwner == client else { throw SessionError.busy }
        try release(client: client)
        removalOwner = client
    }

    public func cancelRemoval(client: UUID) throws {
        guard removalOwner == client else { throw SessionError.notOwner }
        removalOwner = nil
    }

    private func update(snapshot: HardwareSnapshot, now: Date) throws {
        for policy in policies where policy.mode != .automatic {
            guard let fan = snapshot.fans.first(where: { $0.id == policy.fanID }) else { throw ControlError.missingFan }
            let sensor = snapshot.sensors.first { $0.id == policy.sensorID }
            guard let target = PolicyValidator.target(for: policy, fan: fan, temperature: sensor?.celsius) else { throw ControlError.invalidRPM }
            var ramp = ramps[fan.id] ?? RampState()
            let commanded = ramp.update(target: target, sampleTime: sensor?.sampledAt ?? now)
            ramps[fan.id] = ramp
            // 所有权已在本轮读取中核对；目标未变化时无需再次写入和等待 SMC 锁存。
            if confirmedTargets[fan.id] == commanded { continue }
            try driver.setTarget(fanID: fan.id, rpm: commanded)
            confirmedTargets[fan.id] = commanded
        }
    }

    private func verifyOwnership(in snapshot: HardwareSnapshot) throws {
        for id in touched {
            guard let fan = snapshot.fans.first(where: { $0.id == id }), fan.mode == .fixed,
                  let actual = fan.target, actual.isFinite, let expected = confirmedTargets[id],
                  abs(actual - expected) <= 1 else { throw SessionError.externallyControlled }
        }
    }

    private func recover(reason: String, cause: RecoveryReason = .controlFailure) {
        policies = []; temperatureSources = []; ramps = [:]; confirmedTargets = [:]; message = reason
        recoveryReason = cause
        pending.formUnion(touched)
        retriesRemaining = 4
        retryRecovery()
    }

    private func retryRecovery() {
        for id in pending.sorted() {
            do { try driver.restoreAutomatic(fanID: id); pending.remove(id); touched.remove(id) }
            catch { message = "恢复未确认：\(id) · \(error.localizedDescription)" }
        }
        do { try journal.save(pending); journalFailure = false }
        catch {
            journalFailure = true
            message = "恢复日志写入失败：\(error.localizedDescription)"
            // 磁盘状态尚未确认时禁止新控制；下次服务重启会再次读取日志恢复。
            pending.formUnion(touched)
        }
        if pending.isEmpty && !journalFailure { owner = nil; touched = []; retriesRemaining = 0 }
    }
}
