import Foundation
import IceCore
import PersistenceKit
import SwiftUI
import ThumbnailKit

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

        // 升级后首次启动立即把旧版本遗留的超大缓存收敛到新预算。
        CacheMaintenance.runAtLaunch()
        if ProcessInfo.processInfo.arguments.contains("-cacheReport") {
            emitCacheReport()
        }
    }

    /// 真机排查：`-cacheReport` 把各缓存模块的实际占用写到 stdout，
    /// 可通过 `devicectl device process launch --console` 直接读取。
    private func emitCacheReport() {
        Task.detached(priority: .utility) {
            if let thumbnails = try? ThumbnailStore() {
                await thumbnails.evictIfNeeded()
            }
            let report = CacheUsageReport.text()
            FileHandle.standardOutput.write(Data((report + "\n").utf8))
            await MainActor.run {
                Log.info(.app, "缓存占用\n\(report)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(
            for: [
                SavedHost.self,
                PlaybackProgressRecord.self,
                PhotoLibraryTarget.self,
                FavoritePhoto.self,
            ]
        )
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
