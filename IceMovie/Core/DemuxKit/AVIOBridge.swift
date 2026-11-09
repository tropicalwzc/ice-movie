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
    private let windowSize: Int

    private var window = Data()
    private var windowStart: Int64 = 0
    private var position: Int64 = 0
    private var reachedEOF = false

    private(set) var context: UnsafeMutablePointer<AVIOContext>?

    /// 已预读到当前读位置之后的字节数；进度条缓冲区间使用。
    var bufferedAheadBytes: Int64 {
        (source as? BufferMetricsProviding)?.bufferedAheadBytes ?? 0
    }

    var sourceLength: Int64? { source.length }

    /// 播放源最近的实际下载速度；本地源为 0。
    var downloadBytesPerSecond: Double {
        (source as? NetworkSpeedProviding)?.downloadBytesPerSecond ?? 0
    }

    init(source: any ByteSource, windowSize: Int = 4 << 20) throws {
        self.source = source
        self.windowSize = windowSize

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
        guard fillWindowIfNeeded() else { return ffmpeg_eof }

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
        return position
    }

    // MARK: - 内部

    private func fillWindowIfNeeded() -> Bool {
        let offsetInWindow = position - windowStart
        if offsetInWindow >= 0, offsetInWindow < Int64(window.count) {
            return true
        }
        if reachedEOF, offsetInWindow >= Int64(window.count) {
            return false
        }

        let data = readSynchronously(at: position, count: windowSize)
        if data.isEmpty {
            reachedEOF = true
            return false
        }
        window = data
        windowStart = position
        reachedEOF = data.count < windowSize
        return true
    }

    /// 在独立任务里调用异步数据源，并在当前线程等待结果。
    /// 这段等待发生在 FFmpeg 自己的线程上，不会占用 Swift 并发池。
    private func readSynchronously(at offset: Int64, count: Int) -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ReadResult()
        let source = self.source
        Task.detached {
            do {
                box.data = try await source.read(at: offset, count: count)
            } catch {
                Log.error(.demux, "字节源读取失败 offset=\(offset) \(error.localizedDescription)")
                box.data = Data()
            }
            semaphore.signal()
        }
        semaphore.wait()
        return box.data
    }
}

private final class ReadResult: @unchecked Sendable {
    var data = Data()
}

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
