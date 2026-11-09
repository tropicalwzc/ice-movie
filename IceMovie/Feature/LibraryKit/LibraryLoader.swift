import Foundation

/// 目录列举接口。SMB、本地文件与测试替身都实现它。
public protocol LibraryDirectoryLoading: Sendable {
    /// 列出相对共享根路径 `path` 下的条目。根目录传空串。
    func listDirectory(path: String) async throws -> [MediaEntry]
}

/// 把任意来源的条目转成媒体库条目：过滤非媒体文件、补全路径、按展示顺序排序。
public enum LibraryEntryBuilder {
    public static func build(
        directoryPath: String,
        items: [(name: String, isDirectory: Bool, size: Int64, modified: Date?)]
    ) -> [MediaEntry] {
        let prefix = directoryPath.isEmpty ? "" : directoryPath + "/"
        let entries = items.compactMap { item -> MediaEntry? in
            guard !item.name.isEmpty else { return nil }
            let entry = MediaEntry(
                path: prefix + item.name,
                name: item.name,
                isDirectory: item.isDirectory,
                size: item.size,
                modified: item.modified
            )
            return MediaKind.isVisible(entry: entry) ? entry : nil
        }
        return MediaOrdering.sorted(entries)
    }
}
