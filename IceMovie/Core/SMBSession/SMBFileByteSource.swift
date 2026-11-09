import Foundation
import IceCore

/// 跨 actor 传递 `SMB2FileHandle` 的盒子。句柄本身由 SMBClient 串行创建，这里只做所有权转移。
struct SMBHandleBox: @unchecked Sendable {
    let handle: SMB2FileHandle
}

/// 重开文件句柄的闭包。会话重连后用它恢复读取。
struct SMBHandleProvider: @unchecked Sendable {
    let open: () async throws -> SMBHandleBox

    init(open: @escaping () async throws -> SMBHandleBox) {
        self.open = open
    }
}

/// SMB 文件的字节源。
///
/// - 所有读取经 `SMBReadScheduler` 串行排队，按优先级出队（播放 > 枚举 > 抽帧）；
/// - 1 MB 分块，24 块（24 MB）预读环；
/// - 播放源按顺序读时在后台预读，缩略图源不预读；
/// - 句柄失效时重开一次并重试同一偏移。
final class SMBFileByteSource: ByteSource, BufferMetricsProviding, NetworkSpeedProviding, @unchecked Sendable {
    private let scheduler: SMBReadScheduler
    private let priority: SMBReadPriority
    private let reopen: SMBHandleProvider?
    private let lengthValue: Int64?
    private let chunkSize: Int
    private let ring: SMBChunkRing

    private var handle: SMB2FileHandle
    private let lock = NSLock()
    private var closed = false
    private var prefetchTask: Task<Void, Never>?
    private var prefetchActive = false
    private var prefetchGeneration = 0
    private var lastReadEnd: Int64 = -1
    private var reachedEOF = false
    private var speedSamples: [(time: Double, bytes: Int)] = []

    var length: Int64? { lengthValue }

    /// 最近约 2 秒的实际网络下载速度（含预读）。
    var downloadBytesPerSecond: Double {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        speedSamples.removeAll { now - $0.time > 2.5 }
        let samples = speedSamples
        lock.unlock()
        guard let first = samples.first else { return 0 }
        let bytes = samples.reduce(0) { $0 + $1.bytes }
        let span = max(0.5, min(2.5, now - first.time))
        return Double(bytes) / span
    }

    /// 当前读位置之后连续缓存了多少字节；进度条据此画缓冲区间。
    var bufferedAheadBytes: Int64 {
        lock.lock()
        let end = lastReadEnd
        lock.unlock()
        guard end >= 0 else { return 0 }
        let cachedEnd = ring.contiguousEnd(from: end)
        return max(0, cachedEnd - end)
    }

    init(
        handle: SMB2FileHandle,
        length: Int64?,
        reopen: SMBHandleProvider?,
        scheduler: SMBReadScheduler,
        priority: SMBReadPriority,
        chunkSize: Int = 1 << 20,
        ringCapacity: Int = 24
    ) {
        self.handle = handle
        self.lengthValue = length
        self.reopen = reopen
        self.scheduler = scheduler
        self.priority = priority
        self.chunkSize = max(1, chunkSize)
        self.ring = SMBChunkRing(chunkSize: chunkSize, capacity: ringCapacity)
    }

    func read(at offset: Int64, count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        let closedNow = lock.withLock { closed }
        guard !closedNow else { throw ByteSourceError.closed }
        if let length, offset >= length { return Data() }

        if priority == .playback, !lock.withLock({ reachedEOF }) {
            if let cached = ring.readAvailable(at: offset, count: count) {
                Log.debug(.smb, "预读命中 偏移=\(offset) 长度=\(cached.count) 优先级=\(priority.label)")
                schedulePrefetch(after: offset + Int64(cached.count))
                return cached
            }
        } else if let cached = ring.readAvailable(at: offset, count: count) {
            return cached
        }

        let requestEnd = offset + Int64(count)
        var chunkStart = aligned(offset)
        var result = Data()

        while chunkStart < requestEnd {
            if let length, chunkStart >= length { break }

            let chunk: Data
            if let cached = ring.chunk(at: chunkStart) {
                chunk = cached
            } else {
                chunk = try await fetchChunk(at: chunkStart)
                ring.store(chunk, at: chunkStart)
            }

            let inside = Int(max(0, offset - chunkStart))
            if inside < chunk.count {
                let take = min(count - result.count, chunk.count - inside)
                result.append(chunk.subdata(in: inside..<(inside + take)))
            }
            if chunk.count < chunkSize {
                lock.withLock { reachedEOF = true }
                break
            }
            chunkStart += Int64(chunkSize)
        }

        if result.count < count {
            if let length, offset + Int64(result.count) < length, !lock.withLock({ reachedEOF }) {
                // 中间缺块等异常情况，不把短读伪装成 EOF。
                Log.notice(.smb, "读取未满足 偏移=\(offset) 请求=\(count) 实际=\(result.count)")
            }
        }
        if priority == .playback, !result.isEmpty {
            schedulePrefetch(after: offset + Int64(result.count))
        }
        return result
    }

