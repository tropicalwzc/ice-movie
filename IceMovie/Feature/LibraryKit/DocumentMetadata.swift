import Foundation

/// 文档在媒体库列表中的展示信息。
///
/// 文档不使用 `MediaTitleParser`：面试资料文件名里的 `P0`、`P1`、日期等
/// 可能被误解析成季集号。这里只去掉扩展名，保留原始可读文件名。
public struct DocumentMetadata: Equatable, Sendable {
    public let title: String
    public let format: DocumentFormat
    public let size: Int64
    public let modified: Date?

    public init?(entry: MediaEntry) {
        guard let format = entry.documentFormat else { return nil }
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
