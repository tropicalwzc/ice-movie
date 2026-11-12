import CryptoKit
import Foundation
import IceCore
import MediaLibraryKit

/// 内封字幕脚本缓存。
///
/// 内封字幕必须顺序扫完整个 MKV；SMB 上大文件可能耗时数十秒。
/// 以「格式版本 + 数据源 + 路径 + 文件大小 + 修改时间 + 流号」为键缓存已经降级后的 ASS，
/// 二次打开直接命中，不再扫描整个容器。
enum SubtitleScriptCache {
    private static let directoryName = "SubtitleScripts"
    /// 缓存内容版本：解析/降级逻辑变化时递增，升级后旧缓存自动失效。
    private static let formatVersion = 2
    /// 与缩略图、容器头缓存合计控制在 200MB 以内：字幕 16MB。
    nonisolated(unsafe) private static let capacityBytes: Int64 = 16 * 1024 * 1024
    private static let lock = NSLock()

    static func load(entry: MediaEntry, streamIndex: Int, namespace: String) -> String? {
        guard let url = url(entry: entry, streamIndex: streamIndex, namespace: namespace) else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
            return nil
        }
        // 刷新修改时间作为 LRU 依据。
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
        return text
    }

    static func save(_ text: String, entry: MediaEntry, streamIndex: Int, namespace: String) {
        guard let url = url(entry: entry, streamIndex: streamIndex, namespace: namespace) else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
            evictIfNeeded()
        } catch {
            Log.error(.subtitle, "字幕缓存写入失败：\(error.localizedDescription)")
        }
    }

    /// 启动时按当前上限修剪，兼容升级前写入的超限缓存。
    static func trimToLimit() {
        lock.lock()
        defer { lock.unlock() }
        evictIfNeeded()
    }

    static func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        guard let directory = directoryURL() else { return }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in files {
            try? FileManager.default.removeItem(at: url)
        }
        Log.info(.subtitle, "字幕脚本缓存已清空")
    }

    private static func evictIfNeeded() {
        guard let directory = directoryURL() else { return }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys)
        )) ?? []
        var items: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for url in files {
            let values = try? url.resourceValues(forKeys: keys)
            let size = Int64(values?.fileSize ?? 0)
            total += size
            items.append((url, size, values?.contentModificationDate ?? .distantPast))
        }
        guard total > capacityBytes else { return }
        for item in items.sorted(by: { $0.date < $1.date }) {
            guard total > capacityBytes else { break }
            try? FileManager.default.removeItem(at: item.url)
            total -= item.size
        }
        Log.info(.subtitle, "字幕缓存淘汰后 \(total)B，上限=\(capacityBytes)B")
    }

    private static func directoryURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func url(entry: MediaEntry, streamIndex: Int, namespace: String) -> URL? {
        guard let directory = directoryURL() else { return nil }
        let raw = "v\(formatVersion)|\(namespace)|\(entry.path)|\(entry.size)|\(entry.modified?.timeIntervalSince1970 ?? 0)|\(streamIndex)"
        let digest = SHA256.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent("\(digest).ass")
    }
}
