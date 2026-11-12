import Foundation
import ThumbnailKit
import XCTest

final class SharedThumbnailCacheTests: XCTestCase {
    func testCacheKeyChangesWithPathSizeAndModified() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let base = SharedThumbnailKey.hash(path: "A.jpg", size: 10, modified: date)
        XCTAssertEqual(
            base,
            SharedThumbnailKey.hash(path: "A.jpg", size: 10, modified: date)
        )
        XCTAssertNotEqual(
            base,
            SharedThumbnailKey.hash(path: "A.jpg", size: 11, modified: date)
        )
        XCTAssertNotEqual(
            base,
            SharedThumbnailKey.hash(
                path: "A.jpg",
                size: 10,
                modified: date.addingTimeInterval(1)
            )
        )
        let relative = SharedThumbnailKey.relativePath(
            path: "A.jpg",
            size: 10,
            modified: date
        )
        XCTAssertTrue(relative.hasPrefix("thumbs/\(base.prefix(2))/"))
        XCTAssertTrue(relative.hasSuffix(".jpg"))
    }

    func testIndexRoundTrip() throws {
        let index = SharedThumbnailIndex(entries: [
            "A.jpg": .init(
                thumb: "thumbs/ab/hash.jpg",
                width: 320,
                height: 240,
                size: 10,
                modified: 100
            ),
        ])
        let data = try JSONEncoder().encode(index)
        let decoded = try JSONDecoder().decode(SharedThumbnailIndex.self, from: data)
        XCTAssertEqual(decoded, index)
    }

    func testStoreThenReadFromSidecar() async {
        let provider = FakeSidecarProvider()
        let cache = SharedThumbnailCache(provider: provider)
        let date = Date(timeIntervalSince1970: 100)
        let data = Data([1, 2, 3, 4])

        await cache.store(
            thumbnailData: data,
            width: 320,
            height: 240,
            path: "A.jpg",
            size: 10,
            modified: date
        )

        let hit = await cache.thumbnail(path: "A.jpg", size: 10, modified: date)
        XCTAssertEqual(hit, data)
        let has = await cache.hasThumbnail(path: "A.jpg", size: 10, modified: date)
        XCTAssertTrue(has)
        let changed = await cache.thumbnail(
            path: "A.jpg",
            size: 11,
            modified: date
        )
        XCTAssertNil(changed, "大小变化后旧缩略图不得命中")
    }

    func testIndexFlushesInBatches() async {
        let provider = FakeSidecarProvider()
        let cache = SharedThumbnailCache(provider: provider)
        let date = Date(timeIntervalSince1970: 100)

        for index in 0..<20 {
            await cache.store(
                thumbnailData: Data([UInt8(index)]),
                width: 320,
                height: 240,
                path: "P\(index).jpg",
                size: Int64(index + 1),
                modified: date
            )
        }

        let writes = await provider.indexWriteCount
        XCTAssertGreaterThanOrEqual(writes, 1)
        let indexData = await provider.indexData
        let index = try? JSONDecoder().decode(
            SharedThumbnailIndex.self,
            from: indexData ?? Data()
        )
        XCTAssertEqual(index?.entries.count, 20)
    }

    func testWriteFailureDowngradesWithoutBreakingReads() async {
        let provider = FakeSidecarProvider()
        let cache = SharedThumbnailCache(provider: provider)
        let date = Date(timeIntervalSince1970: 100)

        await cache.store(
            thumbnailData: Data([1]),
            width: 10,
            height: 10,
            path: "A.jpg",
            size: 1,
            modified: date
        )
        await provider.setWritable(false)
        await cache.store(
            thumbnailData: Data([2]),
            width: 10,
            height: 10,
            path: "B.jpg",
            size: 1,
            modified: date
        )

        let writable = await cache.isWritable
        XCTAssertFalse(writable)
        let hit = await cache.thumbnail(path: "A.jpg", size: 1, modified: date)
        XCTAssertEqual(hit, Data([1]), "写入失败不应影响已有侧车读取")
    }

    func testCorruptIndexRebuilds() async {
        let provider = FakeSidecarProvider()
        await provider.setIndexData(Data("not json".utf8))
        let cache = SharedThumbnailCache(provider: provider)
        let date = Date(timeIntervalSince1970: 100)

        let miss = await cache.thumbnail(path: "A.jpg", size: 1, modified: date)
        XCTAssertNil(miss)

        await cache.store(
            thumbnailData: Data([9]),
            width: 10,
            height: 10,
            path: "A.jpg",
            size: 1,
            modified: date
        )
        let hit = await cache.thumbnail(path: "A.jpg", size: 1, modified: date)
        XCTAssertEqual(hit, Data([9]))
    }

    func testRemoveDeletesEntryAndThumbnail() async {
        let provider = FakeSidecarProvider()
        let cache = SharedThumbnailCache(provider: provider)
        let date = Date(timeIntervalSince1970: 100)

        await cache.store(
            thumbnailData: Data([1]),
            width: 10,
            height: 10,
            path: "A.jpg",
            size: 1,
            modified: date
        )
        await cache.remove(path: "A.jpg")

        let hit = await cache.thumbnail(path: "A.jpg", size: 1, modified: date)
        XCTAssertNil(hit)
        let thumbCount = await provider.thumbnailCount
        XCTAssertEqual(thumbCount, 0)
    }
}

private actor FakeSidecarProvider: ThumbnailSidecarProviding {
    private(set) var indexData: Data?
    private(set) var indexWriteCount = 0
    private(set) var thumbnailCount = 0
    private var thumbs: [String: Data] = [:]
    private var writable = true

    func setWritable(_ writable: Bool) { self.writable = writable }
    func setIndexData(_ data: Data?) { indexData = data }

    func prepare() async throws {}

    func loadIndex() async throws -> Data? { indexData }

    func storeIndex(_ data: Data) async throws {
        guard writable else { throw FakeError.readOnly }
        indexData = data
        indexWriteCount += 1
    }

    func loadThumbnail(relativePath: String) async throws -> Data? {
        thumbs[relativePath]
    }

    func storeThumbnail(_ data: Data, relativePath: String) async throws {
        guard writable else { throw FakeError.readOnly }
        thumbs[relativePath] = data
        thumbnailCount = thumbs.count
    }

    func removeThumbnail(relativePath: String) async throws {
        thumbs[relativePath] = nil
        thumbnailCount = thumbs.count
    }

    func removeAll() async throws {
        indexData = nil
        thumbs.removeAll()
        thumbnailCount = 0
    }
}

private enum FakeError: Error {
    case readOnly
}
