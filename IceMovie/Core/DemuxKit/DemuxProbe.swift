import CFFmpeg
import CoreGraphics
import Foundation
import IceCore
import ImageIO
import UniformTypeIdentifiers

public enum MediaStreamKind: String, Sendable {
    case video
    case audio
    case subtitle
}

public struct MediaStreamInfo: Sendable, Identifiable {
    public let index: Int
    public let kind: MediaStreamKind
    public let codec: String
    public let width: Int
    public let height: Int
    public let channels: Int
    public let sampleRate: Int
    public let language: String?
    public let title: String?

    public var id: Int { index }
}

public struct MediaInfo: Sendable {
    public let format: String
    public let duration: Double
    public let streams: [MediaStreamInfo]
}

/// 缩略图取帧结果。`source` 用于验证「命中 attached_pic 时跳过解码」。
public struct ThumbnailImage: Sendable {
    public enum Source: String, Sendable {
        case attachedPicture = "attached_pic"
        case videoFrame = "video_frame"
    }

    public let data: Data
    public let source: Source
    public let width: Int
    public let height: Int

    public init(data: Data, source: Source, width: Int, height: Int) {
        self.data = data
        self.source = source
        self.width = width
        self.height = height
    }
}

public enum DemuxError: LocalizedError {
    case openFailed(Int32)
    case streamInfoFailed(Int32)
    case noVideoStream
    case decoderUnavailable(String)
    case decodeFailed(Int32)
    case scaleFailed
    case pngFailed

    public var errorDescription: String? {
        switch self {
        case .openFailed(let code): "打开文件失败（\(code)）"
        case .streamInfoFailed(let code): "读取流信息失败（\(code)）"
        case .noVideoStream: "该文件没有视频轨"
        case .decoderUnavailable(let name): "找不到解码器：\(name)"
        case .decodeFailed(let code): "解码失败（\(code)）"
        case .scaleFailed: "像素格式转换失败"
        case .pngFailed: "PNG 编码失败"
        }
    }
}

/// 基于 FFmpeg 的解封装与抽帧入口。
public enum DemuxProbe {
    public static func inspect(path: String) throws -> MediaInfo {
        try MediaReader.open(path: path).info
    }

    /// 通过字节源读取并解析流信息。用于直接读取 SMB 上的文件。
    public static func inspect(source: any ByteSource, label: String = "byte-source") throws -> MediaInfo {
        try MediaReader.open(source: source, label: label).info
    }

    static func readInfo(
        format: UnsafeMutablePointer<AVFormatContext>,
        probeStreams: Bool = true
    ) throws -> MediaInfo {
        if probeStreams {
            let info = avformat_find_stream_info(format, nil)
            guard info >= 0 else { throw DemuxError.streamInfoFailed(info) }
        }

        let formatName = format.pointee.iformat.map { String(cString: $0.pointee.name) } ?? "unknown"
        let duration = format.pointee.duration > 0
            ? Double(format.pointee.duration) / Double(AV_TIME_BASE)
            : 0

        var streams: [MediaStreamInfo] = []
        for index in 0..<Int(format.pointee.nb_streams) {
            guard let stream = format.pointee.streams?[index],
                  let params = stream.pointee.codecpar else { continue }

            let kind: MediaStreamKind
            switch params.pointee.codec_type {
            case AVMEDIA_TYPE_VIDEO: kind = .video
            case AVMEDIA_TYPE_AUDIO: kind = .audio
            case AVMEDIA_TYPE_SUBTITLE: kind = .subtitle
            default: continue
            }

            streams.append(
                MediaStreamInfo(
                    index: index,
                    kind: kind,
                    codec: String(cString: avcodec_get_name(params.pointee.codec_id)),
                    width: Int(params.pointee.width),
                    height: Int(params.pointee.height),
                    channels: Int(params.pointee.ch_layout.nb_channels),
                    sampleRate: Int(params.pointee.sample_rate),
                    language: stream.pointee.metadata.flatMap { Self.metadata($0, key: "language") },
                    title: stream.pointee.metadata.flatMap { Self.metadata($0, key: "title") }
                )
            )
        }

        return MediaInfo(format: formatName, duration: duration, streams: streams)
    }

    private static func metadata(_ dict: OpaquePointer, key: String) -> String? {
        guard let entry = av_dict_get(dict, key, nil, 0), let value = entry.pointee.value else {
            return nil
        }
        let text = String(cString: value)
        return text.isEmpty ? nil : text
    }

    // MARK: - 缩略图

    /// 从本地文件生成缩略图。优先使用 MKV 内嵌 `attached_pic`，没有时才解第一帧。
    public static func thumbnail(
        path: String,
        maxWidth: Int = 480,
        position: Double? = nil
    ) throws -> ThumbnailImage {
        var context: UnsafeMutablePointer<AVFormatContext>?
        let opened = avformat_open_input(&context, path, nil, nil)
        guard opened >= 0, let format = context else { throw DemuxError.openFailed(opened) }
        defer { avformat_close_input(&context) }

        let info = avformat_find_stream_info(format, nil)
        guard info >= 0 else { throw DemuxError.streamInfoFailed(info) }
        return try thumbnail(format: format, maxWidth: maxWidth, label: path, position: position)
    }

