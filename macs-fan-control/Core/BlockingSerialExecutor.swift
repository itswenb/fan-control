import Foundation

/// 将同步硬件调用限制在独立串行队列，避免占用 Swift 协作线程。 / Isolate synchronous hardware calls on a serial dispatch queue.
public final class BlockingSerialExecutor: SerialExecutor, @unchecked Sendable {
    private let queue: DispatchQueue

    public init(label: String) { queue = DispatchQueue(label: label, qos: .userInitiated) }

    public func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        queue.async { unownedJob.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }
}
