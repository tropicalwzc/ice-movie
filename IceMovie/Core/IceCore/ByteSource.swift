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

/// 可选预读取消：切换视频/停止播放时，旧文件的预读任务必须立即退出，不能继续抢带宽。
public protocol PrefetchCancelling: AnyObject, Sendable {
    func cancelPrefetch()
}

/// 可选供给反馈：音频低于安全水位时暂停后台预读，把 SMB 带宽让给播放读。
public protocol BufferSupplyProviding: AnyObject, Sendable {
    func setSupply(audioAhead: Double, videoAhead: Double)
}

/// 可选 seek 缓存指标：播放引擎写入播放头，并读取从播放头起算的连续缓冲。
public protocol SeekCacheProviding: AnyObject, Sendable {
    func setPlayhead(byteOffset: Int64)
    func bufferedBytes(from offset: Int64) -> Int64
    var ringResetCount: Int { get }
    var seekCacheHits: Int { get }
    var seekCacheMisses: Int { get }
    var lastSeekCacheHit: Bool { get }
    var playheadByteOffset: Int64 { get }
    var readHeadByteOffset: Int64 { get }
    var prefetchHeadByteOffset: Int64 { get }
}

/// 可选 seek 通知：解封装层发生跳转时，缓存可以立刻丢掉旧窗口并从新位置预读。
public protocol SeekAwareByteSource: AnyObject, Sendable {
    /// 同步调用，不能阻塞；实现方负责取消旧预读并启动新位置的预读。
    func seekWillChange(to offset: Int64)
}

/// 可选缓存保留策略：只保留当前读位置之前少量回看数据，其余内存让给未来窗口。
public protocol BufferRetentionProviding: AnyObject {
    func setRetainBackBytes(_ bytes: Int64)
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
