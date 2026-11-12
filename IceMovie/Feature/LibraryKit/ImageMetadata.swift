import Foundation

/// 图片在媒体库网格中的展示信息。
///
/// 图片不使用 `MediaTitleParser`：相机文件名里的数字、下划线不是季集标记。
/// 标题只去掉扩展名并保留原始可读名称。
public struct ImageMetadata: Equatable, Sendable {
    public let title: String
    public let format: ImageFormat
    public let size: Int64
    public let modified: Date?

    public init?(entry: MediaEntry) {
        guard let format = entry.imageFormat else { return nil }
        let stripped = (entry.name as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = stripped.isEmpty ? entry.name : stripped
        self.format = format
        self.size = entry.size
        self.modified = entry.modified
    }

    public var typeLabel: String { format.displayLabel }

    public var sizeText: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
