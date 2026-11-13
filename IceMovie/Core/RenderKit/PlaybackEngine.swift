import AVFAudio
import CFFmpeg
import CoreMedia
import DemuxKit
import Foundation
import IceCore

/// 播放引擎：把「解封装 → 音频解码/视频封装 → 输出 → 主时钟」串起来。
///
/// 拉流在一条独立线程上串行执行（FFmpeg 的上下文不是线程安全的），
/// 通过「已排入数据领先播放位置不超过上限」来限速，避免把整个文件读进内存。
/// 主时钟由音频渲染位置每 100 ms 校正一次，视频显示层的时间基跟随主时钟（design.md D2/D3）。
///
/// 音频与视频共用同一条读流，因此容器只打开一次、SMB 只读一遍。
public final class PlaybackEngine: @unchecked Sendable {
    public struct Statistics: Sendable {
        public var packetsRead = 0
        public var packetsDecoded = 0
        public var videoPackets = 0
        public var bytesRead: Int64 = 0
        public var decodedSeconds: Double = 0
        public var underruns = 0
        public var maxDrift: Double = 0
        public var maxDriftPosition: Double = 0
        public var maxDriftAudioTime: Double = 0
        public var maxDriftClockTime: Double = 0
        public var clockJumpCount = 0
        public var clockCorrections = 0
        public var startupMilliseconds = 0
        public var firstVideoMilliseconds = 0
        public var maxVideoOffset: Double = 0
        /// seek 完成时/完成后 2 秒内，显示层时间基与主时钟的最大偏差。
        public var lastSeekTimebaseOffset: Double = 0
        public var maxSeekTimebaseOffset: Double = 0
        /// 时间基偏差超过 1 秒的次数；SSIS-499 这类“画面停住/像 3 倍速追赶”的直接信号。
        public var seekTimebaseJumpCount = 0
        public var seekCount = 0
        public var lastSeekLatencyMilliseconds = 0
        public var lastSeekPrerollFrames = 0
        public var lastSeekDrift: Double = 0
        public var droppedSeeks = 0
        /// 播放中进入“缓冲不足”的次数与累计时长。
        public var bufferStalls = 0
        public var bufferSeconds: Double = 0
        /// 任意 60 秒窗口内最多的缓冲次数；≥6 视为频繁缓冲。
        public var maxBufferStallsPerMinute = 0
        /// 全部数据都已播完（区别于「读到文件结尾」）。
        public var drained = false
        public var failure: String?
        public var videoQueueDepth = 0
        public var videoQueueDropped = 0
        public var videoQueueBytes = 0
        /// 起播后 30 秒内的缓冲次数；用于起播水位自适应验收。
        public var startupBufferStalls = 0
        public var startupPrerollMode = "fast"
    }

    /// 当前起播预滚档位：fast（1 帧 + ≤300ms 音频）或 conservative（2s/1s）。
    public private(set) var startupPrerollMode = "fast"
    private var startupThroughputBytesPerSecond: Double = 0
    private var startupModeDecided = false

    /// 打开阶段平均读取速度；用于在慢链路选择保守起播水位。
    public func setStartupThroughput(bytesPerSecond: Double) {
        lock.withLock {
            startupThroughputBytesPerSecond = max(0, bytesPerSecond)
        }
    }

    /// 在生成起播/验收快照前先解析档位；`play()` 内还会再调用一次，已决策时直接返回。
    public func resolveStartupPrerollMode() {
        decideStartupMode()
    }

    /// 起播预滚档位的纯函数版本，便于验收两档阈值。
    public static func startupPreroll(mode: String) -> (audio: Double, video: Double) {
        mode == "conservative"
            ? (conservativeAudioPrerollSeconds, conservativeVideoPrerollSeconds)
            : (prerollSeconds, videoPrerollSeconds)
    }

    private var effectiveAudioPrerollSeconds: Double {
        Self.startupPreroll(mode: startupPrerollMode).audio
    }

    private var effectiveVideoPrerollSeconds: Double {
        Self.startupPreroll(mode: startupPrerollMode).video
    }

    /// 吞吐低于码率 1.5 倍时回退保守档；没有码率信息时用快速档。
    private func decideStartupMode() {
        guard !startupModeDecided else { return }
        startupModeDecided = true
        let bytesPerSecond: Double
        if let length = reader.byteLength, duration > 0, length > 0 {
            bytesPerSecond = Double(length) / duration
        } else {
            bytesPerSecond = 0
        }
        let measured = max(
            startupThroughputBytesPerSecond,
            reader.downloadBytesPerSecond
        )
        startupPrerollMode = Self.startupPrerollMode(
            measuredBytesPerSecond: measured,
            bitrateBytesPerSecond: bytesPerSecond
        )
        lock.withLock {
            stats.startupPrerollMode = startupPrerollMode
        }
        Log.info(
            .render,
            "起播水位档位=\(startupPrerollMode) 实测=\(Int(measured / 1024))KB/s "
                + "码率=\(Int(bytesPerSecond / 1024))KB/s"
        )
    }

    /// 起播前先垫这么多秒的音频（快速档：首帧可用即起播）。
    private static let prerollSeconds = 0.3
    /// 快速档视频只需要 1 帧；显示层未绑定时按待发帧数判断。
    private static let videoPrerollSeconds = 0.05
    /// 慢链路保守档：先垫 2 秒音频 + 1 秒视频，避免开头反复欠载。
    private static let conservativeAudioPrerollSeconds = 2.0
    private static let conservativeVideoPrerollSeconds = 1.0
    /// 播放中音频低于这个水位就暂停主时钟。
    private static let audioStallSeconds = 0.12
    /// 缓冲暂停后音频回到这个水位才恢复。
    private static let audioResumeSeconds = 0.5
    /// 读包一直补到音频领先这个水位；8GB 设备内存充足，用时间换稳定。
    private static let audioAheadSeconds = 15.0
    /// 视频最多领先主时钟这么多秒；局域网带宽足够时提前解码，吸收网络抖动。
    private static let videoAheadSeconds = 15.0

    public let clock: MasterClock
    public let duration: Double
    public let audioCodecName: String
    public let videoCodecName: String
    public let videoRenderer: VideoRenderer?

    private let reader: MediaReader
    private let decoder: AudioDecoder?
    private let output: AudioOutput?
    private let sampleBuilder: SampleBufferBuilder?
    private let audioStreamIndex: Int?
    private let videoStreamIndex: Int?
    private let lock = NSLock()
    private let condition = NSCondition()
    private var videoPipeline: VideoPacketPipeline?
    private var audioTimeBase = AVRational(num: 0, den: 1)
    private var videoTimeBase = AVRational(num: 0, den: 1)
    private var lastAudioPacketPos: Int64 = -1
    private var lastAudioPacketPTS: Double = -1
    private var lastVideoPacketPos: Int64 = -1
    private var lastVideoPacketPTS: Double = -1

