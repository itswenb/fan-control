import Foundation

public enum HelperConstants {
    public static let machService = "com.itswenb.fancontrol.helper"
    public static let appIdentifier = "com.itswenb.fancontrol"
    public static let plistName = machService + ".plist"
    public static let protocolVersion = 4
    public static let installedHelperPath = "/Library/PrivilegedHelperTools/" + machService
    public static let daemonPath = "/Library/LaunchDaemons/" + plistName
    public static let supportPath = "/Library/Application Support/FanControl-helper"
    public static let trustPath = supportPath + "/trust.json"
    public static let sleepRecoveryPath = supportPath + "/sleep-recovery.json"

}

@objc public protocol FanHelperProtocol {
    func request(_ data: Data, reply: @escaping @Sendable (Data) -> Void)
}

public struct HelperRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case status, apply, heartbeat, restore, prepareUninstall, cancelUninstall
        case sleepStatus, sleepEnable, sleepHeartbeat, sleepDisable, sleepDiagnostics

        public var isSleepOperation: Bool {
            switch self {
            case .sleepStatus, .sleepEnable, .sleepHeartbeat, .sleepDisable, .sleepDiagnostics: true
            default: false
            }
        }
    }
    public var version = HelperConstants.protocolVersion
    public var operation: Operation
    public var policies: [FanPolicy]
    public var temperatureSources: [ControlTemperatureSource]
    public init(operation: Operation, policies: [FanPolicy] = [], temperatureSources: [ControlTemperatureSource] = []) {
        self.operation = operation; self.policies = policies; self.temperatureSources = temperatureSources
    }
}

public struct HelperReply: Codable, Sendable {
    public var version = HelperConstants.protocolVersion
    public var available: Bool
    public var status: SessionStatus?
    public var error: String?
    /// 仅表示 apply 的写入前校验失败；旧服务没有此字段时按普通错误处理。
    public var readingsNotReady: Bool?
    public var ownsSession = false
    public var sleepStatus: SleepInhibitionStatus?
    public var sleepDiagnostics: String?
    public init(available: Bool, status: SessionStatus? = nil, error: String? = nil) {
        self.available = available; self.status = status; self.error = error
    }
}
