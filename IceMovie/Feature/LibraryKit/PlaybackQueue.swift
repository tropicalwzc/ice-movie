import Foundation

/// 播放队列：按目录中的自然顺序找下一个视频。
public enum PlaybackQueue {
    /// `entries` 已按界面顺序排列（目录在前、文件自然排序）。
    /// 当前条目不在列表中或后面没有视频时返回 nil。
    public static func next(after entry: MediaEntry, in entries: [MediaEntry]) -> MediaEntry? {
        guard !entry.isDirectory else { return nil }
        guard let index = entries.firstIndex(where: { $0.path == entry.path }) else {
            return nil
        }
        return entries[(index + 1)...].first { !$0.isDirectory }
    }
}
