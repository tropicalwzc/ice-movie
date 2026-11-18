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

    func testSearchIndexesOtherSharesAfterCurrentShare() async throws {
        let source = MultiShareSearchSource(
            share: "Videos",
            entriesByShare: [
                "Videos": [
                    "": [
                        directory(path: "Shows", name: "Shows"),
                    ],
                    "Shows": [
                        video(path: "Shows/OnlyCurrent.mkv", name: "OnlyCurrent.mkv"),
                    ],
                ],
                "Anime": [
                    "": [
                        video(path: "OnlyOtherShare.mkv", name: "OnlyOtherShare.mkv"),
                    ],
                ],
            ]
        )
        let store = try LibraryStore(
            source: source,
            initialPath: "",
            cacheCapacityBytes: 1024 * 1024
        )

        store.applySearch("OnlyOtherShare")
        for _ in 0..<200 where store.isIndexing {
            try? await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertFalse(store.isIndexing, "后台索引应结束")
        XCTAssertEqual(store.indexedShareCount, 2)
        XCTAssertEqual(store.searchHits.map(\.share), ["Anime"])
        XCTAssertEqual(store.searchHits.first?.entry.path, "OnlyOtherShare.mkv")
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

private actor MultiShareSearchSource: LibrarySource {
    nonisolated let hostName = "stub-host"
    nonisolated let shareName: String
    private let entriesByShare: [String: [String: [MediaEntry]]]

    init(share: String, entriesByShare: [String: [String: [MediaEntry]]]) {
        self.shareName = share
        self.entriesByShare = entriesByShare
    }

    func listDirectory(path: String) async throws -> [MediaEntry] {
        entriesByShare[shareName]?[path] ?? []
    }

    func listAllEntries(path: String) async throws -> [MediaEntry] {
        entriesByShare[shareName]?[path] ?? []
    }

    func availableShares() async throws -> [String] {
        entriesByShare.keys.sorted()
    }

    func makeSearchIndexSource(share: String) async throws -> (any LibrarySource)? {
        guard share != shareName else { return nil }
        return MultiShareSearchSource(share: share, entriesByShare: entriesByShare)
    }

    func openByteSource(path: String) async throws -> any ByteSource {
        throw ByteSourceError.underlying("unused")
    }
}

private func directory(path: String, name: String) -> MediaEntry {
    MediaEntry(path: path, name: name, isDirectory: true, size: 0, modified: nil)
}

private func video(path: String, name: String) -> MediaEntry {
    MediaEntry(path: path, name: name, isDirectory: false, size: 1, modified: nil)
}
