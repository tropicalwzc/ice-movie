import Foundation
import IceCore

/// 读取优先级。数值越小越先执行。
public enum SMBReadPriority: Int, Sendable, Comparable, CaseIterable {
    case playback = 0
    case enumeration = 1
    case thumbnail = 2

    public static func < (lhs: SMBReadPriority, rhs: SMBReadPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .playback: "playback"
        case .enumeration: "enumeration"
        case .thumbnail: "thumbnail"
        }
    }
}

public enum SMBReadError: LocalizedError, Sendable, Equatable {
    case timeout(TimeInterval)
    case disconnected
    case cancelled
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .timeout(let seconds):
            "读取超时（\(String(format: "%.1f", seconds))s）"
        case .disconnected:
            "连接已断开，挂起的读取已终止"
        case .cancelled:
            "读取已取消"
        case .underlying(let detail):
            "读取失败：\(detail)"
        }
    }
}

/// 单线程读调度器：所有 SMB 读取经同一队列串行执行，按优先级出队。
///
/// 这样播放读取可以插到抽帧读取之前，同时避免同时向 libsmb2 句柄发起并发读取。
public final class SMBReadScheduler: @unchecked Sendable {
    private struct Job {
        let id: UInt64
        let priority: SMBReadPriority
        let enqueuedAt: Date
        let timeout: TimeInterval
        let operation: @Sendable () throws -> Data
        let continuation: CheckedContinuation<Data, Error>
    }

    private let condition = NSCondition()
    private var pending: [UInt64] = []
    private var jobs: [UInt64: Job] = [:]
    private var nextID: UInt64 = 0
    private var workerRunning = false
    private var stopped = false
    private var limitBytesPerSecond = 0
    private let label: String

    public init(label: String = "smb-read") {
        self.label = label
    }

    deinit {
        shutdown()
    }

    public var pendingCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return pending.count
    }

    /// 仅用于带宽验收：限制调度器的总读取速率（字节/秒）。0 表示不限制。
    public func setLimit(bytesPerSecond: Int) {
        condition.lock()
        limitBytesPerSecond = max(0, bytesPerSecond)
        condition.unlock()
        Log.info(.smb, "读调度限速=\(max(0, bytesPerSecond) / 1024)KB/s")
    }

    /// 提交一次读取。超时与断连都会让调用方立即收到错误，而不是无限等待。
    public func submit(
        priority: SMBReadPriority,
        timeout: TimeInterval = 30,
        operation: @escaping @Sendable () throws -> Data
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            condition.lock()
            guard !stopped else {
                condition.unlock()
                continuation.resume(throwing: SMBReadError.disconnected)
                return
            }

            nextID += 1
            let id = nextID
            jobs[id] = Job(
                id: id,
                priority: priority,
                enqueuedAt: Date(),
                timeout: timeout,
                operation: operation,
                continuation: continuation
            )
            pending.append(id)
            ensureWorkerLocked()
            condition.broadcast()
            condition.unlock()

            if timeout > 0 {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    [weak self] in
                    self?.expire(id: id)
                }
            }
        }
    }

    /// 会话断开时调用：让所有排队与执行中的请求立即以断开错误结束。
    public func cancelAll(error: SMBReadError = .disconnected) {
        condition.lock()
        let all = jobs
        jobs.removeAll()
        pending.removeAll()
        condition.broadcast()
        condition.unlock()

        for job in all.values {
            job.continuation.resume(throwing: error)
        }
        if !all.isEmpty {
            Log.notice(.smb, "读调度终止挂起请求 数量=\(all.count) 原因=\(error.localizedDescription)")
        }
    }

    // MARK: - 内部

    private func ensureWorkerLocked() {
        guard !workerRunning, !stopped else { return }
        workerRunning = true
        let thread = Thread { [weak self] in
            self?.run()
        }
        thread.name = "com.wangzicheng.icemovie.\(label)"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func run() {
        while true {
            condition.lock()
            while pending.isEmpty && !stopped {
                condition.wait()
            }
            if stopped {
                condition.unlock()
                break
            }
            let id = pickNextLocked()
            guard let job = jobs[id] else {
                condition.unlock()
                continue
            }
            let limit = limitBytesPerSecond
            condition.unlock()

            let startedAt = Date()
            let result: Result<Data, Error>
            do {
                result = .success(try job.operation())
            } catch {
                result = .failure(error)
            }

            // 带宽验收用：按单次读取大小折算应耗时间，超出部分补足。
            if limit > 0, case .success(let data) = result {
                let expected = Double(data.count) / Double(limit)
                let elapsed = Date().timeIntervalSince(startedAt)
                if expected > elapsed {
                    Thread.sleep(forTimeInterval: expected - elapsed)
                }
            }

            condition.lock()
            let shouldResume = jobs.removeValue(forKey: id) != nil
            condition.unlock()

            if shouldResume {
                let waitMS = Int(startedAt.timeIntervalSince(job.enqueuedAt) * 1000)
                let runMS = Int(Date().timeIntervalSince(startedAt) * 1000)
                switch result {
                case .success(let data):
                    Log.debug(
                        .smb,
                        "读调度 \(job.priority.label) 等待=\(waitMS)ms 执行=\(runMS)ms 长度=\(data.count)B"
                    )
                case .failure(let error):
                    Log.debug(
                        .smb,
                        "读调度失败 \(job.priority.label) 等待=\(waitMS)ms 执行=\(runMS)ms \(error.localizedDescription)"
                    )
                }
                job.continuation.resume(with: result)
            }
        }

        condition.lock()
        workerRunning = false
        condition.unlock()
    }

    /// 取优先级最高、同优先级下最早入队的请求。
    private func pickNextLocked() -> UInt64 {
        var bestIndex = 0
        for index in pending.indices where index > 0 {
            guard let candidate = jobs[pending[index]],
                  let current = jobs[pending[bestIndex]] else { continue }
            if candidate.priority < current.priority {
                bestIndex = index
            }
        }
        return pending.remove(at: bestIndex)
    }

    private func expire(id: UInt64) {
        condition.lock()
        guard let job = jobs.removeValue(forKey: id) else {
            condition.unlock()
            return
        }
        pending.removeAll { $0 == id }
        condition.unlock()

        Log.notice(.smb, "读调度超时 \(job.priority.label) 等待=\(String(format: "%.1f", job.timeout))s")
        job.continuation.resume(throwing: SMBReadError.timeout(job.timeout))
    }

    private func shutdown() {
        condition.lock()
        stopped = true
        let all = jobs
        jobs.removeAll()
        pending.removeAll()
        condition.broadcast()
        condition.unlock()
        for job in all.values {
            job.continuation.resume(throwing: SMBReadError.cancelled)
        }
    }
}
