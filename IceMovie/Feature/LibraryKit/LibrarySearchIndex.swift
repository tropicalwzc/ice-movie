import Foundation

/// 一条检索命中。保留所在目录路径，便于界面标注与跳转。
public struct LibrarySearchHit: Identifiable, Hashable, Sendable {
    public let entry: MediaEntry
    public let displayPath: String
    /// 命中项所在共享。跨共享检索时同一个相对路径可能重复出现。
    public let share: String

    public var id: String { "\(share)|\(entry.id)" }

    public init(entry: MediaEntry, displayPath: String, share: String = "") {
        self.entry = entry
        self.displayPath = displayPath
        self.share = share
    }
}

/// 累积式检索索引。
///
/// 每浏览一个目录就把条目并入索引；后台补全只追加，不清空已有结果，
/// 因此检索可以在尚未索引完整个共享时先给出局部结果。
public struct LibrarySearchIndex: Sendable {
    private struct EntryKey: Hashable, Sendable {
        let share: String
        let path: String
    }

    private var entries: [EntryKey: MediaEntry] = [:]
    private var directories: Set<EntryKey> = []
    private var titles: [EntryKey: MediaTitle] = [:]
    private var shares: Set<String> = []

    public init() {}

    public var indexedDirectoryCount: Int { directories.count }

    public var indexedEntryCount: Int { entries.count }

    /// 已经进入索引的共享数量。
    public var indexedShareCount: Int { shares.count }

    public func hasIndexed(_ directoryPath: String, share: String = "") -> Bool {
        directories.contains(EntryKey(share: share, path: directoryPath))
    }

    public mutating func index(
        directoryPath: String,
        entries newEntries: [MediaEntry],
        share: String = ""
    ) {
        shares.insert(share)
        directories.insert(EntryKey(share: share, path: directoryPath))
        for entry in newEntries where !entry.isDirectory {
            let key = EntryKey(share: share, path: entry.path)
            entries[key] = entry
            if let image = ImageMetadata(entry: entry) {
                // 图片不参与季集解析：相机文件名的数字不是集号。
                titles[key] = MediaTitle(
                    title: image.title,
                    season: nil,
                    episode: nil
                )
            } else if let document = DocumentMetadata(entry: entry) {
                // 文档不参与季集解析：文件名中的 P0/P1、日期等不是集号。
                titles[key] = MediaTitle(
                    title: document.title,
                    season: nil,
                    episode: nil
                )
            } else {
                titles[key] = MediaTitleParser.parse(entry.name)
            }
        }
    }

    public func search(
        _ rawQuery: String,
        limit: Int = 200,
        preferredShare: String? = nil
    ) -> [LibrarySearchHit] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        var hits: [(hit: LibrarySearchHit, score: Int)] = []
        for (key, entry) in entries {
            let parsed = titles[key] ?? MediaTitleParser.parse(entry.name)
            let displayTitle = parsed.title
            let score: Int
            if displayTitle.localizedCaseInsensitiveHasPrefix(query) {
                score = 0
            } else if displayTitle.localizedCaseInsensitiveContains(query) {
                score = 1
            } else if entry.name.localizedCaseInsensitiveContains(query) {
                score = 2
            } else if key.path.localizedCaseInsensitiveContains(query) {
                score = 3
            } else {
                continue
            }
            hits.append((
                LibrarySearchHit(
                    entry: entry,
                    displayPath: entry.displayDirectoryPath,
                    share: key.share
                ),
                score
            ))
        }

        hits.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            if let preferredShare {
                let lhsPreferred = lhs.hit.share == preferredShare
                let rhsPreferred = rhs.hit.share == preferredShare
                if lhsPreferred != rhsPreferred { return lhsPreferred }
            }
            if lhs.hit.share != rhs.hit.share {
                return lhs.hit.share.localizedStandardCompare(rhs.hit.share)
                    == .orderedAscending
            }
            if lhs.hit.entry.path != rhs.hit.entry.path {
                return lhs.hit.entry.path.localizedStandardCompare(rhs.hit.entry.path) == .orderedAscending
            }
            return false
        }
        return hits.prefix(limit).map(\.hit)
    }
}

private extension String {
    func localizedCaseInsensitiveHasPrefix(_ prefix: String) -> Bool {
        range(of: prefix, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
    }
}
