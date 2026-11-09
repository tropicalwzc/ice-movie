import AVFoundation
import CoreMedia
import Foundation
import IceCore

/// 视频输出：持有 `AVSampleBufferDisplayLayer`，用主时钟驱动它的 `controlTimebase`。
///
/// 显示层在 SDK 里标了 `NS_SWIFT_UI_ACTOR`，只能在主 actor 上调用；而拉流线程不是主线程。
/// 因此这里做了一层「投递 + 出队」：泵线程把样本投到主队列，主线程按 FIFO 再 `enqueue`
/// 到显示层。顺序由主队列保证，样本本身不解码，投递开销可以忽略。
///
/// 显示层内部调用 VideoToolbox 硬解。时钟与显示层都基于宿主时钟，因此不需要逐帧设置
/// 播放时间，只在偏差超过 100 ms 或状态变化（播放/暂停/跳转）时同步一次。
public final class VideoRenderer: @unchecked Sendable {
    public struct Metrics: Sendable {
        public var enqueued = 0
        public var droppedWhileUnbound = 0
        public var flushes = 0
        public var recoveries = 0
        public var lastEnqueuedTime: Double = 0
        public var lastRecoveryReason: String?
        public var lastRecoveryPosition: Double = 0
    }

    /// 跨越主线程边界时用来包裹非 Sendable 的样本。
    private struct SampleBox: @unchecked Sendable {
        let buffer: CMSampleBuffer
        let presentationTime: Double
    }

    private weak var layer: AVSampleBufferDisplayLayer?
    private let clock: MasterClock
    private let lock = NSLock()
    private var timebase: CMTimebase?
    private var pending: [CMSampleBuffer] = []
    private var stats = Metrics()
    private var loggedFirstSample = false
    private var observers: [NSObjectProtocol] = []
    private var needsRecovery = false
    private var pendingRecoveryReason: String?

