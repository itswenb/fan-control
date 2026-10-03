import Foundation

public enum HelperConstants {
    public static let machService = "com.itswenb.fancontrol.helper"
    public static let appIdentifier = "com.itswenb.fancontrol"
    public static let plistName = machService + ".plist"
    public static let protocolVersion = 3
    public static let installedHelperPath = "/Library/PrivilegedHelperTools/" + machService
    public static let daemonPath = "/Library/LaunchDaemons/" + plistName
    public static let supportPath = "/Library/Application Support/FanControl-helper"
    public static let trustPath = supportPath + "/trust.json"

}

@objc public protocol FanHelperProtocol {
    func request(_ data: Data, reply: @escaping @Sendable (Data) -> Void)
}

public struct HelperRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case status, apply, heartbeat, restore, prepareUninstall, cancelUninstall }
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
    public var ownsSession = false
    public init(available: Bool, status: SessionStatus? = nil, error: String? = nil) {
        self.available = available; self.status = status; self.error = error
    }
}
