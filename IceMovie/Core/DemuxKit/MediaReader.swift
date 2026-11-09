import CFFmpeg
import Foundation
import IceCore

public enum MediaReaderError: LocalizedError, Sendable {    case openFailed(Int32)
    case streamInfoFailed(Int32)
    case noAudioStream
    case noVideoStream
    case seekFailed(Int32)
    case readFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let code): "打开媒体失败（\(code)）"
        case .streamInfoFailed(let code): "读取流信息失败（\(code)）"
        case .noAudioStream: "该文件没有音频轨"
        case .noVideoStream: "该文件没有视频轨"
        case .seekFailed(let code): "跳转失败（\(code)）"
        case .readFailed(let code): "读取失败（\(code)）"
        }
    }
}

/// 容器内的附件（主要是字幕字体）。数据在打开时已由 demuxer 读入内存。
public struct MediaAttachment: Sendable {
    public let name: String
    public let data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }

    public var isFont: Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".ttf") || lower.hasSuffix(".otf") || lower.hasSuffix(".ttc")
    }
}

/// 容器内的一条字幕事件（未解析成时间轴）。用于按窗口分片提取内封字幕。
public struct SubtitlePacketEvent: Sendable {
    public let start: Double
    public let end: Double
    public let style: String
    public let text: String
    public let isASS: Bool

    public init(start: Double, end: Double, style: String, text: String, isASS: Bool) {
        self.start = start
        self.end = end
        self.style = style
        self.text = text
        self.isASS = isASS
    }
}

/// 解封装读取器：持有一个打开后的容器，提供按包读取与跳转。
///
/// 只能用 `open(path:)` / `open(source:label:)` 构造。构造函数本身不做任何 C 调用，
/// 避免在 Swift 的类初始化过程中执行 FFmpeg 逻辑。
/// 只能在单一串行上下文里使用（当前是播放泵线程），因此标记为 `@unchecked Sendable`。
///
/// 自定义 `AVIOContext` 的所有权归 `AVIOBridge`：调用 `avformat_open_input` 前
/// 必须置位 `AVFMT_FLAG_CUSTOM_IO`，否则 `avformat_close_input` 会释放它造成重复释放。
public final class MediaReader: @unchecked Sendable {
    public enum ReadResult: Sendable {
        case packet
        case endOfFile
        case failed(Int32)
    }

    private var format: UnsafeMutablePointer<AVFormatContext>?
    private let bridge: AVIOBridge?
    public let info: MediaInfo

    /// 最近一次 seek 的现场，用于在读到第一个包时补一条「落点」日志。
    private var pendingSeek: (target: Double, startedAt: Double)?

    private init(format: UnsafeMutablePointer<AVFormatContext>?, bridge: AVIOBridge?, info: MediaInfo) {
        self.format = format
        self.bridge = bridge
        self.info = info
    }

    deinit {
        close()
        bridge?.releaseContext()
    }

    // MARK: - 打开

    public static func open(path: String) throws -> MediaReader {
        var context: UnsafeMutablePointer<AVFormatContext>?
        let opened = avformat_open_input(&context, path, nil, nil)
        guard opened >= 0, let context else { throw MediaReaderError.openFailed(opened) }

        do {
            let info = try loadInfo(format: context, label: path)
            return MediaReader(format: context, bridge: nil, info: info)
        } catch {
            var failed: UnsafeMutablePointer<AVFormatContext>? = context
            avformat_close_input(&failed)
            throw error
        }
    }

    public static func open(source: any ByteSource, label: String) throws -> MediaReader {
        let bridge = try AVIOBridge(source: source)
        guard let context = avformat_alloc_context() else {
            bridge.releaseContext()
            throw MediaReaderError.openFailed(-1)
        }
        context.pointee.pb = bridge.context
        // 自定义 IO 由我们自己的 bridge 释放。
        context.pointee.flags |= AVFMT_FLAG_CUSTOM_IO

        var opened: UnsafeMutablePointer<AVFormatContext>? = context
        let result = avformat_open_input(&opened, nil, nil, nil)
        guard result >= 0, let opened else {
            // avformat_open_input 失败时会自行释放 context，这里只释放我们自己创建的 AVIO。
            bridge.releaseContext()
            throw MediaReaderError.openFailed(result)
        }

        do {
            let info = try loadInfo(format: opened, label: label)
            return MediaReader(format: opened, bridge: bridge, info: info)
        } catch {
            var failed: UnsafeMutablePointer<AVFormatContext>? = opened
            avformat_close_input(&failed)
            bridge.releaseContext()
            throw error
        }
    }

