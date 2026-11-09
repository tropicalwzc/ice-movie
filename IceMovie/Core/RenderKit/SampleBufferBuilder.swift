import CFFmpeg
import CoreMedia
import Foundation
import IceCore

/// `AV_NOPTS_VALUE`（`INT64_MIN`），RenderKit 侧自用，避免依赖 DemuxKit 的内部常量。
private let sampleNoPTS: Int64 = Int64.min

public enum VideoPipelineError: LocalizedError, Sendable {
    case unsupportedCodec(String)
    case missingExtradata
    case formatDescriptionFailed(Int32)
    case sampleBufferFailed(Int32)
    case blockBufferFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .unsupportedCodec(let name): "暂不支持的视频编码：\(name)"
        case .missingExtradata: "缺少参数集（extradata）"
        case .formatDescriptionFailed(let code): "创建格式描述失败（\(code)）"
        case .sampleBufferFailed(let code): "创建样本缓冲失败（\(code)）"
        case .blockBufferFailed(let code): "创建数据块失败（\(code)）"
        }
    }
}

/// 把 Matroska/MP4 里的长度前缀码流封装成 `CMSampleBuffer`。
///
/// 这里**不解码**：`AVSampleBufferDisplayLayer` 接受压缩样本，内部调用 VideoToolbox。
/// FFmpeg 从 MKV/MP4 解出的 H.264/HEVC 已经是 AVCC/HVCC（4 字节长度前缀），
/// 与 `CMSampleBuffer` 要求的封装一致，因此不需要 Annex-B 转换。
public final class SampleBufferBuilder: @unchecked Sendable {
    public let codecName: String

    private let formatDescription: CMFormatDescription
    private let timeBaseNum: Int32
    private let timeBaseDen: Int32
    private let defaultDuration: CMTime

    public init(stream: UnsafeMutablePointer<AVStream>) throws {
        guard let params = stream.pointee.codecpar else {
            throw VideoPipelineError.missingExtradata
        }
        let name = String(cString: avcodec_get_name(params.pointee.codec_id))
        codecName = name

        guard let extradata = params.pointee.extradata, params.pointee.extradata_size > 0 else {
            throw VideoPipelineError.missingExtradata
        }
        let size = Int(params.pointee.extradata_size)
        let bytes = UnsafeRawBufferPointer(start: extradata, count: size)

        switch params.pointee.codec_id {
        case AV_CODEC_ID_H264:
            formatDescription = try Self.makeH264Description(bytes)
        case AV_CODEC_ID_HEVC:
            formatDescription = try Self.makeHEVCDescription(bytes)
        default:
            throw VideoPipelineError.unsupportedCodec(name)
        }

        timeBaseNum = stream.pointee.time_base.num
        timeBaseDen = stream.pointee.time_base.den

        // 平均帧率用于补齐缺省的样本时长。
        let rate = stream.pointee.avg_frame_rate
        if rate.num > 0, rate.den > 0 {
            defaultDuration = CMTime(value: CMTimeValue(rate.den), timescale: rate.num)
        } else {
            defaultDuration = CMTime(value: 1, timescale: 30)
        }

        Log.info(
            .render,
            "视频封装器就绪 codec=\(name) 尺寸=\(CMVideoFormatDescriptionGetDimensions(formatDescription).width)"
                + "x\(CMVideoFormatDescriptionGetDimensions(formatDescription).height)"
        )
    }

    public var dimensions: CMVideoDimensions {
        CMVideoFormatDescriptionGetDimensions(formatDescription)
    }

