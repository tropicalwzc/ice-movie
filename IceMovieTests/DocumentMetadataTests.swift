import MediaLibraryKit
import XCTest

final class DocumentMetadataTests: XCTestCase {
    func testMarkdownMetadata() {
        let metadata = DocumentMetadata(entry: entry("iOS面试-P0P1核心.md", size: 118_784))
        XCTAssertEqual(metadata?.title, "iOS面试-P0P1核心")
        XCTAssertEqual(metadata?.format, .markdown)
        XCTAssertEqual(metadata?.typeLabel, "MD")
        XCTAssertEqual(metadata?.size, 118_784)
        XCTAssertFalse(metadata?.sizeText.isEmpty ?? true)
    }

    func testPDFMetadata() {
        let metadata = DocumentMetadata(entry: entry("swift.pdf", size: 1_530_000))
        XCTAssertEqual(metadata?.title, "swift")
        XCTAssertEqual(metadata?.format, .pdf)
        XCTAssertEqual(metadata?.typeLabel, "PDF")
    }

    func testSameNameMarkdownAndPDFRemainDistinguishable() {
        let markdown = DocumentMetadata(entry: entry("swift.md"))
        let pdf = DocumentMetadata(entry: entry("swift.pdf"))
        XCTAssertEqual(markdown?.title, pdf?.title)
        XCTAssertNotEqual(markdown?.typeLabel, pdf?.typeLabel)
    }

    func testNumberedDocumentTitleIsNotEpisodeParsed() {
        let metadata = DocumentMetadata(entry: entry("第 2 篇 - 第 10 题.md"))
        XCTAssertEqual(metadata?.title, "第 2 篇 - 第 10 题")
    }

    func testNonDocumentReturnsNil() {
        XCTAssertNil(DocumentMetadata(entry: entry("Episode 01.mkv")))
        XCTAssertNil(DocumentMetadata(entry: entry("notes.txt")))
        XCTAssertNil(DocumentMetadata(entry: entry("iOS", directory: true)))
    }

    private func entry(
        _ name: String,
        directory: Bool = false,
        size: Int64 = 100
    ) -> MediaEntry {
        MediaEntry(
            path: name,
            name: name,
            isDirectory: directory,
            size: directory ? 0 : size,
            modified: nil
        )
    }
}
