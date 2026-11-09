import DemuxKit
import Foundation
import IceCore
import MediaLibraryKit
import RenderKit
import SMBSession

/// 播放失败的分类与用户提示。
///
/// 三类核心失败必须给出不同文案：解封装失败、编码不支持、主机不可达；
/// 其余错误统一落到「无法开始播放」，但仍然可以返回媒体库。
struct PlaybackFailure: Identifiable, Equatable {
    enum Kind: String {
        case demux
        case unsupportedCodec
        case hostUnreachable
        case other
    }

    let kind: Kind
    let title: String
    let message: String

    var id: String { kind.rawValue }

    static func classify(_ error: Error) -> PlaybackFailure {
        if let error = error as? VideoPipelineError,
           case .unsupportedCodec(let name) = error {
            return PlaybackFailure(
                kind: .unsupportedCodec,
                title: "暂不支持这种视频编码",
                message: "这个视频使用 \(name) 编码，当前设备的硬解码不支持。可以换一个文件，或等待后续版本。"
            )
        }

        if let error = error as? MediaReaderError {
            return PlaybackFailure(
                kind: .demux,
                title: "无法解析这个视频",
                message: "文件可能已损坏，或容器格式不在支持范围内。\n\(error.localizedDescription)"
            )
        }

        if let error = error as? SMBConnectionError {
            switch error {
            case .unreachable, .notConnected, .staleHandle:
                return PlaybackFailure(
                    kind: .hostUnreachable,
                    title: "无法连接主机",
                    message: "播放需要持续读取共享文件，但主机当前不可达。请检查 Wi-Fi 与主机电源后重试。\n\(error.localizedDescription)"
                )
            default:
                break
            }
        }

        return PlaybackFailure(
            kind: .other,
            title: "无法开始播放",
            message: error.localizedDescription
        )
    }

    /// 播放中途失败时，统一按「播放中断」呈现。
    static func interrupted(_ detail: String) -> PlaybackFailure {
        PlaybackFailure(
            kind: .other,
            title: "播放中断",
            message: "读取或解码过程中出现问题，已停止播放。\n\(detail)"
        )
    }
}
