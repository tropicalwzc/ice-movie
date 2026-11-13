import CoreGraphics
import Foundation
import IceCore

public enum ImageDecodeError: LocalizedError, Sendable {
    case unreadableSource
    case emptyData
    case invalidImage
    case decodeFailed
    case encodeFailed
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .unreadableSource: "无法读取图片数据源"
        case .emptyData: "图片数据为空"
        case .invalidImage: "无法识别图片格式"
        case .decodeFailed: "图片解码失败"
        case .encodeFailed: "图片编码失败"
        case .tooLarge: "图片超出可预览大小"
        }
    }
}

/// 远程图片的按需数据源。
///
/// 用 `CGDataProvider` 的直接访问回调把 `ByteSource` 包装成可随机读取的图片数据，
/// 让 ImageIO 只取它需要的 JPEG/HEIC 区段，而不是每次都下载完整文件。
///
/// 生命周期要点：数据提供者通过 `passRetained` 持有内部的 `Reader`，回调始终访问
/// `Reader` 而不是 `RemoteImageDataProvider` 本身。即使包装对象先释放，ImageIO
/// 仍持有 provider 时回调状态依然有效；provider 释放时再由 `releaseInfo` 释放。
public final class RemoteImageDataProvider: @unchecked Sendable {
    public private(set) var provider: CGDataProvider!

    fileprivate final class Reader: @unchecked Sendable {
        let source: any ByteSource
        let label: String
        let length: Int64
        let windowSize: Int
        /// ImageIO 可能一次请求整张图；限制单次网络读取峰值，剩余部分由后续请求补齐。
        let maxWindowSize = 8 * 1024 * 1024

        private let lock = NSLock()
        private var window = Data()
        private var windowStart: Int64 = 0
        private var bytesReadValue: Int64 = 0
        private var requestCountValue = 0
        private var networkReadCountValue = 0

        init(
            source: any ByteSource,
            label: String,
            length: Int64,
            windowSize: Int
        ) {
            self.source = source
            self.label = label
            self.length = length
            self.windowSize = max(64 * 1024, windowSize)
        }

        var bytesRead: Int64 {
            lock.withLock { bytesReadValue }
        }

        var requestCount: Int {
            lock.withLock { requestCountValue }
        }

        var networkReadCount: Int {
            lock.withLock { networkReadCountValue }
        }

        func copyBytes(
            into buffer: UnsafeMutableRawPointer,
            position: Int64,
            count: Int
        ) -> Int {
            guard position >= 0, position < length, count > 0 else { return 0 }
            let wanted = min(count, Int(length - position))

            lock.lock()
            defer { lock.unlock() }

            if position >= windowStart,
               position + Int64(wanted) <= windowStart + Int64(window.count) {
                let offset = Int(position - windowStart)
                window.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    memcpy(buffer, base.advanced(by: offset), wanted)
                }
                return wanted
            }

            let requestCount = min(max(wanted, windowSize), maxWindowSize)
            let data = readSynchronously(at: position, count: requestCount)
            guard !data.isEmpty else { return 0 }

            window = data
            windowStart = position
            bytesReadValue += Int64(data.count)
            networkReadCountValue += 1

            let copied = min(wanted, data.count)
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                memcpy(buffer, base, copied)
            }
            return copied
        }

        private func readSynchronously(at offset: Int64, count: Int) -> Data {
            requestCountValue += 1
            let semaphore = DispatchSemaphore(value: 0)
            let box = ImageReadResult()
            let source = self.source
            // 与等待线程保持同一 QoS，避免 Thread Performance Checker 报优先级反转。
            Task.detached(priority: .userInitiated) {
                do {
                    box.data = try await source.read(at: offset, count: count)
                } catch {
                    box.error = error
                }
                semaphore.signal()
            }
            semaphore.wait()
            if let error = box.error {
                Log.error(
                    .thumbnail,
                    "图片按需读取失败 \(Log.shortPath(label)) offset=\(offset) \(error.localizedDescription)"
                )
                return Data()
            }
            return box.data
        }
    }

    private let reader: Reader

    public init(
        source: any ByteSource,
        label: String,
        windowSize: Int = 256 * 1024
    ) throws {
        guard let length = source.length, length > 0, length <= Int64(Int.max) else {
            throw ImageDecodeError.unreadableSource
        }
        let reader = Reader(
            source: source,
            label: label,
            length: length,
            windowSize: windowSize
        )
        self.reader = reader

        var callbacks = CGDataProviderDirectCallbacks(
            version: 0,
            getBytePointer: nil,
            releaseBytePointer: nil,
            getBytesAtPosition: remoteImageGetBytesAtPosition,
            releaseInfo: remoteImageReleaseInfo
        )
        let info = Unmanaged.passRetained(reader).toOpaque()
        guard let provider = CGDataProvider(
            directInfo: info,
            size: length,
            callbacks: &callbacks
        ) else {
            Unmanaged<Reader>.fromOpaque(info).release()
            throw ImageDecodeError.unreadableSource
        }
        self.provider = provider
    }

    public var bytesRead: Int64 { reader.bytesRead }
    public var requestCount: Int { reader.requestCount }
    public var networkReadCount: Int { reader.networkReadCount }
}

private final class ImageReadResult: @unchecked Sendable {
    var data = Data()
    var error: Error?
}

private let remoteImageGetBytesAtPosition: @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafeMutableRawPointer,
    Int64,
    Int
) -> Int = { info, buffer, position, count in
    guard let info else { return 0 }
    let reader = Unmanaged<RemoteImageDataProvider.Reader>
        .fromOpaque(info)
        .takeUnretainedValue()
    return reader.copyBytes(into: buffer, position: position, count: count)
}

private let remoteImageReleaseInfo: @convention(c) (UnsafeMutableRawPointer?) -> Void = { info in
    guard let info else { return }
    Unmanaged<RemoteImageDataProvider.Reader>.fromOpaque(info).release()
}
