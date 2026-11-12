import UIKit

/// 全局屏幕方向锁。
///
/// iPhone：媒体库保持竖屏，进入全屏视频时切到横屏（即使系统开了方向锁定），
/// 退出播放回到竖屏。iPad：始终跟随系统。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        ThumbnailPrewarmBackground.register()
        return true
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedMask: UIInterfaceOrientationMask = .all

    static var orientationMask: UIInterfaceOrientationMask {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedMask
        }
        set {
            lock.lock()
            storedMask = newValue
            lock.unlock()
        }
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.orientationMask
    }
}