    public func close() {
        guard format != nil else { return }
        avformat_close_input(&format)
        format = nil
    }

    // MARK: - 轨道

    public var audioTrack: MediaStreamInfo? { info.streams.first { $0.kind == .audio } }
    public var videoTrack: MediaStreamInfo? { info.streams.first { $0.kind == .video } }

    /// 容器内的字体等附件。MKV 将字体放在 attachment 流的 extradata 中，
    /// `avformat_find_stream_info` 时已随 Tracks 头一起读入。
    public func attachments() -> [MediaAttachment] {
        guard let format else { return [] }
        var result: [MediaAttachment] = []
        for index in 0..<Int(format.pointee.nb_streams) {
            guard let stream = format.pointee.streams?[index],
                  let params = stream.pointee.codecpar,
                  params.pointee.codec_type == AVMEDIA_TYPE_ATTACHMENT,
                  let extra = params.pointee.extradata,
                  params.pointee.extradata_size > 0,
                  params.pointee.extradata_size < 64 * 1024 * 1024 else { continue }
            let name = stream.pointee.metadata.flatMap {
                Self.metadata($0, key: "filename")
            } ?? "attachment-\(index)"
            let data = Data(bytes: extra, count: Int(params.pointee.extradata_size))
            result.append(MediaAttachment(name: name, data: data))
        }
        return result
    }

    private static func metadata(_ dict: OpaquePointer, key: String) -> String? {
        guard let entry = av_dict_get(dict, key, nil, 0), let value = entry.pointee.value else {
            return nil
        }
        let text = String(cString: value)
        return text.isEmpty ? nil : text
    }

    /// 供解码器初始化使用的流指针，调用方不得持有超过 reader 生命周期。
    public func stream(at index: Int) -> UnsafeMutablePointer<AVStream>? {
        guard let format, index >= 0, index < Int(format.pointee.nb_streams) else { return nil }
        return format.pointee.streams?[index]
    }

    public var duration: Double { info.duration }

    /// 播放源已预读到当前读位置之后的字节数；进度条缓冲区间使用。
    public var bufferedAheadBytes: Int64 { bridge?.bufferedAheadBytes ?? 0 }

    /// 播放源的文件长度（用于把缓冲字节换算成秒）。
    public var byteLength: Int64? { bridge?.sourceLength }

    /// 播放源最近的实际下载速度；本地源为 0。
    public var downloadBytesPerSecond: Double { bridge?.downloadBytesPerSecond ?? 0 }

    // MARK: - 读取

    public func read(into packet: UnsafeMutablePointer<AVPacket>) -> ReadResult {
        guard let format else { return .failed(-1) }
        let result = av_read_frame(format, packet)
        if result == ffmpeg_eof {
            return .endOfFile
        }
        guard result >= 0 else { return .failed(result) }

        if let pending = pendingSeek, let stream = stream(at: Int(packet.pointee.stream_index)) {
            let seconds = Self.seconds(packet.pointee.pts, timeBase: stream.pointee.time_base)
            let elapsed = (ProcessInfo.processInfo.systemUptime - pending.startedAt) * 1000
            let keyframe = packet.pointee.flags & AV_PKT_FLAG_KEY != 0
            Log.info(
                .demux,
                "seek 落点 目标=\(Self.fmt(pending.target))s 关键帧=\(keyframe ? "是" : "否") "
                    + "pts=\(Self.fmt(seconds))s 距目标=\(Self.fmt(seconds - pending.target))s "
                    + "首包耗时=\(Int(elapsed))ms"
            )
            pendingSeek = nil
        }

        if packet.pointee.flags & AV_PKT_FLAG_CORRUPT != 0 {
            Log.debug(.demux, "读到损坏包 pts=\(packet.pointee.pts) size=\(packet.pointee.size)")
        }
        return .packet
    }

