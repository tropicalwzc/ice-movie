import Foundation

/// 播放跳转步长：底部快进/快退按钮、双击屏幕左右、键盘方向键与锁屏控制共用。
///
/// 默认 90 秒：长片里一次跳转就能跨过片头或一段剧情，又不会像分钟级步长
/// 那样一下跳得太远，比 10 秒更适合日常观看。
public enum PlaybackSeek {
    /// 单次快进/快退的秒数。
    public static let step: Double = 90

    public static var forwardSymbol: String { "goforward.90" }
    public static var backwardSymbol: String { "gobackward.90" }

    public static func label(forward: Bool) -> String {
        "\(forward ? "快进" : "快退") \(Int(step)) 秒"
    }
}
