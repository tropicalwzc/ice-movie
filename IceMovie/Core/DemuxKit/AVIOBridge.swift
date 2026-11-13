import CFFmpeg
import Foundation
import IceCore

/// 把 `ByteSource` 桥接成 FFmpeg 的 `AVIOContext`。
///
/// 读回调不逐次访问数据源，而是维持一个 4 MB 的预读窗口：
/// 顺序读取时绝大多数请求都命中窗口，只有跨越窗口边界才真正读一次网络。
/// 跳转只需要移动读取位置，窗口越界时自然失效。
final class AVIOBridge {
    private let source: any ByteSource
    private let maxWindowSize: Int
    private let startWindowSize: Int
    private var currentWindowSize: Int
    private var sequentialFills = 0

    private var window = Data()
    private var windowStart: Int64 = 0
    private var position: Int64 = 0
    private var reachedEOF = false
    private(set) var fillCount = 0
    private(set) var bytesRead: Int64 = 0

    private(set) var context: UnsafeMutablePointer<AVIOContext>?

    /// 底层字节源的读取统计；本地源没有实现时返回 AVIO 自身的填充计数。
    var sourceReadStats: ByteSourceReadStats {
        (source as? ReadStatsProviding)?.readStats
            ?? ByteSourceReadStats(readCount: fillCount, bytesRead: bytesRead)
    }

    /// 已预读到当前读位置之后的字节数；进度条缓冲区间使用。
    var bufferedAheadBytes: Int64 {
        (source as? BufferMetricsProviding)?.bufferedAheadBytes ?? 0
    }

    var sourceLength: Int64? { source.length }

    func setRetainBackBytes(_ bytes: Int64) {
        (source as? BufferRetentionProviding)?.setRetainBackBytes(bytes)
    }

    /// 从指定字节偏移起连续可用的缓冲；包含解封装已读和预读环。
    func bufferedBytes(from offset: Int64) -> Int64 {
        (source as? SeekCacheProviding)?.bufferedBytes(from: offset) ?? 0
    }

    func cancelPrefetch() {
        (source as? PrefetchCancelling)?.cancelPrefetch()
    }

    func setPrefetchEnabled(_ enabled: Bool) {
        (source as? PrefetchControlling)?.setPrefetchEnabled(enabled)
    }

    /// 打开阶段结束：缓存层停止把播放媒体数据写盘。
    func endOpenPhase() {
        (source as? CachePhaseControlling)?.endOpenPhase()
    }

    func setSupply(audioAhead: Double, videoAhead: Double) {
        (source as? BufferSupplyProviding)?.setSupply(audioAhead: audioAhead, videoAhead: videoAhead)
    }

    /// 播放引擎定期写入播放头，供回看窗口和淘汰策略使用。
    func setPlayhead(byteOffset: Int64) {
        (source as? SeekCacheProviding)?.setPlayhead(byteOffset: byteOffset)
    }

    var ringResetCount: Int {
        (source as? SeekCacheProviding)?.ringResetCount ?? 0
    }

    var seekCacheHits: Int {
        (source as? SeekCacheProviding)?.seekCacheHits ?? 0
    }

    var seekCacheMisses: Int {
        (source as? SeekCacheProviding)?.seekCacheMisses ?? 0
    }

    var lastSeekCacheHit: Bool {
        (source as? SeekCacheProviding)?.lastSeekCacheHit ?? false
    }

    var playheadByteOffset: Int64 {
        (source as? SeekCacheProviding)?.playheadByteOffset ?? 0
    }

    var readHeadByteOffset: Int64 {
        (source as? SeekCacheProviding)?.readHeadByteOffset ?? 0
    }

    var prefetchHeadByteOffset: Int64 {
        (source as? SeekCacheProviding)?.prefetchHeadByteOffset ?? 0
    }

    /// 播放源最近的实际下载速度；本地源为 0。
    var downloadBytesPerSecond: Double {
        (source as? NetworkSpeedProviding)?.downloadBytesPerSecond ?? 0
    }

    init(
        source: any ByteSource,
        windowSize: Int = 4 << 20,
        startWindowSize: Int = 256 << 10
    ) throws {
        self.source = source
        self.maxWindowSize = max(64 << 10, windowSize)
        self.startWindowSize = min(max(16 << 10, startWindowSize), self.maxWindowSize)
        self.currentWindowSize = self.startWindowSize

        let avioBufferSize = 64 << 10
        guard let raw = av_malloc(avioBufferSize) else {
            throw DemuxError.openFailed(-1)
        }

        let opaque = Unmanaged.passUnretained(self).toOpaque()
        guard let ctx = avio_alloc_context(
            raw.assumingMemoryBound(to: UInt8.self),
            Int32(avioBufferSize),
            0,
            opaque,
            avioReadCallback,
            nil,
            avioSeekCallback
        ) else {
            av_free(raw)
            throw DemuxError.openFailed(-1)
        }
        context = ctx
    }

