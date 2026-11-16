import Foundation
import IceCore
import MediaLibraryKit
import XCTest
@testable import IceMovie

private struct SlowLibrarySource: LibrarySource {
    let hostName = "slow"
    let shareName = "share"

    func listDirectory(path: String) async throws -> [MediaEntry] { [] }
    func listAllEntries(path: String) async throws -> [MediaEntry] { [] }

    func openByteSource(path: String) async throws -> any ByteSource {
        try await Task.sleep(for: .seconds(10))
        throw CancellationError()
    }
}

private struct BlockingContainerLibrarySource: LibrarySource {
    let hostName = "blocking"
    let shareName = "share"
    let byteSource: BlockingAfterFirstReadByteSource

    init(samplePath: String) throws {
        byteSource = try BlockingAfterFirstReadByteSource(samplePath: samplePath)
    }

    func listDirectory(path: String) async throws -> [MediaEntry] { [] }
    func listAllEntries(path: String) async throws -> [MediaEntry] { [] }
    func openByteSource(path: String) async throws -> any ByteSource { byteSource }
}

private final class BlockingAfterFirstReadByteSource: ByteSource, ReadCancelling,
    @unchecked Sendable {
    private let lock = NSLock()
    private let firstReadData: Data
    private var readCount = 0
    private var blocked = false
    private var closed = false

    init(samplePath: String) throws {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: samplePath))
        defer { try? handle.close() }
        firstReadData = try handle.read(upToCount: 4 << 20) ?? Data()
    }

    var didBlock: Bool {
        lock.withLock { blocked }
    }

    var isClosed: Bool {
        lock.withLock { closed }
    }

    var length: Int64? { Int64(firstReadData.count) }

    func read(at offset: Int64, count: Int) async throws -> Data {
        let response = lock.withLock { () -> Data? in
            readCount += 1
            guard readCount == 1 else {
                blocked = true
                return nil
            }
            return firstReadData
        }
        if let response {
            let start = min(Int(max(0, offset)), response.count)
            // 首读故意短于一个缓存页，避免 CachedByteSource 写页后让
            // MediaReader.open 完全命中缓存而绕过被阻塞的真实容器读。
            let end = min(response.count, start + min(count, 16 * 1024))
            return response.subdata(in: start..<end)
        }

        while !isClosed {
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ByteSourceError.closed
    }

    func cancelReads() {
        lock.withLock { closed = true }
    }

    func close() async {
        cancelReads()
    }
}

final class StartupCancellationTests: XCTestCase {
    @MainActor
    func testPreparePlaybackCancellationReturnsNil() async throws {
        let store = try LibraryStore(
            source: SlowLibrarySource(),
            initialPath: "",
            cacheCapacityBytes: 1024 * 1024
        )
        let entry = MediaEntry(
            path: "episode.mkv",
            name: "episode.mkv",
            isDirectory: false,
            size: 1024,
            modified: nil
        )

        let task = Task { await store.preparePlayback(entry) }
        try await Task.sleep(for: .milliseconds(120))
        task.cancel()
        let prepared = await task.value

        XCTAssertNil(prepared)
        XCTAssertTrue(task.isCancelled)
        XCTAssertNil(store.preparingPlaybackID, "取消后应清理加载态")
    }

    @MainActor
    func testCancellationAbortsContainerOpenAndClosesByteSource() async throws {
        let path = "/private/tmp/animi/强风吹拂/[Kamigami] Kaze ga Tsuyoku Fuiteiru - 01 [BD 1080p x265 Ma10p AAC].mkv"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("强风吹拂样本未挂载")
        }
        let source = try BlockingContainerLibrarySource(samplePath: path)
        let store = try LibraryStore(
            source: source,
            initialPath: "",
            cacheCapacityBytes: 1024 * 1024
        )
        let entry = MediaEntry(
            path: "blocked-open-\(UUID().uuidString).mkv",
            name: "blocked-open.mkv",
            isDirectory: false,
            size: 1024,
            modified: nil
        )

        let task = Task { await store.preparePlayback(entry) }
        for _ in 0..<200 {
            if source.byteSource.didBlock { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(source.byteSource.didBlock, "应已进入真实容器读取阶段")

        task.cancel()
        let prepared = await task.value

        XCTAssertNil(prepared)
        XCTAssertTrue(source.byteSource.isClosed, "取消必须显式关闭准备中的 ByteSource")
        XCTAssertNil(store.preparingPlaybackID)
    }
}
