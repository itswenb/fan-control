import Darwin
import Foundation
import IOKit
#if SWIFT_PACKAGE
import FanCore
#endif

@MainActor
protocol LidBacklightManaging: AnyObject {
    func prepare() async throws
    func start(onFailure: @escaping @MainActor (String) -> Void)
    func stop() async throws
}

@MainActor
final class LidBacklightController: LidBacklightManaging {
    private var task: Task<Void, Never>?
    private var failure: String?
    private let helperURL: URL
    private let diagnostics: SleepDiagnosticLog?

    init(helperURL: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/HelperTools/FanControlHelper"), diagnostics: SleepDiagnosticLog? = nil) {
        self.helperURL = helperURL; self.diagnostics = diagnostics
    }

    func prepare() async throws {
        diagnostics?.event("lighting", "probe.begin")
        guard Self.lidClosed() != nil else { throw SleepLightingError.unavailable }
        let probe = try Child(url: helperURL, operation: "--backlight-probe", diagnostics: diagnostics)
        do {
            try await probe.ready()
            try await probe.stop()
            diagnostics?.event("lighting", "probe.confirmed")
        } catch {
            diagnostics?.event("lighting", "probe.failed", SleepDiagnosticLog.describe(error), error: true)
            try? await probe.stop(); throw error
        }
    }

    func start(onFailure: @escaping @MainActor (String) -> Void) {
        guard task == nil else { return }
        failure = nil
        task = Task { [weak self] in
            guard let self else { return }
            var child: Child?
            var previousLid: Bool?
            diagnostics?.event("lighting", "monitor.start")
            do {
                while !Task.isCancelled {
                    guard let closed = Self.lidClosed() else { throw SleepLightingError.unavailable }
                    if previousLid != closed {
                        diagnostics?.event("lighting", "lid.changed", "closed=\(closed)")
                        previousLid = closed
                    }
                    if closed {
                        if child == nil {
                            child = try Child(url: helperURL, operation: "--backlight-session", diagnostics: diagnostics)
                            try await child?.ready()
                        }
                        guard child?.process.isRunning == true else { throw SleepLightingError.unconfirmed }
                        try child?.heartbeat()
                    } else if let previous = child {
                        child = nil
                        try await previous.stop()
                    }
                    try await Task.sleep(for: .seconds(1))
                }
            } catch is CancellationError {
                // 取消只结束会话，不视为故障。 / Cancellation is a normal session end.
            } catch {
                diagnostics?.event("lighting", "monitor.failed", SleepDiagnosticLog.describe(error), error: true)
                failure = error.localizedDescription
                onFailure(error.localizedDescription)
            }
            do { try await child?.stop() }
            catch {
                diagnostics?.event("lighting", "cleanup.failed", SleepDiagnosticLog.describe(error), error: true)
                failure = error.localizedDescription; onFailure(error.localizedDescription)
            }
            diagnostics?.event("lighting", "monitor.stopped")
        }
    }

    func stop() async throws {
        let previous = task
        previous?.cancel()
        await previous?.value
        task = nil
        if let failure { self.failure = nil; throw SleepLightingError.restore(failure) }
    }

    private static func lidClosed() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        return (IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.boolValue
    }

    private final class Child {
        let process = Process()
        private let input = Pipe()
        private let output = Pipe()
        private let errors = Pipe()
        private let diagnostics: SleepDiagnosticLog?

        init(url: URL, operation: String, diagnostics: SleepDiagnosticLog?) throws {
            self.diagnostics = diagnostics
            process.executableURL = url
            process.arguments = [operation]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            // 子进程退出时写入转为可处理错误。 / A closed child pipe must not terminate the app with SIGPIPE.
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw SleepLightingError.unavailable }
            try process.run()
            diagnostics?.event("lighting", "child.launched", "operation=\(operation) childPID=\(process.processIdentifier)")
            try errors.fileHandleForWriting.close()
            _ = fcntl(errors.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK)
            try input.fileHandleForReading.close()
            try output.fileHandleForWriting.close()
        }

        func ready() async throws {
            let descriptor = output.fileHandleForReading.fileDescriptor
            let ready = await Task.detached {
                var item = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                guard poll(&item, 1, 2_000) > 0 else { return false }
                var bytes = [UInt8](repeating: 0, count: 6)
                return Darwin.read(descriptor, &bytes, 6) == 6 && bytes == Array("ready\n".utf8)
            }.value
            guard ready else {
                diagnostics?.event("lighting", "child.ready_failed", childDetail(), error: true)
                throw SleepLightingError.unavailable
            }
            diagnostics?.event("lighting", "child.ready", "childPID=\(process.processIdentifier)")
        }

        func heartbeat() throws { try input.fileHandleForWriting.write(contentsOf: Data([1])) }

        func stop() async throws {
            try? input.fileHandleForWriting.close()
            // 清理不继承取消状态，确保有时间恢复亮度。 / Cleanup waits even if the monitoring task was cancelled.
            let process = process
            let exited = await Task.detached {
                for _ in 0..<40 {
                    if !process.isRunning { return true }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                return !process.isRunning
            }.value
            let succeeded = exited && process.terminationStatus == 0
            diagnostics?.event("lighting", "child.stopped", childDetail(), error: !succeeded)
            guard succeeded else { throw SleepLightingError.unconfirmed }
        }

        private func childDetail() -> String {
            var buffer = [UInt8](repeating: 0, count: 2048)
            let count = Darwin.read(errors.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
            let stderr = count > 0 ? String(decoding: buffer.prefix(count), as: UTF8.self) : ""
            let state = process.isRunning ? "running" : "exit=\(process.terminationStatus) reason=\(process.terminationReason.rawValue)"
            return "childPID=\(process.processIdentifier) \(state) stderr=\(stderr)"
        }
    }
}

enum SleepLightingError: Error, LocalizedError {
    case unavailable, unconfirmed, restore(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: "本机屏幕或键盘背光接口不可用，未开启防休眠。"
        case .unconfirmed: "背光关闭或恢复未确认，已请求结束防休眠。"
        case .restore(let detail): "背光恢复未确认：\(detail)"
        }
    }
}
