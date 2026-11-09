import CryptoKit
import DemuxKit
import Foundation
import IceCore

/// 缩略图缓存键：SHA256(路径|大小|修改时间)。
/// 源文件被替换后大小或修改时间变化，键自然不同，旧封面不会再被命中。
public enum ThumbnailCacheKey {
    public static func make(
        path: String,
        size: Int64,
        modified: Date?,
        namespace: String = ""
    ) -> String {
        let stamp = modified.map { String(Int64($0.timeIntervalSince1970 * 1000)) } ?? "0"
        let raw = "\(namespace)|\(path)|\(size)|\(stamp)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// 磁盘缩略图缓存，带容量上限与 LRU 淘汰。
public actor ThumbnailStore {
    public struct Snapshot: Sendable, Equatable {
        public let count: Int
        public let bytes: Int64
        public let capacityBytes: Int64
    }

    public nonisolated let directory: URL
    public nonisolated let capacityBytes: Int64

    private var totalBytes: Int64 = 0

    public init(
        directory: URL? = nil,
        capacityBytes: Int64 = 200 * 1024 * 1024
    ) throws {
        let target = directory ?? Self.defaultDirectory()
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        self.directory = target
        self.capacityBytes = capacityBytes
        self.totalBytes = Self.directorySize(target)
    }

    public nonisolated static func defaultDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appending(path: "Thumbnails", directoryHint: .isDirectory)
    }

    public func snapshot() -> Snapshot {
        Snapshot(count: fileURLs().count, bytes: totalBytes, capacityBytes: capacityBytes)
    }

    /// 命中时刷新访问时间，作为 LRU 依据。
    public func cachedData(forKey key: String) -> Data? {
        let url = fileURL(forKey: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
        return data
    }

    public func save(_ data: Data, forKey key: String) throws {
        let url = fileURL(forKey: key)
        let previous = Self.fileSize(url)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
        totalBytes += Int64(data.count) - previous
        evictIfNeeded()
    }

    public func removeAll() {
        for url in fileURLs() {
            try? FileManager.default.removeItem(at: url)
        }
        totalBytes = 0
    }

    /// 仅用于验证：把上限临时调小后可直接观察淘汰行为。
    public func evictIfNeeded() {
        guard totalBytes > capacityBytes else { return }
        let candidates = fileURLs().compactMap { url -> (URL, Int64, Date)? in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let size = values?.fileSize else { return nil }
            return (url, Int64(size), values?.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.2 < $1.2 }

        var evicted = 0
        for candidate in candidates {
            guard totalBytes > capacityBytes else { break }
            try? FileManager.default.removeItem(at: candidate.0)
            totalBytes -= candidate.1
            evicted += 1
        }
        if evicted > 0 {
            Log.info(
                .thumbnail,
                "缓存淘汰 数量=\(evicted) 当前=\(totalBytes)B 上限=\(capacityBytes)B"
            )
        }
    }

    private func fileURL(forKey key: String) -> URL {
        directory.appending(path: key + ".png")
    }

    private func fileURLs() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private static func directorySize(_ directory: URL) -> Int64 {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return urls.reduce(into: Int64(0)) { total, url in
            total += fileSize(url)
        }
    }
}

/// 为缩略图提供字节源。SMB 与本地库各实现一份。
public protocol ThumbnailByteSourceProvider: Sendable {
    func openByteSource(path: String) async throws -> any ByteSource
    /// 抽帧专用入口。默认回落到普通源；SMB 实现会用低优先级读取。
    func openThumbnailByteSource(path: String) async throws -> any ByteSource
}

extension ThumbnailByteSourceProvider {
    public func openThumbnailByteSource(path: String) async throws -> any ByteSource {
        try await openByteSource(path: path)
    }
}

/// 缩略图服务：缓存命中直接返回，未命中时按低并发抽帧；
/// 失败条目在当前会话内不再重试，避免损坏文件反复消耗带宽。
public actor ThumbnailService {
    public struct Outcome: Sendable {
        public let data: Data
        public let fromCache: Bool
        public let source: ThumbnailImage.Source?

        public init(data: Data, fromCache: Bool, source: ThumbnailImage.Source?) {
            self.data = data
            self.fromCache = fromCache
            self.source = source
        }
    }

    private let store: ThumbnailStore
    private let maxWidth: Int
    private let maxConcurrent: Int

    private var failedKeys: Set<String> = []
    private var inFlight: [String: Task<Outcome?, Never>] = [:]
    private var activeCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(store: ThumbnailStore, maxWidth: Int = 480, maxConcurrent: Int = 3) {
        self.store = store
        self.maxWidth = maxWidth
        self.maxConcurrent = max(1, maxConcurrent)
    }

    public func isKnownFailure(
        path: String,
        size: Int64,
        modified: Date?,
        namespace: String = ""
    ) -> Bool {
        failedKeys.contains(
            ThumbnailCacheKey.make(
                path: path,
                size: size,
                modified: modified,
                namespace: namespace
            )
        )
    }

    public func thumbnail(
        path: String,
        size: Int64,
        modified: Date?,
        namespace: String = "",
        provider: any ThumbnailByteSourceProvider
    ) async -> Outcome? {
        let key = ThumbnailCacheKey.make(
            path: path,
            size: size,
            modified: modified,
            namespace: namespace
        )

        if let cached = await store.cachedData(forKey: key) {
            Log.debug(.thumbnail, "缓存命中 \(Log.shortPath(path))")
            return Outcome(data: cached, fromCache: true, source: nil)
        }
        if failedKeys.contains(key) { return nil }
        if let existing = inFlight[key] {
            return await existing.value
        }

        let task: Task<Outcome?, Never> = Task.detached(priority: .utility) { [store, maxWidth, maxConcurrent] () -> Outcome? in
            await self.acquireSlot(maxConcurrent: maxConcurrent)
            defer { Task { await self.releaseSlot() } }

            let source: any ByteSource
            do {
                source = try await provider.openThumbnailByteSource(path: path)
            } catch {
                Log.error(.thumbnail, "打开失败 \(Log.shortPath(path)) \(error.localizedDescription)")
                await self.markFailed(key)
                return nil
            }

            do {
                let image = try DemuxProbe.thumbnail(
                    source: source,
                    label: path,
                    maxWidth: maxWidth
                )
                await source.close()
                try? await store.save(image.data, forKey: key)
                return Outcome(data: image.data, fromCache: false, source: image.source)
            } catch {
                await source.close()
                Log.error(.thumbnail, "生成失败 \(Log.shortPath(path)) \(error.localizedDescription)")
                await self.markFailed(key)
                return nil
            }
        }

        inFlight[key] = task
        let outcome = await task.value
        inFlight[key] = nil
        return outcome
    }

    private func markFailed(_ key: String) {
        failedKeys.insert(key)
    }

    private func acquireSlot(maxConcurrent: Int) async {
        if activeCount < maxConcurrent {
            activeCount += 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
        activeCount += 1
    }

    private func releaseSlot() {
        activeCount = max(0, activeCount - 1)
        guard !waiters.isEmpty else { return }
        let next = waiters.removeFirst()
        next.resume()
    }
}
