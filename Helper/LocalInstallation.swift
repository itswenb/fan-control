import Foundation
import FanCore
import Darwin

enum InstallationError: Error, LocalizedError {
    case existing, unsafePath, pendingRecovery, commandFailed, rollbackFailed
    var errorDescription: String? {
        switch self {
        case .existing: "已有控制服务。请先用安装该服务的应用恢复自动并移除服务，再安装新版本。"
        case .unsafePath: "服务目录的所有者或权限不符合要求，安装已停止。"
        case .pendingRecovery: "风扇恢复尚未确认，暂时不能更新或移除服务。请用原版本应用恢复系统自动后重试。"
        case .commandFailed: "系统未能完成服务注册。请查看系统后台项目权限。"
        case .rollbackFailed: "服务更新失败，旧服务也未能自动恢复。请保留原应用并检查控制服务状态。"
        }
    }
}

enum LocalInstallation {
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard arguments.count > 1, ["--install", "--upgrade", "--uninstall", "--uninstall-stale"].contains(arguments[1]) else { return false }
        do {
            guard geteuid() == 0, arguments.count == 5, CodeIdentity.validHash(arguments[3]), CodeIdentity.validHash(arguments[4]) else { throw ControlError.invalidSignature }
            let app = URL(fileURLWithPath: arguments[2]).standardizedFileURL
            let client = try CodeIdentity.read(at: app, identifier: HelperConstants.appIdentifier)
            let helperURL = app.appendingPathComponent("Contents/Library/HelperTools/FanControlHelper")
            let helper = try CodeIdentity.read(at: helperURL, identifier: HelperConstants.machService)
            guard client.hash == arguments[3], helper.hash == arguments[4] else { throw ControlError.invalidSignature }
            try helper.validateRunningProcess()
            let trust = InstalledTrust(client: client, helper: helper)
            switch arguments[1] {
            case "--install": try install(helperURL: helperURL, trust: trust)
            case "--upgrade": try retireExisting { try install(helperURL: helperURL, trust: trust) }
            case "--uninstall": try uninstall(trust: trust)
            default: try retireExisting {}
            }
            return true
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    private static func secureDirectory(_ path: String, create: Bool = false, mode: mode_t = 0o755) throws {
        var metadata = stat()
        if lstat(path, &metadata) != 0 {
            guard create, errno == ENOENT, mkdir(path, mode) == 0, chmod(path, mode) == 0, lstat(path, &metadata) == 0 else { throw InstallationError.unsafePath }
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == 0, metadata.st_mode & 0o022 == 0 else { throw InstallationError.unsafePath }
    }

    private static func checkDirectories() throws {
        for path in ["/Library", "/Library/Application Support", "/Library/LaunchDaemons"] { try secureDirectory(path) }
        try secureDirectory("/Library/PrivilegedHelperTools", create: true)
        try secureDirectory(HelperConstants.supportPath, create: true, mode: 0o700)
    }

    private static func install(helperURL: URL, trust: InstalledTrust) throws {
        try checkDirectories()
        let paths = [HelperConstants.installedHelperPath, HelperConstants.daemonPath, HelperConstants.trustPath]
        for path in paths {
            var metadata = stat()
            guard lstat(path, &metadata) != 0, errno == ENOENT else { throw InstallationError.existing }
        }
        guard runLaunchctl(["print", "system/" + HelperConstants.machService]) != 0 else { throw InstallationError.existing }
        try requireEmptyRecovery()
        let manager = FileManager.default
        var created: [String] = []
        do {
            let temporary = HelperConstants.installedHelperPath + "." + UUID().uuidString
            try manager.copyItem(atPath: helperURL.path, toPath: temporary)
            created.append(temporary)
            try manager.setAttributes([.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o755], ofItemAtPath: temporary)
            guard try CodeIdentity.read(at: URL(fileURLWithPath: temporary), identifier: HelperConstants.machService) == trust.helper else { throw ControlError.invalidSignature }
            try manager.moveItem(atPath: temporary, toPath: HelperConstants.installedHelperPath)
            created.append(HelperConstants.installedHelperPath)
            let trustData = try JSONEncoder().encode(trust)
            try trustData.write(to: URL(fileURLWithPath: HelperConstants.trustPath), options: .atomic)
            created.append(HelperConstants.trustPath)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: HelperConstants.trustPath)
            let plist: [String: Any] = ["Label": HelperConstants.machService,
                                      "ProgramArguments": [HelperConstants.installedHelperPath],
                                      "MachServices": [HelperConstants.machService: true],
                                      "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 5, "ProcessType": "Background"]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: HelperConstants.daemonPath), options: .atomic)
            created.append(HelperConstants.daemonPath)
            try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: HelperConstants.daemonPath)
            guard runLaunchctl(["bootstrap", "system", HelperConstants.daemonPath]) == 0 else { throw InstallationError.commandFailed }
        } catch {
            for path in created.reversed() { try? manager.removeItem(atPath: path) }
            throw error
        }
    }

    private static func requireEmptyRecovery() throws {
        let path = HelperConstants.supportPath + "/recovery.json"
        var metadata = stat()
        if lstat(path, &metadata) != 0 {
            guard errno == ENOENT else { throw InstallationError.unsafePath }
            return
        }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw InstallationError.unsafePath }
        defer { close(descriptor) }
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == 0,
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o022 == 0,
              metadata.st_size <= 4096 else { throw InstallationError.unsafePath }
        struct Recovery: Decodable { let version: Int; let fans: [String] }
        let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() ?? Data()
        let recovery = try JSONDecoder().decode(Recovery.self, from: data)
        guard recovery.version == 1, recovery.fans.isEmpty else { throw InstallationError.pendingRecovery }
    }

