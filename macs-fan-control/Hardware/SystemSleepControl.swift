import Darwin
import Foundation
import IOKit
import IOKit.ps
#if SWIFT_PACKAGE
import FanCore
#endif

public final class SystemSleepControl: SleepInhibitionDriver {
    private let diagnostics: SleepDiagnosticLog?
    private var lastReadFailure: String?
    public init(diagnostics: SleepDiagnosticLog? = nil) { self.diagnostics = diagnostics }

    public func read() throws -> SleepPowerState {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { throw readFailure("IOPMrootDomain unavailable") }
        defer { IOObjectRelease(root) }
        func flag(_ name: String) -> Bool? {
            (IORegistryEntryCreateCFProperty(root, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.boolValue
        }
        guard let disabled = flag("SleepDisabled") else { throw readFailure("SleepDisabled property missing or not boolean") }
        var state = SleepPowerState(disabled: disabled, lidClosed: flag("AppleClamshellState"), onBattery: true)
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            _ = readFailure("IOPSCopyPowerSourcesInfo unavailable; treating power source as unknown battery")
            return state
        }
        lastReadFailure = nil
        state.onBattery = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) != kIOPSACPowerValue
        let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Double,
                  let maximum = description[kIOPSMaxCapacityKey] as? Double, maximum > 0 else { continue }
            state.batteryPercent = min(100, max(0, current / maximum * 100))
        }
        return state
    }

    private func readFailure(_ detail: String) -> PowerReadError {
        if lastReadFailure != detail { diagnostics?.event("power", "read.failed", detail, error: true) }
        lastReadFailure = detail
        return PowerReadError(detail: detail)
    }

    private struct PowerReadError: LocalizedError {
        let detail: String
        var errorDescription: String? { "无法读取电源状态：" + detail }
    }

    public func setDisabled(_ disabled: Bool) throws {
        diagnostics?.event("power", "write.begin", "requested=\(disabled)")
        _ = try Self.pmset(["-a", "disablesleep", disabled ? "1" : "0"], diagnostics: diagnostics)
        let settings = try Self.pmset(["-g"], diagnostics: diagnostics)
        let configured = settings.split(separator: "\n").first { $0.split(whereSeparator: { $0.isWhitespace }).first == "SleepDisabled" }
            .flatMap { $0.split(whereSeparator: { $0.isWhitespace }).last }.map { $0 == "1" } ?? false
        diagnostics?.event("power", "preferences.readback", "expected=\(disabled) configured=\(configured)")
        guard configured == disabled else { throw SleepInhibitionError.unconfirmed }
        for _ in 0..<20 {
            let state = try read()
            if state.disabled == disabled {
                diagnostics?.event("power", "kernel.readback", state.diagnosticSummary)
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        diagnostics?.event("power", "kernel.readback_timeout", "expected=\(disabled)", error: true)
        throw SleepInhibitionError.unconfirmed
    }

    /// 参数仅由内部常量构成，不接受 shell。 / Only fixed internal arguments, never a shell.
    private static func pmset(_ arguments: [String], diagnostics: SleepDiagnosticLog?) throws -> String {
        let process = Process(), output = Pipe(), errors = Pipe(), finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { @Sendable _ in finished.signal() }
        let started = ProcessInfo.processInfo.systemUptime
        do { try process.run() }
        catch {
            diagnostics?.event("power", "pmset.launch_failed", "args=\(arguments) \(SleepDiagnosticLog.describe(error))", error: true)
            throw error
        }
        guard finished.wait(timeout: .now() + 1) == .success else {
            diagnostics?.event("power", "pmset.timeout", "args=\(arguments) pid=\(process.processIdentifier)", error: true)
            kill(process.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + 1)
            throw SleepInhibitionError.unconfirmed
        }
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile().prefix(2048), as: UTF8.self)
        diagnostics?.event("power", "pmset.finished", "args=\(arguments) exit=\(process.terminationStatus) reason=\(process.terminationReason.rawValue) elapsed=\(ProcessInfo.processInfo.systemUptime - started) stderr=\(stderr)", error: process.terminationStatus != 0)
        guard process.terminationStatus == 0 else { throw SleepInhibitionError.unconfirmed }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}

public final class SleepRecoveryJournal: SleepInhibitionJournal {
    private let url: URL
    private struct Record: Codable { var version = 1; var needsRecovery: Bool }
    public init(url: URL = URL(fileURLWithPath: HelperConstants.sleepRecoveryPath)) { self.url = url }

    public func load() throws -> Bool {
        var metadata = stat()
        if lstat(url.path, &metadata) != 0 {
            guard errno == ENOENT else { throw SleepInhibitionError.recoveryRequired }
            return false
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw SleepInhibitionError.recoveryRequired }
        defer { close(descriptor) }
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == geteuid(),
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o077 == 0,
              metadata.st_size <= 4096 else { throw SleepInhibitionError.recoveryRequired }
        let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() ?? Data()
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.version == 1 else { throw SleepInhibitionError.recoveryRequired }
        return record.needsRecovery
    }

    public func save(needsRecovery: Bool) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0, metadata.st_uid == geteuid(),
              metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_mode & 0o022 == 0 else { throw SleepInhibitionError.recoveryRequired }
        let data = try JSONEncoder().encode(Record(needsRecovery: needsRecovery))
        let temporary = directory.appendingPathComponent(".sleep-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SleepInhibitionError.recoveryRequired }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        defer { close(descriptor); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temporary.path, url.path) == 0 else { throw SleepInhibitionError.recoveryRequired }
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY)
        guard parent >= 0 else { throw SleepInhibitionError.recoveryRequired }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw SleepInhibitionError.recoveryRequired }
    }
}
