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
/// - 1 MB 分块，默认约 512 块预读环；播放源按顺序读时在后台预读；
/// - 显式区分播放头、解封装读头和预读最远点，seek 优先复用连续缓存；
/// - 句柄失效时重开一次并重试同一偏移。
final class SMBFileByteSource: ByteSource, BufferMetricsProviding, NetworkSpeedProviding,
    BufferRetentionProviding, SeekAwareByteSource, SeekCacheProviding, BufferSupplyProviding,
    PrefetchCancelling, @unchecked Sendable {
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

    /// 播放头：当前播放位置对应的估算字节偏移，由播放引擎定期写入。
    private var playhead: Int64 = 0
    /// 解封装读头：解封装器已经消费到的字节偏移。
    private var readHead: Int64 = -1
    /// 预读最远点：从读头起连续预读到达的末尾。
    private var prefetchHead: Int64 = 0
    /// 回看窗口起点。
    private var windowStart: Int64 = 0
    private var ringResetTotal = 0
    private var seekHitTotal = 0
    private var seekMissTotal = 0
    private var lastSeekHit = false
    private let seekCacheEnabled: Bool

    private var reachedEOF = false
    /// 音频/视频供给低于安全水位时暂停预读，避免预读和播放读抢 SMB 带宽。
    private var supplyLow = false
    private var speedSamples: [(time: Double, bytes: Int)] = []
    private var retainBackBytes: Int64 = 0

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

    var ringResetCount: Int { lock.withLock { ringResetTotal } }
    var seekCacheHits: Int { lock.withLock { seekHitTotal } }
    var seekCacheMisses: Int { lock.withLock { seekMissTotal } }
    var lastSeekCacheHit: Bool { lock.withLock { lastSeekHit } }
    var playheadByteOffset: Int64 { lock.withLock { playhead } }
    var readHeadByteOffset: Int64 { lock.withLock { readHead } }
    var prefetchHeadByteOffset: Int64 { lock.withLock { prefetchHead } }

    /// 停止播放/切换文件时立即让旧预读退出；最多再完成一个在途 1MB 读。
    func cancelPrefetch() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            prefetchGeneration += 1
            let task = prefetchTask
            prefetchTask = nil
            prefetchActive = false
            return task
        }
        task?.cancel()
        diag("prefetch cancel")
    }

    func setSupply(audioAhead: Double, videoAhead: Double) {
        lock.withLock {
            // 只在音频接近断流时暂停预读；视频领先低不代表音频危险。
            // 纯视频没有音频时 audioAhead 传 15，不会误暂停。
            supplyLow = audioAhead < 1.0
        }
    }

    func setRetainBackBytes(_ bytes: Int64) {
        lock.withLock {
            retainBackBytes = max(0, bytes)
            updateRetentionLocked()
        }
    }

    /// 播放引擎定期写入播放头；回看窗口与淘汰顺序都依赖这个位置。
    func setPlayhead(byteOffset: Int64) {
        let target = max(0, min(byteOffset, lengthValue ?? byteOffset))
        lock.lock()
        playhead = target
        updateRetentionLocked()
        let keepTo = target + forwardBudgetLocked()
        ring.trim(keepFrom: windowStart, keepTo: keepTo)
        lock.unlock()
    }

    /// 从指定偏移起连续可用的字节数；包含解封装已读和预读环两部分。
    func bufferedBytes(from offset: Int64) -> Int64 {
        let target = max(0, offset)
        if let lengthValue, target >= lengthValue { return 0 }
        return max(0, ring.contiguousEnd(from: target) - target)
    }

    /// 兼容旧接口：从当前播放头起算。
    var bufferedAheadBytes: Int64 {
        let head = lock.withLock { playhead }
        return bufferedBytes(from: head)
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

        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-smbSeekCache"),
           arguments.indices.contains(index + 1),
           let value = Int(arguments[index + 1]) {
            self.seekCacheEnabled = value != 0
        } else {
            self.seekCacheEnabled = true
        }
        let capacityBytes = Int64(self.ring.capacity) * Int64(self.chunkSize)
        self.ring.setRetentionWindow(start: 0, focus: 0, end: capacityBytes)
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
        var box = currentHandleBox()
        var data = Data()
        var offset = start
        var remaining = chunkSize
        var retried = false

        while remaining > 0 {
            if let length = lengthValue, offset >= length { break }
            let want: Int
            if let length = lengthValue {
                want = min(remaining, Int(max(0, length - offset)))
            } else {
                want = remaining
            }
            guard want > 0 else { break }

            do {
                let part = try await submitRead(
                    box: box,
                    start: offset,
                    length: want,
                    priority: effectivePriority
                )
                if part.isEmpty { break }
                data.append(part)
                offset += Int64(part.count)
                remaining -= part.count
            } catch {
                guard !retried, let reopen else { throw error }
                retried = true
                Log.notice(
                    .smb,
                    "读取失败，重开句柄 偏移=\(offset) 优先级=\(effectivePriority.label) "
                        + error.localizedDescription
                )
                let newBox = try await reopen.open()
                lock.withLock {
                    guard !closed else { return }
                    handle = newBox.handle
                }
                box = newBox
            }
        }

        recordDownload(data.count)
        return data
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
        length: Int,
        priority: SMBReadPriority
    ) async throws -> Data {
        try await scheduler.submit(priority: priority, timeout: 30) {
            try box.handle.pread(offset: UInt64(start), length: length)
        }
    }

    /// 低量级诊断日志；只有 -debugLog 时写入 Documents/ice-smb.log。
    private func diag(_ message: String) {
        guard ProcessInfo.processInfo.arguments.contains("-debugLog") else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ice-smb.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url, options: .atomic)
        }
    }

    /// FFmpeg 已确定新的绝对字节位置。先判断是否命中连续缓存：
    /// 命中只移动播放头；回看窗口附近保留重叠段；完全未命中才丢弃前向窗口。
    /// 必须同步返回，不能阻塞 AVIO 线程。
    func seekWillChange(to offset: Int64) {
        guard priority == .playback else { return }
        let target = max(0, min(offset, lengthValue ?? offset))
        var old: Task<Void, Never>?
        var generation = 0

        lock.lock()
        // 命中/未命中都要允许后续读取和预读；短读设置的 reachedEOF 不能跨 seek 保留。
        reachedEOF = false
        let cachedEnd = ring.contiguousEnd(from: target)
        let windowEnd = max(readHead, max(prefetchHead, playhead))
        let kind = seekCacheEnabled
            ? SMBSeekClassifier.classify(
                target: target,
                cachedEnd: cachedEnd,
                windowStart: windowStart,
                windowEnd: windowEnd,
                chunkSize: chunkSize
            )
            : .miss

        if kind == .cacheHit, seekCacheEnabled {
            playhead = target
            if readHead < target { readHead = target }
            prefetchHead = max(prefetchHead, cachedEnd)
            lastSeekHit = true
            seekHitTotal += 1
            updateRetentionLocked()
            lock.unlock()
            diag(
                "seek hit target=\(target) cachedEnd=\(cachedEnd) "
                    + "readHead=\(readHead) prefetchHead=\(prefetchHead)"
            )
            return
        }

        generation = prefetchGeneration + 1
        prefetchGeneration = generation
        old = prefetchTask
        prefetchTask = nil
        prefetchActive = false
        playhead = target
        readHead = target
        prefetchHead = target
        reachedEOF = false
        windowStart = max(0, target - backBudgetLocked())
        if seekCacheEnabled {
            ring.trim(keepFrom: windowStart, keepTo: target + forwardBudgetLocked())
        } else {
            ring.reset()
        }
        ringResetTotal += 1
        lastSeekHit = false
        seekMissTotal += 1
        updateRetentionLocked()
        lock.unlock()

        old?.cancel()
        diag(
            "seek \(kind) target=\(target) reset=\(ringResetTotal) "
                + "windowStart=\(windowStart) mode=\(seekCacheEnabled ? "cache" : "legacy")"
        )
    }

    private func schedulePrefetch(after end: Int64) {
        guard priority == .playback else { return }
        guard !lock.withLock({ closed || reachedEOF }) else { return }

        var previous: Task<Void, Never>?
        var generation = 0
        var start: Int64 = 0
        var capacity = 0
        lock.lock()
        // 正常情况下读头只前进；只有没有显式 seek 通知的异常回退才把锚点拉回。
        if readHead >= 0, end + Int64(chunkSize) < readHead {
            readHead = end
        } else {
            readHead = max(readHead, end)
        }
        prefetchHead = max(prefetchHead, ring.contiguousEnd(from: max(0, readHead)))
        updateRetentionLocked()
        let keepTo = max(playhead, readHead) + forwardBudgetLocked()
        ring.trim(keepFrom: windowStart, keepTo: keepTo)
        // 供给危险时只更新读头/缓冲统计，不启动新的预读任务。
        if prefetchActive || supplyLow {
            lock.unlock()
            return
        }
        previous = prefetchTask
        prefetchTask = nil
        prefetchActive = true
        prefetchGeneration += 1
        generation = prefetchGeneration
        start = aligned(max(readHead, end))
        // 预读只填前向预算，给回看窗口留空间；再留 8 个块的余量，
        // 避免预读把当前读位置的块挤掉导致绿条瞬间归零。
        let forwardChunks = Int(forwardBudgetLocked() / Int64(chunkSize))
        capacity = max(1, min(ring.capacity - 8, max(8, forwardChunks) - 8))
        lock.unlock()

        previous?.cancel()
        startPrefetch(from: start, capacity: capacity, generation: generation)
    }

    /// 从指定偏移开始预读；seek 路径与正常播放路径共用。
    /// 取消或 generation 变化时立即停，旧任务晚返回也不能写入新窗口。
    private func startPrefetch(from start: Int64, capacity: Int, generation: Int) {
        let source = self
        diag("prefetch start=\(start) capacity=\(capacity) gen=\(generation)")
        let task = Task.detached(priority: .utility) { [weak source] in
            guard let source else { return }
            var next = start
            var stored = 0
            var stop = "capacity"
            for _ in 0..<capacity {
                if Task.isCancelled { stop = "cancelled"; break }
                if source.isSupplyLow() { stop = "supply-low"; break }
                if source.prefetchGenerationIsCurrent(generation) == false {
                    stop = "generation"
                    break
                }
                if let length = source.length, next >= length { stop = "eof"; break }
                if source.ring.containsChunk(at: next) {
                    next += Int64(source.chunkSize)
                    continue
                }
                // 预读让位于播放读：否则 1MB 预读会插在音频/视频小读之前，
                // 高码率 4K 上会把音频队列拖空，表现成 seek 后反复缓冲。
                guard let data = try? await source.fetchChunk(at: next, priority: .enumeration) else {
                    stop = "fetch-failed"
                    break
                }
                if data.isEmpty { stop = "empty"; break }
                source.storePrefetched(data, at: next, generation: generation)
                stored += 1
                if stored % 16 == 0 {
                    source.diag("prefetch progress next=\(next) stored=\(stored) gen=\(generation)")
                }
                if data.count < source.chunkSize { stop = "short"; break }
                next += Int64(source.chunkSize)
            }
            source.diag("prefetch stop=\(stop) next=\(next) stored=\(stored) gen=\(generation)")
            source.finishPrefetch(generation: generation)
        }
        lock.withLock {
            if prefetchGeneration == generation {
                prefetchTask = task
            } else {
                task.cancel()
            }
        }
    }

    private func prefetchGenerationIsCurrent(_ generation: Int) -> Bool {
        lock.withLock { prefetchGeneration == generation }
    }

    private func isSupplyLow() -> Bool {
        lock.withLock { supplyLow }
    }

    /// 只有同一代预读任务才能写入：seek 后旧任务即使刚从 SMB 返回，也不能污染新窗口。
    private func storePrefetched(_ data: Data, at start: Int64, generation: Int) {
        lock.withLock {
            guard prefetchGeneration == generation else { return }
            ring.store(data, at: start)
            prefetchHead = max(prefetchHead, ring.contiguousEnd(from: max(0, readHead)))
        }
    }

    private func finishPrefetch(generation: Int) {
        lock.withLock {
            if prefetchGeneration == generation {
                prefetchActive = false
                prefetchTask = nil
            }
        }
    }

    private func backBudgetLocked() -> Int64 {
        retainBackBytes > 0 ? retainBackBytes : Int64(chunkSize) * 8
    }

    private func forwardBudgetLocked() -> Int64 {
        let capacityBytes = Int64(ring.capacity) * Int64(chunkSize)
        return max(Int64(chunkSize) * 8, capacityBytes - backBudgetLocked())
    }

    private func updateRetentionLocked() {
        windowStart = max(0, playhead - backBudgetLocked())
        let end = playhead + forwardBudgetLocked()
        ring.setRetentionWindow(start: windowStart, focus: playhead, end: end)
    }
}

