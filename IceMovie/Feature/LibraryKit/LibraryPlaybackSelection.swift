import Foundation

/// 媒体库自动播放/自动打开的目标选择。
///
/// 文档也会出现在 `currentEntries` 中，但只有视频才能进入播放链路。
public enum LibraryPlaybackSelection {
    public static func firstVideo(
        in entries: [MediaEntry],
        preferredName: String? = nil
    ) -> MediaEntry? {
        let videos = entries.filter { $0.kind == .video }
        guard let preferredName, !preferredName.isEmpty else {
            return videos.first
        }
        return videos.first {
            $0.name.localizedCaseInsensitiveContains(preferredName)
        } ?? videos.first
    }
}
