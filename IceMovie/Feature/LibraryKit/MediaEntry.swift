import Foundation

/// 媒体库中的一个条目。与 SMB 解耦，便于用本地目录、协议替身或单元测试驱动。
public struct MediaEntry: Identifiable, Hashable, Sendable {
    /// 相对共享根（或本地库根）的路径，使用 `/` 分隔，不含前导斜杠。
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modified: Date?

    public var id: String { path }

    public init(path: String, name: String, isDirectory: Bool, size: Int64, modified: Date?) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }

    public var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }

    public var isPlayableMedia: Bool {
        !isDirectory && MediaKind.isPlayable(name)
    }

    /// 所在目录路径；根目录为空串。
    public var directoryPath: String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// 展示用相对路径。根目录显示为共享根。
    public var displayDirectoryPath: String {
        directoryPath.isEmpty ? "/" : directoryPath
    }
}

/// 可播放媒体的扩展名集合。
///
/// 只列出当前 FFmpeg 构建实际支持的容器：避免把 `.rmvb` 之类列出来却打不开。
public enum MediaKind {
    public static let playableExtensions: Set<String> = [
        "mkv", "mp4", "mov", "m4v", "avi", "ts", "m2ts", "webm",
    ]

    public static func isPlayable(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return playableExtensions.contains(ext)
    }

    /// 目录始终保留，文件只有可播放媒体才进入网格。
    public static func isVisible(entry: MediaEntry) -> Bool {
        entry.isDirectory || isPlayable(entry.name)
    }
}
