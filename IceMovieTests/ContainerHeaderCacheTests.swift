import Foundation
import IceCore
import PersistenceKit
import XCTest

final class ContainerHeaderCacheTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContainerHeaderCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeKey(
        path: String = "movie.mkv",
        fingerprint: UInt64 = 1,
        size: Int64 = 1024
    ) -> ContainerHeaderCache.Key {
        ContainerHeaderCache.Key(
            namespace: "host|share",
            path: path,
            size: size,
            modified: 100,
            fingerprint: fingerprint
        )
    }

    func testStoreAndReadPage() async throws {
        let cache = try ContainerHeaderCache(directory: directory)
        let key = makeKey()
        let page = Data(repeating: 7, count: ContainerHeaderCache.pageSize)
        await cache.storePage(for: key, page: 0, data: page)

        let hit = await cache.cachedPage(for: key, page: 0)
        XCTAssertEqual(hit, page)
        let miss = await cache.cachedPage(for: key, page: 1)
        XCTAssertNil(miss)
    }

    func testFingerprintChangeMisses() async throws {
        let cache = try ContainerHeaderCache(directory: directory)
        let first = makeKey(fingerprint: 1)
        let second = makeKey(fingerprint: 2)
        await cache.storePage(
            for: first,
            page: 0,
            data: Data(repeating: 1, count: ContainerHeaderCache.pageSize)
        )

        let miss = await cache.cachedPage(for: second, page: 0)
        XCTAssertNil(miss, "指纹变化后不能命中旧文件的页")
    }

    func testEvictionKeepsCapacity() async throws {
        let cache = try ContainerHeaderCache(
            directory: directory,
            capacityBytes: 128 * 1024,
            perFileBytes: 128 * 1024
        )
        let first = makeKey(path: "a.mkv")
        let second = makeKey(path: "b.mkv")
        let page = Data(repeating: 1, count: ContainerHeaderCache.pageSize)
        await cache.storePage(for: first, page: 0, data: page)
        await cache.storePage(for: second, page: 0, data: page)
        await cache.storePage(for: second, page: 1, data: page)

        let total = await cache.totalBytes()
        XCTAssertLessThanOrEqual(total, 128 * 1024)
        let firstHit = await cache.cachedPage(for: first, page: 0)
        XCTAssertNil(firstHit, "超限时应淘汰最久未使用的文件")
        let secondHit = await cache.cachedPage(for: second, page: 0)
        XCTAssertNotNil(secondHit)
    }

    func testCorruptIndexRecoversEmpty() async throws {
        try Data("not json".utf8).write(
            to: directory.appendingPathComponent("index.json"),
            options: .atomic
        )
        let cache = try ContainerHeaderCache(directory: directory)
        let total = await cache.totalBytes()
        XCTAssertEqual(total, 0)
    }

    func testUnwritableDirectoryThrows() {
        let unwritable = URL(fileURLWithPath: "/dev/null/ContainerHeaderCache")
        XCTAssertThrowsError(
            try ContainerHeaderCache(directory: unwritable)
        )
    }

    func testCachedByteSourceWithoutCacheFallsBackToNetwork() async throws {
        let base = TestByteSource(data: Data(repeating: 9, count: 4096))
        let source = CachedByteSource(
            base: base,
            cache: nil,
            namespace: "host|share",
            path: "movie.mkv",
            size: 4096,
            modified: nil
        )
        let data = try await source.read(at: 0, count: 1024)
        XCTAssertEqual(data.count, 1024)
        XCTAssertGreaterThan(base.readCount, 0, "缓存不可用时应直接走字节源")
    }

    func testCachedByteSourceReusesHeaderAcrossSeeks() async throws {
        let cache = try ContainerHeaderCache(directory: directory)
        let payload = Data(repeating: 5, count: 256 * 1024)
        let firstBase = TestByteSource(data: payload)
        let first = CachedByteSource(
            base: firstBase,
            cache: cache,
            namespace: "host|share",
            path: "movie.mkv",
            size: Int64(payload.count),
            modified: Date(timeIntervalSince1970: 100)
        )
        await first.prepare()
        _ = try await first.read(at: 0, count: ContainerHeaderCache.pageSize)
        _ = try await first.read(
            at: Int64(ContainerHeaderCache.pageSize),
            count: ContainerHeaderCache.pageSize
        )
        await first.close()

        let secondBase = TestByteSource(data: payload)
        let second = CachedByteSource(
            base: secondBase,
            cache: cache,
            namespace: "host|share",
            path: "movie.mkv",
            size: Int64(payload.count),
            modified: Date(timeIntervalSince1970: 100)
        )
        await second.prepare()
        let head = try await second.read(at: 0, count: ContainerHeaderCache.pageSize)
        let secondPage = try await second.read(
            at: Int64(ContainerHeaderCache.pageSize),
            count: ContainerHeaderCache.pageSize
        )
        XCTAssertEqual(head, Data(repeating: 5, count: ContainerHeaderCache.pageSize))
        XCTAssertEqual(secondPage, Data(repeating: 5, count: ContainerHeaderCache.pageSize))
        XCTAssertEqual(secondBase.readCount, 0, "二次打开的头/索引区应完全命中本地缓存")
    }

    func testCachedByteSourceHitsOnSecondRead() async throws {
        let cache = try ContainerHeaderCache(directory: directory)
        let base = TestByteSource(data: Data(repeating: 3, count: 256 * 1024))
        let source = CachedByteSource(
            base: base,
            cache: cache,
            namespace: "host|share",
            path: "movie.mkv",
            size: 256 * 1024,
            modified: Date(timeIntervalSince1970: 100)
        )
        await source.prepare()
        let first = try await source.read(at: 0, count: 64 * 1024)
        let second = try await source.read(at: 0, count: 64 * 1024)
        XCTAssertEqual(first, second)
        XCTAssertGreaterThan(source.readStats.cacheHitBytes, 0)
        await source.close()
    }
}

private final class TestByteSource: ByteSource, ReadStatsProviding, @unchecked Sendable {
    let data: Data
    var length: Int64? { Int64(data.count) }
    private(set) var readCount = 0
    private(set) var bytesRead: Int64 = 0

    init(data: Data) {
        self.data = data
    }

    func read(at offset: Int64, count: Int) async throws -> Data {
        readCount += 1
        let start = max(0, Int(offset))
        guard start < data.count else { return Data() }
        let end = min(data.count, start + count)
        let part = data.subdata(in: start..<end)
        bytesRead += Int64(part.count)
        return part
    }

    func close() async {}

    var readStats: ByteSourceReadStats {
        ByteSourceReadStats(readCount: readCount, bytesRead: bytesRead)
    }
}
