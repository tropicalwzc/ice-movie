import Foundation

/// 目标目录中已有图片的只读索引。
///
/// 去重不依赖严格文件名：远端语料可能带导出日期前缀，也可能被转成别的扩展名。
/// 因此同时保留完整文件名精确集合与“末尾拍摄时间 -> 时间戳前 stem”的桶。
public struct RemotePhotoIndex: Sendable, Equatable {
    public let exactNames: Set<String>
    public let prefixByTimestamp: [String: [String]]
    public let imageNames: [String]

    public var imageCount: Int { imageNames.count }

    public init(entries: [MediaEntry]) {
        var exactNames: Set<String> = []
        var prefixByTimestamp: [String: [String]] = [:]
        var imageNames: [String] = []

        for entry in entries {
            guard !entry.isDirectory else { continue }
            guard MediaKind.isImage(entry.name) else { continue }
            guard !Self.isTemporaryName(entry.name) else { continue }
            guard !entry.name.hasPrefix(".") else { continue }

            imageNames.append(entry.name)
            exactNames.insert(entry.name.lowercased())

            guard let timestamp = entry.captureTimestamp else { continue }
            let compact = timestamp.compactString
            let stem = (entry.name as NSString).deletingPathExtension.lowercased()
            let prefix: String
            let suffix = "_\(compact)"
            if stem.hasSuffix(suffix) {
                prefix = String(stem.dropLast(suffix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                prefix = stem.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            prefixByTimestamp[compact, default: []].append(prefix)
        }

        self.exactNames = exactNames
        self.prefixByTimestamp = prefixByTimestamp
        self.imageNames = imageNames
    }

    public func containsRemoteFile(named name: String) -> Bool {
        exactNames.contains(name.lowercased())
    }

    /// 判断远端是否已有同一张照片：同一拍摄时间桶里，stem 等于原名，
    /// 或以原名结尾/包含 `_原名`、` 原名`、`原名_`。
    /// 原名过短时只允许精确匹配，避免 `IMG_12` 误命中 `IMG_123`。
    public func matches(base: String, timestamp: String) -> Bool {
        let lower = base.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return false }
        guard let prefixes = prefixByTimestamp[timestamp] else { return false }

        for prefix in prefixes {
            if prefix == lower {
                return true
            }
            guard lower.count >= 4 else { continue }
            if prefix.hasSuffix(lower)
                || prefix.contains("_\(lower)")
                || prefix.contains(" \(lower)")
                || prefix.contains("\(lower)_") {
                return true
            }
        }
        return false
    }

    /// 临时文件与备份文件不进入去重索引，也不应被当作既有照片。
    public static func isTemporaryName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains(".icemovie-tmp-") || lower.contains(".icemovie-bak-")
    }
}
