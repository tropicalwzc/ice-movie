import MediaLibraryKit
import XCTest

final class ImageMetadataTests: XCTestCase {
    func testCameraFilenameKeepsRawStemAndDoesNotParseEpisode() {
        let entry = makeEntry("IMG_1234.HEIC")
        let metadata = ImageMetadata(entry: entry)
        XCTAssertEqual(metadata?.title, "IMG_1234")
        XCTAssertEqual(metadata?.format, .heic)
        XCTAssertNil(MediaTitleParser.parse(entry.name).episode)
    }

    func testChineseFilename() {
        let metadata = ImageMetadata(entry: makeEntry("海边日落 2024.PNG"))
        XCTAssertEqual(metadata?.title, "海边日落 2024")
        XCTAssertEqual(metadata?.format, .png)
    }

    func testNumberedFilenameKeepsRawStemEvenIfParserWouldFindAnEpisode() {
        let entry = makeEntry("P0P1 - 03.jpg")
        let metadata = ImageMetadata(entry: entry)
        XCTAssertEqual(metadata?.title, "P0P1 - 03")
        // 发布名解析器可能把 "- 03" 当集号，但图片展示不应使用它的结果。
        XCTAssertEqual(MediaTitleParser.parse(entry.name).episode, 3)
        XCTAssertEqual(entry.kind, .image)
    }

    func testNonImageHasNoMetadata() {
        XCTAssertNil(ImageMetadata(entry: makeEntry("Episode 01.mkv")))
        XCTAssertNil(ImageMetadata(entry: makeEntry("notes.md")))
    }

    private func makeEntry(_ name: String) -> MediaEntry {
        MediaEntry(path: name, name: name, isDirectory: false, size: 1024, modified: nil)
    }
}
