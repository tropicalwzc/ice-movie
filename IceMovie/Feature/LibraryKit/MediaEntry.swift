import Foundation

/// 媒体库中的一个条目。与 SMB 解耦，便于用本地目录、协议替身或单元测试驱动。
public struct MediaEntry: Identifiable, Hashable, Sendable {
    /// 相对共享根（或本地库根）的路径，使用 `/` 分隔，不含前导斜杠。
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modified: Date?
    /// 文件名末尾 `_yyyyMMddHHmmss` 解析出的拍摄时间；非图片/视频或无该格式时为 nil。
    public let captureTimestamp: PhotoTimestamp?

    public var id: String { path }

    public init(path: String, name: String, isDirectory: Bool, size: Int64, modified: Date?) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.captureTimestamp = isDirectory
            ? nil
            : PhotoTimestampParser.parse(filename: name)
    }

    public var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }

    public var isPlayableMedia: Bool {
        !isDirectory && MediaKind.isPlayable(name)
    }

    /// 条目类型。视频、图片与文档都是文件，但进入媒体库后的呈现与打开方式不同。
    public var kind: MediaEntryKind {
        if isDirectory { return .directory }
        if MediaKind.isPlayable(name) { return .video }
        switch MediaKind.documentFormat(for: name) {
        case .markdown: return .markdown
        case .pdf: return .pdf
        case nil: break
        }
        if MediaKind.isImage(name) { return .image }
        return .other
    }

    public var isDocument: Bool { kind.isDocument }

    public var isImage: Bool { kind == .image }

    public var documentFormat: DocumentFormat? {
        isDocument ? MediaKind.documentFormat(for: name) : nil
    }

    public var imageFormat: ImageFormat? {
        isImage ? MediaKind.imageFormat(for: name) : nil
    }

    public var isLivePhoto: Bool {
        imageFormat == .livePhoto
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

/// 媒体库条目类型。
public enum MediaEntryKind: String, Sendable, Equatable {
    case directory
    case video
    case image
    case markdown
    case pdf
    case other

    public var isDocument: Bool {
        self == .markdown || self == .pdf
    }
}

/// 可浏览图片格式。LIVP 仍然属于图片，只为相册与徽标提供额外能力。
public enum ImageFormat: String, Sendable, Equatable, CaseIterable {
    case jpeg
    case png
    case heic
    case livePhoto

    public var allowedExtensions: Set<String> {
        switch self {
        case .jpeg: ["jpg", "jpeg"]
        case .png: ["png"]
        case .heic: ["heic", "heif"]
        case .livePhoto: ["livp"]
        }
    }

    /// 列表/徽标使用的短标签。
    public var displayLabel: String {
        switch self {
        case .jpeg: "JPG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .livePhoto: "LIVE"
        }
    }

    public var isLivePhoto: Bool { self == .livePhoto }
}

/// 可在应用内阅读的文档格式。
public enum DocumentFormat: String, Sendable, Equatable, CaseIterable {
    case markdown
    case pdf

    /// 文档列表中的类型徽标。
    public var displayLabel: String {
        switch self {
        case .markdown: "MD"
        case .pdf: "PDF"
        }
    }

    public var displayName: String {
        switch self {
        case .markdown: "Markdown"
        case .pdf: "PDF"
        }
    }

    /// 单文件读取上限。Markdown 是纯文本，PDF 需要 PDFKit 建立文档，限制更宽。
    public var maxByteCount: Int64 {
        switch self {
        case .markdown: 5 * 1024 * 1024
        case .pdf: 30 * 1024 * 1024
        }
    }

    public var allowedExtensions: Set<String> {
        switch self {
        case .markdown: ["md", "markdown"]
        case .pdf: ["pdf"]
        }
    }
}

/// 可播放媒体与可阅读文档的扩展名集合。
///
/// 只列出当前 FFmpeg 构建实际支持的容器：避免把 `.rmvb` 之类列出来却打不开。
public enum MediaKind {
    public static let playableExtensions: Set<String> = [
        "mkv", "mp4", "mov", "m4v", "avi", "ts", "m2ts", "webm",
    ]

    /// 进入媒体库的文档扩展名。
    public static let documentExtensions: Set<String> = [
        "md", "markdown", "pdf",
    ]

    /// 进入媒体库的图片扩展名。
    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "livp",
    ]

    public static func isPlayable(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return playableExtensions.contains(ext)
    }

    public static func documentFormat(for name: String) -> DocumentFormat? {
        let ext = (name as NSString).pathExtension.lowercased()
        if DocumentFormat.markdown.allowedExtensions.contains(ext) {
            return .markdown
        }
        if DocumentFormat.pdf.allowedExtensions.contains(ext) {
            return .pdf
        }
        return nil
    }

    public static func isDocument(_ name: String) -> Bool {
        documentFormat(for: name) != nil
    }

    public static func imageFormat(for name: String) -> ImageFormat? {
        let ext = (name as NSString).pathExtension.lowercased()
        for format in ImageFormat.allCases where format.allowedExtensions.contains(ext) {
            return format
        }
        return nil
    }

    public static func isImage(_ name: String) -> Bool {
        imageFormat(for: name) != nil
    }

    /// 目录始终保留；文件只有视频、图片或文档才进入媒体库。
    public static func isVisible(entry: MediaEntry) -> Bool {
        entry.isDirectory
            || isPlayable(entry.name)
            || isDocument(entry.name)
            || isImage(entry.name)
    }
}
