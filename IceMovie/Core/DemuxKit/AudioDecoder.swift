import CFFmpeg
import Foundation
import IceCore

/// 解码后的一段 PCM。样本为**交织**的 Float32，声道数固定为 2（design.md 的规范化输出）。
public struct DecodedAudio: Sendable {
    public let samples: [Float]
    public let frameCount: Int
    public let pts: Double
    public let sampleRate: Double

    public init(samples: [Float], frameCount: Int, pts: Double, sampleRate: Double) {
        self.samples = samples
        self.frameCount = frameCount
        self.pts = pts
        self.sampleRate = sampleRate
    }

    public var duration: Double { Double(frameCount) / sampleRate }

    /// 把落在目标时间之前的部分裁掉。整段都在目标之前时返回 nil。
    ///
    /// 跳转后音频必须从目标位置开始出声，否则会比画面早一个关键帧的距离。
    public func trimming(to target: Double) -> DecodedAudio? {
        let end = pts + duration
        if end <= target { return nil }
        if pts >= target { return self }

        let channels = 2
        let skip = Int(((target - pts) * sampleRate).rounded(.up))
        guard skip > 0, skip < frameCount else { return pts >= target ? self : nil }
        let start = skip * channels
        guard start < samples.count else { return nil }
        return DecodedAudio(
            samples: Array(samples[start...]),
            frameCount: frameCount - skip,
            pts: target,
            sampleRate: sampleRate
        )
    }
}

/// 音频解码器：FFmpeg 解码 + `libswresample` 重采样到统一的 48 kHz 立体声 Float32。
///
/// 统一输出格式有两个好处：音频输出层不必为每种编码准备不同格式；
/// 主时钟推进速率不随素材采样率变化，音画同步只需要一套参数。
public final class AudioDecoder: @unchecked Sendable {
    public static let outputSampleRate: Int32 = AudioFormatSpec.sampleRateInt
    public static let outputChannels: UInt32 = AudioFormatSpec.channels

    public let codecName: String
    public let inputSampleRate: Int32
    public let inputChannels: Int

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var resampler: OpaquePointer?
    private let timeBase: Double
    private var nextPTS: Double = 0
    private var flushed = false

    public init(stream: UnsafeMutablePointer<AVStream>) throws {
        guard let params = stream.pointee.codecpar else {
            throw DemuxError.decoderUnavailable("缺少编码参数")
        }
        let name = String(cString: avcodec_get_name(params.pointee.codec_id))
        codecName = name
        inputSampleRate = params.pointee.sample_rate
        inputChannels = Int(params.pointee.ch_layout.nb_channels)
        timeBase = Double(stream.pointee.time_base.num) / Double(stream.pointee.time_base.den)

        guard let decoder = avcodec_find_decoder(params.pointee.codec_id),
              let context = avcodec_alloc_context3(decoder) else {
            throw DemuxError.decoderUnavailable(name)
        }
        codecContext = context

        guard avcodec_parameters_to_context(context, params) >= 0,
              avcodec_open2(context, decoder, nil) >= 0 else {
            avcodec_free_context(&codecContext)
            throw DemuxError.decoderUnavailable(name)
        }

        var inputLayout = context.pointee.ch_layout
        if inputLayout.nb_channels == 0 {
            av_channel_layout_default(&inputLayout, context.pointee.ch_layout.nb_channels)
        }
        var outputLayout = AVChannelLayout()
        av_channel_layout_default(&outputLayout, Int32(Self.outputChannels))

        var resampler: OpaquePointer?
        let created = swr_alloc_set_opts2(
            &resampler,
            &outputLayout, AV_SAMPLE_FMT_FLT, Self.outputSampleRate,
            &inputLayout, context.pointee.sample_fmt, context.pointee.sample_rate,
            0, nil
        )
        guard created >= 0, let resampler, swr_init(resampler) >= 0 else {
            avcodec_free_context(&codecContext)
            throw DemuxError.decoderUnavailable("重采样器初始化失败：\(name)")
        }
        self.resampler = resampler

        Log.info(
            .demux,
            "音频解码器就绪 codec=\(name) 输入=\(inputSampleRate)Hz/\(inputChannels)ch "
                + "输出=\(Self.outputSampleRate)Hz/\(Self.outputChannels)ch"
        )
    }

    deinit {
        if let resampler {
            var value: OpaquePointer? = resampler
            swr_free(&value)
        }
        avcodec_free_context(&codecContext)
    }

    // MARK: - 解码

    public func decode(_ packet: UnsafeMutablePointer<AVPacket>) throws -> [DecodedAudio] {
        let sent = avcodec_send_packet(codecContext, packet)
        guard sent >= 0 else { throw DemuxError.decodeFailed(sent) }
        return try drain()
    }

    /// 跳转后清空解码器内部状态。
    public func reset(to seconds: Double) {
        guard let codecContext else { return }
        avcodec_flush_buffers(codecContext)
        if let resampler {
            // 重采样器里可能残留前一位置的样本，一并丢弃。
            swr_close(resampler)
            swr_init(resampler)
        }
        flushed = false
        nextPTS = seconds
    }

    /// 冲刷解码器里剩余的帧。
    public func flush() throws -> [DecodedAudio] {
        guard !flushed else { return [] }
        flushed = true
        let sent = avcodec_send_packet(codecContext, nil)
        guard sent >= 0 else { throw DemuxError.decodeFailed(sent) }
        return try drain()
    }

    private func drain() throws -> [DecodedAudio] {
        guard let codecContext else { return [] }
        var outputs: [DecodedAudio] = []
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        guard let frame else { throw DemuxError.decodeFailed(-1) }

        while true {
            let received = avcodec_receive_frame(codecContext, frame)
            if received == ffmpeg_eof || received == ffmpeg_eagain { break }
            guard received >= 0 else { throw DemuxError.decodeFailed(received) }
            if let converted = convert(frame) {
                outputs.append(converted)
            }
            av_frame_unref(frame)
        }
        return outputs
    }

    private func convert(_ frame: UnsafeMutablePointer<AVFrame>) -> DecodedAudio? {
        guard let resampler else { return nil }
        let frameCount = Int(frame.pointee.nb_samples)
        guard frameCount > 0 else { return nil }

        let delay = swr_get_delay(resampler, Int64(inputSampleRate))
        let capacity = Int(
            av_rescale_rnd(delay + Int64(frameCount), Int64(Self.outputSampleRate), Int64(inputSampleRate), AV_ROUND_UP)
        )
        guard capacity > 0 else { return nil }

        var samples = [Float](repeating: 0, count: capacity * Int(Self.outputChannels))
        var produced = 0
        samples.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var output: UnsafeMutablePointer<UInt8>? = UnsafeMutableRawPointer(mutating: base)
                .assumingMemoryBound(to: UInt8.self)
            let input = frame.pointee.extended_data.map {
                UnsafeRawPointer($0).assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
            }
            produced = Int(
                swr_convert(resampler, &output, Int32(capacity), input, Int32(frameCount))
            )
        }
        guard produced > 0 else { return nil }
        samples.removeLast(samples.count - produced * Int(Self.outputChannels))

        let timestamp = frame.pointee.best_effort_timestamp
        let pts: Double
        if timestamp == ffmpeg_nopts {
            pts = nextPTS
        } else {
            pts = Double(timestamp) * timeBase
        }
        nextPTS = pts + Double(frameCount) / Double(inputSampleRate)

        return DecodedAudio(
            samples: samples,
            frameCount: produced,
            pts: pts,
            sampleRate: Double(Self.outputSampleRate)
        )
    }
}
