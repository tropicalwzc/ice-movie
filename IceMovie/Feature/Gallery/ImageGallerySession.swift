import Foundation
import MediaLibraryKit
import Observation

/// 一次全屏相册会话。分页集合只包含图片，按媒体库自然顺序排列。
///
/// 覆盖保存会改变源文件的大小与修改时间；会话作为引用类型持有最新条目，
/// 让相册内的缩略图键、收藏/删除和页码查询都使用刷新后的值。
@MainActor
@Observable
final class ImageGallerySession: Identifiable {
    let id = UUID()
    private(set) var entries: [MediaEntry]
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

    /// 覆盖保存成功后同步刷新会话快照，避免后续仍用旧 size/modified 命中缩略图缓存。
    func replaceEntry(_ updated: MediaEntry) {
        guard let index = entries.firstIndex(where: { $0.id == updated.id }) else {
            return
        }
        entries[index] = updated
    }
}
