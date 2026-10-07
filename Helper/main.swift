import Foundation
import FanCore
import FanHardware

private final class RecoveryJournal: ControlJournal {
    private let url = URL(fileURLWithPath: "/Library/Application Support/FanControl-helper/recovery.json")
    private let model: String
    private struct Record: Codable { var version: Int; var model: String; var fans: [String] }
    init(model: String) { self.model = model }
    func load() throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard data.count <= 4_096 else { throw ControlError.invalidConfiguration }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.version == 1, record.model == model,
              record.fans.count <= 16,
              record.fans.allSatisfy({ SMCFanControl.fanIndex($0) != nil }) else { throw ControlError.invalidConfiguration }
        return Set(record.fans)
    }
    func save(_ fans: Set<String>) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(Record(version: 1, model: model, fans: fans.sorted()))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private actor HelperWorker {
    private let device = SMCDevice(allowWrites: true)
    private var session: ControlSession?
    private var initializationError: String?
    private var nextInitializationAttempt: TimeInterval = 0
    private var retryDelay: TimeInterval = 1

    private func initialize(force: Bool = false) {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard session == nil, force || uptime >= nextInitializationAttempt else { return }
        do {
            let snapshot = try device.controlSnapshot(temperatureSources: [])
            session = try ControlSession(driver: device, journal: RecoveryJournal(model: snapshot.model))
            initializationError = nil
            retryDelay = 1
        } catch {
            initializationError = error.localizedDescription
            device.reset()
            nextInitializationAttempt = uptime + retryDelay
            retryDelay = min(30, retryDelay * 2)
        }
    }

    func request(_ data: Data, connection: ClientConnection) -> Data {
        let client = connection.id
        var response = HelperReply(available: false)
        do {
            guard connection.isOpen else { throw SessionError.notOwner }
            guard data.count <= 65_536 else { throw ControlError.invalidConfiguration }
            let request = try JSONDecoder().decode(HelperRequest.self, from: data)
            guard request.version == HelperConstants.protocolVersion, request.policies.count <= 16 else { throw ControlError.invalidConfiguration }
            initialize(force: request.operation == .restore)
            response.error = initializationError
            response.available = device.controlAvailable && session != nil && session?.preparingRemoval == false
            if request.operation != .status {
                guard let session else { throw ControlError.readOnly }
                switch request.operation {
                case .status: break
                case .heartbeat: session.heartbeat(client: client, uptime: ProcessInfo.processInfo.systemUptime)
                case .restore: try session.release(client: client)
                case .prepareUninstall:
                    try session.prepareRemoval(client: client)
                case .cancelUninstall:
                    try session.cancelRemoval(client: client)
                case .apply:
                    guard device.controlAvailable else { throw ControlError.readOnly }
                    let state = ProcessInfo.processInfo.thermalState
                    guard state != .serious, state != .critical else { throw ControlError.readOnly }
                    try session.apply(request.policies, temperatureSources: request.temperatureSources,
                                      client: client, uptime: ProcessInfo.processInfo.systemUptime, now: Date())
                }
            }
        } catch {
            response.error = error.localizedDescription
            if let error = error as? SessionError, case .readingsNotReady = error {
                response.readingsNotReady = true
            }
        }
        response.status = session?.status
        if !device.controlAvailable, response.status?.message == nil {
            response.status?.message = "未检测到可用的风扇调速接口或有效转速范围，目前仅支持监控。"
        }
        response.ownsSession = session?.status.owner == client
        if let owner = session?.status.owner, owner != client { response.available = false }
        if session?.status.recoveryBlocked == true { response.available = false }
        return (try? JSONEncoder().encode(response)) ?? Data()
    }

    func tick() {
        initialize()
        let state = ProcessInfo.processInfo.thermalState
        session?.tick(uptime: ProcessInfo.processInfo.systemUptime, now: Date(), thermalEmergency: state == .serious || state == .critical)
    }
    func disconnected(_ id: UUID) { session?.disconnected(client: id) }
}

/// XPC 关闭回调先同步失效此标记，避免排队中的旧请求在断连后重新取得控制。
private final class ClientConnection: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var open = true
    var isOpen: Bool { lock.withLock { open } }
    func close() { lock.withLock { open = false } }
}

private final class Endpoint: NSObject, FanHelperProtocol, Sendable {
    let connection: ClientConnection
    let worker: HelperWorker
    init(connection: ClientConnection, worker: HelperWorker) { self.connection = connection; self.worker = worker }
    func request(_ data: Data, reply: @escaping @Sendable (Data) -> Void) {
        Task { reply(await worker.request(data, connection: connection)) }
    }
}

private final class Listener: NSObject, NSXPCListenerDelegate {
    let worker: HelperWorker
    let requirement: String
    init(worker: HelperWorker, requirement: String) { self.worker = worker; self.requirement = requirement }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let client = ClientConnection(), worker = self.worker
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        connection.exportedObject = Endpoint(connection: client, worker: worker)
        connection.invalidationHandler = { client.close(); Task { await worker.disconnected(client.id) } }
        connection.interruptionHandler = { client.close(); Task { await worker.disconnected(client.id) } }
        connection.resume()
        return true
    }
}

if LocalInstallation.runIfRequested() { exit(0) }
guard geteuid() == 0, let trust = try? InstalledTrust.read(),
      (try? trust.helper.validateRunningProcess()) != nil else {
    FileHandle.standardError.write(Data("Helper requires root and the installed code identity.\n".utf8))
    exit(1)
}
let requirement = trust.client.requirement
private let worker = HelperWorker()
private let delegate = Listener(worker: worker, requirement: requirement)
let listener = NSXPCListener(machServiceName: HelperConstants.machService)
listener.delegate = delegate
listener.resume()
Task(priority: .userInitiated) {
    while !Task.isCancelled {
        await worker.tick()
        try? await Task.sleep(for: .seconds(1))
    }
}
RunLoop.current.run()
