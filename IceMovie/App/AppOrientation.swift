import IceCore
import UIKit

/// 屏幕方向控制。
///
/// iPhone 默认允许竖屏；进入全屏视频时主动请求横屏，这样即使系统开了
/// “竖排方向锁定”也能横屏观看；退出播放再回到竖屏。iPad 保持系统默认行为。
@MainActor
enum AppOrientation {
    private static var generation = 0

    static func request(
        _ orientations: UIInterfaceOrientationMask,
        delay: Duration = .milliseconds(80),
        phoneOnly: Bool = true
    ) {
        if phoneOnly, UIDevice.current.userInterfaceIdiom != .phone { return }
        generation += 1
        let token = generation
        AppDelegate.orientationMask = orientations
        Task { @MainActor in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard token == generation else { return }
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first else {
                Log.error(.app, "旋转失败：没有可用场景")
                return
            }
            if let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController {
                var controller: UIViewController? = root
                while let current = controller {
                    current.setNeedsUpdateOfSupportedInterfaceOrientations()
                    controller = current.presentedViewController
                }
            }
            Log.info(.app, "请求屏幕方向 mask=\(orientations.rawValue)")
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { error in
                Log.error(.app, "旋转失败 \(error.localizedDescription)")
            }
        }
    }
}