    /// 提取一条内封字幕轨，转成 ASS 文档（供 SubtitleKit 解析）。
    ///
    /// 只用于打开后的短时间扫描；调用方应在完成后重新 seek 到 0。
    public func readSubtitleScript(streamIndex: Int) throws -> String {
        guard let stream = stream(at: streamIndex),
              let params = stream.pointee.codecpar else {
            throw MediaReaderError.streamInfoFailed(-1)
        }
        let codecName = String(cString: avcodec_get_name(params.pointee.codec_id))
        guard let decoder = avcodec_find_decoder(params.pointee.codec_id),
              let context = avcodec_alloc_context3(decoder) else {
            throw MediaReaderError.noVideoStream
        }
        var context_: UnsafeMutablePointer<AVCodecContext>? = context
        defer { avcodec_free_context(&context_) }

        guard avcodec_parameters_to_context(context, params) >= 0,
              avcodec_open2(context, decoder, nil) >= 0 else {
            Log.error(.subtitle, "字幕解码器打开失败 codec=\(codecName)")
            throw MediaReaderError.streamInfoFailed(-1)
        }

        guard seek(to: 0) else { throw MediaReaderError.seekFailed(-1) }
        Log.info(.subtitle, "内封字幕提取开始 stream=\(streamIndex) codec=\(codecName)")

        // 跳过非字幕流，减少容器读取时的不必要拷贝。
        if let format {
            for index in 0..<Int(format.pointee.nb_streams) where index != streamIndex {
                format.pointee.streams?[index]?.pointee.discard = AVDISCARD_ALL
            }
        }

        var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard let packet else { throw MediaReaderError.readFailed(-1) }

        var dialogues: [String] = []
        var subtitleCount = 0
        let isASS = codecName == "ass" || codecName == "ssa"
        let header = Self.subtitleHeader(context)
        let timeBase = stream.pointee.time_base
        let timeScale = Double(timeBase.num) / Double(timeBase.den)

        var reading = true
        while reading {
            switch read(into: packet) {
            case .packet:
                break
            case .endOfFile, .failed:
                reading = false
                continue
            }
            guard packet.pointee.stream_index == streamIndex else {
                av_packet_unref(packet)
                continue
            }

            var subtitle = AVSubtitle()
            var got: Int32 = 0
            let decoded = avcodec_decode_subtitle2(context, &subtitle, &got, packet)
            if decoded >= 0, got != 0 {
                let pts = Self.seconds(packet.pointee.pts, timeBase: timeBase)
                let packetDuration = Self.seconds(packet.pointee.duration, timeBase: timeBase)
                let numRects = Int(subtitle.num_rects)
                for index in 0..<numRects {
                    guard let rect = subtitle.rects?[index] else { continue }
                    let text: String?
                    // 文本型解码器（subrip/mov_text/webvtt）也会把内容放进 rect.ass，
                    // 必须按 ASS 事件字段拆分，否则界面上会出现 "0,0,Default,,..." 前缀。
                    let hasDialogFields: Bool
                    if let ass = rect.pointee.ass {
                        text = String(cString: ass)
                        hasDialogFields = true
                    } else if let raw = rect.pointee.text {
                        text = String(cString: raw)
                        hasDialogFields = false
                    } else {
                        text = nil
                        hasDialogFields = false
                    }
                    guard let text, !text.isEmpty else { continue }

                    // 结束时间优先用容器包的显示时长；缺失时再看解码器给出的相对时间。
                    let displayStart = pts + Double(subtitle.start_display_time) / 1000
                    let decodedDuration = Double(subtitle.end_display_time - subtitle.start_display_time) / 1000
                    let duration = packetDuration > 0.05
                        ? packetDuration
                        : (decodedDuration > 0.05 ? decodedDuration : 3.0)
                    let start = displayStart
                    let end = start + max(0.1, duration)

                    if text.hasPrefix("Dialogue:") {
                        // 已经是完整 ASS 行，保留它自带的时间轴与样式字段。
                        dialogues.append(text)
                    } else if (isASS || hasDialogFields),
                              let event = Self.parseASSEvent(text) {
                        // Matroska 的 ASS 包是 ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text，
                        // 没有 Dialogue: 前缀；用统一解析器拆出字段，避免样式和时间互相错位。
                        dialogues.append(
                            "Dialogue: \(event.layer),\(Self.assTime(start)),\(Self.assTime(end)),"
                                + "\(event.style),\(event.name),\(event.marginLeft),\(event.marginRight),"
                                + "\(event.marginVertical),\(event.effect),\(event.text)"
                        )
                    } else {
                        dialogues.append(
                            "Dialogue: 0,\(Self.assTime(start)),\(Self.assTime(end)),Default,,0,0,0,,\(text)"
                        )
                    }
                }
                subtitleCount += 1
                avsubtitle_free(&subtitle)
            }
            av_packet_unref(packet)
        }

        Log.info(
            .subtitle,
            "内封字幕提取 #\(streamIndex) codec=\(codecName) 事件=\(subtitleCount) 文本行=\(dialogues.count)"
        )
        guard !dialogues.isEmpty else {
            throw MediaReaderError.noVideoStream
        }
        return Self.assDocument(header: header, dialogues: dialogues)
    }

