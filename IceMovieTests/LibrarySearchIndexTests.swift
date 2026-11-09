import MediaLibraryKit
import XCTest

final class LibrarySearchIndexTests: XCTestCase {
    func testSearchAccumulatesAcrossDirectoriesAndLabelsPath() {
        var index = LibrarySearchIndex()
        index.index(
            directoryPath: "A",
            entries: [entry(path: "A/Show - 01.mkv", name: "Show - 01.mkv")]
        )
        XCTAssertEqual(index.search("Show").count, 1)

        index.index(
            directoryPath: "B/C",
            entries: [entry(path: "B/C/Show - 02.mkv", name: "Show - 02.mkv")]
        )

        let hits = index.search("Show")
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(Set(hits.map(\.displayPath)), ["A", "B/C"])
        XCTAssertEqual(index.indexedDirectoryCount, 2)
    }

    func testSearchMatchesParsedTitleNotJustRawName() {
        var index = LibrarySearchIndex()
        index.index(
            directoryPath: "Season",
            entries: [
                entry(
                    path: "Season/[Group] My Show - 03 [1080p AAC].mkv",
                    name: "[Group] My Show - 03 [1080p AAC].mkv"
                )
            ]
        )
        XCTAssertEqual(index.search("My Show").count, 1)
        XCTAssertEqual(index.search("my show").count, 1)
    }

    func testEmptyQueryReturnsNothing() {
        var index = LibrarySearchIndex()
        index.index(
            directoryPath: "A",
            entries: [entry(path: "A/Episode.mkv", name: "Episode.mkv")]
        )
        XCTAssertTrue(index.search("  ").isEmpty)
    }

    private func entry(path: String, name: String) -> MediaEntry {
        MediaEntry(path: path, name: name, isDirectory: false, size: 1, modified: nil)
    }
}
