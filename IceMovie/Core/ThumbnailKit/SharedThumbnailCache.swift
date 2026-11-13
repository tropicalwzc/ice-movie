import CryptoKit
import Foundation
import IceCore

/// 共享侧车缩略图提供方。SMB 与本地测试各实现一份。
public protocol ThumbnailSidecarProviding: Sendable {
    /// 创建 `.icemovie/`、`thumbs/` 与版本文件；已存在时直接返回。
    func prepare() async throws
    func loadIndex() async throws -> Data?
    func storeIndex(_ data: Data) async throws
    func loadThumbnail(relativePath: String) async throws -> Data?
    func storeThumbnail(_ data: Data, relativePath: String) async throws
    func removeThumbnail(relativePath: String) async throws
    /// 删除索引与版本文件；缩略图可留给后续清理。
    func removeAll() async throws
}

public struct SharedThumbnailIndex: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var thumb: String?
        public var width: Int?
        public var height: Int?
        public var size: Int64
        public var modified: TimeInterval

        public init(
            thumb: String? = nil,
            width: Int? = nil,
            height: Int? = nil,
            size: Int64,
            modified: TimeInterval
        ) {
            self.thumb = thumb
            self.width = width
            self.height = height
            self.size = size
            self.modified = modified
        }
    }

    /// 2：侧车缩略图从 384px 提升到 512px，旧索引需重建。
    public static let currentVersion = 2

    public var version: Int
    public var entries: [String: Entry]

    public init(
        version: Int = SharedThumbnailIndex.currentVersion,
        entries: [String: Entry] = [:]
    ) {
        self.version = version
        self.entries = entries
    }
}

/// 侧车缩略图的键与分片路径。
public enum SharedThumbnailKey {
    public static func hash(path: String, size: Int64, modified: Date?) -> String {
        let stamp = modified.map {
            String(Int64($0.timeIntervalSince1970 * 1000))
        } ?? "0"
        let digest = SHA256.hash(data: Data("\(path)|\(size)|\(stamp)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func relativePath(path: String, size: Int64, modified: Date?) -> String {
        let hash = hash(path: path, size: size, modified: modified)
        return "thumbs/\(hash.prefix(2))/\(hash).jpg"
    }
}

/// 共享侧车缩略图缓存。
///
/// 负责索引加载、命中读取、生成后写回与批量落盘；所有失败都只降级为本地缓存，
/// 不向调用方抛出，避免影响网格显示。
public actor SharedThumbnailCache {
    public static let maxPixelSize = 512
    /// 索引条目上限。超出后保留源文件修改时间较新的条目，避免 index.json
    /// 无限增长并撞上侧车读取上限，导致整个会话静默降级。
    public static let maxIndexEntries = 30_000
    private static let flushDelay: Duration = .seconds(5)

    private let provider: any ThumbnailSidecarProviding
    private var index: SharedThumbnailIndex?
    private var dirtyEntries = 0
    /// 每次索引变更递增；flush 完成时用它判断等待期间是否有新条目。
    private var mutationGeneration: UInt64 = 0
    private var flushTask: Task<Void, Never>?
    /// 同一时间只允许一个索引写入/删除操作，避免旧快照覆盖新状态。
    private var persisting = false
    private var persistWaiters: [CheckedContinuation<Void, Never>] = []
    private var writable = true
    private var available = true

    public init(provider: any ThumbnailSidecarProviding) {
        self.provider = provider
    }

    public var isWritable: Bool { writable }
    public var isAvailable: Bool { available }

    public func thumbnail(
        path: String,
        size: Int64,
        modified: Date?
    ) async -> Data? {
        guard await ensureLoaded(), let index else { return nil }
        guard let entry = index.entries[path],
              entry.size == size,
              entry.modified == modifiedTime(modified),
              let thumb = entry.thumb else {
            return nil
        }
        do {
            guard let data = try await provider.loadThumbnail(relativePath: thumb),
                  !data.isEmpty else {
                return nil
            }
            Log.debug(
                .thumbnail,
                "共享侧车命中 \(Log.shortPath(path)) \(data.count)B"
            )
            return data
        } catch {
            Log.debug(.thumbnail, "共享缩略图读取失败 \(Log.shortPath(path))")
            return nil
        }
    }

    public func hasThumbnail(
        path: String,
        size: Int64,
        modified: Date?
    ) async -> Bool {
        guard await ensureLoaded(), let index else { return false }
        guard let entry = index.entries[path] else { return false }
        return entry.size == size
            && entry.modified == modifiedTime(modified)
            && entry.thumb != nil
    }

    public func store(
        thumbnailData: Data,
        width: Int,
        height: Int,
        path: String,
        size: Int64,
        modified: Date?
    ) async {
        guard writable, await ensureLoaded(), index != nil else { return }
        let relativePath = SharedThumbnailKey.relativePath(
            path: path,
            size: size,
            modified: modified
        )
        do {
            try await provider.storeThumbnail(thumbnailData, relativePath: relativePath)
            index?.entries[path] = SharedThumbnailIndex.Entry(
                thumb: relativePath,
                width: width,
                height: height,
                size: size,
                modified: modifiedTime(modified)
            )
            dirtyEntries += 1
            mutationGeneration &+= 1
            if dirtyEntries >= 20 {
                await flush()
            } else {
                // 稀疏写入时不在每张图后重写整个 JSON；合并到 5 秒后的
                // 一次 flush，避免预热每 6 秒来一张也产生一次全量写。
                scheduleFlush()
            }
        } catch {
            writable = false
            Log.notice(
                .thumbnail,
                "共享缩略图写入失败，本次会话降级为本地缓存：\(error.localizedDescription)"
            )
        }
    }

    public func flush() async {
        flushTask?.cancel()
        flushTask = nil
        // 两个 flush 并发时，后一个不等待前一个；前一个会在循环里继续
        // 把等待期间新增的 dirtyEntries 写掉。
        guard !persisting else { return }
        persisting = true
        defer { finishPersisting() }
        while dirtyEntries > 0, writable {
            guard var snapshot = index else { return }
            let generation = mutationGeneration
            let dirtyAtStart = dirtyEntries
            trimIndexIfNeeded(&snapshot)
            snapshot.version = SharedThumbnailIndex.currentVersion
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            do {
                try await provider.storeIndex(data)
            } catch {
                writable = false
                Log.notice(
                    .thumbnail,
                    "共享缩略图索引写入失败，本次会话降级为本地缓存：\(error.localizedDescription)"
                )
                return
            }
            if mutationGeneration == generation {
                // 等待 SMB 写盘期间没有新变更：可以安全用带裁剪/版本号的快照替换内存索引。
                self.index = snapshot
                dirtyEntries = 0
            } else {
                // 期间有新的 store/remove：保留内存索引里的新状态，只扣掉本次已写入的条目数，
                // 然后继续循环把剩余变更写盘，避免旧快照覆盖新条目。
                dirtyEntries = max(0, dirtyEntries - dirtyAtStart)
            }
        }
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flushDelay)
            guard !Task.isCancelled else { return }
            await self?.flushScheduled()
        }
    }

