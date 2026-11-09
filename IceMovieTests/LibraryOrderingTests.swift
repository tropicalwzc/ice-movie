import MediaLibraryKit
import XCTest

final class LibraryOrderingTests: XCTestCase {
    func testEpisodesSortNaturally() {
        let entries = [
            entry("Show - 10.mkv"),
            entry("Show - 2.mkv"),
            entry("Show - 1.mkv"),
        ]
        let sorted = MediaOrdering.sorted(entries)
        XCTAssertEqual(
            sorted.map { MediaTitleParser.parse($0.name).episode },
            [1, 2, 10]
        )
    }

    func testDirectoriesComeBeforeVideos() {
        let entries = [
            entry("Show - 01.mkv"),
            entry("Sub", isDirectory: true),
        ]
        let sorted = MediaOrdering.sorted(entries)
        XCTAssertTrue(sorted[0].isDirectory)
        XCTAssertFalse(sorted[1].isDirectory)
    }

    func testNonMediaItemsAreFilteredButDirectoriesRemain() {
        let items: [(name: String, isDirectory: Bool, size: Int64, modified: Date?)] = [
            ("Episode 01.mkv", false, 100, nil),
            ("Show", true, 0, nil),
            ("notes.txt", false, 10, nil),
            ("show.ass", false, 20, nil),
            ("download.torrent", false, 30, nil),
        ]
        let built = LibraryEntryBuilder.build(directoryPath: "Anime", items: items)
        XCTAssertEqual(built.map(\.name), ["Show", "Episode 01.mkv"])
        XCTAssertEqual(built[1].path, "Anime/Episode 01.mkv")
    }

    private func entry(_ name: String, isDirectory: Bool = false) -> MediaEntry {
        MediaEntry(
            path: name,
            name: name,
            isDirectory: isDirectory,
            size: 1,
            modified: nil
        )
    }
}
