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
        /// 回放缓存因"连续段超出窗口"整段重建的次数。频繁重建意味着
        /// 关键帧间隔大于缓存窗口，旋转/重建会退化为一次刷新 seek。
        public var recentRestarts = 0
    }

    /// 跨越主线程边界时用来包裹非 Sendable 的样本。
    private struct SampleBox: @unchecked Sendable {
        let buffer: CMSampleBuffer
        let presentationTime: Double
        let isKeyframe: Bool
        /// 入队序号：帧每次进入 enqueue 就 +1（含被丢弃的帧）。
        /// 回放前逐帧校验它连续，才能确认快照里没有缺帧。
        let sequence: UInt64
    }

    private weak var layer: AVSampleBufferDisplayLayer?
    private let clock: MasterClock
    private let lock = NSLock()
    private var timebase: CMTimebase?
    /// 最近排入的帧。SwiftUI 旋转/重建 VideoSurface 或显示层恢复时，
    /// 新层需要立刻有内容，否则会黑屏到下一次播放泵送帧。
    ///
    /// 只允许保存「从关键帧开始的一段连续帧」：中间缺一帧，回放就会因
    /// 参考帧缺失解码失败。因此窗口满了不能抽帧缩容，只能整段作废。
    private var recent: [SampleBox] = []
    /// 缓存段的上限帧数。超过后整段丢弃，等下一个关键帧重建。
    private let recentLimit = 120
    /// 缓存是否在等关键帧重新开始。与 `needsKeyframe` 不同：它只影响
    /// “要不要往 recent 里放”，不会拦下已绑定显示层的正常送帧。
    private var recentAwaitingKeyframe = true
    /// 全局入队序号，用来判定快照是否逐帧连续。
    private var enqueueSequence: UInt64 = 0
    /// 解码失败后只接受下一个关键帧，避免坏帧在“恢复→重灌”之间反复刷屏。
    private var needsKeyframe = false
    private var lastRefreshAt: Double = 0
    private var refreshRetryTask: Task<Void, Never>?
    /// 每次刷新/seek 递增；旧重试唤醒后据此作废。
    private var refreshGeneration = 0
    /// 绑定代次：bind() 接管 recent 缓存时递增。此前投递到主队列、
    /// 尚未 consume 的帧已由 bind() 从 recent 回放，代次不匹配的旧分发
    /// 直接丢弃，保证每帧只通过一种路径（回放或 consume）进入显示层。
    private var bindingGeneration = 0
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
        Log.info(.render, "渲染器释放")
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
        let pending = recent
        recent.removeAll()
        // 快照被取走后缓存从零开始：新段必须有新的关键帧做起点，
        // 否则会存下一段"开头不是关键帧"的帧，永远无法回放。
        recentAwaitingKeyframe = true
        // 快照接管后，此前在飞的 consume 分发作废：这些帧已包含在 pending
        // 里由下面的回放路径入队，旧分发再执行会把同一帧送进新层两次
        //（重复解码、统计双计、显示层背压）。
        bindingGeneration &+= 1
        // 只有「首帧是关键帧且序号逐帧连续」的快照才能直接回放。缓存超窗
        // 重建、丢包、恢复清空都会在段中留下缺口，回放这种序列会让显示层
        // 因参考帧缺失解码失败，进而触发恢复与二次 seek —— 正是回放要避免的。
        // 不可回放时置 needsKeyframe，refreshOrRetry 才会真正发出刷新请求。
        let replayable = Self.isReplayable(
            firstIsKeyframe: pending.first?.isKeyframe ?? false,
            sequences: pending.map(\.sequence)
        )
        needsKeyframe = !replayable
        lock.unlock()

        let created = makeTimebase()
        lock.lock()
        timebase = created
        lock.unlock()

        layer.videoGravity = .resizeAspect
        layer.controlTimebase = created
        observe(layer: layer)

        // 起播前绑定：resume seek 已经把解封装器放到目标位置，播放泵会送来
        // 第一个关键帧；此时再发一次 refresh seek 只会制造二次跳转和额外缓冲。
        if !clock.isPlaying, pending.isEmpty {
            Log.info(
                .render,
                "显示层绑定，等待播放泵送关键帧 位置=\(String(format: "%.2f", clock.currentTime))s"
            )
            return
        }

        // 播放开始后图层才绑定时，播放泵已缓存了「关键帧 + 其后的连续帧」。
        // 直接补发这些帧，避免为了拿关键帧再发一次 seek，造成起播二次跳转。
        if replayable, let first = pending.first {
            lock.withLock {
                needsKeyframe = false
                stats.enqueued += pending.count
                stats.lastEnqueuedTime = max(
                    stats.lastEnqueuedTime,
                    pending.last?.presentationTime ?? 0
                )
            }
            for box in pending {
                layer.enqueue(box.buffer)
            }
            Log.info(
                .render,
                "显示层绑定，回放缓存帧 \(pending.count) 帧 "
                    + "起点=\(String(format: "%.2f", first.presentationTime))s"
            )
            return
        }
        let restarts = lock.withLock { stats.recentRestarts }
        Log.info(
            .render,
            "显示层绑定，缓存不可回放 帧数=\(pending.count) "
                + "首帧关键帧=\(pending.first?.isKeyframe == true) 重建次数=\(restarts)"
        )
        refreshOrRetry(reason: "显示层绑定")
    }

    /// 快照能否直接回放：首帧是关键帧，且入队序号逐帧连续。
    ///
    /// 序号把"缓存超窗重建、丢包、恢复清空"造成的缺口都算在内，比只看
    /// 首帧是否关键帧更严格；连续段内少一帧就会因参考帧缺失解码失败。
    static func isReplayable(firstIsKeyframe: Bool, sequences: [UInt64]) -> Bool {
        guard firstIsKeyframe else { return false }
        guard sequences.count > 1 else { return true }
        for index in 1..<sequences.count
        where sequences[index] != sequences[index - 1] &+ 1 {
            return false
        }
        return true
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
            // 缓存段被清空后必须重新以关键帧开头，否则会存下一段
            // 无法回放的半截序列。
            recentAwaitingKeyframe = true
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

    /// 延迟刷新是否仍然必要：关键帧可能已经到达，或期间发生了新的 seek/刷新。
    static func shouldPerformDelayedRefresh(
        needsKeyframe: Bool,
        currentGeneration: Int,
        capturedGeneration: Int
    ) -> Bool {
        needsKeyframe && currentGeneration == capturedGeneration
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
            guard !Task.isCancelled, let self else { return }
            let shouldRefresh = self.lock.withLock {
                Self.shouldPerformDelayedRefresh(
                    needsKeyframe: self.needsKeyframe,
                    currentGeneration: self.refreshGeneration,
                    capturedGeneration: generation
                )
            }
            guard shouldRefresh,
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
            recentAwaitingKeyframe = true
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
        var dispatchGeneration = 0
        var sampleBox: SampleBox?
        let unbound: Bool = lock.withLock {
            if needsKeyframe, !isKeyframe {
                return true
            }
            enqueueSequence &+= 1
            let box = SampleBox(
                buffer: sample,
                presentationTime: presentation.isValid ? presentation.seconds : 0,
                isKeyframe: isKeyframe,
                sequence: enqueueSequence
            )
            sampleBox = box
            if isKeyframe {
                needsKeyframe = false
                // 新的关键帧是唯一可接受的缓存起点。
                recent.removeAll()
                recentAwaitingKeyframe = false
            }
            if !recentAwaitingKeyframe {
                // 只缓存「从关键帧开始的连续段」：上面的 gate 已把等待期内的
                // 非关键帧挡在外面，因此这里 append 的帧不会在段中留缺口。
                recent.append(box)
                if recent.count > recentLimit {
                    // 连续段已超出窗口。不能删中间帧缩容——删掉关键帧后的
                    // 第 1 帧会让段内出现越来越大的缺口，回放到显示层必然
                    // 因参考帧缺失解码失败。整段作废，等下一个关键帧重建；
                    // 期间旋转/重建由 bind 的连续性校验改走 refreshOrRetry。
                    recent.removeAll()
                    recentAwaitingKeyframe = true
                    stats.recentRestarts += 1
                }
            }
            dispatchGeneration = bindingGeneration
            return layer == nil
        }
        guard !unbound, let box = sampleBox else { return }
        lock.withLock { stats.pendingDispatch += 1 }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.consume(box, generation: dispatchGeneration)
            }
        }
    }

    @MainActor
    private func consume(_ box: SampleBox, generation: Int) {
        lock.lock()
        stats.pendingDispatch = max(0, stats.pendingDispatch - 1)
        // 绑定重建后，本次分发对应的帧已由 bind() 从 recent 回放；
        // 代次不匹配说明是绑定前的旧分发，直接丢弃，避免同一帧
        // 第二次进入新显示层。
        guard generation == bindingGeneration else {
            lock.unlock()
            return
        }
        guard let layer else {
            lock.unlock()
            return
        }
        lock.unlock()

        lock.lock()
        // 恢复后只放行关键帧；已经排在主队列里的旧帧直接丢弃。
        if needsKeyframe, !box.isKeyframe {
            lock.unlock()
            return
        }
        let wasWaitingForKeyframe = needsKeyframe
        if box.isKeyframe {
            needsKeyframe = false
            if wasWaitingForKeyframe {
                let timebaseSeconds = timebase.map { CMTimebaseGetTime($0).seconds } ?? -1
                Log.info(
                    .render,
                    "seek 后关键帧入队 pts=\(String(format: "%.3f", box.presentationTime))s "
                        + "时钟=\(String(format: "%.3f", clock.currentTime))s "
                        + "时间基=\(String(format: "%.3f", timebaseSeconds))s"
                )
            }
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
            return max(0, last.presentationTime - clock.currentTime)
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
        recentAwaitingKeyframe = true
        needsKeyframe = true
        stats.lastEnqueuedTime = 0
        let timebase = self.timebase
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.layer?.flush()
                let pending = self.lock.withLock { self.stats.pendingDispatch }
                Log.info(
                    .render,
                    "视频跳转清层 位置=\(String(format: "%.2f", seconds))s "
                        + "状态=\(self.layer?.status.rawValue ?? -1) "
                        + "待发=\(pending)"
                )
            }
        }
        if let timebase {
            CMTimebaseSetTime(timebase, time: CMTime(seconds: seconds, preferredTimescale: 600))
        }
        Log.info(
            .render,
            "视频跳转 位置=\(String(format: "%.2f", seconds))s "
                + "时间基=\(timebase.map { String(format: "%.3f", CMTimebaseGetTime($0).seconds) } ?? "无")"
        )
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
