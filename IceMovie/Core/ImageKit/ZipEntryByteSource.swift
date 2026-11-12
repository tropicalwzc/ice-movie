import Foundation
import IceCore
import Synchronization

/// 把 ZIP 条目的相对偏移映射到底层字节源。用于 LIVP 内的静态图与 MOV。
///
/// 不拥有底层 `ByteSource`：关闭条目源不会关闭 LIVP 文件源，调用方负责最终关闭。
public final class ZipEntryByteSource: ByteSource, @unchecked Sendable {
    private let base: any ByteSource
    private let dataOffset: Int64
    private let label: String
    private let closed = Mutex(false)

    public nonisolated let length: Int64?

    public init(
        base: any ByteSource,
        dataOffset: Int64,
        length: Int64,
        label: String = ""
    ) {
        self.base = base
        self.dataOffset = dataOffset
        self.length = max(0, length)
        self.label = label
    }

    public func read(at offset: Int64, count: Int) async throws -> Data {
        let isClosed = closed.withLock { $0 }
        guard !isClosed else { throw ByteSourceError.closed }
        guard count > 0, offset >= 0, offset < (length ?? 0) else { return Data() }
        let remaining = (length ?? 0) - offset
        let wanted = min(Int64(count), remaining)
        guard wanted > 0 else { return Data() }
        return try await base.read(at: dataOffset + offset, count: Int(wanted))
    }

    public func close() async {
        closed.withLock { $0 = true }
    }
}

/// 内存字节源，用于 deflate 条目解压后的数据。
public final class MemoryByteSource: ByteSource, @unchecked Sendable {
    private let data: Data
    private let closed = Mutex(false)

    public nonisolated let length: Int64?

    public init(data: Data) {
        self.data = data
        self.length = Int64(data.count)
    }

    public func read(at offset: Int64, count: Int) async throws -> Data {
        let isClosed = closed.withLock { $0 }
        guard !isClosed else { throw ByteSourceError.closed }
        guard count > 0, offset >= 0, offset < Int64(data.count) else { return Data() }
        let start = Int(offset)
        let end = min(data.count, start + count)
        return data.subdata(in: start..<end)
    }

    public func close() async {
        closed.withLock { $0 = true }
    }
}
