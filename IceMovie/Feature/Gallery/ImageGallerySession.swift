import Foundation
import MediaLibraryKit

/// 一次全屏相册会话。分页集合只包含图片，按媒体库自然顺序排列。
struct ImageGallerySession: Identifiable {
    let id = UUID()
    let entries: [MediaEntry]
    let initialIndex: Int
    let source: any LibrarySource
    let title: String

    init(
        entries: [MediaEntry],
        initialIndex: Int,
        source: any LibrarySource,
        title: String
    ) {
        self.entries = entries
        self.initialIndex = min(max(0, initialIndex), max(0, entries.count - 1))
        self.source = source
        self.title = title
    }

    var initialEntry: MediaEntry? {
        guard entries.indices.contains(initialIndex) else { return entries.first }
        return entries[initialIndex]
    }
}
