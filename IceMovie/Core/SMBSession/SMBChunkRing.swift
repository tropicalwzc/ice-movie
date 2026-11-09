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
    private var order: [Int64] = []
    private var hits = 0
    private var misses = 0

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
        order.removeAll()
        lock.unlock()
    }

    public func containsChunk(at start: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return chunks[start] != nil
    }

    public func chunk(at start: Int64) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = chunks[start] else {
            misses += 1
            return nil
        }
        hits += 1
        touchLocked(start)
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
            touchLocked(start)

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
        touchLocked(start)
        while order.count > capacity {
            let evicted = order.removeFirst()
            chunks.removeValue(forKey: evicted)
        }
        lock.unlock()
    }

    private func touchLocked(_ start: Int64) {
        if let index = order.firstIndex(of: start) {
            order.remove(at: index)
        }
        order.append(start)
    }
}
