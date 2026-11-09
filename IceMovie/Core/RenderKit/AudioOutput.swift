import AVFAudio
import DemuxKit
import Foundation
import IceCore

public enum RenderKitError: LocalizedError, Sendable {
    case audioFormatUnavailable
    case audioEngineFailed(String)

    public var errorDescription: String? {
        switch self {
        case .audioFormatUnavailable: "无法创建音频输出格式"
        case .audioEngineFailed(let detail): "音频引擎启动失败：\(detail)"
        }
    }
}

/// 音频输出：`AVAudioEngine` + `AVAudioPlayerNode`，中间串一个 `AVAudioUnitTimePitch` 做变速。
///
/// 输入统一为 48 kHz 立体声 Float32 交织样本（`AudioDecoder` 的规范化输出），
/// 这里只做「交织 → 平面」的搬运，不再重采样。设备采样率交给引擎的混音器处理。
public final class AudioOutput: @unchecked Sendable {
    public struct Metrics: Sendable {
        public var scheduledBuffers = 0
        public var playedBuffers = 0
        public var scheduledFrames: Int64 = 0
        public var contentGaps = 0
        public var lateSchedules = 0
        public var maxLateMilliseconds = 0
        public var firstSampleTime: Int64 = 0
    }

    public let format: AVAudioFormat

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let lock = NSLock()

    /// 首个排入缓冲对应的媒体时间。
    private var anchorContentTime: Double?
    /// 已排入数据的媒体结束时间。
    private var scheduledEnd: Double?
    /// 最近一次能从 playerTime 读到的播放位置；暂停/重置后 playerTime 可能失效。
    private var lastPlayedContentTime: Double?
    private var stats = Metrics()
    private var started = false
    /// 当前播放锚点下的 sampleTime 基线；seek/stop 后会重置。
    private var sampleBaselineSet = false

    public init() throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioFormatSpec.sampleRate,
            channels: AudioFormatSpec.channels,
            interleaved: false
        ) else {
            throw RenderKitError.audioFormatUnavailable
        }
        self.format = format

        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw RenderKitError.audioEngineFailed(error.localizedDescription)
        }
        started = true
        let device = engine.outputNode.outputFormat(forBus: 0)
        Log.info(
            .render,
            "音频引擎就绪 输入=\(Int(format.sampleRate))Hz/\(format.channelCount)ch "
                + "设备=\(Int(device.sampleRate))Hz/\(device.channelCount)ch"
        )
    }

    deinit {
        if started {
            engine.stop()
        }
    }

    // MARK: - 排入

    public func setVolume(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        engine.mainMixerNode.outputVolume = clamped
    }

    /// 排入一段解码后的音频。`pts` 用于检测内容断层与推算时钟锚点。
    public func enqueue(_ audio: DecodedAudio) {
        guard audio.frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(audio.frameCount)
              ) else { return }

        buffer.frameLength = AVAudioFrameCount(audio.frameCount)
        let channels = Int(format.channelCount)
        if let destination = buffer.floatChannelData {
            for channel in 0..<channels {
                let target = destination[channel]
                for index in 0..<audio.frameCount {
                    target[index] = audio.samples[index * channels + channel]
                }
            }
        }

        let playedBefore = currentPlayedContentTime()
        lock.lock()
        if let end = scheduledEnd {
            if audio.pts - end > 0.05 {
                stats.contentGaps += 1
                Log.error(
                    .render,
                    "音频内容断层 上次结束=\(fmt(end))s 本次起点=\(fmt(audio.pts))s"
                )
            }
            // 只有真正在播放时才可能欠载：起播前的预缓冲阶段没有消费者，
            // 缓冲短是正常的，不能算作供给滞后。
            if player.isPlaying {
                let ahead = end - (playedBefore ?? (anchorContentTime ?? 0))
                if ahead < 0.05 {
                    let late = Int((0.05 - ahead) * 1000)
                    stats.lateSchedules += 1
                    stats.maxLateMilliseconds = max(stats.maxLateMilliseconds, late)
                    Log.error(.render, "音频供给滞后 \(late)ms，可能听到断续")
                }
            }
        }
        if anchorContentTime == nil {
            anchorContentTime = max(0, audio.pts)
        }
        scheduledEnd = max(scheduledEnd ?? audio.pts, audio.pts) + audio.duration
        stats.scheduledBuffers += 1
        stats.scheduledFrames += Int64(audio.frameCount)
        lock.unlock()

        player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self.stats.playedBuffers += 1 }
        }
    }

    // MARK: - 控制

    public func play() {
        guard started else { return }
        player.play()
    }

    public func pause() {
        guard started else { return }
        player.pause()
    }

    /// 停止并清空已排入的数据，为跳转后的新位置重置时间锚点。
    public func reset() {
        guard started else { return }
        // 先停播放器（会取引擎锁），再清自己的状态，避免与其他线程的锁序反转。
        player.stop()
        lock.withLock {
            anchorContentTime = nil
            scheduledEnd = nil
            lastPlayedContentTime = nil
            sampleBaselineSet = false
            stats.firstSampleTime = 0
        }
    }

    /// 播放速率。1.0 为原速，范围 0.5–2.0。
    public func setRate(_ rate: Float) {
        timePitch.rate = min(max(rate, 0.5), 2.0)
        Log.info(.render, "播放速率=\(String(format: "%.2f", rate))")
    }

    // MARK: - 时钟

    /// 音频渲染位置换算出的媒体时间；未在播放或尚无排入数据时返回 nil。
    public var playedContentTime: Double? {
        currentPlayedContentTime()
    }

    /// 音频时钟换算；`baseline` 是当前锚点下 player node 的首个 sampleTime。
    static func playedTime(
        anchor: Double,
        sampleTime: Int64,
        baseline: Int64,
        sampleRate: Double
    ) -> Double {
        guard sampleRate > 0 else { return anchor }
        return anchor + Double(max(0, sampleTime - baseline)) / sampleRate
    }

    /// 注意：必须在**不持有** `lock` 的情况下调用。
    /// `AVAudioPlayerNode` 的方法会取引擎内部的锁，而重置路径是「先引擎锁、后本对象锁」，
    /// 若这里持锁调用就会形成锁序反转，之前正是它让拉流线程卡死在跳转里。
    private func currentPlayedContentTime() -> Double? {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else { return nil }

        lock.lock()
        defer { lock.unlock() }
        guard let anchor = anchorContentTime else { return nil }
        // playerTime.sampleTime 是节点自开始以来的绝对采样数；seek 后
        // stop/play 不一定把它清零。必须减去当前锚点的第一帧基线，
        // 否则一次 seek 会把音频时钟直接跳前几十秒，视频跟着主时钟一起错位。
        if !sampleBaselineSet {
            sampleBaselineSet = true
            stats.firstSampleTime = playerTime.sampleTime
        }
        let played = Self.playedTime(
            anchor: anchor,
            sampleTime: playerTime.sampleTime,
            baseline: stats.firstSampleTime,
            sampleRate: playerTime.sampleRate
        )
        lastPlayedContentTime = played
        return played
    }

    /// 尚有多少秒数据排在播放位置之后。
    public var bufferedAhead: Double {
        let played = currentPlayedContentTime()
        return lock.withLock {
            guard let end = scheduledEnd else { return 0 }
            let position = played ?? lastPlayedContentTime ?? anchorContentTime ?? 0
            return max(0, end - position)
        }
    }

    public var metrics: Metrics {
        lock.withLock { stats }
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
