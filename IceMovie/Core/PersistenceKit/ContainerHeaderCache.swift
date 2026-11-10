import Foundation
import IceCore

/// 容器头/尾区间缓存：按 64KB 页落盘，二次打开同一文件时不再走 SMB。
///
/// 只缓存打开阶段实际读过的页（容器头、moov、Cues、附件），播放阶段的媒体数据
/// 不写入；容量按文件最近访问做 LRU，单文件与全局都有上限。
public actor ContainerHeaderCache {
    public static let pageSize = 64 * 1024
    public static let shared: ContainerHeaderCache? = try? ContainerHeaderCache()

    public struct Key: Hashable, Sendable {
        public let namespace: String
        public let path: String
        public let size: Int64
        public let modified: TimeInterval
        public let fingerprint: UInt64

        public init(
            namespace: String,
            path: String,
            size: Int64,
            modified: TimeInterval,
            fingerprint: UInt64
        ) {
            self.namespace = namespace
            self.path = path
            self.size = size
            self.modified = modified
            self.fingerprint = fingerprint
        }
    }

    private struct Entry: Codable {
        var namespace: String
        var path: String
        var size: Int64
        var modified: TimeInterval
        var fingerprint: UInt64
        var pages: Set<Int>
        var bytes: Int64
        var lastAccess: TimeInterval
    }

    private let directory: URL
    private let dataDirectory: URL
    private let indexURL: URL
    private let capacityBytes: Int64
    private let perFileBytes: Int64
    private var entries: [String: Entry] = [:]
    private var dirtyStores = 0
    private var lastPersist = Date.distantPast
    private var accessCounter: Double = 0

    public init(
        directory: URL? = nil,
        capacityBytes: Int64 = 512 * 1024 * 1024,
        perFileBytes: Int64 = 64 * 1024 * 1024
    ) throws {
        let base = directory ?? FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("ContainerHeaderCache", isDirectory: true)
        self.directory = base
        self.dataDirectory = base.appendingPathComponent("data", isDirectory: true)
        self.indexURL = base.appendingPathComponent("index.json")
        self.capacityBytes = max(Int64(ContainerHeaderCache.pageSize), capacityBytes)
        self.perFileBytes = max(Int64(ContainerHeaderCache.pageSize), perFileBytes)
        try FileManager.default.createDirectory(
            at: dataDirectory,
            withIntermediateDirectories: true
        )
        entries = Self.loadIndex(indexURL: indexURL, dataDirectory: dataDirectory)
    }

    public func totalBytes() -> Int64 {
        entries.values.reduce(0) { $0 + $1.bytes }
    }

    /// 用路径/大小/修改时间找首 64KB，避免二次打开为了算指纹又走一次网络。
    public func cachedHeadPage(
        namespace: String,
        path: String,
        size: Int64,
        modified: TimeInterval
    ) -> Data? {
        guard let entry = entries.values.first(where: {
            $0.namespace == namespace && $0.path == path &&
                $0.size == size && $0.modified == modified && $0.pages.contains(0)
        }) else { return nil }
        let key = Key(
            namespace: entry.namespace,
            path: entry.path,
            size: entry.size,
            modified: entry.modified,
            fingerprint: entry.fingerprint
        )
        return cachedPage(for: key, page: 0)
    }

    public func cachedPage(for key: Key, page: Int) -> Data? {
        guard page >= 0, let entry = entry(for: key), entry.pages.contains(page) else {
            return nil
        }
        let url = dataURL(for: key)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            removeEntry(for: key)
            return nil
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(page * ContainerHeaderCache.pageSize))
            let data = try handle.read(upToCount: ContainerHeaderCache.pageSize) ?? Data()
            guard !data.isEmpty else {
                entryPagesRemove(key: key, page: page)
                return nil
            }
            touch(key: key)
            return data
        } catch {
            entryPagesRemove(key: key, page: page)
            return nil
        }
    }

    public func storePage(for key: Key, page: Int, data: Data) {
        guard page >= 0, data.count > 0 else { return }
        var entry = entry(for: key) ?? Entry(
            namespace: key.namespace,
            path: key.path,
            size: key.size,
            modified: key.modified,
            fingerprint: key.fingerprint,
            pages: [],
            bytes: 0,
            lastAccess: nextAccess()
        )
        guard entry.fingerprint == key.fingerprint else {
            removeEntry(for: key)
            return
        }
        let url = dataURL(for: key)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        do {
            try handle.seek(toOffset: UInt64(page * ContainerHeaderCache.pageSize))
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
            return
        }
        if !entry.pages.contains(page) {
            entry.bytes += Int64(data.count)
        }
        entry.pages.insert(page)
        entry.lastAccess = nextAccess()
        entries[storageKey(for: key)] = entry
        trimIfNeeded()
        dirtyStores += 1
        // 打开阶段页数不多，逐页持久化索引，避免 App 被系统终止时页位图丢失。
        if dirtyStores >= 1 || Date().timeIntervalSince(lastPersist) > 3 {
            persist()
        }
    }

    public func flush() {
        persist()
    }

    public func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: dataDirectory)
        try? FileManager.default.createDirectory(
            at: dataDirectory,
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: indexURL)
        dirtyStores = 0
    }

    // MARK: - 内部

    private func nextAccess() -> TimeInterval {
        accessCounter += 1
        return Date().timeIntervalSince1970 + accessCounter * 0.000001
    }

    private func entry(for key: Key) -> Entry? {
        entries[storageKey(for: key)]
    }

    private func touch(key: Key) {
        let name = storageKey(for: key)
        guard var entry = entries[name] else { return }
        entry.lastAccess = nextAccess()
        entries[name] = entry
    }

    private func entryPagesRemove(key: Key, page: Int) {
        let name = storageKey(for: key)
        guard var entry = entries[name], entry.pages.remove(page) != nil else { return }
        entry.bytes = max(0, entry.bytes - Int64(ContainerHeaderCache.pageSize))
        entries[name] = entry
    }

    private func removeEntry(for key: Key) {
        let name = storageKey(for: key)
        entries.removeValue(forKey: name)
        try? FileManager.default.removeItem(at: dataURL(for: key))
    }

    private func trimIfNeeded() {
        // 单文件超限：整文件淘汰，下一次重新建立；比逐页淘汰更容易保证一致性。
        for (name, entry) in entries where entry.bytes > perFileBytes {
            entries.removeValue(forKey: name)
            try? FileManager.default.removeItem(at: dataURL(forEntry: entry))
        }
        var total = totalBytes()
        guard total > capacityBytes else { return }
        let victims = entries.sorted { $0.value.lastAccess < $1.value.lastAccess }
        for (name, entry) in victims {
            guard total > capacityBytes else { break }
            entries.removeValue(forKey: name)
            total -= entry.bytes
            try? FileManager.default.removeItem(at: dataURL(forEntry: entry))
        }
    }

    private func storageKey(for key: Key) -> String {
        "\(key.namespace)|\(key.path)|\(key.size)|\(key.modified)|\(key.fingerprint)"
    }

    private func dataURL(for key: Key) -> URL {
        dataURL(forName: stableHash(storageKey(for: key)))
    }

    private func dataURL(forEntry entry: Entry) -> URL {
        let key = "\(entry.namespace)|\(entry.path)|\(entry.size)|\(entry.modified)|\(entry.fingerprint)"
        return dataURL(forName: stableHash(key))
    }

    private func dataURL(forName name: UInt64) -> URL {
        dataDirectory.appendingPathComponent(String(format: "%016llx.bin", name))
    }

    private func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    private static func loadIndex(
        indexURL: URL,
        dataDirectory: URL
    ) -> [String: Entry] {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else {
            // 索引损坏：清空数据目录，避免留下无法解释的孤儿文件。
            try? FileManager.default.removeItem(at: dataDirectory)
            try? FileManager.default.createDirectory(
                at: dataDirectory,
                withIntermediateDirectories: true
            )
            return [:]
        }
        var loaded: [String: Entry] = [:]
        for entry in decoded {
            let key = "\(entry.namespace)|\(entry.path)|\(entry.size)|\(entry.modified)|\(entry.fingerprint)"
            loaded[key] = entry
        }
        return loaded
    }

    private func persist() {
        let values = Array(entries.values)
        guard let data = try? JSONEncoder().encode(values) else { return }
        do {
            try data.write(to: indexURL, options: .atomic)
            lastPersist = Date()
            dirtyStores = 0
        } catch {
            // 缓存写失败只影响下次打开速度，不影响播放。
        }
    }
}

