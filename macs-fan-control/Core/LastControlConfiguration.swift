import Foundation

/// 记录用户最后一次成功应用的选择；显示状态仍以控制服务的回复为准。
public struct LastControlConfiguration: Codable, Sendable, Equatable {
    public var version = 1
    public var model: String
    public var policies: [FanPolicy]
    public var presetID: UUID?
    public var fullSpeed: Bool

    public init(model: String, policies: [FanPolicy], presetID: UUID? = nil, fullSpeed: Bool = false) {
        self.model = model; self.policies = policies; self.presetID = presetID; self.fullSpeed = fullSpeed
    }

    public func validateForResume(in snapshot: HardwareSnapshot, at now: Date) throws {
        guard version == 1, policies.count <= 16 else { throw ControlError.invalidConfiguration }
        guard snapshot.source == .live, snapshot.model == model else { throw ControlError.wrongDevice }
        guard (0...3).contains(now.timeIntervalSince(snapshot.timestamp)) else { throw ControlError.invalidConfiguration }
        try PolicyValidator.validate(policies, in: snapshot, at: now)
        for policy in policies {
            guard let fan = snapshot.fans.first(where: { $0.id == policy.fanID }), fan.mode == .automatic else {
                throw SessionError.externallyControlled
            }
            if policy.mode != .automatic, !fan.isFresh(at: now) { throw ControlError.invalidRPM }
        }
    }
}
