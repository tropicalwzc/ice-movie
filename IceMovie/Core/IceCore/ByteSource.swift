import Foundation

/// 随机可读的字节源。
///
/// 解封装层只依赖这个协议，因此 SMB 与本地文件在它眼里没有区别：
/// 这样播放内核可以用本地样本在模拟器里验证，不必每次都连共享。
public protocol ByteSource: Sendable {
    /// 数据总长度。无法预知时为 nil（例如流式源）。
    var length: Int64? { get }

    /// 从指定偏移读取最多 `count` 字节。返回的 Data 长度可能小于请求值，抵达末尾时为空。
    func read(at offset: Int64, count: Int) async throws -> Data

    func close() async
}

/// 可选的预读指标：报告当前读位置之后已经缓存了多少字节，供进度条画缓冲区间。
public protocol BufferMetricsProviding: Sendable {
    var bufferedAheadBytes: Int64 { get }
}

/// 可选网络指标：报告播放源最近的实际下载速度，供播放器状态栏展示。
public protocol NetworkSpeedProviding: Sendable {
    var downloadBytesPerSecond: Double { get }
}

public enum ByteSourceError: LocalizedError, Sendable {
    case closed
    case outOfRange(offset: Int64, count: Int)
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .closed:
            "数据源已关闭"
        case .outOfRange(let offset, let count):
            "读取越界：offset=\(offset) count=\(count)"
        case .underlying(let detail):
            "读取失败：\(detail)"
        }
    }
}

/// 本地文件的字节源实现，主要用于测试样本与未来的离线播放。
public actor LocalFileByteSource: ByteSource {
    private let handle: FileHandle
    public nonisolated let length: Int64?
    private var isClosed = false

    public init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        length = size.map(Int64.init)
    }

    public func read(at offset: Int64, count: Int) async throws -> Data {
        guard !isClosed else { throw ByteSourceError.closed }
        if let length, offset >= length {
            return Data()
        }
        do {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count) ?? Data()
        } catch {
            throw ByteSourceError.underlying(error.localizedDescription)
        }
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        try? handle.close()
    }
}
