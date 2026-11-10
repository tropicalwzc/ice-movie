import Foundation

/// 1 MB 分块的 24 MB 环形预读缓存。
///
/// 只缓存成功读到的块；命中时按字节裁剪返回。最后一块可能短于 1 MB（文件末尾），
/// 此时允许返回短读，调用方按 EOF 处理。
public final class SMBChunkRing: @unchecked Sendable {
    public let chunkSize: Int
    public let capacity: Int

    private let lock = NSLock()
    private var chunks: [Int64: Data] = [:]
    private var hits = 0
    private var misses = 0
    /// 保留窗口：窗口外的块优先淘汰，窗口内按离 focus 的距离淘汰。
    private var retentionStart: Int64 = 0
    private var retentionFocus: Int64 = 0
    private var retentionEnd: Int64 = .max

    public init(chunkSize: Int = 1 << 20, capacity: Int = 24) {
        self.chunkSize = max(1, chunkSize)
        self.capacity = max(1, capacity)
    }

    public struct Stats: Sendable, Equatable {
        public let chunks: Int
        public let bytes: Int
        public let hits: Int
        public let misses: Int
    }

    public func stats() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        return Stats(
            chunks: chunks.count,
            bytes: chunks.values.reduce(0) { $0 + $1.count },
            hits: hits,
            misses: misses
        )
    }

    public func reset() {
        lock.lock()
        chunks.removeAll()
        lock.unlock()
    }

    public func containsChunk(at start: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return chunks[start] != nil
    }

    /// `[offset, offset + length)` 是否全部连续缓存；length <= 0 视为命中。
    public func hasContiguousBytes(from offset: Int64, length: Int64) -> Bool {
        guard length > 0 else { return true }
        return contiguousEnd(from: offset) >= offset + length
    }

    /// 设置保留窗口。窗口外的块优先被淘汰，窗口内优先保留离 focus 近的数据。
    public func setRetentionWindow(start: Int64, focus: Int64, end: Int64) {
        lock.lock()
        retentionStart = start
        retentionFocus = focus
        retentionEnd = max(start, end)
        lock.unlock()
    }

    /// 只保留与 `[keepFrom, keepTo)` 有交集的块；部分重叠的块整块保留。
    /// `pinHeaderBytes` 用于固定容器头区间：seek 到文件尾部再回到头部时，
    /// MP4 的 moov / MKV 的 SeekHead 不需要重新走网络。
    public func trim(keepFrom: Int64, keepTo: Int64, pinHeaderBytes: Int64 = 0) {
        lock.lock()
        let victims = chunks.compactMap { start, data -> Int64? in
            let end = start + Int64(data.count)
            let intersectsPinnedHeader = pinHeaderBytes > 0 && start < pinHeaderBytes
            guard !intersectsPinnedHeader else { return nil }
            return end <= keepFrom || start >= keepTo ? start : nil
        }
        for start in victims {
            chunks.removeValue(forKey: start)
        }
        lock.unlock()
    }

    /// 从 `offset` 所在的块开始，返回连续缓存到的最高偏移。
    public func contiguousEnd(from offset: Int64) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard !chunks.isEmpty else { return offset }
        var start = (offset / Int64(chunkSize)) * Int64(chunkSize)
        var end = offset
        while let chunk = chunks[start] {
            let chunkEnd = start + Int64(chunk.count)
            if end < start { end = start }
            if chunkEnd > end { end = chunkEnd }
            if chunk.count < chunkSize { break }
            start += Int64(chunkSize)
        }
        return end
    }

    public func chunk(at start: Int64) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = chunks[start] else {
            misses += 1
            return nil
        }
        hits += 1
        return data
    }

    /// 读取缓存中可用的字节。首块缺失时返回 nil（未命中）；
    /// 若中途缺块且前一块不是 EOF 短块，也返回 nil，避免把缓存缺口误判成文件结尾。
    public func readAvailable(at offset: Int64, count: Int) -> Data? {
        guard count > 0 else { return Data() }
        lock.lock()
        defer { lock.unlock() }

        var result = Data()
        var position = offset
        var sawChunk = false

        while result.count < count {
            let start = (position / Int64(chunkSize)) * Int64(chunkSize)
            guard let chunk = chunks[start] else { break }
            sawChunk = true

            let inside = Int(position - start)
            guard inside < chunk.count else { break }

            let take = min(count - result.count, chunk.count - inside)
            result.append(chunk.subdata(in: inside..<(inside + take)))
            position += Int64(take)

            if chunk.count < chunkSize {
                // EOF 短块。
                break
            }
        }

        guard sawChunk, !result.isEmpty else {
            misses += 1
            return nil
        }

        if result.count < count {
            let lastStart = ((offset + Int64(result.count) - 1) / Int64(chunkSize)) * Int64(chunkSize)
            if let last = chunks[lastStart], last.count == chunkSize {
                // 缓存里还有完整块，但中间缺块：不能当作 EOF。
                misses += 1
                return nil
            }
        }

        hits += 1
        return result
    }

    public func store(_ data: Data, at start: Int64) {
        guard !data.isEmpty else { return }
        lock.lock()
        chunks[start] = data
        while chunks.count > capacity, let victim = evictionCandidateLocked() {
            chunks.removeValue(forKey: victim)
        }
        lock.unlock()
    }

    /// 主动丢掉读位置之前的块；保留少量回看余量。
    public func trim(before offset: Int64) {
        guard offset > 0 else { return }
        trim(keepFrom: offset, keepTo: .max)
    }

    /// 淘汰顺序：先丢回看窗口之外的远端块，再丢前向窗口之外的远端块，
    /// 最后丢窗口内离 focus 最远的回看块，避免把刚预读的未来数据挤掉。
    private func evictionCandidateLocked() -> Int64? {
        var outsideBack: Int64?
        var outsideForward: Int64?
        var back: Int64?
        for (start, data) in chunks {
            let end = start + Int64(data.count)
            if end <= retentionStart {
                if outsideBack == nil || start < outsideBack! { outsideBack = start }
            } else if start >= retentionEnd {
                if outsideForward == nil || start > outsideForward! { outsideForward = start }
            } else if start < retentionFocus {
                if back == nil || start < back! { back = start }
            }
        }
        return outsideBack ?? outsideForward ?? back ?? chunks.keys.min()
    }
}


/// seek 命中分类。
public enum SMBSeekKind: Equatable, Sendable {
    /// 目标位置本身已在连续缓存中，可直接复用。
    case cacheHit
    /// 目标在回看/预读窗口附近，但目标块缺失，需要保留重叠段并补读。
    case backWindow
    /// 目标完全在窗口外，需要丢弃前向窗口。
    case miss
}

public enum SMBSeekClassifier {
    /// - Parameters:
    ///   - target: seek 目标字节偏移。
    ///   - cachedEnd: 从 target 起连续缓存的末尾；等于 target 表示目标块缺失。
    ///   - windowStart: 回看窗口起点。
    ///   - windowEnd: 允许保留的窗口末端（读头/预读头再加少量余量）。
    ///   - chunkSize: 预读块大小，用于给窗口末端留余量。
    public static func classify(
        target: Int64,
        cachedEnd: Int64,
        windowStart: Int64,
        windowEnd: Int64,
        chunkSize: Int
    ) -> SMBSeekKind {
        if cachedEnd > target { return .cacheHit }
        let margin = Int64(max(1, chunkSize)) * 8
        if target >= windowStart, target <= windowEnd + margin { return .backWindow }
        return .miss
    }
}