/// 容器头缓存包装层：读时先查本地页，打开阶段把网络读到的页写回磁盘。
public final class CachedByteSource: ByteSource, ReadStatsProviding,
    BufferMetricsProviding, NetworkSpeedProviding, PrefetchControlling, PrefetchCancelling,
    BufferSupplyProviding, SeekCacheProviding, SeekAwareByteSource, BufferRetentionProviding,
    CachePhaseControlling, @unchecked Sendable {
    private let base: any ByteSource
    private let cache: ContainerHeaderCache?
    private let namespace: String
    private let path: String
    private let size: Int64
    private let modified: TimeInterval
    private let lock = NSLock()
    private var key: ContainerHeaderCache.Key?
    private var openPhase = true
    private var cacheHitBytes: Int64 = 0
    private var cacheReadBytes: Int64 = 0
    private var networkReadCount = 0
    private var networkBytes: Int64 = 0

    public init(
        base: any ByteSource,
        cache: ContainerHeaderCache?,
        namespace: String,
        path: String,
        size: Int64,
        modified: Date?
    ) {
        self.base = base
        self.cache = cache
        self.namespace = namespace
        self.path = path
        self.size = size
        self.modified = modified?.timeIntervalSince1970 ?? 0
    }

    public var length: Int64? { base.length }

    public var readStats: ByteSourceReadStats {
        var stats = (base as? ReadStatsProviding)?.readStats
            ?? ByteSourceReadStats(readCount: networkReadCount, bytesRead: networkBytes)
        lock.lock()
        stats.cacheHitBytes = cacheHitBytes
        stats.cacheReadBytes = cacheReadBytes
        lock.unlock()
        return stats
    }

    /// 计算首 64KB 指纹并把页 0 写入缓存；失败时仍然允许播放。
    public func prepare() async {
        guard let cache else { return }
        let cachedHead = await cache.cachedHeadPage(
            namespace: namespace,
            path: path,
            size: size,
            modified: modified
        )
        let head: Data
        if let cachedHead {
            head = cachedHead
        } else {
            head = (try? await base.read(at: 0, count: ContainerHeaderCache.pageSize)) ?? Data()
            lock.withLock {
                networkReadCount += 1
                networkBytes += Int64(head.count)
            }
        }
        let fingerprint = Self.fingerprint(head)
        let newKey = ContainerHeaderCache.Key(
            namespace: namespace,
            path: path,
            size: size,
            modified: modified,
            fingerprint: fingerprint
        )
        lock.withLock { key = newKey }
        if cachedHead == nil, head.count == ContainerHeaderCache.pageSize {
            await cache.storePage(for: newKey, page: 0, data: head)
        }
    }

    public func read(at offset: Int64, count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        guard let cache, let key, count <= 1024 * 1024 else {
            return try await base.read(at: offset, count: count)
        }
        let pageSize = ContainerHeaderCache.pageSize
        let firstPage = Int(offset / Int64(pageSize))
        let lastPage = Int((offset + Int64(count) - 1) / Int64(pageSize))
        var pages: [Int: Data] = [:]
        var allHit = true
        for page in firstPage...lastPage {
            if let data = await cache.cachedPage(for: key, page: page) {
                pages[page] = data
            } else {
                allHit = false
                break
            }
        }
        lock.withLock { cacheReadBytes += Int64(count) }
        if allHit {
            var result = Data()
            for page in firstPage...lastPage {
                guard let data = pages[page] else { continue }
                let pageStart = Int64(page) * Int64(pageSize)
                let from = max(0, Int(offset - pageStart))
                let to = min(data.count, Int(offset + Int64(count) - pageStart))
                if from < to, from < data.count {
                    result.append(data.subdata(in: from..<min(to, data.count)))
                }
            }
            if result.count >= count {
                lock.withLock { cacheHitBytes += Int64(count) }
                return result.prefix(count)
            }
        }

        // 打开阶段按 64KB 页对齐取数，保证写回的是完整页；多读的尾部会进入
        // 下一次打开的头缓存，代价只有一次小读。
        let writable = lock.withLock { openPhase }
        let fetchStart = writable ? (offset / Int64(pageSize)) * Int64(pageSize) : offset
        let fetchEnd = writable
            ? ((offset + Int64(count) + Int64(pageSize) - 1) / Int64(pageSize)) * Int64(pageSize)
            : offset + Int64(count)
        let data = try await base.read(
            at: fetchStart,
            count: max(count, Int(fetchEnd - fetchStart))
        )
        lock.withLock {
            networkReadCount += 1
            networkBytes += Int64(data.count)
        }
        guard writable, data.count > 0 else {
            if fetchStart != offset, data.count > Int(offset - fetchStart) {
                let from = Int(offset - fetchStart)
                return data.subdata(in: from..<min(data.count, from + count))
            }
            return data
        }
        // 只写完整页，避免把半页数据当成整页。
        var page = Int(fetchStart / Int64(pageSize))
        let lastWrittenPage = Int((fetchStart + Int64(data.count) - 1) / Int64(pageSize))
        while page <= lastWrittenPage {
            let pageStart = Int64(page) * Int64(pageSize)
            let from = Int(pageStart - fetchStart)
            let available = max(0, min(pageSize, data.count - from))
            guard from >= 0, available > 0 else {
                page += 1
                continue
            }
            // 最后一页可能是文件尾短页；允许缓存，读取时按实际长度返回。
            let isLast = page == lastWrittenPage
            guard available == pageSize || isLast else {
                page += 1
                continue
            }
            let pageData = data.subdata(in: from..<(from + available))
            await cache.storePage(for: key, page: page, data: pageData)
            page += 1
        }
        let sliceStart = Int(offset - fetchStart)
        guard sliceStart >= 0, sliceStart < data.count else { return data }
        return data.subdata(in: sliceStart..<min(data.count, sliceStart + count))
    }

    public func endOpenPhase() {
        lock.withLock { openPhase = false }
    }

    public func close() async {
        await base.close()
        await cache?.flush()
    }

    public var bufferedAheadBytes: Int64 {
        (base as? BufferMetricsProviding)?.bufferedAheadBytes ?? 0
    }

    public var downloadBytesPerSecond: Double {
        (base as? NetworkSpeedProviding)?.downloadBytesPerSecond ?? 0
    }

    public func setPrefetchEnabled(_ enabled: Bool) {
        (base as? PrefetchControlling)?.setPrefetchEnabled(enabled)
    }

    public func cancelPrefetch() {
        (base as? PrefetchCancelling)?.cancelPrefetch()
    }

    public func setSupply(audioAhead: Double, videoAhead: Double) {
        (base as? BufferSupplyProviding)?.setSupply(
            audioAhead: audioAhead,
            videoAhead: videoAhead
        )
    }

    public func setRetainBackBytes(_ bytes: Int64) {
        (base as? BufferRetentionProviding)?.setRetainBackBytes(bytes)
    }

    public func setPlayhead(byteOffset: Int64) {
        (base as? SeekCacheProviding)?.setPlayhead(byteOffset: byteOffset)
    }

    public func bufferedBytes(from offset: Int64) -> Int64 {
        (base as? SeekCacheProviding)?.bufferedBytes(from: offset) ?? 0
    }

    public var ringResetCount: Int { (base as? SeekCacheProviding)?.ringResetCount ?? 0 }
    public var seekCacheHits: Int { (base as? SeekCacheProviding)?.seekCacheHits ?? 0 }
    public var seekCacheMisses: Int { (base as? SeekCacheProviding)?.seekCacheMisses ?? 0 }
    public var lastSeekCacheHit: Bool {
        (base as? SeekCacheProviding)?.lastSeekCacheHit ?? false
    }
    public var playheadByteOffset: Int64 {
        (base as? SeekCacheProviding)?.playheadByteOffset ?? 0
    }
    public var readHeadByteOffset: Int64 {
        (base as? SeekCacheProviding)?.readHeadByteOffset ?? 0
    }
    public var prefetchHeadByteOffset: Int64 {
        (base as? SeekCacheProviding)?.prefetchHeadByteOffset ?? 0
    }

    public func seekWillChange(to offset: Int64) {
        (base as? SeekAwareByteSource)?.seekWillChange(to: offset)
    }

    private static func fingerprint(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
