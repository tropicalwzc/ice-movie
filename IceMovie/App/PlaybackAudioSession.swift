import AVFAudio
import Foundation

/// 播放所需的后台音频会话配置。
///
/// 在 App 启动与每次进入播放前调用 `activate()`；`Info.plist` 中的
/// `UIBackgroundModes: audio` 与这里的 category 共同决定锁屏后是否继续出声。
/// `setActive` 在切换路由或抢占其他 App 的音频时可能阻塞上百毫秒，
/// 因此放到后台任务执行，避免卡住主线程。
enum PlaybackAudioSession {
    static func activate() async throws {
        // 用默认优先级执行：AVFAudio 内部还会等待自己的默认队列，
        // 若这里抬高到 userInitiated，会被 Thread Performance Checker 判为优先级反转。
        try await Task.detached(priority: .medium) {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
        }.value
    }

    static func deactivate() async throws {
        try await Task.detached(priority: .medium) {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        }.value
    }
}
