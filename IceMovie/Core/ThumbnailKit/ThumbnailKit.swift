import CryptoKit
import DemuxKit
import Foundation
import IceCore
import ImageIO
import ImageKit

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
    /// 图片/视频缩略图共用的磁盘硬上限：iPhone/iPad 本地空间有限，不能无限缓存。
    public static let maximumDiskBytes: Int64 = 64 * 1024 * 1024

    /// 把启动参数或外部配置的 MB 值收敛到 `maximumDiskBytes` 以内。
    /// `nil` 使用硬上限；小于 1 MB 的请求按 1 MB 处理。
    public static func clampedCapacityBytes(requestedMB: Int64?) -> Int64 {
        let maximumMB = maximumDiskBytes / (1024 * 1024)
        let mb = min(maximumMB, max(1, requestedMB ?? maximumMB))
        return mb * 1024 * 1024
    }

    public struct Snapshot: Sendable, Equatable {
        public let count: Int
        public let bytes: Int64
        public let capacityBytes: Int64
    }

    public nonisolated let directory: URL
    public nonisolated let capacityBytes: Int64

    private struct Entry {
        var bytes: Int64
        var lastAccess: Date
    }

    /// 内存里的 LRU 表。命中只更新时间戳，不再每次 stat + 写文件元数据。
    private var entries: [String: Entry] = [:]
    /// 限制 mtime 刷新频率，保留跨启动的 LRU 信息，又避免滚动时大量元数据写入。
    private var lastStamped: [String: Date] = [:]
    private var totalBytes: Int64 = 0

    public init(
        directory: URL? = nil,
        capacityBytes: Int64 = maximumDiskBytes
    ) throws {
        let target = directory ?? Self.defaultDirectory()
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        self.directory = target
        // 在缓存边界强制硬上限，避免未来调用方绕过启动参数直接传入更大值。
        self.capacityBytes = min(max(0, capacityBytes), Self.maximumDiskBytes)
        let scanned = Self.scanEntries(target)
        self.entries = scanned
        self.totalBytes = scanned.values.reduce(0) { $0 + $1.bytes }
    }

    public nonisolated static func defaultDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appending(path: "Thumbnails", directoryHint: .isDirectory)
    }

    /// 目录封面独立缓存，避免被频繁写入的文件缩略图 LRU 淘汰。
    public nonisolated static func folderCoverDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appending(path: "FolderCovers", directoryHint: .isDirectory)
    }

    public static let folderCoverCapacityBytes: Int64 = 16 * 1024 * 1024

    public func snapshot() -> Snapshot {
        Snapshot(count: entries.count, bytes: totalBytes, capacityBytes: capacityBytes)
    }

    /// 命中时只更新内存 LRU；文件 mtime 最多每 60 秒刷新一次，避免滚动时写放大。
    public func cachedData(forKey key: String) -> Data? {
        let url = fileURL(forKey: key)
        guard let data = try? Data(contentsOf: url) else {
            if let stale = entries.removeValue(forKey: key) {
                totalBytes = max(0, totalBytes - stale.bytes)
            }
            return nil
        }
        let now = Date()
        let previous = entries[key]?.bytes ?? 0
        totalBytes += Int64(data.count) - previous
        entries[key] = Entry(bytes: Int64(data.count), lastAccess: now)
        if lastStamped[key].map({ now.timeIntervalSince($0) >= 60 }) ?? true {
            try? FileManager.default.setAttributes(
                [.modificationDate: now],
                ofItemAtPath: url.path
            )
            lastStamped[key] = now
        }
        return data
    }

    public func save(_ data: Data, forKey key: String) throws {
        let url = fileURL(forKey: key)
        let previous = entries[key]?.bytes ?? Self.fileSize(url)
        try data.write(to: url, options: .atomic)
        let now = Date()
        totalBytes += Int64(data.count) - previous
        entries[key] = Entry(bytes: Int64(data.count), lastAccess: now)
        lastStamped[key] = now
        try? FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: url.path
        )
        evictIfNeeded()
    }

    public func removeAll() {
        for url in fileURLs() {
            try? FileManager.default.removeItem(at: url)
        }
        entries.removeAll()
        lastStamped.removeAll()
        totalBytes = 0
    }

    /// 仅用于验证：把上限临时调小后可直接观察淘汰行为。
    ///
    /// LRU 表在内存里，淘汰不再扫描整个目录；排序本身足够便宜。
    public func evictIfNeeded() {
        guard totalBytes > capacityBytes else { return }
        let candidates = entries.sorted { $0.value.lastAccess < $1.value.lastAccess }

        var evicted = 0
        for (key, entry) in candidates {
            guard totalBytes > capacityBytes else { break }
            try? FileManager.default.removeItem(at: fileURL(forKey: key))
            totalBytes = max(0, totalBytes - entry.bytes)
            entries[key] = nil
            lastStamped[key] = nil
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

    /// 启动时扫描一次，之后 LRU 完全在内存里维护。
    private static func scanEntries(_ directory: URL) -> [String: Entry] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        )) ?? []
        var result: [String: Entry] = [:]
        result.reserveCapacity(urls.count)
        for url in urls {
            let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            )
            guard let size = values?.fileSize else { continue }
            let key = url.deletingPathExtension().lastPathComponent
            result[key] = Entry(
                bytes: Int64(size),
                lastAccess: values?.contentModificationDate ?? .distantPast
            )
        }
        return result
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

