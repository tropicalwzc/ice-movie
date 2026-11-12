import Foundation

/// App 容器内各缓存模块的实际磁盘占用。
///
/// 稀疏文件（容器头缓存的 `.bin`）的逻辑大小可能远大于真实占用，
/// 因此统一按分配块统计，避免报告出现几百 GB 的假数字。
enum CacheUsageReport {
    struct Module {
        let name: String
        let bytes: Int64
    }

    static func modules() -> [Module] {
        let fileManager = FileManager.default
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]

        let thumbnails = caches.appendingPathComponent("Thumbnails", isDirectory: true)
        let folderCovers = caches.appendingPathComponent("FolderCovers", isDirectory: true)
        let headers = caches.appendingPathComponent("ContainerHeaderCache", isDirectory: true)
        let subtitles = caches.appendingPathComponent("SubtitleScripts", isDirectory: true)
        let splash = library.appendingPathComponent("SplashBoard", isDirectory: true)
        let appSupport = library.appendingPathComponent("Application Support", isDirectory: true)

        let cachesTotal = allocatedBytes(at: caches)
        let knownCaches = [thumbnails, folderCovers, headers, subtitles]
            .reduce(Int64(0)) { $0 + allocatedBytes(at: $1) }

        return [
            Module(name: "容器头缓存", bytes: allocatedBytes(at: headers)),
            Module(name: "缩略图", bytes: allocatedBytes(at: thumbnails)),
            Module(name: "目录封面", bytes: allocatedBytes(at: folderCovers)),
            Module(name: "日志与报告", bytes: allocatedBytes(at: documents)),
            Module(name: "系统快照", bytes: allocatedBytes(at: splash)),
            Module(name: "内封字幕", bytes: allocatedBytes(at: subtitles)),
            Module(name: "应用支持", bytes: allocatedBytes(at: appSupport)),
            Module(name: "其他缓存", bytes: max(0, cachesTotal - knownCaches)),
        ]
        .sorted { $0.bytes > $1.bytes }
    }

    static func text() -> String {
        let items = modules()
        let total = items.reduce(Int64(0)) { $0 + $1.bytes }
        var lines = items.map { "\($0.name)：\(formatted($0.bytes))" }
        lines.append("合计：\(formatted(total))")
        lines.append(
            "预算：目标 < \(formatted(200_000_000))，硬上限 \(formatted(500_000_000))"
        )
        return lines.joined(separator: "\n")
    }

    private static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func allocatedBytes(at url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: nil
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
