import Foundation
import Testing
import FanCore

struct SleepDiagnosticLogTests {
    @Test func persistsAcrossInstancesAndBoundsStorageWhileKeepingRecentFailures() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sleep.log")
        let log = SleepDiagnosticLog(url: url, maximumBytes: 4096)
        for index in 0..<30 { log.event("test", "checkpoint", "\(index) " + String(repeating: "合盖", count: 200)) }
        log.event("test", "restore.failed", "domain=POSIX code=13 line1\nline2", error: true)
        let reloaded = SleepDiagnosticLog(url: url).history()
        #expect(reloaded.contains("restore.failed") && reloaded.contains("code=13"))
        #expect(reloaded.contains("line1 | line2") && !reloaded.contains("checkpoint 0 "))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.size] as? NSNumber)?.intValue ?? .max <= 4096)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(reloaded.utf8.count <= 24_000)
    }

    @Test func independentWritersDoNotLoseOrInterleaveRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sleep.log")
        let writers = [SleepDiagnosticLog(url: url), SleepDiagnosticLog(url: url)]
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            writers[index % 2].event("test", "writer", "record=\(index)")
        }
        let lines = writers[0].history().split(separator: "\n")
        #expect(lines.count == 20)
        for index in 0..<20 { #expect(lines.contains { $0.hasSuffix("record=\(index)") }) }
    }

    @Test func diagnosticLoggingDoesNotFollowSymlinksOrExposeUnsafeFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("target.txt"), link = directory.appendingPathComponent("sleep.log")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let log = SleepDiagnosticLog(url: link)
        log.event("test", "must_not_write")
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
        #expect(!log.history().contains("keep"))
    }
}