    deinit {
        releaseContext()
    }

    /// 释放 AVIO 上下文。使用方必须在关闭 `AVFormatContext` 之后调用一次。
    func releaseContext() {
        guard let context else { return }
        self.context = nil
        var ctx: UnsafeMutablePointer<AVIOContext>? = context
        // 缓冲区归 AVIOContext 所有，可能已被内部重新分配，按当前指针释放。
        if let raw = ctx?.pointee.buffer {
            av_free(raw)
            ctx?.pointee.buffer = nil
        }
        avio_context_free(&ctx)
    }

    // MARK: - 回调实现

    fileprivate func read(into destination: UnsafeMutablePointer<UInt8>, size: Int) -> Int32 {
        guard size > 0 else { return 0 }
        // FFmpeg 约定：到达末尾必须返回 AVERROR_EOF，返回 0 会让部分 demuxer 反复轮询。
        if let error = fillWindowIfNeeded(requested: size) { return error }

        let offsetInWindow = Int(position - windowStart)
        let available = window.count - offsetInWindow
        guard available > 0 else { return ffmpeg_eof }

        let count = min(size, available)
        window.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(destination, base.advanced(by: offsetInWindow), count)
        }
        position += Int64(count)
        return Int32(count)
    }

    fileprivate func seek(offset: Int64, whence: Int32) -> Int64 {
        let previous = position
        switch whence {
        case SEEK_SET:
            position = offset
        case SEEK_CUR:
            position += offset
        case SEEK_END:
            guard let length = source.length else { return -1 }
            position = length + offset
        case 0x10000: // AVSEEK_SIZE
            return source.length ?? -1
        default:
            return -1
        }
        guard position >= 0 else {
            position = previous
            return -1
        }
        // 显式通知缓存层：seek 后旧窗口作废，立刻从新位置预读。
        if position != previous {
            currentWindowSize = startWindowSize
            sequentialFills = 0
            if position >= 0, let seekable = source as? any SeekAwareByteSource {
                seekable.seekWillChange(to: position)
            }
        }
        return position
    }

    // MARK: - 内部

    private func fillWindowIfNeeded(requested: Int) -> Int32? {
        let offsetInWindow = position - windowStart
        if offsetInWindow >= 0, offsetInWindow < Int64(window.count) {
            return nil
        }
        if reachedEOF, offsetInWindow >= Int64(window.count) {
            return nil
        }

        // 元数据小读按小窗口取；FFmpeg 自己要大块时按请求大小取，不能被窗口截断。
        let readSize = min(max(requested, currentWindowSize), maxWindowSize)
        let previousEnd = windowStart + Int64(window.count)
        let isSequential = !window.isEmpty && position == previousEnd
        let result = readSynchronously(at: position, count: readSize)
        if let error = result.error {
            reachedEOF = false
            Log.error(
                .demux,
                "字节源读取失败 offset=\(position) \(error.localizedDescription)"
            )
            return ffmpeg_eio
        }
        let data = result.data
        if data.isEmpty {
            reachedEOF = true
            return nil
        }
        window = data
        windowStart = position
        fillCount += 1
        bytesRead += Int64(data.count)
        if isSequential {
            sequentialFills += 1
            if sequentialFills % 4 == 0 {
                currentWindowSize = min(maxWindowSize, currentWindowSize * 2)
            }
        } else {
            sequentialFills = 0
            currentWindowSize = startWindowSize
        }
        reachedEOF = data.count < readSize
        return nil
    }

    /// 在独立任务里调用异步数据源，并在当前线程等待结果。
    /// 这段等待发生在 FFmpeg 自己的线程上，不会占用 Swift 并发池。
    /// 读取任务与等待线程使用同一 QoS（userInitiated），避免优先级反转。
    private func readSynchronously(at offset: Int64, count: Int) -> ReadResult {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ReadResult()
        let source = self.source
        Task.detached(priority: .userInitiated) {
            do {
                box.data = try await source.read(at: offset, count: count)
            } catch {
                Log.error(.demux, "字节源读取失败 offset=\(offset) \(error.localizedDescription)")
                box.error = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        return box
    }
}

private final class ReadResult: @unchecked Sendable {
    var data = Data()
    var error: Error?
}

private let ffmpeg_eio: Int32 = Int32(-EIO)

private let avioReadCallback: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?, Int32
) -> Int32 = { opaque, destination, size in
    guard let opaque, let destination, size > 0 else { return -1 }
    let bridge = Unmanaged<AVIOBridge>.fromOpaque(opaque).takeUnretainedValue()
    return bridge.read(into: destination, size: Int(size))
}

private let avioSeekCallback: @convention(c) (
    UnsafeMutableRawPointer?, Int64, Int32
) -> Int64 = { opaque, offset, whence in
    guard let opaque else { return -1 }
    let bridge = Unmanaged<AVIOBridge>.fromOpaque(opaque).takeUnretainedValue()
    return bridge.seek(offset: offset, whence: whence)
}
