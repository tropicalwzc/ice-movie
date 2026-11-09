import Foundation

/// 一条检索命中。保留所在目录路径，便于界面标注与跳转。
public struct LibrarySearchHit: Identifiable, Hashable, Sendable {
    public let entry: MediaEntry
    public let displayPath: String

    public var id: String { entry.id }

    public init(entry: MediaEntry, displayPath: String) {
        self.entry = entry
        self.displayPath = displayPath
    }
}

/// 累积式检索索引。
///
/// 每浏览一个目录就把条目并入索引；后台补全只追加，不清空已有结果，
/// 因此检索可以在尚未索引完整个共享时先给出局部结果。
public struct LibrarySearchIndex: Sendable {
    private var entries: [String: MediaEntry] = [:]
    private var directories: Set<String> = []
    private var titles: [String: MediaTitle] = [:]

    public init() {}

    public var indexedDirectoryCount: Int { directories.count }

    public var indexedEntryCount: Int { entries.count }

    public func hasIndexed(_ directoryPath: String) -> Bool {
        directories.contains(directoryPath)
    }

    public mutating func index(directoryPath: String, entries newEntries: [MediaEntry]) {
        directories.insert(directoryPath)
        for entry in newEntries where !entry.isDirectory {
            entries[entry.path] = entry
            titles[entry.path] = MediaTitleParser.parse(entry.name)
        }
    }

    public func search(_ rawQuery: String, limit: Int = 200) -> [LibrarySearchHit] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        var hits: [(hit: LibrarySearchHit, score: Int)] = []
        for (path, entry) in entries {
            let parsed = titles[path] ?? MediaTitleParser.parse(entry.name)
            let displayTitle = parsed.title
            let score: Int
            if displayTitle.localizedCaseInsensitiveHasPrefix(query) {
                score = 0
            } else if displayTitle.localizedCaseInsensitiveContains(query) {
                score = 1
            } else if entry.name.localizedCaseInsensitiveContains(query) {
                score = 2
            } else if path.localizedCaseInsensitiveContains(query) {
                score = 3
            } else {
                continue
            }
            hits.append((
                LibrarySearchHit(entry: entry, displayPath: entry.displayDirectoryPath),
                score
            ))
        }

        hits.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
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
