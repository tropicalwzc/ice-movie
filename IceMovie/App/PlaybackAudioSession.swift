import AVFAudio
import Foundation

/// 播放所需的后台音频会话配置。
///
/// 在 App 启动与每次进入播放前调用 `activate()`；`Info.plist` 中的
/// `UIBackgroundModes: audio` 与这里的 category 共同决定锁屏后是否继续出声。
enum PlaybackAudioSession {
    static func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .moviePlayback, options: [])
        try session.setActive(true)
    }

    static func deactivate() throws {
        try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