    private func flushScheduled() async {
        flushTask = nil
        await flush()
    }

    private func trimIndexIfNeeded(_ index: inout SharedThumbnailIndex) {
        guard index.entries.count > Self.maxIndexEntries else { return }
        let kept = index.entries
            .sorted { $0.value.modified > $1.value.modified }
            .prefix(Self.maxIndexEntries)
        index.entries = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        Log.notice(
            .thumbnail,
            "共享缩略图索引超过上限，已裁剪到 \(Self.maxIndexEntries) 条"
        )
    }

    public func entry(
        for path: String
    ) async -> SharedThumbnailIndex.Entry? {
        guard await ensureLoaded(), let index else { return nil }
        return index.entries[path]
    }

    public func entries() async -> [String: SharedThumbnailIndex.Entry] {
        guard await ensureLoaded(), let index else { return [:] }
        return index.entries
    }

    /// 侧车索引里已经记录了宽高，进入目录时可直接用于瀑布流初始布局。
    public func aspectRatios() async -> [String: CGFloat] {
        guard await ensureLoaded(), let index else { return [:] }
        var result: [String: CGFloat] = [:]
        result.reserveCapacity(index.entries.count)
        for (path, entry) in index.entries {
            guard let width = entry.width,
                  let height = entry.height,
                  width > 0,
                  height > 0 else {
                continue
            }
            result[path] = CGFloat(width) / CGFloat(height)
        }
        return result
    }

    public func remove(path: String) async {
        guard await ensureLoaded(), let entry = index?.entries.removeValue(forKey: path) else {
            return
        }
        // 先记录变更再等待网络删除；否则 flush 可能在本函数等待期间把已删条目写回内存索引。
        dirtyEntries += 1
        mutationGeneration &+= 1
        if let thumb = entry.thumb {
            try? await provider.removeThumbnail(relativePath: thumb)
        }
        await flush()
    }

    public func removeAll() async {
        flushTask?.cancel()
        flushTask = nil
        // 等正在写盘的旧快照结束后再删除，否则旧 flush 可能在 removeAll 之后
        // 把索引重新写回来。
        await waitForPersisting()
        persisting = true
        defer { finishPersisting() }
        try? await provider.removeAll()
        index = SharedThumbnailIndex()
        dirtyEntries = 0
        mutationGeneration &+= 1
        writable = true
        available = true
    }

    // MARK: - 内部

    private func waitForPersisting() async {
        while persisting {
            await withCheckedContinuation { persistWaiters.append($0) }
        }
    }

    private func finishPersisting() {
        persisting = false
        let waiters = persistWaiters
        persistWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func ensureLoaded() async -> Bool {
        guard available else { return false }
        if index != nil { return true }

        do {
            try await provider.prepare()
        } catch {
            // 只读共享也可能已经有索引，继续尝试读取。
            writable = false
        }

        let data: Data?
        do {
            data = try await provider.loadIndex()
        } catch {
            available = false
            Log.notice(
                .thumbnail,
                "共享缩略图索引读取失败，本次会话使用本地缓存：\(error.localizedDescription)"
            )
            return false
        }

        if let data,
           var decoded = try? JSONDecoder().decode(SharedThumbnailIndex.self, from: data),
           decoded.version == SharedThumbnailIndex.currentVersion {
            trimIndexIfNeeded(&decoded)
            index = decoded
            return true
        }

        // 索引缺失/损坏/版本不匹配：重新开始，缩略图文件留给后续覆盖或清理。
        if data != nil {
            try? await provider.removeAll()
            Log.notice(.thumbnail, "共享缩略图索引无效，已重建")
        }
        index = SharedThumbnailIndex()
        return true
    }

    private func modifiedTime(_ date: Date?) -> TimeInterval {
        date?.timeIntervalSince1970 ?? 0
    }
}