    /// 通过字节源生成缩略图，供 SMB 媒体库使用。
    public static func thumbnail(
        source: any ByteSource,
        label: String,
        maxWidth: Int = 480,
        position: Double? = nil
    ) throws -> ThumbnailImage {
        let bridge = try AVIOBridge(source: source)
        guard let context = avformat_alloc_context() else {
            bridge.releaseContext()
            throw DemuxError.openFailed(-1)
        }
        context.pointee.pb = bridge.context
        context.pointee.flags |= AVFMT_FLAG_CUSTOM_IO

        var opened: UnsafeMutablePointer<AVFormatContext>? = context
        let result = avformat_open_input(&opened, nil, nil, nil)
        guard result >= 0, let format = opened else {
            // avformat_open_input 失败时会自行释放 context，只需回收自定义 AVIO。
            bridge.releaseContext()
            throw DemuxError.openFailed(result)
        }

        defer {
            var closing: UnsafeMutablePointer<AVFormatContext>? = format
            avformat_close_input(&closing)
            bridge.releaseContext()
        }

        let info = avformat_find_stream_info(format, nil)
        guard info >= 0 else { throw DemuxError.streamInfoFailed(info) }
        return try thumbnail(format: format, maxWidth: maxWidth, label: label, position: position)
    }

    private static func thumbnail(
        format: UnsafeMutablePointer<AVFormatContext>,
        maxWidth: Int,
        label: String,
        position: Double? = nil
    ) throws -> ThumbnailImage {
        let began = ProcessInfo.processInfo.systemUptime
        if let picture = attachedPictureData(format: format),
           let image = resizedPNG(data: picture, maxWidth: maxWidth) {
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - began) * 1000)
            Log.info(
                .thumbnail,
                "命中 attached_pic \(Log.shortPath(label)) 大小=\(picture.count)B 耗时=\(elapsed)ms"
            )
            return ThumbnailImage(
                data: image.data,
                source: .attachedPicture,
                width: image.width,
                height: image.height
            )
        }

        let image = try decodeFirstFrame(
            format: format,
            maxWidth: maxWidth,
            label: label,
            position: position
        )
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - began) * 1000)
        Log.info(
            .thumbnail,
            "抽帧完成 \(Log.shortPath(label)) \(image.width)x\(image.height) 耗时=\(elapsed)ms"
        )
        return ThumbnailImage(
            data: image.data,
            source: .videoFrame,
            width: image.width,
            height: image.height
        )
    }

    /// MKV 封面通常以 `attached_pic` 形式挂在一条 mjpeg/png 轨上。
    private static func attachedPictureData(format: UnsafeMutablePointer<AVFormatContext>) -> Data? {
        for index in 0..<Int(format.pointee.nb_streams) {
            guard let stream = format.pointee.streams?[index] else { continue }
            guard stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC != 0 else { continue }
            let packet = stream.pointee.attached_pic
            guard packet.size > 0, let bytes = packet.data else { continue }
            return Data(bytes: bytes, count: Int(packet.size))
        }
        return nil
    }

    /// 用 ImageIO 解码内嵌封面，而不是走视频解码器。
    private static func resizedPNG(data: Data, maxWidth: Int) -> (data: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxWidth,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        guard let png = encodePNG(image) else { return nil }
        return (png, image.width, image.height)
    }

    private static func decodeFirstFrame(
        format: UnsafeMutablePointer<AVFormatContext>,
        maxWidth: Int,
        label: String,
        position: Double? = nil
    ) throws -> (data: Data, width: Int, height: Int) {
        guard let videoIndex = videoStreamIndex(format: format) else {
            throw DemuxError.noVideoStream
        }
        guard let stream = format.pointee.streams?[videoIndex],
              let params = stream.pointee.codecpar else {
            throw DemuxError.noVideoStream
        }

        // 片头常有黑场或纯色淡入，直接从第 0 秒抽帧会得到一张全黑封面。
        // 取片长的 10%（最少 5 秒、最多 5 分钟）作为落点，封面更有代表性。
        let duration = format.pointee.duration > 0
            ? Double(format.pointee.duration) / Double(AV_TIME_BASE)
            : 0
        let target: Double
        if let position {
            target = max(0, position)
        } else if duration > 3 {
            target = min(max(duration * 0.1, 1), max(0, duration - 1))
        } else {
            target = 0
        }
        if target > 0 {
            let timestamp = Int64(target * Double(AV_TIME_BASE))
            if av_seek_frame(format, -1, timestamp, AVSEEK_FLAG_BACKWARD) >= 0 {
                avformat_flush(format)
                Log.info(.thumbnail, "抽帧定位 \(Log.shortPath(label)) 目标=\(String(format: "%.1f", target))s")
            }
        }

        let codecName = String(cString: avcodec_get_name(params.pointee.codec_id))
        guard let decoder = avcodec_find_decoder(params.pointee.codec_id),
              let codecContext = avcodec_alloc_context3(decoder) else {
            throw DemuxError.decoderUnavailable(codecName)
        }
        var codecContext_: UnsafeMutablePointer<AVCodecContext>? = codecContext
        defer { avcodec_free_context(&codecContext_) }

        guard avcodec_parameters_to_context(codecContext, params) >= 0,
              avcodec_open2(codecContext, decoder, nil) >= 0 else {
            throw DemuxError.decoderUnavailable(codecName)
        }

        var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&packet) }
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        guard let packet, let frame else { throw DemuxError.decodeFailed(-1) }

        var decoded = false
        var received: Int32 = ffmpeg_eagain
        var readPackets = 0

        while av_read_frame(format, packet) >= 0 {
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == videoIndex else { continue }
            readPackets += 1

            let sent = avcodec_send_packet(codecContext, packet)
            guard sent >= 0 else { continue }
            received = avcodec_receive_frame(codecContext, frame)
            if received >= 0 {
                decoded = true
                break
            }
            // 有些编码需要先喂多个包才能解出第一帧，继续读。
            if readPackets > 600 { break }
        }

        if !decoded {
            _ = avcodec_send_packet(codecContext, nil)
            received = avcodec_receive_frame(codecContext, frame)
            decoded = received >= 0
        }
        guard decoded else { throw DemuxError.decodeFailed(received) }

        let sourceWidth = Int(frame.pointee.width)
        let sourceHeight = Int(frame.pointee.height)
        guard sourceWidth > 0, sourceHeight > 0 else { throw DemuxError.decodeFailed(-1) }

        let targetWidth = min(maxWidth, sourceWidth)
        let targetHeight = max(1, sourceHeight * targetWidth / sourceWidth)
        let pixelFormat = AVPixelFormat(rawValue: frame.pointee.format)

        guard let scaler = sws_getContext(
            Int32(sourceWidth), Int32(sourceHeight), pixelFormat,
            Int32(targetWidth), Int32(targetHeight), AV_PIX_FMT_BGRA,
            SWS_BILINEAR, nil, nil, nil
        ) else { throw DemuxError.scaleFailed }
        defer { sws_freeContext(scaler) }

        let bytesPerRow = targetWidth * 4
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bytesPerRow * targetHeight)
        defer { buffer.deallocate() }

        var sourcePlanes: [UnsafePointer<UInt8>?] = [
            frame.pointee.data.0.map { UnsafePointer($0) },
            frame.pointee.data.1.map { UnsafePointer($0) },
            frame.pointee.data.2.map { UnsafePointer($0) },
            frame.pointee.data.3.map { UnsafePointer($0) },
        ]
        var sourceStrides: [Int32] = [
            frame.pointee.linesize.0, frame.pointee.linesize.1,
            frame.pointee.linesize.2, frame.pointee.linesize.3,
        ]
        var destinationPlanes: [UnsafeMutablePointer<UInt8>?] = [buffer, nil, nil, nil]
        var destinationStrides: [Int32] = [Int32(bytesPerRow), 0, 0, 0]

        sws_scale(
            scaler, &sourcePlanes, &sourceStrides, 0, Int32(sourceHeight),
            &destinationPlanes, &destinationStrides
        )

        let pixels = Data(bytes: buffer, count: bytesPerRow * targetHeight)
        var nonZero = 0
        var total: UInt64 = 0
        for index in stride(from: 0, to: bytesPerRow * targetHeight, by: 4) {
            let value = UInt32(buffer[index]) | UInt32(buffer[index + 1]) << 8
                | UInt32(buffer[index + 2]) << 16
            if value != 0 { nonZero += 1 }
            total += UInt64(value)
        }
        Log.debug(
            .thumbnail,
            "抽帧像素 \(Log.shortPath(label)) 非零=\(nonZero)/\(targetWidth * targetHeight) 均值=\(total / UInt64(max(1, targetWidth * targetHeight)))"
        )
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(
                  width: targetWidth,
                  height: targetHeight,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(
                      rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                          | CGBitmapInfo.byteOrder32Little.rawValue
                  ),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ),
              let png = encodePNG(image) else {
            throw DemuxError.pngFailed
        }
        return (png, targetWidth, targetHeight)
    }

    /// 选择面积最大的非封面视频轨。attached_pic 轨的尺寸经常是 0。
    private static func videoStreamIndex(format: UnsafeMutablePointer<AVFormatContext>) -> Int? {
        var best: (index: Int, area: Int)?
        for index in 0..<Int(format.pointee.nb_streams) {
            guard let stream = format.pointee.streams?[index],
                  let params = stream.pointee.codecpar,
                  params.pointee.codec_type == AVMEDIA_TYPE_VIDEO else { continue }
            if stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC != 0 { continue }
            let area = Int(params.pointee.width) * Int(params.pointee.height)
            if best == nil || area > best!.area {
                best = (index, area)
            }
        }
        return best?.index
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// 解码首个可用视频帧并编码为 PNG，用于验证解码链路。
    public static func firstFramePNG(path: String, maxWidth: Int = 640) throws -> Data {
        try thumbnail(path: path, maxWidth: maxWidth).data
    }
}
