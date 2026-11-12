import Foundation
import PersistenceKit
import ThumbnailKit

/// 启动时把各缓存收敛到当前预算，并清理旧版本/调试留下的超限文件。
///
/// 之前容器头缓存允许 512MB、缩略图 100MB、字幕 50MB，叠加后会把
/// iPad 的 App 数据推到 800MB 以上；这里保证升级后首次启动就降下来。
enum CacheMaintenance {
    private static let once: Void = run()

    static func runAtLaunch() {
        _ = once
    }

    private static func run() {
        // 初始化时即按新预算裁剪并删除孤儿页文件。
        _ = ContainerHeaderCache.shared

        if let thumbnails = try? ThumbnailStore() {
            Task { await thumbnails.evictIfNeeded() }
        }
        if let folderCovers = try? ThumbnailStore(
            directory: ThumbnailStore.folderCoverDirectory(),
            capacityBytes: ThumbnailStore.folderCoverCapacityBytes
        ) {
            Task { await folderCovers.evictIfNeeded() }
        }

        SubtitleScriptCache.trimToLimit()
        trimDiagnosticFiles()
    }

    private static func trimDiagnosticFiles() {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        let maxBytes: Int64 = 4 * 1024 * 1024
        let capped = [
            "ice-playback.log",
            "ice-playback.log.1",
            "ice-smb.log",
            "ice-stress.log",
            "ice-acceptance.json",
        ]
        for name in capped {
            let url = documents.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            if Int64(values?.fileSize ?? 0) > maxBytes {
                try? FileManager.default.removeItem(at: url)
            }
        }

        // 文档自检报告只保留最近 3 份。
        let files = (try? FileManager.default.contentsOfDirectory(
            at: documents,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let selfTests = files
            .filter { $0.lastPathComponent.hasPrefix("DocumentSelfTest-") }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return left > right
            }
        for url in selfTests.dropFirst(3) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