    func close() async {
        let task = lock.withLock { () -> Task<Void, Never>? in
            guard !closed else { return nil }
            closed = true
            let task = prefetchTask
            prefetchTask = nil
            handle.close()
            return task
        }
        task?.cancel()
        ring.reset()
    }

    // MARK: - 内部

    private func aligned(_ offset: Int64) -> Int64 {
        (offset / Int64(chunkSize)) * Int64(chunkSize)
    }

    private func currentHandleBox() -> SMBHandleBox {
        lock.withLock { SMBHandleBox(handle: handle) }
    }

    private func fetchChunk(
        at start: Int64,
        priority: SMBReadPriority? = nil
    ) async throws -> Data {
        let effectivePriority = priority ?? self.priority
        let box = currentHandleBox()
        do {
            let data = try await submitRead(box: box, start: start, priority: effectivePriority)
            recordDownload(data.count)
            return data
        } catch {
            guard let reopen else {
                throw error
            }
            Log.notice(
                .smb,
                "读取失败，重开句柄 偏移=\(start) 优先级=\(effectivePriority.label) \(error.localizedDescription)"
            )
            let newBox = try await reopen.open()
            lock.withLock {
                guard !closed else { return }
                handle = newBox.handle
            }
            let data = try await submitRead(box: newBox, start: start, priority: effectivePriority)
            recordDownload(data.count)
            return data
        }
    }

    private func recordDownload(_ bytes: Int) {
        guard bytes > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            speedSamples.append((now, bytes))
            speedSamples.removeAll { now - $0.time > 2.5 }
        }
    }

    private func submitRead(
        box: SMBHandleBox,
        start: Int64,
        priority: SMBReadPriority
    ) async throws -> Data {
        let size = chunkSize
        return try await scheduler.submit(priority: priority, timeout: 30) {
            try box.handle.pread(offset: UInt64(start), length: size)
        }
    }

    private func schedulePrefetch(after end: Int64) {
        guard priority == .playback else { return }
        guard !lock.withLock({ closed || reachedEOF }) else { return }

        var shouldReset = false
        var previous: Task<Void, Never>?
        var generation = 0
        var start: Int64 = 0
        var capacity = 0
        lock.lock()
        if lastReadEnd >= 0,
           end < lastReadEnd || end > lastReadEnd + Int64(chunkSize) * 8 {
            shouldReset = true
        }
        lastReadEnd = max(lastReadEnd, end)
        if shouldReset {
            ring.reset()
        }
        // 已在预读就让它继续跑到环形缓冲满；只有跳转/回退才重启。
        // 用独立的 active 标志而不是 Task 引用：任务可能在上面的赋值前就结束，
        // 否则会留下一个已完成的 Task 引用，之后再也不预读（缓冲耗尽不续段）。
        if prefetchActive, !shouldReset {
            lock.unlock()
            return
        }
        previous = prefetchTask
        prefetchTask = nil
        prefetchActive = true
        prefetchGeneration += 1
        generation = prefetchGeneration
        start = aligned(end)
        capacity = ring.capacity
        lock.unlock()

        previous?.cancel()

        let source = self
        let task = Task.detached(priority: .utility) { [weak source] in
            guard let source else { return }
            var next = start
            for _ in 0..<capacity {
                if Task.isCancelled { break }
                if let length = source.length, next >= length { break }
                if source.ring.containsChunk(at: next) {
                    next += Int64(source.chunkSize)
                    continue
                }
                // 预读与播放同优先级：局域网带宽有富余时尽快填满 2 分钟窗口；
                // 已缓存的块会跳过，不会重复占带宽。
                guard let data = try? await source.fetchChunk(at: next, priority: .playback) else { break }
                if data.isEmpty { break }
                source.ring.store(data, at: next)
                if data.count < source.chunkSize { break }
                next += Int64(source.chunkSize)
            }
            source.finishPrefetch(generation: generation)
        }
        lock.withLock { prefetchTask = task }
    }

    private func finishPrefetch(generation: Int) {
        lock.withLock {
            if prefetchGeneration == generation {
                prefetchActive = false
                prefetchTask = nil
            }
        }
    }
}
