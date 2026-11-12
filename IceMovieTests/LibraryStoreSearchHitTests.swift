import Foundation
import IceCore
import MediaLibraryKit
import XCTest
@testable import IceMovie

@MainActor
final class LibraryStoreSearchHitTests: XCTestCase {
    func testStaleImageHitReturnsFalseInsteadOfOpeningFirstImage() async throws {
        let existing = MediaEntry(
            path: "Photos/IMG_0001.jpg",
            name: "IMG_0001.jpg",
            isDirectory: false,
            size: 1,
            modified: nil
        )
        let source = StaleImageSearchSource(entries: [existing])
        let store = try LibraryStore(
            source: source,
            initialPath: "Photos",
            cacheCapacityBytes: 1024 * 1024
        )
        let hit = LibrarySearchHit(
            entry: MediaEntry(
                path: "Photos/deleted.jpg",
                name: "deleted.jpg",
                isDirectory: false,
                size: 1,
                modified: nil
            ),
            displayPath: "Photos"
        )

        let opened = await store.openImageGallery(for: hit)

        XCTAssertFalse(opened, "已失效的图片命中不应打开目录里的第一张图")
        XCTAssertEqual(store.errorMessage, "这张图片已不在目录中")
    }
}

private actor StaleImageSearchSource: LibrarySource {
    nonisolated let hostName = "stub-host"
    nonisolated let shareName = "stub-share"
    private let entries: [MediaEntry]

    init(entries: [MediaEntry]) {
        self.entries = entries
    }

    func listDirectory(path: String) async throws -> [MediaEntry] { entries }
    func listAllEntries(path: String) async throws -> [MediaEntry] { entries }
    func openByteSource(path: String) async throws -> any ByteSource {
        throw ByteSourceError.underlying("unused")
    }
}
