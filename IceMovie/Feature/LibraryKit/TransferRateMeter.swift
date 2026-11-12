import Foundation

/// 上传吞吐的滚动窗口计量器。
///
/// SMB 写入回调在后台线程执行，因此内部加锁；UI 侧按固定间隔读取 `rate()`，
/// 避免每个 1 MiB 回调都触发 SwiftUI 刷新。
public final class TransferRateMeter: @unchecked Sendable {
    private struct Sample {
        let time: TimeInterval
        let bytes: Int64
    }

    private let lock = NSLock()
    private let window: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private var samples: [Sample] = []
    private var latestBytes: Int64 = 0

    public init(
        window: TimeInterval = 3,
        now: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.window = max(0.1, window)
        self.now = now
    }

    public func reset() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        latestBytes = 0
        lock.unlock()
    }

    public func record(totalBytes: Int64) {
        let timestamp = now()
        lock.lock()
        defer { lock.unlock() }
        prune(now: timestamp)
        samples.append(Sample(time: timestamp, bytes: totalBytes))
        latestBytes = totalBytes
    }

    public func totalBytes() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return latestBytes
    }

    public func rate() -> Double {
        let timestamp = now()
        lock.lock()
        defer { lock.unlock() }
        prune(now: timestamp)
        guard let first = samples.first, let last = samples.last else { return 0 }
        let duration = last.time - first.time
        guard duration > 0.001 else { return 0 }
        let bytes = last.bytes - first.bytes
        guard bytes > 0 else { return 0 }
        return Double(bytes) / duration
    }

    private func prune(now timestamp: TimeInterval) {
        let cutoff = timestamp - window
        if let firstFresh = samples.firstIndex(where: { $0.time >= cutoff }) {
            if firstFresh > 0 {
                samples.removeFirst(firstFresh)
            }
        } else {
            samples.removeAll(keepingCapacity: true)
        }
    }
}
