import Foundation
#if SWIFT_PACKAGE
import FanCore
#endif

@MainActor
protocol ControlServiceConnection: AnyObject {
    var bundled: Bool { get }
    var signed: Bool { get }
    var installed: Bool { get }
    var onDisconnect: (() -> Void)? { get set }
    func request(_ request: HelperRequest) async throws -> HelperReply
    func register() async throws
    func unregister(connectionFailed: Bool) async throws
    func disconnect()
}

@MainActor
final class HelperClient: ControlServiceConnection {
    private var connection: NSXPCConnection?
    private var connectionID: UUID?
    private var pending: [UUID: CheckedContinuation<HelperReply, any Error>] = [:]
    private var timeouts: [UUID: Task<Void, Never>] = [:]
    var onDisconnect: (() -> Void)?
    var bundled: Bool {
        Bundle.main.url(forResource: "FanControlHelper", withExtension: nil, subdirectory: "../Library/HelperTools") != nil ||
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Library/HelperTools/FanControlHelper").path)
    }
    private var helperURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Library/HelperTools/FanControlHelper") }
    var signed: Bool { (try? CodeIdentity.read(at: helperURL, identifier: HelperConstants.machService)) != nil }
    var installed: Bool { FileManager.default.fileExists(atPath: HelperConstants.installedHelperPath) }

    func register() async throws {
        guard bundled, signed else { throw ControlError.readOnly }
        disconnect()
        try await installation(operation: installed ? "--upgrade" : "--install")
    }

    func unregister(connectionFailed: Bool = false) async throws {
        if connectionFailed {
            try await installation(operation: "--uninstall-stale")
            disconnect()
            return
        }
        do { _ = try await request(HelperRequest(operation: .prepareUninstall)) }
        catch {
            // 服务仍在但不再信任新版 app 时，XPC prepareUninstall 无法送达。
            // 管理员安装器会独立检查旧签名及未完成的风扇恢复，再决定能否移除。
            if let clientError = error as? HelperClientError, case .remote = clientError { throw error }
            try await installation(operation: "--uninstall-stale")
            disconnect()
            return
        }
        do { try await installation(operation: "--uninstall") }
        catch {
            _ = try? await request(HelperRequest(operation: .cancelUninstall))
            throw error
        }
        disconnect()
    }

    private func installation(operation: String) async throws {
        let app = Bundle.main.bundleURL
        let client = try CodeIdentity.read(at: app, identifier: HelperConstants.appIdentifier)
        try client.validateRunningProcess()
        let helper = try CodeIdentity.read(at: helperURL, identifier: HelperConstants.machService)
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let clientVerification = client.verificationArguments.map(quoted).joined(separator: " ")
        let helperVerification = helper.verificationArguments.map(quoted).joined(separator: " ")
        let command = """
        set -eu
        umask 077
        fan_stage=$(/usr/bin/mktemp -d /private/tmp/fancontrol-install.XXXXXXXX)
        trap '/bin/rm -rf "$fan_stage"' EXIT
        /usr/bin/ditto \(quoted(app.path)) "$fan_stage/FanControl.app"
        /usr/bin/codesign --verify --deep --strict "$fan_stage/FanControl.app"
        /usr/bin/codesign \(clientVerification) "$fan_stage/FanControl.app"
        /usr/bin/codesign \(helperVerification) "$fan_stage/FanControl.app/Contents/Library/HelperTools/FanControlHelper"
        "$fan_stage/FanControl.app/Contents/Library/HelperTools/FanControlHelper" \(quoted(operation)) "$fan_stage/FanControl.app" \(quoted(client.hash)) \(quoted(helper.hash))
        """
        try await Task.detached {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "on run argv\n do shell script (item 1 of argv) with administrator privileges\nend run", command]
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw HelperClientError.remote(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }.value
    }

    func request(_ request: HelperRequest) async throws -> HelperReply {
        let data = try JSONEncoder().encode(request)
        let connection = try connect()
        guard let connectionID else { throw HelperClientError.disconnected }
        let id = UUID()
        let response: HelperReply = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard self?.pending[id] != nil else { return }
                self?.lostConnection(id: connectionID, error: HelperClientError.timeout)
            }
            // XPC 在自己的连接队列同步回调，闭包必须非隔离，否则 @MainActor 推断会在
            // 回调入口触发 Swift 并发执行器断言(brk 1)。用 @Sendable 强制非隔离入口，
            // 真正的状态变更仍通过内部 Task { @MainActor in } 跳回主执行器。
            guard let remote = connection.remoteObjectProxyWithErrorHandler({ @Sendable [weak self] error in
                Task { @MainActor in self?.lostConnection(id: connectionID, error: error) }
            }) as? FanHelperProtocol else { lostConnection(id: connectionID, error: ControlError.readOnly); return }
            remote.request(data) { @Sendable [weak self] response in
                Task { @MainActor in
                    guard let self, self.connectionID == connectionID, self.pending[id] != nil else { return }
                    do {
                        guard response.count <= 65_536 else { throw ControlError.invalidConfiguration }
                        let value = try JSONDecoder().decode(HelperReply.self, from: response)
                        guard value.version == HelperConstants.protocolVersion else { throw ControlError.invalidConfiguration }
                        self.finish(id, result: .success(value))
                    } catch { self.lostConnection(id: connectionID, error: error) }
                }
            }
        }
        if let error = response.error { throw HelperClientError.remote(error) }
        return response
    }

    private func connect() throws -> NSXPCConnection {
        if let connection { return connection }
        guard bundled, installed else { throw ControlError.readOnly }
        let requirement = try CodeIdentity.read(at: helperURL, identifier: HelperConstants.machService).requirement
        let connection = NSXPCConnection(machServiceName: HelperConstants.machService, options: .privileged)
        let id = UUID()
        connection.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
        connection.setCodeSigningRequirement(requirement)
        // 同 request：失效/中断回调在 XPC 队列触发，必须非隔离入口再跳回主执行器。
        connection.invalidationHandler = { @Sendable [weak self] in Task { @MainActor in self?.lostConnection(id: id) } }
        connection.interruptionHandler = { @Sendable [weak self] in Task { @MainActor in self?.lostConnection(id: id) } }
        self.connection = connection
        connectionID = id
        connection.resume()
        return connection
    }

    private func finish(_ id: UUID, result: Result<HelperReply, any Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func lostConnection(id: UUID? = nil, error: any Error = HelperClientError.disconnected) {
        if let id, id != connectionID { return }
        let previous = connection
        connection = nil
        connectionID = nil
        previous?.invalidationHandler = nil
        previous?.interruptionHandler = nil
        previous?.invalidate()
        for id in Array(pending.keys) { finish(id, result: .failure(error)) }
        onDisconnect?()
    }
    func disconnect() { lostConnection() }
}

enum HelperClientError: Error, LocalizedError {
    case timeout, disconnected, remote(String)
    var errorDescription: String? {
        switch self {
        case .timeout: "控制服务响应超时，硬件状态未确认。"
        case .disconnected: "控制服务连接中断，等待服务恢复系统控制。"
        case .remote(let message): message
        }
    }
}
