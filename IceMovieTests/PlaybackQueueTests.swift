import MediaLibraryKit
import XCTest

final class PlaybackQueueTests: XCTestCase {
    private func entry(_ name: String, directory: Bool = false) -> MediaEntry {
        MediaEntry(
            path: "白箱/\(name)",
            name: name,
            isDirectory: directory,
            size: directory ? 0 : 100,
            modified: nil
        )
    }

    func testNextVideoInNaturalOrder() {
        let first = entry("Shirobako 01.mkv")
        let second = entry("Shirobako 02.mkv")
        let third = entry("Shirobako 03.mkv")
        let entries = [entry("Bonus", directory: true), first, second, third]

        XCTAssertEqual(PlaybackQueue.next(after: first, in: entries)?.path, second.path)
        XCTAssertEqual(PlaybackQueue.next(after: second, in: entries)?.path, third.path)
        XCTAssertNil(PlaybackQueue.next(after: third, in: entries))
    }

    func testSkipsDirectoriesAndMissingEntry() {
        let first = entry("Shirobako 01.mkv")
        let entries = [first, entry("Subs", directory: true), entry("Shirobako 02.mkv")]
        XCTAssertEqual(
            PlaybackQueue.next(after: first, in: entries)?.name,
            "Shirobako 02.mkv"
        )

        let missing = entry("Not In List.mkv")
        XCTAssertNil(PlaybackQueue.next(after: missing, in: entries))
    }

    func testDirectoryNeverAdvances() {
        let folder = entry("白箱", directory: true)
        XCTAssertNil(PlaybackQueue.next(after: folder, in: [folder, entry("01.mkv")]))
    }
}
