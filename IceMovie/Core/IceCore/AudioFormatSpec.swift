import Foundation

/// 播放通路的规范化音频格式。
///
/// 解码器与音频输出共用同一组参数：任何素材最终都转成 48 kHz 立体声 Float32，
/// 这样主时钟的推进速率与素材无关，音画同步只有一套参数。
public enum AudioFormatSpec {
    public static let sampleRate: Double = 48_000
    public static let sampleRateInt: Int32 = 48_000
    public static let channels: UInt32 = 2
}
