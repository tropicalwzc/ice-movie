import Foundation
import IceCore
import RenderKit

/// 播放命令总线：把菜单栏命令与键盘快捷键转给当前播放器。
/// 菜单栏只能拿到全局命令，不能直接访问 SwiftUI 的视图状态，因此用这一层桥接。
@MainActor
final class PlayerCommands {
    static let shared = PlayerCommands()

    private var engine: PlaybackEngine?
    private var activeToken: UUID?
    private var toggleFullscreenHandler: (() -> Void)?

    var isAvailable: Bool { engine != nil }

    func attach(
        engine: PlaybackEngine,
        toggleFullscreen: (() -> Void)?
    ) -> UUID {
        let token = UUID()
        activeToken = token
        self.engine = engine
        self.toggleFullscreenHandler = toggleFullscreen
        return token
    }

    func detach(token: UUID) {
        guard activeToken == token else { return }
        activeToken = nil
        engine = nil
        toggleFullscreenHandler = nil
    }

    func togglePlayPause() {
        guard let engine else { return }
        if engine.isPlaying {
            engine.pause()
        } else {
            engine.play()
        }
        Log.info(.app, "菜单/快捷键：播放暂停切换")
    }

    func seek(by seconds: Double) {
        guard let engine else { return }
        engine.seek(to: engine.clock.currentTime + seconds)
        Log.info(.app, "菜单/快捷键：跳转 \(String(format: "%+.0f", seconds))s")
    }

    func toggleFullscreen() {
        guard let toggleFullscreenHandler else { return }
        toggleFullscreenHandler()
        Log.info(.app, "菜单/快捷键：切换全屏")
    }

}
