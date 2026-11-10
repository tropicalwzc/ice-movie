import IceCore
import PersistenceKit
import SwiftUI

@main
struct IceMovieApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // iPhone 媒体库固定竖屏；播放时由 AppOrientation 切到横屏。
        AppDelegate.orientationMask = UIDevice.current.userInterfaceIdiom == .phone
            ? .portrait
            : .all

        // 便于排查：以 -logDebug 启动即把日志级别下调到 debug。
        if ProcessInfo.processInfo.arguments.contains("-logDebug") {
            Log.minimumLevel = .debug
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: [SavedHost.self, PlaybackProgressRecord.self])
        .commands {
            CommandMenu("播放") {
                Button("播放 / 暂停") {
                    PlayerCommands.shared.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("快退 10 秒") {
                    PlayerCommands.shared.seek(by: -10)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])

                Button("快进 10 秒") {
                    PlayerCommands.shared.seek(by: 10)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])

                Divider()

                Button("切换全屏") {
                    PlayerCommands.shared.toggleFullscreen()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }
    }
}
