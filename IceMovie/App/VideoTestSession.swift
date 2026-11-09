import Observation
import RenderKit
import SubtitleKit

/// 自检模式下用来把播放引擎交给 SwiftUI 视图。
/// 正式播放页接入后会由导航层持有引擎，这里只是临时通道。
@MainActor
@Observable
final class VideoTestSession {
    static let shared = VideoTestSession()

    var engine: PlaybackEngine?
    var label = ""
    var subtitle: SubtitleTimeline?
}