    public init(clock: MasterClock) {
        self.clock = clock
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - 绑定

    /// 由视图在创建时（主线程）调用。把此前缓存的样本补发出去。
    @MainActor
    public func bind(_ layer: AVSampleBufferDisplayLayer) {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()

        lock.lock()
        self.layer = layer
        needsRecovery = false
        pendingRecoveryReason = nil
        let backlog = pending
        pending.removeAll()
        lock.unlock()

        let created = makeTimebase()
        lock.lock()
        timebase = created
        lock.unlock()

        layer.videoGravity = .resizeAspect
        layer.controlTimebase = created
        for sample in backlog {
            layer.enqueue(sample)
        }
        if !backlog.isEmpty {
            Log.info(.render, "显示层绑定，补发 \(backlog.count) 帧")
        }

        observe(layer: layer)
    }

    private func observe(layer: AVSampleBufferDisplayLayer) {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: .AVSampleBufferDisplayLayerFailedToDecode,
                object: layer,
                queue: .main
            ) { [weak self] notification in
                let error = notification.userInfo?[
                    AVSampleBufferDisplayLayerFailedToDecodeNotificationErrorKey
                ] as? Error
                MainActor.assumeIsolated {
                    self?.requestRecovery(
                        reason: "解码失败：\(error?.localizedDescription ?? "未知")"
                    )
                }
            }
        )
        observers.append(
            center.addObserver(
                forName: .AVSampleBufferDisplayLayerRequiresFlushToResumeDecodingDidChange,
                object: layer,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let layer = self.layer, layer.requiresFlushToResumeDecoding else {
                        return
                    }
                    self.requestRecovery(reason: "requiresFlushToResumeDecoding")
                }
            }
        )
    }

    @MainActor
    private func requestRecovery(reason: String) {
        lock.lock()
        needsRecovery = true
        pendingRecoveryReason = reason
        stats.lastRecoveryReason = reason
        stats.lastRecoveryPosition = clock.currentTime
        lock.unlock()
        Log.notice(
            .render,
            "显示层需要恢复 原因=\(reason) 位置=\(String(format: "%.2f", clock.currentTime))s"
        )
    }

    @MainActor
    private func recover(layer: AVSampleBufferDisplayLayer, reason: String) {
        Log.notice(
            .render,
            "显示层恢复 原因=\(reason) 位置=\(String(format: "%.2f", clock.currentTime))s"
        )
        layer.flush()
        let rebuilt = makeTimebase()
        lock.lock()
        timebase = rebuilt
        stats.recoveries += 1
        stats.lastRecoveryReason = reason
        stats.lastRecoveryPosition = clock.currentTime
        lock.unlock()
        layer.controlTimebase = rebuilt
        Log.info(.render, "显示层时间基已重建，下一帧重灌参数集")
    }

    private func makeTimebase() -> CMTimebase? {
        var created: CMTimebase?
        let status = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &created
        )
        guard status == noErr, let created else {
            Log.error(.render, "创建时间基失败 code=\(status)")
            return nil
        }
        CMTimebaseSetTime(created, time: CMTime(seconds: clock.currentTime, preferredTimescale: 600))
        CMTimebaseSetRate(created, rate: clock.isPlaying ? Double(clock.rate) : 0)
        return created
    }

    // MARK: - 排入

    public func enqueue(_ sample: CMSampleBuffer) {
        let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
        let box = SampleBox(
            buffer: sample,
            presentationTime: presentation.isValid ? presentation.seconds : 0
        )

        let unbound: Bool = lock.withLock { layer == nil }
        if unbound {
            lock.lock()
            if pending.count < 120 {
                pending.append(sample)
            } else {
                stats.droppedWhileUnbound += 1
            }
            lock.unlock()
            return
        }

        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.consume(box)
            }
        }
    }

    @MainActor
    private func consume(_ box: SampleBox) {
        guard let layer else { return }

        lock.lock()
        stats.enqueued += 1
        stats.lastEnqueuedTime = max(stats.lastEnqueuedTime, box.presentationTime)
        let first = !loggedFirstSample
        loggedFirstSample = true
        lock.unlock()

        if first {
            Log.info(.render, "首帧入队 pts=\(String(format: "%.3f", box.presentationTime))s")
        }

        var recoveryReason: String?
        lock.lock()
        if needsRecovery {
            recoveryReason = pendingRecoveryReason ?? "通知触发"
            needsRecovery = false
            pendingRecoveryReason = nil
        }
        lock.unlock()

        if let recoveryReason {
            recover(layer: layer, reason: recoveryReason)
        } else if layer.status == .failed {
            let error = layer.error?.localizedDescription ?? "未知"
            recover(layer: layer, reason: "显示层状态失败：\(error)")
        } else if layer.requiresFlushToResumeDecoding {
            recover(layer: layer, reason: "requiresFlushToResumeDecoding")
            lock.withLock { stats.flushes += 1 }
        }

        layer.enqueue(box.buffer)
    }

    /// 自检用：注入一次显示层恢复，验证时间基重建与参数集重灌路径。
    @MainActor
    public func simulateDecodeFailureForTesting() {
        requestRecovery(reason: "测试注入解码失败")
    }

    /// 显示层时间基与主时钟的偏差，用于衡量音画是否漂移。
    public var timebaseOffset: Double {
        guard let timebase else { return 0 }
        return CMTimebaseGetTime(timebase).seconds - clock.currentTime
    }

    /// 已排入数据相对当前时钟的领先量，用于限速。
    public var bufferedAhead: Double {
        lock.withLock {
            guard stats.lastEnqueuedTime > 0 else { return 0 }
            return max(0, stats.lastEnqueuedTime - clock.currentTime)
        }
    }

    public var metrics: Metrics {
        lock.withLock { stats }
    }

    // MARK: - 控制

    /// 与主时钟对齐：播放时让时间基自由运行，暂停时停住，偏差过大时纠正。
    public func syncTimebase() {
        guard let timebase else { return }
        let target = clock.currentTime
        let current = CMTimebaseGetTime(timebase).seconds
        let playing = clock.isPlaying

        _ = CMTimebaseSetRate(timebase, rate: playing ? Double(clock.rate) : 0)
        if !playing {
            CMTimebaseSetTime(timebase, time: CMTime(seconds: target, preferredTimescale: 600))
            return
        }
        if abs(current - target) > 0.1 {
            Log.debug(
                .render,
                "显示层时间基校正 当前=\(String(format: "%.3f", current))s 目标=\(String(format: "%.3f", target))s"
            )
            CMTimebaseSetTime(timebase, time: CMTime(seconds: target, preferredTimescale: 600))
        }
    }

    /// 跳转：清空显示层里尚未播放的样本，并把时间基移到新位置。
    public func reset(to seconds: Double) {
        lock.lock()
        pending.removeAll()
        stats.lastEnqueuedTime = 0
        let timebase = self.timebase
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.layer?.flush()
            }
        }
        if let timebase {
            CMTimebaseSetTime(timebase, time: CMTime(seconds: seconds, preferredTimescale: 600))
        }
        Log.info(.render, "视频跳转 位置=\(String(format: "%.2f", seconds))s")
    }
}
