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
        public var clockCorrections = 0
        public var startupMilliseconds = 0
        public var firstVideoMilliseconds = 0
        public var maxVideoOffset: Double = 0
        public var seekCount = 0
        public var lastSeekLatencyMilliseconds = 0
        public var lastSeekPrerollFrames = 0
        public var lastSeekDrift: Double = 0
        public var droppedSeeks = 0
        /// 全部数据都已播完（区别于「读到文件结尾」）。
        public var drained = false
        public var failure: String?
    }

    /// 起播前先垫这么多秒的音频。
    private static let prerollSeconds = 1.0
    /// 视频最多领先主时钟这么多秒。
    private static let videoAheadSeconds = 3.0

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

    private var stats = Statistics()
    private var wantsPlay = false
    private var stopped = false
    private var ended = false
    private var pendingSeek: (target: Double, id: Int, requestedAt: Double)?
    private var seekRequests = 0
    private var pumpThread: Thread?
    private var syncTimer: DispatchSourceTimer?
    private var playStartedAt: Double?
    private var pausedAt: Double?
    private var tickCount = 0
    /// 跳转后各条流各自的追赶目标，追上了就清空。
    private var audioSeekTarget: Double?
    private var videoSeekTarget: Double?
    private var activeSeekID: Int?
    private var seekRequestedAt: Double = 0
    private var seekPrerollFrames = 0
    private var volume: Float = 1
    private var wasBuffering = false

    public init(reader: MediaReader) throws {
        let clock = MasterClock()
        self.clock = clock
        self.reader = reader
        duration = reader.duration

        var audioDecoder: AudioDecoder?
        var audioOutput: AudioOutput?
        var audioIndex: Int?
        if let track = reader.audioTrack, let stream = reader.stream(at: track.index) {
            audioDecoder = try AudioDecoder(stream: stream)
            audioOutput = try AudioOutput()
            audioIndex = track.index
        }

        var builder: SampleBufferBuilder?
        var videoIndex: Int?
        if let track = reader.videoTrack, let stream = reader.stream(at: track.index) {
            builder = try SampleBufferBuilder(stream: stream)
            videoIndex = track.index
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
    }

    deinit {
        stopSyncTimer()
        condition.lock()
        stopped = true
        wantsPlay = false
        condition.broadcast()
        condition.unlock()
    }

    // MARK: - 控制

    public func play() {
        guard !stopped else { return }
        startPumpIfNeeded()

        if let pausedAt {
            Log.info(
                .render,
                "恢复播放 暂停时长=\(String(format: "%.1f", ProcessInfo.processInfo.systemUptime - pausedAt))s"
            )
        }
        pausedAt = nil
        condition.lock()
        wantsPlay = true
        condition.broadcast()
        condition.unlock()
        tryStartPlayback()
    }

    /// 缓冲足够才真正开声，避免起播瞬间供给不足造成断续。
    private func tryStartPlayback() {
        guard wantsPlay, !clock.isPlaying, !stopped else { return }
        if output != nil {
            guard ended || output?.bufferedAhead ?? 0 >= Self.prerollSeconds else { return }
        } else {
            // 纯视频：先攒几帧再开时基，避免第一帧就要等解码。
            let ready = videoRenderer?.metrics.enqueued ?? 0
            guard ended || ready >= 3 else { return }
        }
        if playStartedAt == nil {
            playStartedAt = ProcessInfo.processInfo.systemUptime
        }
        output?.play()
        clock.play()
        videoRenderer?.syncTimebase()
        startSyncTimer()
        Log.info(
            .render,
            "开始播放 位置=\(fmt(clock.currentTime))s 预缓冲=\(fmt(output?.bufferedAhead ?? 0))s"
        )
    }

    public func pause() {
        guard !stopped else { return }
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
        guard !stopped else { return -1 }
        let target = min(max(0, seconds), max(0, duration - 0.1))
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

    public func setRate(_ rate: Float) {
        clock.setRate(rate)
        output?.setRate(rate)
        videoRenderer?.syncTimebase()
        Log.info(
            .render,
            "主时钟速率=\(String(format: "%.2f", rate)) 位置=\(fmt(clock.currentTime))s"
        )
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
        condition.broadcast()
        condition.unlock()
        stopSyncTimer()
        output?.pause()
        output?.reset()
        clock.pause()
        Log.info(.render, "停止 位置=\(fmt(clock.currentTime))s")
    }

    // MARK: - 状态

    public var isPlaying: Bool { clock.isPlaying }

    public var statistics: Statistics {
        lock.withLock {
            var snapshot = stats
            snapshot.clockCorrections = clock.correctionCount
            snapshot.maxDrift = max(snapshot.maxDrift, abs(clock.lastSyncDrift))
            return snapshot
        }
    }

    public var bufferedAhead: Double { output?.bufferedAhead ?? 0 }

    /// 播放中供给不足：音频与视频缓冲都低于 250 ms 时视为缓冲。
    public var isBuffering: Bool {
        guard isPlaying, !stopped else { return false }
        let audioLow = output.map { _ in bufferedAhead < 0.25 } ?? true
        let videoLow = videoRenderer.map { renderer in renderer.bufferedAhead < 0.25 } ?? true
        return audioLow && videoLow
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
        guard pumpThread == nil else { return }
        let thread = Thread { [weak self] in self?.pumpLoop() }
        thread.name = "icemovie.playback.pump"
        thread.qualityOfService = .userInteractive
        pumpThread = thread
        thread.start()
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
            while !stopped, pendingSeek == nil, !ended {
                // 播放中要持续供给；暂停时也先垫到预缓冲水位，起播才不会欠载。
                if wantsPlay || (output?.bufferedAhead ?? 0) < Self.prerollSeconds {
                    break
                }
                condition.wait()
            }
            if stopped {
                condition.unlock()
                break
            }
            let request = pendingSeek
            pendingSeek = nil
            let latest = seekRequests
            condition.unlock()

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
            if !ended {
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
            lock.withLock {
                stats.bytesRead += Int64(max(0, packet.pointee.size))
            }
            if index == audioStreamIndex {
                decodeAudio(packet)
            } else if index == videoStreamIndex {
                enqueueVideo(packet)
            }
            av_packet_unref(packet)
        }
    }

    private func isAheadEnough() -> Bool {
        if let output, output.bufferedAhead > 1.5 { return true }
        if let videoRenderer, videoRenderer.bufferedAhead > Self.videoAheadSeconds { return true }
        return false
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

    private func enqueueVideo(_ packet: UnsafeMutablePointer<AVPacket>) {
        guard let sampleBuilder, let videoRenderer else { return }
        guard let sample = sampleBuilder.makeSample(from: packet) else {
            Log.error(.render, "视频封装失败 pts=\(packet.pointee.pts)")
            return
        }
        lock.withLock { stats.videoPackets += 1 }

        let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
        let seconds = presentation.isValid ? presentation.seconds : 0
        let duration = CMSampleBufferGetDuration(sample).seconds
        if let target = videoSeekTarget {
            if seconds + max(duration, 0) <= target {
                seekPrerollFrames += 1
            } else {
                let latency = Int((ProcessInfo.processInfo.systemUptime - seekRequestedAt) * 1000)
                let drift = seconds - target
                videoSeekTarget = nil
                lock.withLock {
                    stats.lastSeekLatencyMilliseconds = latency
                    stats.lastSeekPrerollFrames = seekPrerollFrames
                    stats.lastSeekDrift = drift
                }
                Log.info(
                    .render,
                    "seek 出画 id=\(activeSeekID ?? -1) 目标=\(fmt(target))s 首帧=\(fmt(seconds))s 偏差=\(fmt(drift))s "
                        + "预滚帧=\(seekPrerollFrames) 松手到出画=\(latency)ms"
                )
            }
        }

        videoRenderer.enqueue(sample)

        if stats.firstVideoMilliseconds == 0, let playStartedAt {
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - playStartedAt) * 1000)
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
        lock.withLock {
            guard !ended else { return }
            ended = true
        }
        tryStartPlayback()
        let snapshot = statistics
        Log.info(
            .render,
            "已读到文件结尾 音频=\(fmt(snapshot.decodedSeconds))s 视频包=\(snapshot.videoPackets) "
                + "剩余缓冲=\(fmt(output?.bufferedAhead ?? 0))s"
        )
    }

    private func performSeek(_ target: Double, id: Int, requestedAt: Double) {
        guard reader.seek(to: target) else {
            Log.error(.demux, "seek 被拒绝 id=\(id) 目标=\(fmt(target))s")
            return
        }
        decoder?.reset(to: target)
        output?.reset()
        // reset 会把播放器停掉；如果本来就在播，立刻重新挂上，否则跳转后只剩画面没有声音。
        if wantsPlay { output?.play() }
        videoRenderer?.reset(to: target)
        clock.seek(to: target)

        audioSeekTarget = output == nil ? nil : target
        // 视频不做丢弃：显示层需要从关键帧开始的所有参考帧才能解出目标帧，
        // 早于目标时间的帧由它按时间基自动丢弃。
        videoSeekTarget = videoRenderer == nil ? nil : target
        seekRequestedAt = requestedAt
        activeSeekID = id
        seekPrerollFrames = 0

        lock.withLock {
            ended = false
            stats.drained = false
            stats.seekCount += 1
        }
        let queued = Int((ProcessInfo.processInfo.systemUptime - requestedAt) * 1000)
        Log.info(
            .render,
            "seek 执行 id=\(id) 位置=\(fmt(target))s 松手到执行=\(max(0, queued))ms"
        )
    }

    private func fail(_ message: String) {
        lock.withLock {
            stats.failure = message
            ended = true
        }
        output?.pause()
        clock.pause()
    }

    // MARK: - 时钟校正

    private func startSyncTimer() {
        guard syncTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "icemovie.clock.sync"))
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.tick() }
        syncTimer = timer
        timer.resume()
    }

    private func stopSyncTimer() {
        syncTimer?.cancel()
        syncTimer = nil
    }

    private func tick() {
        videoRenderer?.syncTimebase()
        if let renderer = videoRenderer {
            let offset = abs(renderer.timebaseOffset)
            lock.withLock { stats.maxVideoOffset = max(stats.maxVideoOffset, offset) }
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

        guard let audioTime = output?.playedContentTime else {
            checkDrained()
            return
        }
        clock.sync(to: audioTime)

        lock.withLock {
            stats.maxDrift = max(stats.maxDrift, abs(clock.lastSyncDrift))
            if stats.startupMilliseconds == 0, audioTime > 0.1, let playStartedAt {
                stats.startupMilliseconds = Int(
                    (ProcessInfo.processInfo.systemUptime - playStartedAt) * 1000
                )
                Log.info(.render, "首帧出声 启动耗时=\(stats.startupMilliseconds)ms")
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
                    + "已读包=\(snapshot.packetsRead) 视频包=\(snapshot.videoPackets) "
                    + "当前偏差=\(fmt(clock.lastSyncDrift))s 最大偏差=\(fmt(snapshot.maxDrift))s "
                    + "显示偏差=\(fmt(snapshot.maxVideoOffset))s 校正=\(snapshot.clockCorrections)"
            )
        }
        if !ended, ahead < 0.4, tickCount % 20 == 0 {
            Log.info(.render, "缓冲偏低 剩余=\(fmt(ahead))s，可能供给不足")
        }
        checkDrained()
    }

    private func checkDrained() {
        guard ended, clock.isPlaying else { return }
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