    private var stats = Statistics()
    private var wantsPlay = false
    private var stopped = false
    private var ended = false
    private var loggedEndPark = false
    private var pendingSeek: (target: Double, id: Int, requestedAt: Double)?
    private var seekRequests = 0
    private var completedSeekID = 0
    private var completedSeekResults: [Int: Bool] = [:]
    private var lastCompletedSeek: (id: Int, success: Bool)?
    private var seekWaitersClosed = false
    private var seekWaiters: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var pumpThread: Thread?
    private var syncTimer: DispatchSourceTimer?
    private var playStartedAt: Double?
    private var pausedAt: Double?
    private var stalledForBuffering = false
    private var lowSupplyTicks = 0
    private var bufferStallTimes: [Double] = []
    private var bufferStallBeganAt: Double?
    private var tickCount = 0
    /// 跳转后各条流各自的追赶目标，追上了就清空。
    private var audioSeekTarget: Double?
    private var videoSeekTarget: Double?
    private var activeSeekID: Int?
    private var seekRequestedAt: Double = 0
    private var seekPrerollFrames = 0
    private var seekTimebaseWatchUntil: Double = 0
    private var seekTimebaseJumpFlagged = false
    /// seek 期间暂停 tick 的时钟/时间基校正，避免旧音频位置把时钟拉回。
    private var seekInProgress = false
    /// seek 代次：每次 seek 开始/结束都 +1。tick 读取音频时间前后各取一次，
    /// 代次前进说明期间发生了 seek，本次读到的音频时间已作废。
    /// 只检查 seekInProgress 布尔值不够：它只保护“检查”这一瞬间，
    /// 保护不了“读取音频时间 → 校正主时钟”整段窗口。
    private var seekEpoch = 0
    private var volume: Float = 1
    private var wasBuffering = false
    private var subtitleStreamIndex: Int?
    private var subtitleDecoder: SubtitlePacketDecoder?
    private var onSubtitleEvents: (([SubtitlePacketEvent]) -> Void)?
    private struct SubtitleCollectorRequest {
        let streamIndex: Int?
        let onEvents: (([SubtitlePacketEvent]) -> Void)?
    }
    /// 字幕解码器必须在播放泵线程创建；主线程只提交请求。
    private var pendingSubtitleCollector: SubtitleCollectorRequest?
    private var audioObservers: [NSObjectProtocol] = []
    private var resumeAfterInterruption = false

    public init(reader: MediaReader) throws {
        let clock = MasterClock()
        self.clock = clock
        self.reader = reader
        duration = reader.duration
        if let length = reader.byteLength, reader.duration > 0 {
            // 已看区域只留 20 秒，最多 64MB；剩下的预读内存全部留给未来。
            let back = Int64(Double(length) / reader.duration * 20)
            reader.setRetainBackBytes(min(64 * 1024 * 1024, max(0, back)))
        }

        var audioDecoder: AudioDecoder?
        var audioOutput: AudioOutput?
        var audioIndex: Int?
        if let track = reader.audioTrack, let stream = reader.stream(at: track.index) {
            audioDecoder = try AudioDecoder(stream: stream)
            audioOutput = try AudioOutput()
            audioIndex = track.index
            audioTimeBase = stream.pointee.time_base
        }

        var builder: SampleBufferBuilder?
        var videoIndex: Int?
        if let track = reader.videoTrack, let stream = reader.stream(at: track.index) {
            builder = try SampleBufferBuilder(stream: stream)
            videoIndex = track.index
            videoTimeBase = stream.pointee.time_base
        }

        guard audioDecoder != nil || builder != nil else {
            throw MediaReaderError.noAudioStream
        }

        decoder = audioDecoder
        output = audioOutput
        sampleBuilder = builder
        audioStreamIndex = audioIndex
        videoStreamIndex = videoIndex
        audioCodecName = audioDecoder?.codecName ?? "无"
        videoCodecName = builder?.codecName ?? "无"
        videoRenderer = builder == nil ? nil : VideoRenderer(clock: clock)

        Log.info(
            .render,
            "播放器就绪 音频=\(audioCodecName) 视频=\(videoCodecName) "
                + "时长=\(String(format: "%.1f", duration))s"
        )
        videoRenderer?.onNeedsRefresh = { [weak self] position in
            self?.seek(to: position)
        }
        if builder != nil {
            let pipeline = VideoPacketPipeline { [weak self] packet, generation in
                self?.processVideoPacket(packet, generation: generation)
            }
            pipeline.onOverflow = { [weak self] in
                DispatchQueue.main.async {
                    self?.videoRenderer?.invalidateForPacketDrop()
                }
            }
            videoPipeline = pipeline
        }
        installAudioObservers()
    }

    deinit {
        for observer in audioObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        stopSyncTimer()
        videoPipeline?.stop()
        condition.lock()
        stopped = true
        wantsPlay = false
        condition.broadcast()
        condition.unlock()
        // 跨文件压测时用这条日志核对引擎是否按时释放（内存每个会话涨几十 MB）。
        Log.info(.render, "引擎释放")
    }

    // MARK: - 控制

    public func play() {
        guard !isStopped else { return }
        reader.endOpenPhase()
        decideStartupMode()
        startPumpIfNeeded()

        if let pausedAt {
            Log.info(
                .render,
                "恢复播放 暂停时长=\(String(format: "%.1f", ProcessInfo.processInfo.systemUptime - pausedAt))s"
            )
        }
        pausedAt = nil
        resetBufferStallState()
        condition.lock()
        wantsPlay = true
        condition.broadcast()
        condition.unlock()
        tryStartPlayback()
    }

    /// 缓冲足够才真正开声，避免起播瞬间供给不足造成断续。
    private func tryStartPlayback() {
        condition.lock()
        let wantsPlaySnapshot = wantsPlay
        let stoppedSnapshot = stopped
        let endedSnapshot = ended
        condition.unlock()
        guard wantsPlaySnapshot, !clock.isPlaying, !stoppedSnapshot else { return }
        if output != nil {
            guard endedSnapshot || output?.bufferedAhead ?? 0 >= effectiveAudioPrerollSeconds else {
                return
            }
            // 显示层尚未绑定时不能等视频水位，否则无头播放/测试永远起不来；
            // 正常 App 里图层会在覆盖层出现后立即绑定并补发缓存帧。
            if let videoRenderer, videoRenderer.isBound {
                guard endedSnapshot || videoRenderer.bufferedAhead >= effectiveVideoPrerollSeconds else {
                    return
                }
            }
        } else if let videoRenderer {
            if videoRenderer.isBound {
                guard endedSnapshot || videoRenderer.bufferedAhead >= effectiveVideoPrerollSeconds else {
                    return
                }
            } else {
                guard endedSnapshot || videoRenderer.pendingCount >= 1 else { return }
            }
        }
        lock.withLock {
            if playStartedAt == nil {
                playStartedAt = ProcessInfo.processInfo.systemUptime
            }
        }
        output?.play()
        clock.play()
        // 第一帧真正开始时才允许后台预读填满窗口，起播/探测阶段不抢带宽。
        reader.setPrefetchEnabled(true)
        videoRenderer?.syncTimebase()
        startSyncTimer()
        Log.info(
            .render,
            "开始播放 位置=\(fmt(clock.currentTime))s "
                + "预缓冲 音频=\(fmt(output?.bufferedAhead ?? 0))s "
                + "视频=\(fmt(videoRenderer?.bufferedAhead ?? 0))s"
        )
    }

