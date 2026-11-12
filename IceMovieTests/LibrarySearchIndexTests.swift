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

    func testDocumentsAreIndexedByTheirFileTitle() {
        var index = LibrarySearchIndex()
        index.index(
            directoryPath: "面试知识库",
            entries: [
                entry(path: "面试知识库/swift.md", name: "swift.md"),
                entry(path: "面试知识库/swift.pdf", name: "swift.pdf"),
                entry(path: "面试知识库/iOS面试-P0P1核心.md", name: "iOS面试-P0P1核心.md"),
            ]
        )

        XCTAssertEqual(index.search("swift").count, 2)
        XCTAssertEqual(index.search("P0P1").count, 1)
        XCTAssertEqual(index.search("P0P1").first?.entry.kind, .markdown)
    }

    func testImagesAreIndexedByRawFilenameWithoutEpisodeParsing() {
        var index = LibrarySearchIndex()
        index.index(
            directoryPath: "Photos",
            entries: [
                entry(path: "Photos/IMG_1234.HEIC", name: "IMG_1234.HEIC"),
                entry(path: "Photos/海边日落.JPG", name: "海边日落.JPG"),
                entry(path: "Photos/Episode 01.mkv", name: "Episode 01.mkv"),
            ]
        )

        let imageHits = index.search("IMG_1234")
        XCTAssertEqual(imageHits.count, 1)
        XCTAssertEqual(imageHits.first?.entry.kind, .image)
        XCTAssertEqual(imageHits.first?.entry.name, "IMG_1234.HEIC")
        XCTAssertEqual(index.search("海边日落").first?.entry.kind, .image)
        XCTAssertEqual(index.search("Episode").first?.entry.kind, .video)
    }

    private func entry(path: String, name: String) -> MediaEntry {
        MediaEntry(path: path, name: name, isDirectory: false, size: 1, modified: nil)
    }
}
