import CFFmpeg
import Foundation

/// 内封文本字幕包的即时解码器。
///
/// 播放泵读到字幕包时直接解码成事件，SRT/mov_text/WebVTT 不再为字幕单独扫一遍文件。
/// 仅由播放泵线程创建与使用；ASS/SSA 走原始文本路径，不经过这里。
public final class SubtitlePacketDecoder: @unchecked Sendable {
    private let context: UnsafeMutablePointer<AVCodecContext>
    private let timeBase: AVRational

    init?(stream: UnsafeMutablePointer<AVStream>) {
        guard let params = stream.pointee.codecpar,
              let decoder = avcodec_find_decoder(params.pointee.codec_id) else { return nil }
        guard let context = avcodec_alloc_context3(decoder) else { return nil }
        guard avcodec_parameters_to_context(context, params) >= 0,
              avcodec_open2(context, decoder, nil) >= 0 else {
            var context_: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&context_)
            return nil
        }
        self.context = context
        self.timeBase = stream.pointee.time_base
    }

    deinit {
        var context_: UnsafeMutablePointer<AVCodecContext>? = context
        avcodec_free_context(&context_)
    }

    public func reset() {
        avcodec_flush_buffers(context)
    }

    public func decode(_ packet: UnsafeMutablePointer<AVPacket>) -> [SubtitlePacketEvent] {
        var subtitle = AVSubtitle()
        var got: Int32 = 0
        let result = avcodec_decode_subtitle2(context, &subtitle, &got, packet)
        guard result >= 0, got != 0 else { return [] }
        defer { avsubtitle_free(&subtitle) }

        let pts = MediaReader.seconds(packet.pointee.pts, timeBase: timeBase)
        let packetDuration = MediaReader.seconds(packet.pointee.duration, timeBase: timeBase)
        let decodedDuration = Double(subtitle.end_display_time - subtitle.start_display_time) / 1000
        let duration = packetDuration > 0.05
            ? packetDuration
            : (decodedDuration > 0.05 ? decodedDuration : 3.0)

        var events: [SubtitlePacketEvent] = []
        for index in 0..<Int(subtitle.num_rects) {
            guard let rect = subtitle.rects?[index] else { continue }
            let decoded: String?
            var style = "Default"
            var isDialogLine = false
            if let ass = rect.pointee.ass {
                let dialog = String(cString: ass)
                if let parts = MediaReader.parseASSEvent(dialog) {
                    decoded = parts.text
                    style = parts.style
                    isDialogLine = true
                } else {
                    decoded = dialog
                }
            } else if let text = rect.pointee.text {
                decoded = String(cString: text)
            } else {
                decoded = nil
            }
            guard let decoded, !decoded.isEmpty else { continue }

            let start = pts + Double(subtitle.start_display_time) / 1000
            events.append(
                SubtitlePacketEvent(
                    start: start,
                    end: start + max(0.1, duration),
                    style: style,
                    text: decoded,
                    isASS: isDialogLine
                )
            )
        }
        return events
    }
}