    public func pause() {
        guard !isStopped else { return }
        resetBufferStallState()
        condition.lock()
        wantsPlay = false
        pausedAt = ProcessInfo.processInfo.systemUptime
        condition.broadcast()
        condition.unlock()
        output?.pause()
        clock.pause()
        videoRenderer?.syncTimebase()
        stopSyncTimer()
        Log.info(.render, "暂停 位置=\(fmt(clock.currentTime))s")
    }

    @discardableResult
    public func seek(to seconds: Double, requestedAt: Double? = nil) -> Int {
        guard !isStopped else { return -1 }
        let target = duration > 0
            ? min(max(0, seconds), max(0, duration - 0.1))
            : max(0, seconds)
        let releaseAt = requestedAt ?? ProcessInfo.processInfo.systemUptime
        condition.lock()
        let previous = pendingSeek
        seekRequests += 1
        let id = seekRequests
        pendingSeek = (target, id, releaseAt)
        condition.broadcast()
        condition.unlock()
        if let previous {
            lock.withLock { stats.droppedSeeks += 1 }
            Log.info(
                .render,
                "seek 取消 id=\(previous.id) 目标=\(fmt(previous.target))s，被 id=\(id) 覆盖"
            )
        }
        startPumpIfNeeded()
        let queued = Int((ProcessInfo.processInfo.systemUptime - releaseAt) * 1000)
        Log.info(
            .render,
            "seek 入队 id=\(id) 目标=\(fmt(target))s 松手到入队=\(max(0, queued))ms"
        )
        return id
    }

    /// 起播前定位：等 demuxer seek、时钟与显示层重置完成（finishSeek）后返回；
    /// 音频裁剪和视频预滚在后续读包时完成，不在 prepareSeek 内等待。
    public func prepareSeek(to seconds: Double) async -> Bool {
        guard !isStopped else { return false }
        let id = seek(to: seconds, requestedAt: ProcessInfo.processInfo.systemUptime)
        guard id > 0 else { return false }
        return await withCheckedContinuation { continuation in
            lock.lock()
            // stop()/fail() 可能发生在 seek 入队之后、continuation 注册之前；
            // 关闭标志与 waiter 注册在同一把锁内，保证不会漏掉 resume。
            if seekWaitersClosed {
                lock.unlock()
                continuation.resume(returning: false)
            } else if let result = completedSeekResults[id] {
                lock.unlock()
                continuation.resume(returning: result)
            } else if completedSeekID >= id {
                // 结果表被裁剪时只信任最近一次同 id 的结果，避免把失败的 seek
                // 用 stats.failure == nil 误判为成功。
                let result = lastCompletedSeek?.id == id
                    ? (lastCompletedSeek?.success ?? false)
                    : false
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                seekWaiters[id] = continuation
                lock.unlock()
            }
        }
    }

    private var isStopped: Bool {
        condition.lock()
        defer { condition.unlock() }
        return stopped
    }

    private var currentWantsPlay: Bool {
        condition.lock()
        defer { condition.unlock() }
        return wantsPlay
    }

    private func finishSeek(id: Int, success: Bool) {
        lock.lock()
        completedSeekID = max(completedSeekID, id)
        completedSeekResults[id] = success
        lastCompletedSeek = (id, success)
        var ready: [(continuation: CheckedContinuation<Bool, Never>, result: Bool)] = []
        let readyKeys = seekWaiters.keys.filter { $0 <= completedSeekID }
        for key in readyKeys {
            guard let waiter = seekWaiters.removeValue(forKey: key) else { continue }
            let result = completedSeekResults[key] ?? (key == id ? success : false)
            ready.append((waiter, result))
        }
        // seek 会随拖动频繁发生；只保留最近一小段结果，避免字典无限增长。
        if completedSeekResults.count > 32 {
            let keepFrom = completedSeekID - 32
            completedSeekResults = completedSeekResults.filter { $0.key >= keepFrom }
        }
        lock.unlock()
        for item in ready {
            item.continuation.resume(returning: item.result)
        }
    }

    private func finishAllSeekWaiters() {
        lock.lock()
        seekWaitersClosed = true
        let waiters = seekWaiters
        seekWaiters.removeAll()
        lock.unlock()
        for continuation in waiters.values {
            continuation.resume(returning: false)
        }
    }

    public func setRate(_ rate: Float) {
        // MasterClock 支持 0.25–4，AudioOutput 只支持 0.5–2.0。
        // 必须取交集后统一钳制，否则时钟与音频速率不一致会触发持续校正。
        let clamped = Self.clampedRate(rate)
        if clamped != rate {
            Log.info(
                .render,
                "倍速钳制 输入=\(String(format: "%.2f", rate)) "
                    + "实际=\(String(format: "%.2f", clamped))"
            )
        }
        clock.setRate(clamped)
        output?.setRate(clamped)
        videoRenderer?.syncTimebase()
        Log.info(
            .render,
            "主时钟速率=\(String(format: "%.2f", clamped)) 位置=\(fmt(clock.currentTime))s"
        )
    }

    /// 音画共同支持的倍速范围（MasterClock 与 AudioOutput 的交集）。
    static let supportedRateRange: ClosedRange<Float> = 0.5...2.0

    static func clampedRate(_ rate: Float) -> Float {
        min(max(rate, supportedRateRange.lowerBound), supportedRateRange.upperBound)
    }

    public var currentVolume: Float {
        lock.withLock { volume }
    }

    public func setVolume(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        lock.withLock { volume = clamped }
        output?.setVolume(clamped)
        Log.debug(.render, "音量=\(Int(clamped * 100))%")
    }

