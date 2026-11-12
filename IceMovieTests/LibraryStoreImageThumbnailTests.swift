import Foundation
import IceCore
import MediaLibraryKit
import XCTest
@testable import IceMovie

@MainActor
final class LibraryStoreImageThumbnailTests: XCTestCase {
    func testImageThumbnailUsesThumbnailProviderNotPlaybackSource() async throws {
        let source = ImageThumbnailStubSource()
        let store = try LibraryStore(source: source, cacheCapacityBytes: 4 * 1024 * 1024)
        // 磁盘缩略图缓存跨测试运行保留；用唯一路径确保本次一定走 provider。
        let name = "IMG_\(UUID().uuidString).JPG"
        let image = MediaEntry(
            path: "Photos/\(name)",
            name: name,
            isDirectory: false,
            size: 1,
            modified: nil
        )

        let thumbnail = await store.thumbnail(for: image)

        XCTAssertNotNil(thumbnail)
        let thumbnailOpens = await source.thumbnailOpenCount
        let playbackOpens = await source.playbackOpenCount
        XCTAssertEqual(thumbnailOpens, 1)
        XCTAssertEqual(playbackOpens, 0, "图片封面不得走播放字节源")
    }

    func testImageSubtitleUsesCaptureDateInsteadOfModificationDate() throws {
        let source = ImageThumbnailStubSource()
        let store = try LibraryStore(
            source: source,
            cacheCapacityBytes: 1024 * 1024
        )
        let entry = MediaEntry(
            path: "Photos/IMG_9399_20260505222609.jpg",
            name: "IMG_9399_20260505222609.jpg",
            isDirectory: false,
            size: 100,
            modified: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let subtitle = store.subtitle(for: entry)

        XCTAssertTrue(subtitle.contains("2026年5月5日"), "应显示文件名里的拍摄日期")
        XCTAssertFalse(subtitle.contains("2027"), "不得显示文件修改日期")
    }

    func testPrefetchThumbnailsPopulatesMemoryCacheInBackground() async throws {
        let source = ImageThumbnailStubSource()
        let store = try LibraryStore(
            source: source,
            cacheCapacityBytes: 4 * 1024 * 1024
        )
        let name = "prefetch-\(UUID().uuidString).jpg"
        let entry = MediaEntry(
            path: "Photos/\(name)",
            name: name,
            isDirectory: false,
            size: 1,
            modified: nil
        )

        XCTAssertNil(store.cachedThumbnail(for: entry))
        store.prefetchThumbnails(for: [entry], limit: 1)
        for _ in 0..<100 where store.cachedThumbnail(for: entry) == nil {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertNotNil(store.cachedThumbnail(for: entry), "预取完成后应直接命中内存缓存")
        let opens = await source.thumbnailOpenCount
        XCTAssertEqual(opens, 1, "预取只应打开一次缩略图源")
        store.cancelThumbnailPrefetches()
    }

    func testImageAspectRatioIsRememberedAndClamped() throws {
        let source = ImageThumbnailStubSource()
        let store = try LibraryStore(
            source: source,
            cacheCapacityBytes: 1024 * 1024
        )
        let entry = MediaEntry(
            path: "Photos/wide.jpg",
            name: "wide.jpg",
            isDirectory: false,
            size: 1,
            modified: nil
        )

        XCTAssertNil(store.aspectRatio(for: entry))
        store.rememberAspectRatio(2, for: entry)
        XCTAssertEqual(store.aspectRatio(for: entry), 2)

        store.rememberAspectRatio(10, for: entry)
        XCTAssertEqual(store.aspectRatio(for: entry), 2.5, "宽高比应收敛到 0.4–2.5")
    }
}

private actor ImageThumbnailStubSource: LibrarySource {
    nonisolated let hostName = "stub-host"
    nonisolated let shareName = "stub-share"
    private(set) var thumbnailOpenCount = 0
    private(set) var playbackOpenCount = 0

    func listDirectory(path: String) async throws -> [MediaEntry] { [] }
    func listAllEntries(path: String) async throws -> [MediaEntry] { [] }

    func openByteSource(path: String) async throws -> any ByteSource {
        playbackOpenCount += 1
        throw ByteSourceError.underlying("playback should not be used")
    }

    func openThumbnailByteSource(path: String) async throws -> any ByteSource {
        thumbnailOpenCount += 1
        let bundle = Bundle(for: ImageThumbnailStubSource.self)
        let url = bundle.url(
            forResource: "sample",
            withExtension: "jpg",
            subdirectory: "ImageGallery"
        ) ?? bundle.url(forResource: "sample", withExtension: "jpg")!
        return try LocalFileByteSource(url: url)
    }
}
