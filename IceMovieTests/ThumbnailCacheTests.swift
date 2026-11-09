import IceCore
import ThumbnailKit
import XCTest

final class ThumbnailCacheTests: XCTestCase {
    func testCacheKeyChangesWithSizeAndModificationDate() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let base = ThumbnailCacheKey.make(path: "A/B.mkv", size: 100, modified: date)
        let same = ThumbnailCacheKey.make(path: "A/B.mkv", size: 100, modified: date)
        let resized = ThumbnailCacheKey.make(path: "A/B.mkv", size: 101, modified: date)
        let replaced = ThumbnailCacheKey.make(
            path: "A/B.mkv",
            size: 100,
            modified: date.addingTimeInterval(1)
        )

        XCTAssertEqual(base, same)
        XCTAssertNotEqual(base, resized)
        XCTAssertNotEqual(base, replaced)
        XCTAssertEqual(base.count, 64)
    }

    func testCacheKeyIncludesShareNamespace() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let animi = ThumbnailCacheKey.make(
            path: "01.mkv",
            size: 100,
            modified: date,
            namespace: "nas|Animi"
        )
        let movies = ThumbnailCacheKey.make(
            path: "01.mkv",
            size: 100,
            modified: date,
            namespace: "nas|Movies"
        )
        XCTAssertNotEqual(animi, movies, "不同共享的同名文件不能共用封面")
    }

    func testStoreEvictsOldestUntilUnderCapacity() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ThumbnailCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try ThumbnailStore(directory: directory, capacityBytes: 10)
        try await store.save(Data(repeating: 1, count: 6), forKey: "a")
        try await store.save(Data(repeating: 2, count: 6), forKey: "b")

        let snapshot = await store.snapshot()
        XCTAssertLessThanOrEqual(snapshot.bytes, 10)
        XCTAssertEqual(snapshot.count, 1)

        let first = await store.cachedData(forKey: "a")
        let second = await store.cachedData(forKey: "b")
        XCTAssertNil(first)
        XCTAssertNotNil(second)
    }

    func testCacheHitRefreshesAccessTimeAndKeepsEntry() async throws {        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ThumbnailCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try ThumbnailStore(directory: directory, capacityBytes: 12)
        try await store.save(Data(repeating: 1, count: 6), forKey: "a")
        try await store.save(Data(repeating: 2, count: 6), forKey: "b")

        // 访问 a，使其成为最近使用。
        _ = await store.cachedData(forKey: "a")
        try await Task.sleep(for: .milliseconds(30))
        try await store.save(Data(repeating: 3, count: 6), forKey: "c")

        let a = await store.cachedData(forKey: "a")
        let b = await store.cachedData(forKey: "b")
        let c = await store.cachedData(forKey: "c")
        XCTAssertNotNil(a, "最近访问过的封面应保留")
        XCTAssertNil(b, "最久未使用的封面应被淘汰")
        XCTAssertNotNil(c)
    }

    func testTwentyMegabyteCapEvictsToLimit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ThumbnailCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let limit: Int64 = 20 * 1024 * 1024
        let store = try ThumbnailStore(directory: directory, capacityBytes: limit)
        let sixMB = Data(repeating: 7, count: 6 * 1024 * 1024)
        for index in 0..<4 {
            try await store.save(sixMB, forKey: "k\(index)")
            try await Task.sleep(for: .milliseconds(10))
        }

        let snapshot = await store.snapshot()
        XCTAssertLessThanOrEqual(snapshot.bytes, limit)
        XCTAssertEqual(snapshot.count, 3, "4 × 6MB 超过 20MB，应淘汰最旧的一张")
    }

    func testFailedEntryIsNotRetriedInSameSession() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ThumbnailCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try ThumbnailStore(directory: directory, capacityBytes: 1024 * 1024)
        let service = ThumbnailService(store: store)
        let provider = FailingProvider()

        let first = await service.thumbnail(
            path: "broken.mkv", size: 1, modified: nil, provider: provider
        )
        let second = await service.thumbnail(
            path: "broken.mkv", size: 1, modified: nil, provider: provider
        )

        XCTAssertNil(first)
        XCTAssertNil(second)
        let calls = await provider.openCount()
        XCTAssertEqual(calls, 1, "同一会话内失败条目不应重复打开")
        let known = await service.isKnownFailure(path: "broken.mkv", size: 1, modified: nil)
        XCTAssertTrue(known)
    }
}

private actor FailingProvider: ThumbnailByteSourceProvider {
    private var opens = 0

    func openByteSource(path: String) async throws -> any ByteSource {
        opens += 1
        throw ByteSourceError.underlying("测试用失败")
    }

    func openCount() -> Int { opens }
}