    public func stop() {
        condition.lock()
        stopped = true
        wantsPlay = false
        pendingSubtitleCollector = nil
        condition.broadcast()
        condition.unlock()
        resetBufferStallState()
        stopSyncTimer()
        finishAllSeekWaiters()
        reader.cancelPrefetch()
        videoPipeline?.stop()
        output?.pause()
        output?.reset()
        clock.pause()
        lock.withLock {
            subtitleStreamIndex = nil
            subtitleDecoder = nil
            onSubtitleEvents = nil
        }
        for observer in audioObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        audioObservers.removeAll()
        resumeAfterInterruption = false
        Log.info(.render, "停止 位置=\(fmt(clock.currentTime))s")
    }

    // MARK: - 音频中断

    private func installAudioObservers() {
        let center = NotificationCenter.default
        audioObservers.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleAudioInterruption(notification)
            }
        )
        audioObservers.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleAudioRouteChange(notification)
            }
        )
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            resumeAfterInterruption = currentWantsPlay
            guard resumeAfterInterruption else { return }
            Log.notice(.render, "音频中断开始，暂停播放")
            pause()
        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            let shouldResume = resumeAfterInterruption && options.contains(.shouldResume)
            resumeAfterInterruption = false
            let drained = lock.withLock { stats.drained }
            guard shouldResume, !drained, !isStopped else { return }
            Log.info(.render, "音频中断结束，恢复播放")
            play()
        @unknown default:
            break
        }
    }

    /// 耳机拔出时按系统建议暂停，避免突然外放；不自动恢复，等待用户操作。
    private func handleAudioRouteChange(_ notification: Notification) {
        guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason),
              reason == .oldDeviceUnavailable else { return }
        guard currentWantsPlay else { return }
        Log.notice(.render, "音频输出设备断开，暂停播放")
        pause()
    }

    // MARK: - 状态

    /// 大文件 ASS/文本字幕直接复用播放泵读到的字幕包，避免为字幕二次扫描 SMB。
    public func setSubtitleCollector(
        streamIndex: Int?,
        onEvents: (([SubtitlePacketEvent]) -> Void)?
    ) {
        // MediaReader/AVFormatContext 只能在播放泵线程访问；这里只登记请求，
        // 真正的 decoder 创建放到 pumpLoop 中执行。
        condition.lock()
        guard !stopped else {
            condition.unlock()
            return
        }
        pendingSubtitleCollector = SubtitleCollectorRequest(
            streamIndex: streamIndex,
            onEvents: onEvents
        )
        condition.broadcast()
        condition.unlock()
    }

    /// 在 pumpLoop 持有 condition 锁时取走请求。
    private func takePendingSubtitleCollectorLocked() -> SubtitleCollectorRequest? {
        let request = pendingSubtitleCollector
        pendingSubtitleCollector = nil
        return request
    }

    /// 仅由播放泵线程调用。
    private func applySubtitleCollector(_ request: SubtitleCollectorRequest) {
        let decoder = request.streamIndex.flatMap {
            reader.makeSubtitlePacketDecoder(streamIndex: $0)
        }
        lock.withLock {
            subtitleStreamIndex = request.streamIndex
            subtitleDecoder = decoder
            onSubtitleEvents = request.onEvents
        }
    }

    public var isPlaying: Bool { clock.isPlaying }

    /// 播放源最近的实际下载速度。
    public var downloadBytesPerSecond: Double { reader.downloadBytesPerSecond }

    /// 当前播放点之后已缓冲的秒数（从播放头到预读最远点）。
    public var bufferedAheadSeconds: Double {
        let avAhead = max(output?.bufferedAhead ?? 0, videoRenderer?.bufferedAhead ?? 0)
        let bytesPerSecond: Double
        if let length = reader.byteLength, duration > 0 {
            bytesPerSecond = Double(length) / duration
        } else {
            bytesPerSecond = 0
        }
        guard bytesPerSecond > 0 else { return max(0, avAhead) }
        let ring = Double(reader.bufferedBytes(from: playheadByteOffset)) / bytesPerSecond
        return max(0, max(avAhead, ring))
    }

    /// 当前播放位置对应的字节偏移。优先用最近音视频包的真实 pos/pts 推算，
    /// VBR 文件上比「平均码率 × 时间」准确得多；没有包位置时退回平均估算。
    public var playheadByteOffset: Int64 {
        guard let length = reader.byteLength, length > 0, duration > 0 else { return 0 }
        let position = min(max(clock.currentTime, 0), duration)
        let packet = lock.withLock { () -> (pos: Int64, pts: Double) in
            if lastAudioPacketPos >= 0 { return (lastAudioPacketPos, lastAudioPacketPTS) }
            return (lastVideoPacketPos, lastVideoPacketPTS)
        }
        if packet.pos >= 0, packet.pts >= 0 {
            let bytesPerSecond = Double(length) / duration
            let estimate = Double(packet.pos) + (position - packet.pts) * bytesPerSecond
            let readHead = reader.readHeadByteOffset
            let upper = readHead >= 0 ? min(length, readHead) : length
            return min(upper, max(0, Int64(estimate)))
        }
        return Int64((position / duration) * Double(length))
    }

    public var ringResetCount: Int { reader.ringResetCount }
    public var seekCacheHits: Int { reader.seekCacheHits }
    public var seekCacheMisses: Int { reader.seekCacheMisses }
    public var lastSeekCacheHit: Bool { reader.lastSeekCacheHit }
    public var sourcePlayheadByteOffset: Int64 { reader.playheadByteOffset }
    public var sourceReadHeadByteOffset: Int64 { reader.readHeadByteOffset }
    public var sourcePrefetchHeadByteOffset: Int64 { reader.prefetchHeadByteOffset }

    public var statistics: Statistics {
        lock.withLock {
            var snapshot = stats
            if let metrics = videoPipeline?.metrics {
                snapshot.videoQueueDepth = metrics.queueDepth
                snapshot.videoQueueDropped = metrics.dropped
                snapshot.videoQueueBytes = metrics.queueBytes
            }
            snapshot.clockCorrections = clock.correctionCount
            snapshot.maxDrift = max(snapshot.maxDrift, abs(clock.lastSyncDrift))
            return snapshot
        }
    }

    public var bufferedAhead: Double { output?.bufferedAhead ?? 0 }
    public var audioOutputMetrics: AudioOutput.Metrics? { output?.metrics }

    /// 播放中供给不足：音频缓冲低于阈值时暂停主时钟，避免声音恢复后落后于画面。
    public var isBuffering: Bool {
        condition.lock()
        let stoppedSnapshot = stopped
        condition.unlock()
        guard !stoppedSnapshot else { return false }
        if lock.withLock({ stalledForBuffering }) { return true }
        guard isPlaying else { return false }
        return audioSupplyLow || (output == nil && videoSupplyLow)
    }

    private var audioSupplyLow: Bool {
        guard let output else { return false }
        return output.bufferedAhead < Self.audioStallSeconds
    }

    private var videoSupplyLow: Bool {
        guard let videoRenderer else { return false }
        return videoRenderer.bufferedAhead < 0.08
    }

    /// 缓冲时冻结主时钟与音频，恢复后从同一位置继续；否则静音期间时钟继续走，
    /// 新排入的音频会整体落后于画面。
    private func updateBufferingState() {
        condition.lock()
        let stoppedSnapshot = stopped
        let endedSnapshot = ended
        let wantsPlaySnapshot = wantsPlay
        condition.unlock()
        guard !stoppedSnapshot, !endedSnapshot, wantsPlaySnapshot else {
            resetBufferStallState()
            return
        }
        let low = audioSupplyLow || (output == nil && videoSupplyLow)
        let clockPlaying = clock.isPlaying

        var shouldStall = false
        var wasStalled = false
        lock.lock()
        if stalledForBuffering {
            wasStalled = true
            lowSupplyTicks = 0
        } else {
            // 供给水位会在 100ms 内被拉流线程补上；连续两次偏低才暂停，
            // 避免在正常波动时反复暂停/恢复。
            lowSupplyTicks = low ? lowSupplyTicks + 1 : 0
            if lowSupplyTicks >= 2, clockPlaying {
                stalledForBuffering = true
                lowSupplyTicks = 0
                shouldStall = true
            }
        }
        lock.unlock()

        if shouldStall {
            recordBufferStall()
            output?.pause()
            clock.pause()
            videoRenderer?.syncTimebase()
            Log.notice(
                .render,
                "缓冲不足，暂停主时钟 音频=\(fmt(bufferedAhead))s "
                    + "本次第 \(statistics.bufferStalls) 次"
            )
            return
        }

        guard wasStalled else { return }
        let recovered: Bool
        if output != nil {
            recovered = bufferedAhead >= Self.audioResumeSeconds
        } else {
            recovered = (videoRenderer?.bufferedAhead ?? 0) >= Self.audioResumeSeconds
        }
        guard recovered else { return }
        let didRecover = lock.withLock { () -> Bool in
            guard stalledForBuffering else { return false }
            stalledForBuffering = false
            return true
        }
        guard didRecover else { return }
        finishBufferStall()
        output?.play()
        clock.play()
        videoRenderer?.syncTimebase()
        let snapshot = statistics
        Log.info(
            .render,
            "缓冲恢复，继续播放 位置=\(fmt(clock.currentTime))s "
                + "累计=\(snapshot.bufferStalls) 次/\(fmt(snapshot.bufferSeconds))s"
        )
    }

    /// 记录一次缓冲事件，并维护任意 60 秒窗口内的峰值次数（验收用）。
    private func recordBufferStall() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            stats.bufferStalls += 1
            if let started = playStartedAt, now - started <= 30 {
                stats.startupBufferStalls += 1
            }
            bufferStallTimes.append(now)
            bufferStallTimes.removeAll { now - $0 > 60 }
            stats.maxBufferStallsPerMinute = max(
                stats.maxBufferStallsPerMinute,
                bufferStallTimes.count
            )
            bufferStallBeganAt = now
        }
    }

    private func finishBufferStall() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            guard let began = bufferStallBeganAt else { return }
            stats.bufferSeconds += max(0, now - began)
            bufferStallBeganAt = nil
        }
    }

    private func resetBufferStallState() {
        let wasStalled = lock.withLock { () -> Bool in
            let wasStalled = stalledForBuffering
            stalledForBuffering = false
            lowSupplyTicks = 0
            return wasStalled
        }
        if wasStalled {
            finishBufferStall()
        }
    }

    /// 阻塞等待播放结束或超时，返回最终统计。仅用于自检与验收脚本。
    public func waitForFinish(timeout: Double) -> Statistics {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshot = statistics
            if snapshot.drained || snapshot.failure != nil { return snapshot }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return statistics
    }

    // MARK: - 拉流

    private func startPumpIfNeeded() {
        // play()/seek() 可能来自 UI、锁屏控制或画中画回调，统一用 lock 保护只启动一条泵线程。
        lock.lock()
        guard pumpThread == nil else {
            lock.unlock()
            return
        }
        let thread = Thread { [weak self] in self?.pumpLoop() }
        thread.name = "icemovie.playback.pump"
        // 泵线程会同步等待异步字节源读取；读取任务使用 .userInitiated，
        // 两边 QoS 保持一致，避免 Thread Performance Checker 报优先级反转。
        thread.qualityOfService = .userInitiated
        pumpThread = thread
        thread.start()
        lock.unlock()
    }

    private func pumpLoop() {
        guard let packet = av_packet_alloc() else {
            fail("无法分配 AVPacket")
            return
        }
        defer {
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&owned)
        }

        while true {
            condition.lock()
            while !stopped, pendingSeek == nil {
                // 字幕采集请求只需在泵线程创建 decoder，不需要有可读数据。
                if pendingSubtitleCollector != nil {
                    break
                }
                if ended {
                    // EOF 后不要空转：等 seek() 把 ended 置回 false，或 stop() 唤醒。
                    if !loggedEndPark {
                        loggedEndPark = true
                        Log.debug(.render, "泵线程 EOF 等待")
                    }
                    condition.wait()
                    continue
                }
                loggedEndPark = false
                // 播放中要持续供给；暂停时也先垫到预缓冲水位，起播才不会欠载。
                if wantsPlay || (output?.bufferedAhead ?? 0) < effectiveAudioPrerollSeconds {
                    break
                }
                condition.wait()
            }
            if stopped {
                condition.unlock()
                break
            }
            let subtitleCollectorRequest = takePendingSubtitleCollectorLocked()
            let request = pendingSeek
            pendingSeek = nil
            let latest = seekRequests
            let endedNow = ended
            condition.unlock()

            if let subtitleCollectorRequest {
                applySubtitleCollector(subtitleCollectorRequest)
            }
            if let request {
                if request.id == latest {
                    performSeek(
                        request.target,
                        id: request.id,
                        requestedAt: request.requestedAt
                    )
                } else {
                    lock.withLock { stats.droppedSeeks += 1 }
                    Log.info(
                        .render,
                        "seek 丢弃 id=\(request.id) 目标=\(fmt(request.target))s，已有更新的请求"
                    )
                }
                continue
            }
            if !endedNow {
                pumpOne(packet)
            }
        }
    }

    private func pumpOne(_ packet: UnsafeMutablePointer<AVPacket>) {
        if isAheadEnough() {
            Thread.sleep(forTimeInterval: 0.02)
            return
        }

        switch reader.read(into: packet) {
        case .failed(let code):
            Log.error(.demux, "读取失败 code=\(code)")
            fail("读取失败（\(code)）")
        case .endOfFile:
            drainDecoder()
            markEnded()
        case .packet:
            let index = Int(packet.pointee.stream_index)
            var packetTransferred = false
            lock.withLock {
                stats.bytesRead += Int64(max(0, packet.pointee.size))
            }
            let subtitleIndex = lock.withLock { subtitleStreamIndex }
            if let subtitleIndex, index == subtitleIndex {
                let decoder = lock.withLock { subtitleDecoder }
                let events: [SubtitlePacketEvent]
                if let decoder {
                    events = decoder.decode(packet)
                } else if let event = reader.subtitleEvent(from: packet, streamIndex: subtitleIndex) {
                    events = [event]
                } else {
                    events = []
                }
                if let callback = lock.withLock({ onSubtitleEvents }) {
                    callback(events)
                }
            } else if index == audioStreamIndex {
                recordPacketPosition(packet, timeBase: audioTimeBase, audio: true)
                decodeAudio(packet)
            } else if index == videoStreamIndex {
                recordPacketPosition(packet, timeBase: videoTimeBase, audio: false)
                if let videoPipeline {
                    videoPipeline.enqueue(packet)
                    packetTransferred = true
                } else {
                    processVideoPacket(packet, generation: 0)
                }
            }
            if !packetTransferred {
                av_packet_unref(packet)
            }
        }
    }

    private func isAheadEnough() -> Bool {
        // 显示层尚未绑定时视频水位来自待发缓存；先垫到起播量就停止读包，
        // 否则缓存帧上限会让视频水位永远达不到 8 秒，播放泵会把整个文件读进来。
        if let videoRenderer, !videoRenderer.isBound {
            let audioReady = output.map {
                $0.bufferedAhead >= effectiveAudioPrerollSeconds
            } ?? true
            return audioReady && videoRenderer.pendingAhead >= effectiveVideoPrerollSeconds
        }
        return Self.isReadAheadEnough(
            audioAhead: output?.bufferedAhead,
            videoAhead: videoRenderer.map(\.bufferedAhead)
        )
    }

    /// seek 后显示层时间基偏差超过 1 秒即视为“画面停住/追赶”风险。
    public static func isSeekTimebaseJump(_ offset: Double) -> Bool {
        abs(offset) > 1.0
    }

    /// 验收同步判定：音频/时钟漂移之外，必须同时满足显示层时间基条件。
    public static func isAcceptanceSyncOK(
        maxDrift: Double,
        clockJumpCount: Int,
        lastSeekDrift: Double,
        maxSeekTimebaseOffset: Double,
        seekTimebaseJumpCount: Int
    ) -> Bool {
        maxDrift < 0.5
            && clockJumpCount == 0
            && abs(lastSeekDrift) < 0.5
            && maxSeekTimebaseOffset <= 1.0
            && seekTimebaseJumpCount == 0
    }

    /// 起播档位的纯函数版本，便于单元测试。
    public static func startupPrerollMode(
        measuredBytesPerSecond: Double,
        bitrateBytesPerSecond: Double
    ) -> String {
        guard bitrateBytesPerSecond > 0, measuredBytesPerSecond > 0 else {
            return "fast"
        }
        return measuredBytesPerSecond < bitrateBytesPerSecond * 1.5
            ? "conservative"
            : "fast"
    }

    /// 读包限速策略：音频和视频都补到各自的高水位才停，避免只维持 1.5 秒音频、
    /// 一点网络抖动就进入“缓冲中”。纯音频/纯视频只检查各自的水位。
    static func isReadAheadEnough(audioAhead: Double?, videoAhead: Double?) -> Bool {
        if let audioAhead {
            guard audioAhead >= Self.audioAheadSeconds else { return false }
            guard let videoAhead else { return true }
            return videoAhead >= Self.videoAheadSeconds
        }
        guard let videoAhead else { return true }
        return videoAhead >= Self.videoAheadSeconds
    }

    private func recordPacketPosition(
        _ packet: UnsafeMutablePointer<AVPacket>,
        timeBase: AVRational,
        audio: Bool
    ) {
        guard packet.pointee.pos >= 0, packet.pointee.pts != Int64.min else { return }
        let pts = Double(packet.pointee.pts) * Double(timeBase.num) / Double(timeBase.den)
        guard pts >= 0 else { return }
        lock.withLock {
            if audio {
                lastAudioPacketPos = packet.pointee.pos
                lastAudioPacketPTS = pts
            } else {
                lastVideoPacketPos = packet.pointee.pos
                lastVideoPacketPTS = pts
            }
        }
    }

    private func decodeAudio(_ packet: UnsafeMutablePointer<AVPacket>) {
        guard let decoder, let output else { return }
        lock.withLock { stats.packetsRead += 1 }
        do {
            for frame in try decoder.decode(packet) {
                let audio = trimForSeek(frame)
                guard let audio else { continue }
                output.enqueue(audio)
                lock.withLock { stats.decodedSeconds += frame.duration }
            }
            lock.withLock { stats.packetsDecoded += 1 }
            tryStartPlayback()
        } catch {
            Log.error(.demux, "音频解码失败：\(error.localizedDescription)")
        }
    }

    private func processVideoPacket(
        _ packet: UnsafeMutablePointer<AVPacket>,
        generation: Int
    ) {
        guard videoPipeline?.isCurrent(generation) ?? true else { return }
        guard let sampleBuilder, let videoRenderer else { return }
        guard let sample = sampleBuilder.makeSample(from: packet) else {
            Log.error(.render, "视频封装失败 pts=\(packet.pointee.pts)")
            return
        }
        lock.withLock { stats.videoPackets += 1 }

        let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
        let seconds = presentation.isValid ? presentation.seconds : 0
        let duration = CMSampleBufferGetDuration(sample).seconds
        let target = lock.withLock { videoSeekTarget }
        if let target {
            if seconds + max(duration, 0) <= target {
                lock.withLock { seekPrerollFrames += 1 }
            } else {
                let latency = Int((ProcessInfo.processInfo.systemUptime - seekRequestedAt) * 1000)
                let drift = seconds - target
                let info = lock.withLock { () -> (id: Int?, preroll: Int) in
                    videoSeekTarget = nil
                    stats.lastSeekLatencyMilliseconds = latency
                    stats.lastSeekPrerollFrames = seekPrerollFrames
                    stats.lastSeekDrift = drift
                    return (activeSeekID, seekPrerollFrames)
                }
                Log.info(
                    .render,
                    "seek 出画 id=\(info.id ?? -1) 目标=\(fmt(target))s 首帧=\(fmt(seconds))s 偏差=\(fmt(drift))s "
                        + "预滚帧=\(info.preroll) 松手到出画=\(latency)ms"
                )
            }
        }

        // seek 可能在封装期间发生；旧 generation 不能再进入新画面。
        guard videoPipeline?.isCurrent(generation) ?? true else { return }
        videoRenderer.enqueue(
            sample,
            isKeyframe: packet.pointee.flags & AV_PKT_FLAG_KEY != 0
        )

        let firstState = lock.withLock { () -> (needsFirst: Bool, startedAt: Double?) in
            (stats.firstVideoMilliseconds == 0, playStartedAt)
        }
        if firstState.needsFirst, let startedAt = firstState.startedAt {
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
            lock.withLock {
                if stats.firstVideoMilliseconds == 0 {
                    stats.firstVideoMilliseconds = elapsed
                    Log.info(.render, "首帧视频就绪 距开播=\(elapsed)ms")
                }
            }
        }
    }

    /// 跳转后把落在目标之前的音频裁掉，并记录首次出声的时刻。
    private func trimForSeek(_ frame: DecodedAudio) -> DecodedAudio? {
        guard let target = audioSeekTarget else { return frame }
        guard let trimmed = frame.trimming(to: target) else { return nil }
        let latency = Int((ProcessInfo.processInfo.systemUptime - seekRequestedAt) * 1000)
        audioSeekTarget = nil
        Log.info(
            .render,
            "seek 出声 id=\(activeSeekID ?? -1) 目标=\(fmt(target))s 首帧=\(fmt(trimmed.pts))s 耗时=\(latency)ms"
        )
        return trimmed
    }

    private func drainDecoder() {
        guard let decoder, let output else { return }
        do {
            for frame in try decoder.flush() {
                output.enqueue(frame)
                lock.withLock { stats.decodedSeconds += frame.duration }
            }
        } catch {
            Log.error(.demux, "解码器冲刷失败：\(error.localizedDescription)")
        }
    }

    private func markEnded() {
        condition.lock()
        let alreadyEnded = ended
        ended = true
        condition.broadcast()
        condition.unlock()
        guard !alreadyEnded else { return }
        tryStartPlayback()
        let snapshot = statistics
        Log.info(
            .render,
            "已读到文件结尾 音频=\(fmt(snapshot.decodedSeconds))s 视频包=\(snapshot.videoPackets) "
                + "剩余缓冲=\(fmt(output?.bufferedAhead ?? 0))s"
        )
    }

    /// 记录 seek 后显示层时间基偏差。SSIS-499 的问题在 maxDrift 上不可见：
    /// 音频和主时钟一致，但显示层时间基被旧时钟校正到 431s，画面停住/追赶。
    private func beginSeekTimebaseWatch() {
        lock.withLock {
            seekTimebaseJumpFlagged = false
            seekTimebaseWatchUntil = ProcessInfo.processInfo.systemUptime + 2
        }
    }

    private func recordSeekTimebaseOffset(_ offset: Double, atCompletion: Bool = false) {
        lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            guard atCompletion || now <= seekTimebaseWatchUntil else { return }
            guard atCompletion || !seekInProgress else { return }
            let magnitude = abs(offset)
            if atCompletion {
                stats.lastSeekTimebaseOffset = magnitude
            }
            stats.maxSeekTimebaseOffset = max(stats.maxSeekTimebaseOffset, magnitude)
            if Self.isSeekTimebaseJump(magnitude), !seekTimebaseJumpFlagged {
                seekTimebaseJumpFlagged = true
                stats.seekTimebaseJumpCount += 1
                Log.notice(
                    .render,
                    "seek 后显示层时间基异常 偏差=\(String(format: "%.2f", magnitude))s "
                        + "位置=\(String(format: "%.1f", clock.currentTime))s"
                )
            }
        }
    }

    private func performSeek(_ target: Double, id: Int, requestedAt: Double) {
        // seek 期间停掉 tick 的时钟/时间基校正；否则旧音频位置会在
        // output.reset 之前把刚移到目标的时钟拉回去。
        // 代次在进入/退出各推进一次：tick 只要在这段窗口内读过音频时间，
        // 前后代次必然不一致，旧值会被丢弃，不会回写主时钟。
        // 必须在 reader.seek 之前置位：SMB 上的 demuxer seek 可能阻塞几百毫秒，
        // 这段时间里 tick 仍可能用旧音频位置校正时钟。
        lock.withLock {
            seekInProgress = true
            seekEpoch &+= 1
        }
        defer {
            lock.withLock {
                seekInProgress = false
                seekEpoch &+= 1
            }
        }
        guard reader.seek(to: target) else {
            Log.error(.demux, "seek 被拒绝 id=\(id) 目标=\(fmt(target))s")
            finishSeek(id: id, success: false)
            return
        }
        resetBufferStallState()
        videoPipeline?.flush()
        lock.withLock { subtitleDecoder }?.reset()
        decoder?.reset(to: target)
        output?.reset()
        // output.reset() 清掉旧音频锚点后再移动主时钟，最后重置显示层，
        // 保证 tick 不会看到“新时间基 + 旧时钟”的组合。
        clock.seek(to: target)
        videoRenderer?.reset(to: target)
        // 只有主时钟本来就在播放时才立刻恢复音频；起播缓冲阶段时钟是暂停的，
        // 先 play 会让音频独自跑出十几秒，随后主时钟再追音频造成音画不同步。
        if currentWantsPlay, clock.isPlaying { output?.play() }
        beginSeekTimebaseWatch()
        recordSeekTimebaseOffset(videoRenderer?.timebaseOffset ?? 0, atCompletion: true)

        audioSeekTarget = output == nil ? nil : target
        Log.info(
            .render,
            "seek 完成 目标=\(fmt(target))s 时钟=\(fmt(clock.currentTime))s "
                + "播放中=\(clock.isPlaying) 速率=\(String(format: "%.2f", clock.rate)) "
                + "音频缓冲=\(fmt(output?.bufferedAhead ?? 0))s "
                + "视频缓冲=\(fmt(videoRenderer?.bufferedAhead ?? 0))s "
                + "时间基偏差=\(fmt(videoRenderer?.timebaseOffset ?? 0))s"
        )
        // 视频不做丢弃：显示层需要从关键帧开始的所有参考帧才能解出目标帧，
        // 早于目标时间的帧由它按时间基自动丢弃。
        lock.withLock {
            videoSeekTarget = videoRenderer == nil ? nil : target
            seekRequestedAt = requestedAt
            activeSeekID = id
            seekPrerollFrames = 0
            lastAudioPacketPos = -1
            lastAudioPacketPTS = -1
            lastVideoPacketPos = -1
            lastVideoPacketPTS = -1
        }

        condition.lock()
        ended = false
        condition.broadcast()
        condition.unlock()
        lock.withLock {
            stats.drained = false
            stats.seekCount += 1
        }
        // 纯视频没有音频解码回调来启动时基；缓冲暂停期间 seek 后必须在这里重新拉起。
        if currentWantsPlay {
            tryStartPlayback()
        }
        let queued = Int((ProcessInfo.processInfo.systemUptime - requestedAt) * 1000)
        Log.info(
            .render,
            "seek 执行 id=\(id) 位置=\(fmt(target))s 松手到执行=\(max(0, queued))ms"
        )
        finishSeek(id: id, success: true)
    }

    private func fail(_ message: String) {
        condition.lock()
        ended = true
        condition.broadcast()
        condition.unlock()
        lock.withLock { stats.failure = message }
        finishAllSeekWaiters()
        output?.pause()
        clock.pause()
        stopSyncTimer()
    }

    // MARK: - 时钟校正

    private func startSyncTimer() {
        // tryStartPlayback 可能同时从播放泵和主线程进入；timer 的创建/取消
        // 必须串行化，否则会创建出两个 tick 源，主时钟被重复校正。
        lock.lock()
        guard syncTimer == nil else {
            lock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "icemovie.clock.sync"))
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.tick() }
        syncTimer = timer
        timer.resume()
        lock.unlock()
    }

    private func stopSyncTimer() {
        lock.lock()
        let timer = syncTimer
        syncTimer = nil
        lock.unlock()
        timer?.cancel()
    }

    private func tick() {
        reader.setPlayhead(byteOffset: playheadByteOffset)
        let audioSupply = output?.bufferedAhead ?? Self.audioAheadSeconds
        reader.setSupply(audioAhead: audioSupply, videoAhead: videoRenderer?.bufferedAhead ?? 0)
        let seeking = lock.withLock { seekInProgress }
        if !seeking {
            videoRenderer?.syncTimebase()
        }
        if let renderer = videoRenderer {
            let offset = abs(renderer.timebaseOffset)
            lock.withLock { stats.maxVideoOffset = max(stats.maxVideoOffset, offset) }
            recordSeekTimebaseOffset(offset)
        }

        let buffering = isBuffering
        if buffering != wasBuffering {
            wasBuffering = buffering
            Log.info(
                .render,
                buffering
                    ? "开始缓冲 音频=\(fmt(bufferedAhead))s 视频=\(fmt(videoRenderer?.bufferedAhead ?? 0))s"
                    : "缓冲结束 位置=\(fmt(clock.currentTime))s"
            )
        }

        updateBufferingState()
        guard !lock.withLock({ stalledForBuffering }) else { return }
        // 先取 seek 代次再读音频时间；读取与校正之间若开始或完成了一次
        // seek，代次会前进，读到的旧音频时间对 seek 后的时钟位置是脏数据，
        // 必须丢弃，否则会把主时钟从目标位置拉回（画面停住/追赶/时间基跳变）。
        let seekEpochAtRead = lock.withLock { seekEpoch }
        guard let audioTime = output?.playedContentTime else {
            checkDrained()
            return
        }
        // 只保护布尔值不够：seek 完成后布尔值已复位，而音频时间还是 seek 前的
        // 旧值。代次一致才说明这段时间没有 seek 活动，音频时间可以信任。
        let canSync = lock.withLock { !seekInProgress && seekEpoch == seekEpochAtRead }
        if canSync {
            clock.sync(to: audioTime)

            lock.withLock {
                let drift = abs(clock.lastSyncDrift)
                if drift > stats.maxDrift {
                    stats.maxDrift = drift
                    stats.maxDriftPosition = clock.currentTime
                    stats.maxDriftAudioTime = audioTime
                    stats.maxDriftClockTime = clock.currentTime
                }
                if drift > 1.0 {
                    stats.clockJumpCount += 1
                    Log.notice(
                        .render,
                        "时钟大偏差 \(String(format: "%.2f", drift))s 音频=\(fmt(audioTime))s "
                            + "主时钟=\(fmt(clock.currentTime))s 位置=\(fmt(clock.currentTime))s"
                    )
                }
                if stats.startupMilliseconds == 0, audioTime > 0.1, let playStartedAt {
                    stats.startupMilliseconds = Int(
                        (ProcessInfo.processInfo.systemUptime - playStartedAt) * 1000
                    )
                    Log.info(.render, "首帧出声 启动耗时=\(stats.startupMilliseconds)ms")
                }
            }
        }

        tickCount += 1
        let ahead = output?.bufferedAhead ?? 0
        if tickCount % 50 == 0 {
            Log.debug(
                .render,
                "时钟 音频=\(fmt(audioTime))s 主时钟=\(fmt(clock.currentTime))s "
                    + "偏差=\(fmt(clock.lastSyncDrift))s 缓冲=\(fmt(ahead))s"
            )
        }
        // 包队列水位：每 30 秒一条 info，便于长播时判断供给是否稳定。
        if tickCount % 300 == 0 {
            let snapshot = statistics
            Log.info(
                .render,
                "播放水位 位置=\(fmt(clock.currentTime))s 音频缓冲=\(fmt(ahead))s "
                    + "视频缓冲=\(fmt(videoRenderer?.bufferedAhead ?? 0))s "
                    + "已缓冲=\(fmt(bufferedAheadSeconds))s "
                    + "已读包=\(snapshot.packetsRead) 视频包=\(snapshot.videoPackets) "
                    + "当前偏差=\(fmt(clock.lastSyncDrift))s 最大偏差=\(fmt(snapshot.maxDrift))s "
                    + "显示偏差=\(fmt(snapshot.maxVideoOffset))s 校正=\(snapshot.clockCorrections)"
            )
        }
        condition.lock()
        let endedSnapshot = ended
        condition.unlock()
        if !endedSnapshot, ahead < 0.4, tickCount % 20 == 0 {
            Log.info(.render, "缓冲偏低 剩余=\(fmt(ahead))s，可能供给不足")
        }
        checkDrained()
    }

    private func checkDrained() {
        condition.lock()
        let endedSnapshot = ended
        condition.unlock()
        guard endedSnapshot, clock.isPlaying else { return }
        let audioEmpty = (output?.bufferedAhead ?? 0) < 0.05
        let videoEmpty = (videoRenderer?.bufferedAhead ?? 0) < 0.05
        guard audioEmpty, videoEmpty else { return }

        stopSyncTimer()
        clock.pause()
        let audioMetrics = output?.metrics
        lock.withLock { stats.drained = true }
        let final = statistics
        Log.info(
            .render,
            "播放结束 位置=\(fmt(clock.currentTime))s 缓冲段=\(audioMetrics?.scheduledBuffers ?? 0) "
                + "内容断层=\(audioMetrics?.contentGaps ?? 0) 供给滞后=\(audioMetrics?.lateSchedules ?? 0) "
                + "视频包=\(final.videoPackets) 时钟校正=\(final.clockCorrections) "
                + "最大偏差=\(fmt(final.maxDrift))s"
        )
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
