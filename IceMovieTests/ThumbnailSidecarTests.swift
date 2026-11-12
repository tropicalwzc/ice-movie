import Foundation
import ThumbnailKit
import XCTest
@testable import IceMovie

final class ThumbnailSidecarTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbnailSidecarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testLocalSidecarRoundTrip() async throws {
        let provider = LocalThumbnailSidecar(rootURL: root)
        try await provider.prepare()

        let index = SharedThumbnailIndex(entries: [
            "A.jpg": .init(thumb: "thumbs/ab/x.jpg", width: 10, height: 20, size: 1, modified: 2),
        ])
        try await provider.storeIndex(JSONEncoder().encode(index))
        let loadedIndex = try await provider.loadIndex()
        XCTAssertEqual(
            try JSONDecoder().decode(SharedThumbnailIndex.self, from: loadedIndex ?? Data()),
            index
        )

        try await provider.storeThumbnail(Data([1, 2, 3]), relativePath: "thumbs/ab/x.jpg")
        let thumb = try await provider.loadThumbnail(relativePath: "thumbs/ab/x.jpg")
        XCTAssertEqual(thumb, Data([1, 2, 3]))

        try await provider.removeThumbnail(relativePath: "thumbs/ab/x.jpg")
        let removed = try await provider.loadThumbnail(relativePath: "thumbs/ab/x.jpg")
        XCTAssertNil(removed)
    }

    func testCacheUsesLocalSidecarAndInvalidatesOnSizeChange() async throws {
        let provider = LocalThumbnailSidecar(rootURL: root)
        let cache = SharedThumbnailCache(provider: provider)
        let date = Date(timeIntervalSince1970: 100)
        let data = Data([7, 8, 9])

        await cache.store(
            thumbnailData: data,
            width: 320,
            height: 240,
            path: "A.jpg",
            size: 10,
            modified: date
        )
        await cache.flush()

        let hit = await cache.thumbnail(path: "A.jpg", size: 10, modified: date)
        XCTAssertEqual(hit, data)
        let changed = await cache.thumbnail(path: "A.jpg", size: 11, modified: date)
        XCTAssertNil(changed)
    }

    func testCorruptSidecarIndexDoesNotBreakCache() async throws {
        let cacheDirectory = root.appendingPathComponent(".icemovie", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try Data("bad json".utf8).write(to: cacheDirectory.appendingPathComponent("index.json"))

        let provider = LocalThumbnailSidecar(rootURL: root)
        let cache = SharedThumbnailCache(provider: provider)
        let date = Date(timeIntervalSince1970: 100)
        let miss = await cache.thumbnail(path: "A.jpg", size: 10, modified: date)
        XCTAssertNil(miss)

        await cache.store(
            thumbnailData: Data([4]),
            width: 20,
            height: 10,
            path: "A.jpg",
            size: 10,
            modified: date
        )
        let hit = await cache.thumbnail(path: "A.jpg", size: 10, modified: date)
        XCTAssertEqual(hit, Data([4]))
    }
}
