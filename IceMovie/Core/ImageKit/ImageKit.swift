import Foundation

/// 静态图片支持模块。
///
/// 负责 ImageIO 解码、远程字节源桥接与 LIVP 包解析；不依赖媒体库模型，
/// 以便缩略图、相册和测试分别复用。
public enum ImageKit {
    public static let version = 1
}
