import Foundation

/// 播放主时钟。
///
/// 以宿主单调时钟推进，音频通路就绪后由音频渲染位置定期校正（design.md D3）。
/// 时钟本身不依赖 AVFoundation，因此可以在模拟器里用假时间源做单元测试。
///
/// 校正策略：偏差小于容差时忽略，避免测量噪声让时间来回抖动；
/// 超过容差时直接把锚点移到音频位置。音频是主时基，画面与字幕跟随它，
/// 单次跳变的上限是容差量级，肉眼不可察。
public final class MasterClock: @unchecked Sendable {
    public struct Snapshot: Sendable, Equatable {
        public let time: Double
        public let rate: Float
        public let isPlaying: Bool
    }

    private let lock = NSLock()
    private let now: @Sendable () -> Double

    /// 锚点：`anchorTime` 对应 `anchorHost` 这一刻的媒体时间。
    private var anchorTime: Double = 0
    private var anchorHost: Double
    private var storedRate: Float = 1
    private var playing = false

    private var lastDrift: Double = 0
    private var corrections: Int = 0

    public init(now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        anchorHost = now()
    }

    // MARK: - 读取

    public var snapshot: Snapshot {
        lock.withLock {
            Snapshot(time: currentLocked(), rate: storedRate, isPlaying: playing)
        }
    }

    public var currentTime: Double { snapshot.time }

    public var rate: Float { lock.withLock { storedRate } }

    public var isPlaying: Bool { lock.withLock { playing } }

    /// 最近一次校正的偏差，正值表示音频走在时钟前面。
    public var lastSyncDrift: Double { lock.withLock { lastDrift } }

    public var correctionCount: Int { lock.withLock { corrections } }

    // MARK: - 控制

    public func play() {
        lock.withLock {
            guard !playing else { return }
            anchorHost = now()
            playing = true
        }
    }

    public func pause() {
        lock.withLock {
            guard playing else { return }
            anchorTime = currentLocked()
            playing = false
        }
    }

    /// 跳转：立即把时钟移到目标位置，不产生插值。
    public func seek(to time: Double) {
        lock.withLock {
            anchorTime = max(0, time)
            anchorHost = now()
            lastDrift = 0
        }
    }

    /// 改变速率。当前时刻保持不变，之后按新速率推进。
    public func setRate(_ rate: Float) {
        let clamped = min(max(rate, 0.25), 4)
        lock.withLock {
            anchorTime = currentLocked()
            anchorHost = now()
            storedRate = clamped
        }
    }

    /// 用音频渲染位置校正时钟。
    public func sync(to audioTime: Double, tolerance: Double = 0.05) {
        lock.withLock {
            let current = currentLocked()
            let drift = audioTime - current
            lastDrift = drift
            guard abs(drift) > tolerance else { return }
            corrections += 1
            anchorTime = max(0, audioTime)
            anchorHost = now()
        }
    }

    // MARK: - 内部

    private func currentLocked() -> Double {
        guard playing else { return anchorTime }
        return max(0, anchorTime + (now() - anchorHost) * Double(storedRate))
    }
}
