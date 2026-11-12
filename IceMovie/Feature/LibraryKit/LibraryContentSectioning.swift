import Foundation

/// 当前目录的呈现模式。
public enum LibraryDirectoryPresentation: String, Sendable, Equatable {
    /// 没有任何可见条目。
    case empty
    /// 只有网格媒体（目录 + 视频 + 图片）。
    case mediaGrid
    /// 网格媒体与文档并存：网格在上，文档列表在下。
    case mixed
    /// 没有视频和图片但有文档：目录与文档统一使用列表。
    case documentsOnly

    /// 兼容旧命名；语义等同于 `.mediaGrid`。
    public static var videoGrid: Self { .mediaGrid }
}

/// 把目录条目分区成“网格部分”和“文档列表部分”。
///
/// 这是纯数据逻辑，与 SwiftUI 无关，便于单元测试覆盖混合目录、
/// 纯文档目录、图片目录、视频目录和空目录。
public struct LibraryContentSectioning: Equatable, Sendable {
    public let presentation: LibraryDirectoryPresentation
    public let hasVideos: Bool
    public let hasImages: Bool
    public let hasGridMedia: Bool
    public let gridItems: [MediaEntry]
    public let documentItems: [MediaEntry]
    /// 纯文档模式下的列表内容：目录在前，文档在后。
    public let documentListItems: [MediaEntry]

    /// 兼容旧命名；语义等同于 `gridItems`。
    public var videoGridItems: [MediaEntry] { gridItems }

    public init(entries: [MediaEntry]) {
        guard !entries.isEmpty else {
            self.presentation = .empty
            self.hasVideos = false
            self.hasImages = false
            self.hasGridMedia = false
            self.gridItems = []
            self.documentItems = []
            self.documentListItems = []
            return
        }

        let videos = entries.contains { $0.kind == .video }
        let images = entries.contains { $0.kind == .image }
        let gridItems = entries.filter {
            $0.kind == .directory || $0.kind == .video || $0.kind == .image
        }
        let documents = entries
            .filter(\.isDocument)
            .sorted { lhs, rhs in
                let compared = lhs.name.localizedStandardCompare(rhs.name)
                if compared != .orderedSame { return compared == .orderedAscending }
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
        let directories = entries.filter(\.isDirectory)
        let hasGridMedia = videos || images

        self.hasVideos = videos
        self.hasImages = images
        self.hasGridMedia = hasGridMedia
        self.gridItems = gridItems
        self.documentItems = documents
        self.documentListItems = directories + documents

        if documents.isEmpty {
            self.presentation = .mediaGrid
        } else if hasGridMedia {
            self.presentation = .mixed
        } else {
            self.presentation = .documentsOnly
        }
    }

    public var isEmpty: Bool { presentation == .empty }
    public var hasDocuments: Bool { !documentItems.isEmpty }
}