/// 缩略图内容类型：视频抽帧、静态图片解码或 LIVP 静态图。
public enum ThumbnailContentKind: Sendable, Equatable {
    case video
    case image
    case livePhoto
}

/// 缩略图服务：缓存命中直接返回，未命中时按低并发抽帧/解码；
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
    private var inFlight: [String: InFlight] = [:]
    private var activeCount = 0

    private final class InFlight {
        let task: Task<Outcome?, Never>

        init(task: Task<Outcome?, Never>) {
            self.task = task
        }
    }
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(store: ThumbnailStore, maxWidth: Int = 512, maxConcurrent: Int = 3) {
        self.store = store
        self.maxWidth = maxWidth
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// 清空磁盘缩略图与失败记录，供设置页释放空间。
    public func removeAll() async {
        await store.removeAll()
        failedKeys.removeAll()
        Log.info(.thumbnail, "缩略图缓存已清空")
    }

    /// 目录刷新/重连成功后允许失败条目重试，避免一次网络抖动把整批照片
    /// 在当前会话里永久标记为“无预览”。
    public func clearFailures() {
        failedKeys.removeAll()
    }

    /// 启动时按当前上限立即修剪一次，避免调低上限后旧缓存继续占盘。
    public func trimToCapacity() async {
        await store.evictIfNeeded()
    }

    /// 单元格滑出屏幕时取消未被任何页面需要的生成任务，尽快把带宽让给可见条目。
    /// 只查本地磁盘缓存，不触发任何读取或生成。
    /// 目录封面用它跳过 SMB 枚举：上次选中的内部视频和缓存键都已持久化。
    public func cachedData(
        path: String,
        size: Int64,
        modified: Date?,
        namespace: String = ""
    ) async -> Data? {
        let key = ThumbnailCacheKey.make(
            path: path,
            size: size,
            modified: modified,
            namespace: namespace
        )
        return await store.cachedData(forKey: key)
    }

    public func cancel(
        path: String,
        size: Int64,
        modified: Date?,
        namespace: String = ""
    ) {
        let key = ThumbnailCacheKey.make(
            path: path,
            size: size,
            modified: modified,
            namespace: namespace
        )
        inFlight.removeValue(forKey: key)?.task.cancel()
    }

    public func isKnownFailure(        path: String,
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
        contentKind: ThumbnailContentKind = .video,
        sidecar: SharedThumbnailCache? = nil,
        positionFraction: Double? = nil,
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

        // 本地缓存 miss 后先查共享侧车；命中时完全不打开原图。
        if let sidecar {
            if let data = await sidecar.thumbnail(path: path, size: size, modified: modified) {
                if Self.isDecodableImage(data) {
                    try? await store.save(data, forKey: key)
                    return Outcome(data: data, fromCache: false, source: nil)
                }
                await sidecar.remove(path: path)
                Log.notice(
                    .thumbnail,
                    "共享缩略图损坏，已删除并回退原图 \(Log.shortPath(path))"
                )
            }
        }

        if let existing = inFlight[key] {
            return await existing.task.value
        }

        let task: Task<Outcome?, Never> = Task.detached(priority: .utility) { [store, maxWidth, maxConcurrent, contentKind, sidecar, positionFraction] () -> Outcome? in
            await self.acquireSlot(maxConcurrent: maxConcurrent)
            defer { Task { await self.releaseSlot() } }
            if Task.isCancelled { return nil }

            let source: any ByteSource
            do {
                source = try await provider.openThumbnailByteSource(path: path)
            } catch {
                if Task.isCancelled { return nil }
                Log.error(.thumbnail, "打开失败 \(Log.shortPath(path)) \(error.localizedDescription)")
                await self.markFailed(key)
                return nil
            }
            if Task.isCancelled {
                await source.close()
                return nil
            }

            do {
                switch contentKind {
                case .video:
                    let image = try DemuxProbe.thumbnail(
                        source: source,
                        label: path,
                        maxWidth: maxWidth,
                        positionFraction: positionFraction
                    )
                    await source.close()
                    try? await store.save(image.data, forKey: key)
                    if let sidecar,
                       let jpeg = ImageDecoder.encodeJPEG(image.data) {
                        await sidecar.store(
                            thumbnailData: jpeg,
                            width: image.width,
                            height: image.height,
                            path: path,
                            size: size,
                            modified: modified
                        )
                    }
                    return Outcome(data: image.data, fromCache: false, source: image.source)

                case .image:
                    let image: ThumbnailOutput
                    let lowerPath = path.lowercased()
                    let isJPEG = lowerPath.hasSuffix(".jpg") || lowerPath.hasSuffix(".jpeg")
                    if isJPEG,
                       let fast = try? await ImageDecoder.thumbnailFromPrefix(
                           source: source,
                           maxPixelSize: maxWidth,
                           label: path,
                           includeJPEG: sidecar != nil
                       ) {
                        // 手机上大部分 3–10MB JPEG 在前 384KB 里就有可用预览图。
                        image = fast
                        await source.close()
                    } else {
                        do {
                            image = try await ImageDecoder.thumbnail(
                                source: source,
                                maxPixelSize: maxWidth,
                                label: path,
                                includeJPEG: sidecar != nil
                            )
                            await source.close()
                        } catch {
                            await source.close()
                            // 某些 SMB JPEG 的按需分段读取会让 ImageIO 报 0x0；
                            // 换新句柄整图读取再解一次，避免网格留下永久“无预览”。
                            Log.notice(
                                .thumbnail,
                                "图片按需解码失败，回退整图 \(Log.shortPath(path)) \(error.localizedDescription)"
                            )
                            let retrySource = try await provider.openThumbnailByteSource(path: path)
                            do {
                                let data = try await ImageDataReader.readAll(
                                    source: retrySource,
                                    // 缩略图回退不需要把超大原图整个读进内存；
                                    // 32MB 已覆盖常见 48MP JPEG/HEIC，超过则回退失败而不是冒 jetsam 风险。
                                    maxBytes: 32 * 1024 * 1024,
                                    label: path
                                )
                                await retrySource.close()
                                image = try ImageDecoder.thumbnail(
                                    data: data,
                                    maxPixelSize: maxWidth,
                                    label: path
                                )
                                Log.notice(
                                    .thumbnail,
                                    "整图回退解码成功 \(Log.shortPath(path)) \(data.count)B"
                                )
                            } catch {
                                await retrySource.close()
                                throw error
                            }
                        }
                    }
                    if Task.isCancelled { return nil }
                    try? await store.save(image.data, forKey: key)
                    if let sidecar,
                       let jpeg = image.jpegData ?? ImageDecoder.encodeJPEG(image.data) {
                        await sidecar.store(
                            thumbnailData: jpeg,
                            width: image.width,
                            height: image.height,
                            path: path,
                            size: size,
                            modified: modified
                        )
                    }
                    return Outcome(data: image.data, fromCache: false, source: nil)

                case .livePhoto:
                    let package = try await LivePhotoPackage.parse(source: source, label: path)
                    let still = try await package.stillImageData(source: source, label: path)
                    let image = try ImageDecoder.thumbnail(
                        data: still,
                        maxPixelSize: maxWidth,
                        label: path,
                        includeJPEG: sidecar != nil
                    )
                    await source.close()
                    try? await store.save(image.data, forKey: key)
                    if let sidecar,
                       let jpeg = image.jpegData ?? ImageDecoder.encodeJPEG(image.data) {
                        await sidecar.store(
                            thumbnailData: jpeg,
                            width: image.width,
                            height: image.height,
                            path: path,
                            size: size,
                            modified: modified
                        )
                    }
                    return Outcome(data: image.data, fromCache: false, source: nil)
                }
            } catch {
                await source.close()
                if Task.isCancelled { return nil }
                Log.error(.thumbnail, "生成失败 \(Log.shortPath(path)) \(error.localizedDescription)")
                await self.markFailed(key)
                return nil
            }
        }

        let box = InFlight(task: task)
        inFlight[key] = box
        let outcome = await task.value
        // 等待期间可能已被 cancel + 新请求替换；只清理自己写入的那一个，
        // 否则会把新任务从表里抹掉，导致同一张图被多路并发读取。
        if inFlight[key] === box {
            inFlight[key] = nil
        }
        return outcome
    }

    /// 共享侧车文件可能损坏；解码失败时删除并回退原图。
    private static func isDecodableImage(_ data: Data) -> Bool {
        guard !data.isEmpty,
              ImageDecoder.isCompleteJPEG(data),
              let source = CGImageSourceCreateWithData(
                  data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              CGImageSourceGetCount(source) > 0 else {
            return false
        }
        let status = CGImageSourceGetStatus(source)
        guard status != .statusInvalidData, status != .statusUnexpectedEOF else {
            return false
        }
        return CGImageSourceCreateImageAtIndex(
            source,
            0,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) != nil
    }

    private func markFailed(_ key: String) {
        // 超大目录长期滚动时失败集合也要有界；丢最早插入的任意一条即可。
        if failedKeys.count >= 4096, let first = failedKeys.first {
            failedKeys.remove(first)
        }
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
        // 许可由 releaseSlot 直接转交，这里不再自增，避免和新进入的请求叠加超限。
    }

    private func releaseSlot() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
            return
        }
        activeCount = max(0, activeCount - 1)
    }
}
