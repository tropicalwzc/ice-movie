import AVFoundation
import CFFmpeg
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
        /// 已投递到主线程、尚未 consume 的样本数；用于定位显示层背压。
        public var pendingDispatch = 0
    }

    /// 跨越主线程边界时用来包裹非 Sendable 的样本。
    private struct SampleBox: @unchecked Sendable {
        let buffer: CMSampleBuffer
        let presentationTime: Double
        let isKeyframe: Bool
    }

    private weak var layer: AVSampleBufferDisplayLayer?
    private let clock: MasterClock
    private let lock = NSLock()
    private var timebase: CMTimebase?
    /// 最近排入的帧。SwiftUI 旋转/重建 VideoSurface 或显示层恢复时，
    /// 新层需要立刻有内容，否则会黑屏到下一次播放泵送帧。
    private var recent: [CMSampleBuffer] = []
    /// 解码失败后只接受下一个关键帧，避免坏帧在“恢复→重灌”之间反复刷屏。
    private var needsKeyframe = false
    private var lastRefreshAt: Double = 0
    private var refreshRetryTask: Task<Void, Never>?
    /// 每次刷新/seek 递增；旧重试唤醒后据此作废。
    private var refreshGeneration = 0
    /// 新层绑定或解码故障时，请播放引擎从当前位置重新解出一段关键帧。
    public var onNeedsRefresh: ((Double) -> Void)?
    private var stats = Metrics()
    private var loggedFirstSample = false
    private var observers: [NSObjectProtocol] = []
    private var needsRecovery = false
    private var pendingRecoveryReason: String?

    public init(clock: MasterClock) {
        self.clock = clock
    }

    deinit {
        refreshRetryTask?.cancel()
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
        lock.unlock()

        let created = makeTimebase()
        lock.lock()
        timebase = created
        recent.removeAll()
        needsKeyframe = true
        lock.unlock()

        layer.videoGravity = .resizeAspect
        layer.controlTimebase = created
        observe(layer: layer)
        refreshOrRetry(reason: "显示层绑定")
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
        lock.withLock {
            needsKeyframe = true
            recent.removeAll()
        }
        refreshOrRetry(reason: "显示层恢复")
    }

    /// 请求从当前位置重新解码。返回 false 表示被 1 秒限流挡住，需要延迟重试；
    /// 不能只设置 needsKeyframe 却不发 seek，否则新显示层会一直等关键帧。
    @MainActor
    @discardableResult
    private func refreshFromCurrentPosition(reason: String) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastRefreshAt >= 1.0 else { return false }
        lastRefreshAt = now
        Log.info(
            .render,
            "\(reason)，从当前位置重新解码 \(String(format: "%.2f", clock.currentTime))s"
        )
        onNeedsRefresh?(clock.currentTime)
        return true
    }

    @MainActor
    private func refreshOrRetry(reason: String) {
        refreshRetryTask?.cancel()
        let generation = lock.withLock { () -> Int in
            refreshGeneration += 1
            return refreshGeneration
        }
        // 关键帧已经到达并清掉 needsKeyframe 时，不需要再 seek。
        guard lock.withLock({ needsKeyframe }) else {
            refreshRetryTask = nil
            return
        }
        if refreshFromCurrentPosition(reason: reason) {
            refreshRetryTask = nil
            return
        }
        let delay = max(0.05, 1.0 - (ProcessInfo.processInfo.systemUptime - lastRefreshAt))
        let expectedLayer = layer
        refreshRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self,
                  self.lock.withLock({ self.needsKeyframe && self.refreshGeneration == generation }),
                  let current = self.layer, current === expectedLayer else { return }
            self.refreshRetryTask = nil
            _ = self.refreshFromCurrentPosition(reason: reason + "（延迟重试）")
        }
    }

    /// 视频包队列丢包后调用：压缩帧依赖链已断，必须从下一个关键帧重新开始。
    @MainActor
    public func invalidateForPacketDrop() {
        lock.withLock {
            needsKeyframe = true
            recent.removeAll()
            stats.flushes += 1
        }
        guard let layer else { return }
        layer.flush()
        refreshOrRetry(reason: "视频包队列丢包")
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

    public func enqueue(_ sample: CMSampleBuffer, isKeyframe: Bool = false) {
        let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
        let box = SampleBox(
            buffer: sample,
            presentationTime: presentation.isValid ? presentation.seconds : 0,
            isKeyframe: isKeyframe
        )

        let unbound: Bool = lock.withLock {
            if needsKeyframe, !isKeyframe {
                return true
            }
            if isKeyframe {
                needsKeyframe = false
                recent.removeAll()
            }
            // 新显示层必须从关键帧开始解码；保留“最近关键帧 + 后续帧”，
            // 旋转/重建/解码恢复时才有可解码的起点。
            recent.append(sample)
            while recent.count > 120 {
                if recent.count > 1 {
                    recent.remove(at: 1)
                } else {
                    recent.removeFirst()
                }
            }
            return layer == nil
        }
        guard !unbound else { return }
        lock.withLock { stats.pendingDispatch += 1 }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.consume(box)
            }
        }
    }

    @MainActor
    private func consume(_ box: SampleBox) {
        lock.withLock { stats.pendingDispatch = max(0, stats.pendingDispatch - 1) }
        guard let layer else { return }

        lock.lock()
        // 恢复后只放行关键帧；已经排在主队列里的旧帧直接丢弃。
        if needsKeyframe, !box.isKeyframe {
            lock.unlock()
            return
        }
        if box.isKeyframe {
            needsKeyframe = false
        }
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

        var recovered = false
        if let recoveryReason {
            recover(layer: layer, reason: recoveryReason)
            recovered = true
        } else if layer.status == .failed {
            let error = layer.error?.localizedDescription ?? "未知"
            recover(layer: layer, reason: "显示层状态失败：\(error)")
            recovered = true
        } else if layer.requiresFlushToResumeDecoding {
            recover(layer: layer, reason: "requiresFlushToResumeDecoding")
            lock.withLock { stats.flushes += 1 }
            recovered = true
        }

        if recovered {
            let drop = lock.withLock { () -> Bool in
                if needsKeyframe, !box.isKeyframe {
                    stats.enqueued = max(0, stats.enqueued - 1)
                    return true
                }
                if box.isKeyframe { needsKeyframe = false }
                return false
            }
            guard !drop else { return }
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

    /// 显示层是否已绑定；未绑定时播放泵不能等待视频水位。
    public var isBound: Bool {
        lock.withLock { layer != nil }
    }

    /// 未绑定时缓存的待发帧数（仅用于起播判断）。
    public var pendingCount: Int {
        lock.withLock { recent.count }
    }

    /// 未绑定时待发帧相对时钟的领先量，避免播放泵把缓存帧冲掉。
    public var pendingAhead: Double {
        lock.withLock {
            guard let last = recent.last else { return 0 }
            let pts = CMSampleBufferGetPresentationTimeStamp(last).seconds
            return max(0, pts - clock.currentTime)
        }
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

    /// 显示层当前状态，供压力验收报告定位黑屏/解码问题。
    public var statusDescription: String {
        lock.withLock {
            guard let layer else { return "unbound" }
            switch layer.status {
            case .failed:
                return "failed:\(layer.error?.localizedDescription ?? "unknown")"
            case .rendering:
                return "rendering"
            case .unknown:
                return "unknown"
            @unknown default:
                return "unknown"
            }
        }
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
        // 用户 seek 后旧刷新重试必须作废，否则冷却结束会对新位置再发一次 seek。
        refreshGeneration += 1
        recent.removeAll()
        needsKeyframe = true
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


/// 视频包供给管线：播放泵只负责读包和移交给本队列，
/// 压缩样本的封装与显示层投递在独立串行线程完成，避免 4K 大包阻塞音频解码。
///
/// 所有权：`enqueue` 使用 `av_packet_move_ref` 接管 AVPacket，调用方不能再 unref；
/// 队列和 worker 负责最终 `av_packet_free`。seek 时 flush 并递增 generation，
/// worker 只处理当前 generation 的包。
final class VideoPacketPipeline: @unchecked Sendable {
    struct Metrics: Sendable {
        var enqueued = 0
        var processed = 0
        var dropped = 0
        var queueDepth = 0
        var maxQueueDepth = 0
        var queueBytes = 0
    }

    private struct Item {
        let packet: UnsafeMutablePointer<AVPacket>
        let generation: Int
        let bytes: Int
    }

    private let condition = NSCondition()
    private let maxPackets: Int
    private let maxBytes: Int
    private let handler: (UnsafeMutablePointer<AVPacket>, Int) -> Void

    private var queue: [Item] = []
    private var bytes = 0
    private var generation = 0
    private var stopped = false
    private var worker: Thread?
    private var stats = Metrics()
    private var waitingForKeyframe = false
    /// 队列溢出导致丢包时通知播放层刷新解码器；由引擎设置。
    var onOverflow: (() -> Void)?

    init(
        maxPackets: Int = 96,
        maxBytes: Int = 96 * 1024 * 1024,
        handler: @escaping (UnsafeMutablePointer<AVPacket>, Int) -> Void
    ) {
        self.maxPackets = max(1, maxPackets)
        self.maxBytes = max(1, maxBytes)
        self.handler = handler

        let thread = Thread { [weak self] in self?.run() }
        thread.name = "icemovie.video.packets"
        thread.qualityOfService = .userInitiated
        worker = thread
        thread.start()
    }

    deinit {
        stop()
    }

    var metrics: Metrics {
        condition.lock()
        defer { condition.unlock() }
        return stats
    }

    /// 当前 generation；seek 时递增。
    var currentGeneration: Int {
        condition.lock()
        defer { condition.unlock() }
        return generation
    }

    func isCurrent(_ value: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return value == generation
    }

    /// 移交视频包所有权；返回 false 表示包被丢弃或管线已停止。
    @discardableResult
    func enqueue(_ packet: UnsafeMutablePointer<AVPacket>) -> Bool {
        guard let owned = av_packet_alloc() else {
            // 这是泵复用的 AVPacket，只清空引用，不能 free 结构体。
            av_packet_unref(packet)
            return false
        }
        av_packet_move_ref(owned, packet)
        let size = max(0, Int(owned.pointee.size))
        let isKeyframe = owned.pointee.flags & AV_PKT_FLAG_KEY != 0

        var victims: [Item] = []
        var notifyOverflow = false
        condition.lock()
        guard !stopped else {
            condition.unlock()
            freePacket(owned)
            return false
        }

        if waitingForKeyframe, !isKeyframe {
            stats.dropped += 1
            condition.unlock()
            freePacket(owned)
            return false
        }
        if isKeyframe { waitingForKeyframe = false }

        if size > maxBytes {
            stats.dropped += 1
            waitingForKeyframe = true
            condition.unlock()
            freePacket(owned)
            onOverflow?()
            return false
        }

        if queue.count >= maxPackets || bytes + size > maxBytes {
            // 丢一个包会破坏压缩帧参考链；整段队列作废，等待下一个关键帧重启。
            victims = queue
            queue.removeAll()
            bytes = 0
            stats.dropped += victims.count
            stats.queueDepth = 0
            stats.queueBytes = 0
            waitingForKeyframe = true
            notifyOverflow = true
        }

        if waitingForKeyframe {
            if !isKeyframe {
                stats.dropped += 1
                condition.unlock()
                freePacket(owned)
                for item in victims { freePacket(item.packet) }
                if notifyOverflow { onOverflow?() }
                return false
            }
            waitingForKeyframe = false
        }

        queue.append(Item(packet: owned, generation: generation, bytes: size))
        bytes += size
        stats.enqueued += 1
        stats.queueDepth = queue.count
        stats.maxQueueDepth = max(stats.maxQueueDepth, queue.count)
        stats.queueBytes = bytes
        condition.signal()
        condition.unlock()

        for item in victims { freePacket(item.packet) }
        if notifyOverflow { onOverflow?() }
        return true
    }

    /// 跳转时清空待处理包并让旧 worker 结果失效。
    func flush() {
        condition.lock()
        generation += 1
        waitingForKeyframe = false
        let victims = queue
        queue.removeAll()
        bytes = 0
        stats.queueDepth = 0
        stats.queueBytes = 0
        condition.broadcast()
        condition.unlock()
        for item in victims {
            freePacket(item.packet)
        }
    }

    func stop() {
        condition.lock()
        guard !stopped else {
            condition.unlock()
            return
        }
        stopped = true
        let victims = queue
        queue.removeAll()
        bytes = 0
        stats.queueDepth = 0
        stats.queueBytes = 0
        condition.broadcast()
        condition.unlock()
        for item in victims {
            freePacket(item.packet)
        }
    }

    // MARK: - 内部

    private func run() {
        while true {
            condition.lock()
            while queue.isEmpty && !stopped {
                condition.wait()
            }
            if queue.isEmpty && stopped {
                condition.unlock()
                return
            }
            let item = queue.removeFirst()
            bytes -= item.bytes
            stats.queueDepth = queue.count
            stats.queueBytes = bytes
            let current = generation
            condition.unlock()

            if item.generation == current {
                handler(item.packet, item.generation)
                condition.lock()
                stats.processed += 1
                condition.unlock()
            } else {
                condition.lock()
                stats.dropped += 1
                condition.unlock()
            }
            freePacket(item.packet)
        }
    }

    private func freePacket(_ packet: UnsafeMutablePointer<AVPacket>) {
        var owned: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&owned)
    }
}
