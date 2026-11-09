import Foundation
import IceCore

/// `AVERROR_EOF` / `AVERROR(EAGAIN)` 在 Swift 里不导出（宏），按其定义写成常量。
let ffmpeg_eof: Int32 = -541_478_725
let ffmpeg_eagain: Int32 = -35
/// `AV_NOPTS_VALUE` 即 `INT64_MIN`。
let ffmpeg_nopts: Int64 = Int64.min

/// 解封装模块入口占位。
///
/// 本模块只依赖 `IceCore.ByteSource`，**不得引用 SMBSession**：
/// 这是 design.md D13 的边界，保证播放内核能用本地样本独立验证。
public enum DemuxKit {
    public static let version = "0.1.0"

    /// 唯一对外暴露的输入方式：任意字节源。
    public static func canOpen(_ source: any ByteSource) -> Bool {
        source.length != nil
    }
}
