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
        self.totalBytes = Self.directorySize(target)
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
    private var inFlight: [String: Task<Outcome?, Never>] = [:]
    private var activeCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(store: ThumbnailStore, maxWidth: Int = 384, maxConcurrent: Int = 3) {
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
        inFlight.removeValue(forKey: key)?.cancel()
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
            return await existing.value
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
                           label: path
                       ) {
                        // 手机上大部分 3–10MB JPEG 在前 384KB 里就有可用预览图。
                        image = fast
                        await source.close()
                    } else {
                        do {
                            image = try ImageDecoder.thumbnail(
                                source: source,
                                maxPixelSize: maxWidth,
                                label: path
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
                                    maxBytes: 64 * 1024 * 1024,
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
                    return Outcome(data: image.data, fromCache: false, source: nil)

                case .livePhoto:
                    let package = try await LivePhotoPackage.parse(source: source, label: path)
                    let still = try await package.stillImageData(source: source, label: path)
                    let image = try ImageDecoder.thumbnail(
                        data: still,
                        maxPixelSize: maxWidth,
                        label: path
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

        inFlight[key] = task
        let outcome = await task.value
        inFlight[key] = nil
        return outcome
    }

    /// 共享侧车文件可能损坏；解码失败时删除并回退原图。
    private static func isDecodableImage(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(
                  data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              CGImageSourceGetCount(source) > 0 else {
            return false
        }
        return CGImageSourceCreateImageAtIndex(
            source,
            0,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) != nil
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