    // 管理员授权后的迁移仍须确认旧安装完整，并且没有待恢复的风扇。
    // 旧版 app 的 cdhash 已变化，不能依赖其 XPC 通道执行 prepareUninstall。
    private static func verifiedExistingInstallation() throws -> InstalledTrust {
        try checkDirectories()
        let installed = try InstalledTrust.read()
        var metadata = stat()
        for path in [HelperConstants.installedHelperPath, HelperConstants.daemonPath] {
            guard lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_uid == 0, metadata.st_mode & 0o022 == 0 else { throw InstallationError.unsafePath }
        }
        let helper = try CodeIdentity.read(at: URL(fileURLWithPath: HelperConstants.installedHelperPath), identifier: HelperConstants.machService)
        guard helper == installed.helper else { throw ControlError.invalidSignature }
        let plistData = try Data(contentsOf: URL(fileURLWithPath: HelperConstants.daemonPath))
        guard let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              plist["Label"] as? String == HelperConstants.machService,
              plist["ProgramArguments"] as? [String] == [HelperConstants.installedHelperPath],
              plist["MachServices"] as? [String: Bool] == [HelperConstants.machService: true] else { throw InstallationError.unsafePath }
        return installed
    }

    private static func retireExisting(then action: () throws -> Void) throws {
        _ = try verifiedExistingInstallation()
        try requireEmptyRecovery()
        let service = "system/" + HelperConstants.machService
        let wasLoaded = runLaunchctl(["print", service]) == 0
        if wasLoaded {
            guard runLaunchctl(["bootout", service]) == 0 else { throw InstallationError.commandFailed }
        }
        let paths = [HelperConstants.installedHelperPath, HelperConstants.daemonPath, HelperConstants.trustPath]
        let manager = FileManager.default
        var backups: [(original: String, backup: String)] = []
        do {
            try requireEmptyRecovery()
            for path in paths {
                let backup = path + ".backup-" + UUID().uuidString
                try manager.moveItem(atPath: path, toPath: backup)
                backups.append((path, backup))
            }
            try action()
            for entry in backups { try? manager.removeItem(atPath: entry.backup) }
        } catch {
            var rollbackFailed = false
            for entry in backups.reversed() {
                do {
                    if manager.fileExists(atPath: entry.original) { try manager.removeItem(atPath: entry.original) }
                    try manager.moveItem(atPath: entry.backup, toPath: entry.original)
                } catch { rollbackFailed = true }
            }
            if wasLoaded && runLaunchctl(["bootstrap", "system", HelperConstants.daemonPath]) != 0 { rollbackFailed = true }
            if rollbackFailed { throw InstallationError.rollbackFailed }
            throw error
        }
    }

    private static func uninstall(trust: InstalledTrust) throws {
        let installed = try verifiedExistingInstallation()
        guard installed.client == trust.client, installed.helper == trust.helper else { throw ControlError.invalidSignature }
        try requireEmptyRecovery()
        guard runLaunchctl(["bootout", "system/" + HelperConstants.machService]) == 0 else { throw InstallationError.commandFailed }
        do { try requireEmptyRecovery() }
        catch { _ = runLaunchctl(["bootstrap", "system", HelperConstants.daemonPath]); throw error }
        for path in [HelperConstants.daemonPath, HelperConstants.installedHelperPath, HelperConstants.trustPath] {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus }
        catch { return -1 }
    }
}