    /// 把一个视频包封装成样本缓冲。时间戳直接取自 FFmpeg，保持精确有理数。
    public func makeSample(from packet: UnsafeMutablePointer<AVPacket>) -> CMSampleBuffer? {
        let length = Int(packet.pointee.size)
        guard length > 0, let data = packet.pointee.data else { return nil }

        var blockBuffer: CMBlockBuffer?
        let created = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard created == kCMBlockBufferNoErr, let blockBuffer else {
            Log.error(.render, "创建数据块失败 code=\(created)")
            return nil
        }
        let copied = CMBlockBufferReplaceDataBytes(
            with: data, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: length
        )
        guard copied == kCMBlockBufferNoErr else {
            Log.error(.render, "填充数据块失败 code=\(copied)")
            return nil
        }

        let pts = packet.pointee.pts == sampleNoPTS
            ? CMTime.invalid
            : CMTime(value: packet.pointee.pts, timescale: timeBaseDen)
        let dts = packet.pointee.dts == sampleNoPTS
            ? CMTime.invalid
            : CMTime(value: packet.pointee.dts, timescale: timeBaseDen)
        let duration = packet.pointee.duration > 0
            ? CMTime(value: packet.pointee.duration, timescale: timeBaseDen)
            : defaultDuration

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: pts,
            decodeTimeStamp: dts
        )
        var sampleSize = length
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            Log.error(.render, "创建样本缓冲失败 code=\(status)")
            return nil
        }

        if packet.pointee.flags & AV_PKT_FLAG_KEY == 0 {
            CMSetAttachment(
                sampleBuffer,
                key: kCMSampleAttachmentKey_NotSync,
                value: kCFBooleanTrue,
                attachmentMode: kCMAttachmentMode_ShouldNotPropagate
            )
        }
        return sampleBuffer
    }

    // MARK: - 参数集解析

    /// AVCDecoderConfigurationRecord：`1 | profile | compat | level | 6bit len | numSPS | ...`
    private static func makeH264Description(_ bytes: UnsafeRawBufferPointer) throws -> CMFormatDescription {
        guard bytes.count > 7, bytes[0] == 1 else { throw VideoPipelineError.missingExtradata }
        let nalLength = Int(bytes[4] & 0x03) + 1
        let spsCount = Int(bytes[5] & 0x1F)
        var offset = 6
        var sets: [(UnsafePointer<UInt8>, Int)] = []

        func readUInt16(_ index: inout Int) -> Int? {
            guard index + 2 <= bytes.count else { return nil }
            let value = Int(bytes[index]) << 8 | Int(bytes[index + 1])
            index += 2
            return value
        }

        for _ in 0..<spsCount {
            guard let length = readUInt16(&offset), offset + length <= bytes.count else {
                throw VideoPipelineError.missingExtradata
            }
            sets.append((bytes.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: offset), length))
            offset += length
        }
        guard offset < bytes.count else { throw VideoPipelineError.missingExtradata }
        let ppsCount = Int(bytes[offset])
        offset += 1
        for _ in 0..<ppsCount {
            guard let length = readUInt16(&offset), offset + length <= bytes.count else {
                throw VideoPipelineError.missingExtradata
            }
            sets.append((bytes.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: offset), length))
            offset += length
        }
        guard !sets.isEmpty else { throw VideoPipelineError.missingExtradata }

        var pointers = sets.map { $0.0 }
        var sizes = sets.map { $0.1 }
        var description: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: sets.count,
            parameterSetPointers: &pointers,
            parameterSetSizes: &sizes,
            nalUnitHeaderLength: Int32(nalLength),
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw VideoPipelineError.formatDescriptionFailed(status)
        }
        return description
    }

    /// HEVCDecoderConfigurationRecord：22 字节头 + 数组表（VPS/SPS/PPS）。
    private static func makeHEVCDescription(_ bytes: UnsafeRawBufferPointer) throws -> CMFormatDescription {
        guard bytes.count > 23, bytes[0] == 1 else { throw VideoPipelineError.missingExtradata }
        let nalLength = Int(bytes[21] & 0x03) + 1
        var offset = 23
        let arrayCount = Int(bytes[22])
        var sets: [(UnsafePointer<UInt8>, Int)] = []
        let base = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)

        for _ in 0..<arrayCount {
            guard offset + 3 <= bytes.count else { break }
            offset += 1 // 数组头（completeness + NAL 类型）
            let count = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
            for _ in 0..<count {
                guard offset + 2 <= bytes.count else { break }
                let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                offset += 2
                guard offset + length <= bytes.count else { break }
                sets.append((base.advanced(by: offset), length))
                offset += length
            }
        }
        guard !sets.isEmpty else { throw VideoPipelineError.missingExtradata }

        var pointers = sets.map { $0.0 }
        var sizes = sets.map { $0.1 }
        var description: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: sets.count,
            parameterSetPointers: &pointers,
            parameterSetSizes: &sizes,
            nalUnitHeaderLength: Int32(nalLength),
            extensions: nil,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw VideoPipelineError.formatDescriptionFailed(status)
        }
        return description
    }
}
