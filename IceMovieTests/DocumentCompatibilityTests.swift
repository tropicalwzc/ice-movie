import Foundation
import IceCore
import MediaLibraryKit
import XCTest
@testable import IceMovie

final class LibraryPlaybackSelectionTests: XCTestCase {
    func testSelectionSkipsDocumentsBeforeFirstVideo() {
        let entries = [
            entry("notes.md"),
            entry("guide.pdf"),
            entry("Episode 01.mkv"),
        ]
        XCTAssertEqual(
            LibraryPlaybackSelection.firstVideo(in: entries)?.name,
            "Episode 01.mkv"
        )
    }

    func testPreferredNameOnlyMatchesVideos() {
        let entries = [
            entry("swift.md"),
            entry("swift.mkv"),
        ]
        XCTAssertEqual(
            LibraryPlaybackSelection.firstVideo(in: entries, preferredName: "swift")?.name,
            "swift.mkv"
        )
    }

    func testNoVideoReturnsNil() {
        XCTAssertNil(
            LibraryPlaybackSelection.firstVideo(in: [entry("notes.md"), entry("guide.pdf")])
        )
    }

    private func entry(_ name: String) -> MediaEntry {
        MediaEntry(path: name, name: name, isDirectory: false, size: 1, modified: nil)
    }
}

@MainActor
final class LibraryStoreDocumentTests: XCTestCase {
    func testDocumentDoesNotRequestThumbnail() async throws {
        let source = StubDocumentLibrarySource()
        let store = try LibraryStore(source: source, cacheCapacityBytes: 1024)
        let document = MediaEntry(
            path: "面试知识库/swift.md",
            name: "swift.md",
            isDirectory: false,
            size: 1024,
            modified: nil
        )

        let image = await store.thumbnail(for: document)
        XCTAssertNil(image)
        XCTAssertNil(store.cachedThumbnail(for: document))
        let thumbnailOpenCount = await source.thumbnailOpenCount
        XCTAssertEqual(thumbnailOpenCount, 0)
    }

    func testImageTitleAndSubtitleBypassEpisodeParsing() throws {
        let store = try LibraryStore(
            source: StubDocumentLibrarySource(),
            cacheCapacityBytes: 1024
        )
        let image = MediaEntry(
            path: "Photos/IMG_1234.HEIC",
            name: "IMG_1234.HEIC",
            isDirectory: false,
            size: 1024,
            modified: Date(timeIntervalSince1970: 1_704_067_200)
        )

        XCTAssertEqual(store.displayTitle(for: image), "IMG_1234")
        let subtitle = store.subtitle(for: image)
        XCTAssertFalse(subtitle.contains("第"), "图片副标题不应出现集数：\(subtitle)")
        XCTAssertTrue(subtitle.contains("2024"), "图片副标题应包含修改日期：\(subtitle)")
    }
}

private actor StubDocumentLibrarySource: LibrarySource {
    nonisolated let hostName = "stub-host"
    nonisolated let shareName = "stub-share"
    private(set) var thumbnailOpenCount = 0

    func listDirectory(path: String) async throws -> [MediaEntry] { [] }
    func listAllEntries(path: String) async throws -> [MediaEntry] { [] }

    func openByteSource(path: String) async throws -> any ByteSource {
        EmptyDocumentByteSource()
    }

    func openThumbnailByteSource(path: String) async throws -> any ByteSource {
        thumbnailOpenCount += 1
        return EmptyDocumentByteSource()
    }
}

private struct EmptyDocumentByteSource: ByteSource {
    let length: Int64? = 0
    func read(at offset: Int64, count: Int) async throws -> Data { Data() }
    func close() async {}
}
