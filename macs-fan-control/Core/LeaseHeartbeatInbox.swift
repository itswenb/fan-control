import Foundation

/// 在 XPC 接收线程记录心跳；连接关闭后不再允许续租。 / Record received heartbeats outside the worker; a closed connection cannot renew.
public final class LeaseHeartbeatInbox: @unchecked Sendable {
    public enum Domain { case fan, sleep }
    private let lock = NSLock()
    private var open = true
    private var fan: TimeInterval?
    private var sleep: TimeInterval?
    private var fanReply: HelperReply?
    private var fanReplyTime: TimeInterval = 0

    public init() {}
    public var isOpen: Bool { lock.withLock { open } }
    public func close() { lock.withLock { open = false } }
    public func record(_ domain: Domain, at uptime: TimeInterval) {
        guard uptime.isFinite, uptime >= 0 else { return }
        lock.withLock {
            guard open else { return }
            switch domain {
            case .fan: fan = max(fan ?? uptime, uptime)
            case .sleep: sleep = max(sleep ?? uptime, uptime)
            }
        }
    }
    public func latest(_ domain: Domain) -> TimeInterval? {
        lock.withLock {
            guard open else { return nil }
            switch domain { case .fan: return fan; case .sleep: return sleep }
        }
    }

    /// 仅缓存最近完成的控制周期；Never present an indefinitely stalled worker as healthy.
    public func publishFanReply(_ reply: HelperReply, at uptime: TimeInterval) {
        lock.withLock {
            guard open, uptime.isFinite, uptime >= 0 else { return }
            fanReply = reply
            fanReplyTime = uptime
        }
    }

    public func invalidateFanReply() { lock.withLock { fanReply = nil } }

    public func recentFanReply(at uptime: TimeInterval) -> HelperReply? {
        lock.withLock {
            guard open, uptime.isFinite, uptime >= fanReplyTime, uptime - fanReplyTime <= 15 else { return nil }
            return fanReply
        }
    }
}
