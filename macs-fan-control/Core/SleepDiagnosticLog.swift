import Darwin
import Foundation
import os

/// 有界持久日志；跨进程锁保护 App 和背光进程并发写入。 / Bound storage and serialize app/child writers.
public final class SleepDiagnosticLog: @unchecked Sendable {
    public static let subsystem = "com.itswenb.fancontrol.sleep"
    public static let application = SleepDiagnosticLog(url: FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Logs/FanControl/sleep.log"))
    public static let helper = SleepDiagnosticLog(url: URL(fileURLWithPath: HelperConstants.supportPath + "/sleep.log"))
    private let url: URL?
    private let limit: Int
    private let logger = Logger(subsystem: subsystem, category: "sleep")

    public init(url: URL? = nil, maximumBytes: Int = 131_072) {
        self.url = url; self.limit = max(4096, maximumBytes)
    }

    public func event(_ component: String, _ stage: String, _ detail: String = "", error: Bool = false) {
        let clean = String(detail.prefix(600)).replacingOccurrences(of: "\n", with: " | ").replacingOccurrences(of: "\r", with: "")
        let line = "\(Date().ISO8601Format()) pid=\(getpid()) uptime=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime)) \(error ? "ERROR" : "INFO") [\(component.prefix(60))] \(stage.prefix(60)) \(clean)\n"
        if error { logger.error("\(line, privacy: .public)") }
        else { logger.notice("\(line, privacy: .public)") }
        guard let url else { return }
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
            guard descriptor >= 0 else { throw POSIXError(.EACCES) }
            defer { close(descriptor) }
            guard valid(descriptor), lock(descriptor, operation: LOCK_EX) else { throw POSIXError(.EACCES) }
            defer { flock(descriptor, LOCK_UN) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            let size = try handle.seekToEnd()
            let data = Data(line.utf8)
            if size + UInt64(data.count) > UInt64(limit) {
                try handle.seek(toOffset: size - min(size, UInt64(limit / 2)))
                let tail = try handle.readToEnd() ?? Data()
                let retained = tail.firstIndex(of: 10).map { Data(tail.suffix(from: tail.index(after: $0))) } ?? Data()
                try handle.truncate(atOffset: 0)
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: retained)
            }
            try handle.write(contentsOf: data)
        } catch {
            logger.error("diagnostics.persist_failed errno=\(errno) code=\((error as NSError).code)")
        }
    }

    public func history(maximumBytes: Int = 24_000) -> String {
        guard let url else { return "Persistent log disabled in this process." }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return "Persistent log unavailable (errno=\(errno))." }
        defer { close(descriptor) }
        guard valid(descriptor), lock(descriptor, operation: LOCK_SH) else { return "Persistent log permissions invalid." }
        defer { flock(descriptor, LOCK_UN) }
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            let size = try handle.seekToEnd(), count = UInt64(max(1, min(32_000, maximumBytes)))
            try handle.seek(toOffset: size - min(size, count))
            let data = try handle.read(upToCount: Int(min(size, count))) ?? Data()
            return String(decoding: data, as: UTF8.self)
        } catch { return "Persistent log read failed: \(Self.describe(error))" }
    }

    public static func describe(_ error: any Error) -> String {
        let value = error as NSError
        return "domain=\(value.domain) code=\(value.code) \(value.localizedDescription)"
    }

    /// 诊断写入不能因另一进程暂停而卡住控制心跳。 / Logging must not wait indefinitely on a paused writer.
    private func lock(_ descriptor: Int32, operation: Int32) -> Bool {
        for _ in 0..<50 {
            if flock(descriptor, operation | LOCK_NB) == 0 { return true }
            guard errno == EWOULDBLOCK || errno == EAGAIN else { return false }
            usleep(1000)
        }
        return false
    }

    private func valid(_ descriptor: Int32) -> Bool {
        var metadata = stat()
        return fstat(descriptor, &metadata) == 0 && metadata.st_uid == geteuid()
            && metadata.st_mode & S_IFMT == S_IFREG && metadata.st_mode & 0o077 == 0
    }
}