    /// 读取解码器保存的 ASS 头（Script Info + Styles）。非 ASS 轨返回空串。
    /// 只读取指定时间窗口内的字幕事件，供大文件分片加载。
    /// 每次调用独立 seek，返回窗口附近的事件；调用方负责去重与时间轴合并。
    public func readSubtitleEvents(
        streamIndex: Int,
        from: Double,
        to: Double
    ) throws -> [SubtitlePacketEvent] {
        guard let stream = stream(at: streamIndex),
              let params = stream.pointee.codecpar else {
            throw MediaReaderError.streamInfoFailed(-1)
        }
        let codecName = String(cString: avcodec_get_name(params.pointee.codec_id))
        guard let decoder = avcodec_find_decoder(params.pointee.codec_id),
              let context = avcodec_alloc_context3(decoder) else {
            throw MediaReaderError.noVideoStream
        }
        var context_: UnsafeMutablePointer<AVCodecContext>? = context
        defer { avcodec_free_context(&context_) }

        guard avcodec_parameters_to_context(context, params) >= 0,
              avcodec_open2(context, decoder, nil) >= 0 else {
            throw MediaReaderError.streamInfoFailed(-1)
        }
        guard seek(to: max(0, from)) else { throw MediaReaderError.seekFailed(-1) }

        if let format {
            for index in 0..<Int(format.pointee.nb_streams) where index != streamIndex {
                format.pointee.streams?[index]?.pointee.discard = AVDISCARD_ALL
            }
        }

        var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard let packet else { throw MediaReaderError.readFailed(-1) }

        let isASS = codecName == "ass" || codecName == "ssa"
        let timeBase = stream.pointee.time_base
        var events: [SubtitlePacketEvent] = []
        var reading = true

        while reading {
            switch read(into: packet) {
            case .packet:
                break
            case .endOfFile:
                reading = false
                continue
            case .failed(let code):
                // 中途读取失败不能当作“窗口已完整读取”，否则字幕缺口会被永久标记为已覆盖。
                av_packet_unref(packet)
                throw MediaReaderError.readFailed(code)
            }
            guard packet.pointee.stream_index == streamIndex else {
                av_packet_unref(packet)
                continue
            }

            let pts = Self.seconds(packet.pointee.pts, timeBase: timeBase)
            if pts > to + 0.5 {
                av_packet_unref(packet)
                reading = false
                continue
            }
            let packetDuration = Self.seconds(packet.pointee.duration, timeBase: timeBase)

            if isASS {
                // ASS 包本身就是文本事件，不需要走 AVSubtitle 解码器；
                // 直接过滤 OP/ED 特效可避免为几万条逐字动画创建对象。
                if let raw = Self.packetText(packet),
                   let event = Self.parseASSEvent(raw) {
                    if !Self.isEffectASS(style: event.style, body: event.text) {
                        let duration = packetDuration > 0.05 ? packetDuration : 3.0
                        events.append(
                            SubtitlePacketEvent(
                                start: pts,
                                end: pts + max(0.1, duration),
                                style: event.style,
                                text: event.text,
                                isASS: true
                            )
                        )
                    }
                }
                av_packet_unref(packet)
                continue
            }

            var subtitle = AVSubtitle()
            var got: Int32 = 0
            let decoded = avcodec_decode_subtitle2(context, &subtitle, &got, packet)
            if decoded >= 0, got != 0 {
                for index in 0..<Int(subtitle.num_rects) {
                    guard let rect = subtitle.rects?[index] else { continue }
                    // FFmpeg 的 subrip/mov_text/webvtt 解码器同样会通过
                    // ff_ass_add_rect 把文本塞进 rect.ass（"0,0,Default,,0,0,0,,text"），
                    // 因此只要 ass 存在就必须按 ASS 事件字段解析，不能整串当文本。
                    let decoded: String?
                    var style = "Default"
                    var isDialogLine = false
                    if let ass = rect.pointee.ass {
                        let dialog = String(cString: ass)
                        if let event = Self.parseASSEvent(dialog) {
                            style = event.style
                            decoded = event.text
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

                    let displayStart = pts + Double(subtitle.start_display_time) / 1000
                    let decodedDuration = Double(subtitle.end_display_time - subtitle.start_display_time) / 1000
                    let duration = packetDuration > 0.05
                        ? packetDuration
                        : (decodedDuration > 0.05 ? decodedDuration : 3.0)
                    let start = displayStart
                    let end = start + max(0.1, duration)
                    if start > to { continue }
                    if end <= from - 0.5 { continue }

                    events.append(
                        SubtitlePacketEvent(
                            start: start,
                            end: end,
                            style: style,
                            text: decoded,
                            isASS: isDialogLine
                        )
                    )
                }
                avsubtitle_free(&subtitle)
            }
            av_packet_unref(packet)
        }
        return events
    }

    private static func packetText(_ packet: UnsafeMutablePointer<AVPacket>) -> String? {
        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return nil }
        let buffer = UnsafeBufferPointer(
            start: UnsafeRawPointer(data).assumingMemoryBound(to: UInt8.self),
            count: Int(packet.pointee.size)
        )
        return String(decoding: buffer, as: UTF8.self)
    }

    private static func isEffectASS(style: String, body: String) -> Bool {
        if body.range(of: #"\\p[0-9]"#, options: .regularExpression) != nil { return true }
        if style.range(
            of: #"(?i)(^|[\s_/])(op|ed|staff|fx|title)"#,
            options: .regularExpression
        ) != nil { return true }
        if style.contains("//") { return true }
        let plain = body.replacingOccurrences(
            of: #"\{[^}]*\}"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
        if plain.isEmpty { return true }
        if plain.range(of: #"^[mblc]\s+-?\d"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// 为文本型内封字幕创建即时解码器；ASS/SSA 返回 nil，走原始文本路径。
    public func makeSubtitlePacketDecoder(streamIndex: Int) -> SubtitlePacketDecoder? {
        guard let stream = stream(at: streamIndex),
              let params = stream.pointee.codecpar else { return nil }
        let codec = String(cString: avcodec_get_name(params.pointee.codec_id))
        guard codec != "ass", codec != "ssa" else { return nil }
        return SubtitlePacketDecoder(stream: stream)
    }

    /// 把播放泵已经读到的 ASS 包直接解析成字幕事件。
    /// 大文件不再为字幕单独顺序扫一遍 SMB，字幕与音画共用同一份读流。
    public func subtitleEvent(
        from packet: UnsafeMutablePointer<AVPacket>,
        streamIndex: Int
    ) -> SubtitlePacketEvent? {
        guard let stream = stream(at: streamIndex),
              let params = stream.pointee.codecpar else { return nil }
        let codec = String(cString: avcodec_get_name(params.pointee.codec_id))
        guard codec == "ass" || codec == "ssa" else { return nil }
        return Self.makeSubtitleEvent(from: packet, timeBase: stream.pointee.time_base)
    }

    static func makeSubtitleEvent(
        from packet: UnsafeMutablePointer<AVPacket>,
        timeBase: AVRational
    ) -> SubtitlePacketEvent? {
        guard let raw = packetText(packet),
              let parts = parseASSEvent(raw),
              !isEffectASS(style: parts.style, body: parts.text) else { return nil }
        let pts = seconds(packet.pointee.pts, timeBase: timeBase)
        let packetDuration = seconds(packet.pointee.duration, timeBase: timeBase)
        let duration = packetDuration > 0.05 ? packetDuration : 3.0
        return SubtitlePacketEvent(
            start: pts,
            end: pts + max(0.1, duration),
            style: parts.style,
            text: parts.text,
            isASS: true
        )
    }

    private static func subtitleHeader(_ context: UnsafeMutablePointer<AVCodecContext>) -> String {        guard let raw = context.pointee.subtitle_header,
              context.pointee.subtitle_header_size > 0 else { return "" }
        let count = Int(context.pointee.subtitle_header_size)
        let bytes = UnsafeRawPointer(raw).assumingMemoryBound(to: UInt8.self)
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    struct ASSEventParts: Equatable {
        let layer: String
        let style: String
        let name: String
        let marginLeft: String
        let marginRight: String
        let marginVertical: String
        let effect: String
        let text: String
    }

    /// 统一解析两种 ASS 事件输入：
    /// - Matroska 字幕包：`ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`
    /// - 完整字幕行：`Dialogue: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text`
    static func parseASSEvent(_ raw: String) -> ASSEventParts? {
        var payload = Substring(raw)
        while let first = payload.first, first == " " || first == "\t" {
            payload = payload.dropFirst()
        }
        let hasDialoguePrefix = payload.hasPrefix("Dialogue:")
        if hasDialoguePrefix {
            payload = payload.dropFirst("Dialogue:".count)
            while let first = payload.first, first == " " || first == "\t" {
                payload = payload.dropFirst()
            }
        }
        let count = hasDialoguePrefix ? 10 : 9
        let fields = splitASSFields(payload, count: count)
        guard fields.count == count else { return nil }

        if hasDialoguePrefix {
            return ASSEventParts(
                layer: fields[0],
                style: fields[3].isEmpty ? "Default" : fields[3],
                name: fields[4],
                marginLeft: fields[5],
                marginRight: fields[6],
                marginVertical: fields[7],
                effect: fields[8],
                text: fields[9]
            )
        }
        return ASSEventParts(
            layer: fields[1],
            style: fields[2].isEmpty ? "Default" : fields[2],
            name: fields[3],
            marginLeft: fields[4],
            marginRight: fields[5],
            marginVertical: fields[6],
            effect: fields[7],
            text: fields[8]
        )
    }

    /// 切分前 `count - 1` 个字段，最后一个字段保留内部逗号。
    private static func splitASSFields(_ text: Substring, count: Int) -> [String] {
        guard count > 0 else { return [] }
        var fields: [String] = []
        var remainder = text
        for _ in 0..<(count - 1) {
            guard let comma = remainder.firstIndex(of: ",") else { return [] }
            fields.append(String(remainder[..<comma]))
            remainder = remainder[remainder.index(after: comma)...]
        }
        fields.append(String(remainder))
        return fields
    }

    /// 用容器自带的样式头拼出完整 ASS；没有头时退回最小可用样式。
    private static func assDocument(header: String, dialogues: [String]) -> String {
        var base = header
        if let range = base.range(of: "[Events]", options: .caseInsensitive) {
            base = String(base[..<range.lowerBound])
        }
        if base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            base = """
            [Script Info]
            ScriptType: v4.00+
            WrapStyle: 0
            PlayResX: 1920
            PlayResY: 1080
            [V4+ Styles]
            Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
            Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,20,1

            """
        }
        return base
            + "\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
            + dialogues.joined(separator: "\n")
    }

    private static func assTime(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let totalCentiseconds = Int((clamped * 100).rounded())
        let h = totalCentiseconds / 360_000
        let m = (totalCentiseconds % 360_000) / 6_000
        let s = (totalCentiseconds % 6_000) / 100
        let cs = totalCentiseconds % 100
        return String(format: "%d:%02d:%02d.%02d", h, m, s, cs)
    }

    /// 跳转到指定秒数（落到目标之前的关键帧）。
    @discardableResult
    public func seek(to seconds: Double) -> Bool {        guard let format else { return false }
        let target = Int64(max(0, seconds) * Double(AV_TIME_BASE))
        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = av_seek_frame(format, -1, target, AVSEEK_FLAG_BACKWARD)
        let elapsed = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000

        guard result >= 0 else {
            Log.error(.demux, "seek 失败 目标=\(Self.fmt(seconds))s code=\(result)")
            return false
        }
        avformat_flush(format)
        pendingSeek = (seconds, startedAt)
        Log.info(.demux, "seek 请求 目标=\(Self.fmt(seconds))s 耗时=\(Int(elapsed))ms")
        return true
    }

    // MARK: - 内部

    private static func loadInfo(
        format: UnsafeMutablePointer<AVFormatContext>,
        label: String
    ) throws -> MediaInfo {
        // 注意：`DemuxProbe.readInfo` 内部已经调用过 `avformat_find_stream_info`。
        // 这里不能再调一次——同一上下文解析两遍会在第二次崩溃（该版本会在结束时
        // 释放流的内部探测状态）。
        let info = try DemuxProbe.readInfo(format: format)
        Log.info(
            .demux,
            "打开媒体 容器=\(info.format) 时长=\(String(format: "%.1f", info.duration))s "
                + "轨道=\(info.streams.count) 来源=\(label)"
        )
        for stream in info.streams {
            var detail = "轨道 #\(stream.index) \(stream.kind.rawValue) \(stream.codec)"
            switch stream.kind {
            case .video: detail += " \(stream.width)x\(stream.height)"
            case .audio: detail += " \(stream.channels)ch \(stream.sampleRate)Hz"
            case .subtitle: break
            }
            Log.info(.demux, detail)
        }
        return info
    }

    static func seconds(_ value: Int64, timeBase: AVRational) -> Double {
        guard value != ffmpeg_nopts else { return 0 }
        return Double(value) * Double(timeBase.num) / Double(timeBase.den)
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
