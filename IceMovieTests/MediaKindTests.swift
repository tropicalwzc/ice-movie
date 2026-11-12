import MediaLibraryKit
import XCTest

final class MediaKindTests: XCTestCase {
    func testDirectoryKind() {
        XCTAssertEqual(entry("iOS", directory: true).kind, .directory)
    }

    func testVideoExtensions() {
        for name in ["a.mkv", "a.mp4", "a.mov", "a.m4v", "a.avi", "a.ts", "a.m2ts", "a.webm"] {
            XCTAssertEqual(entry(name).kind, .video, name)
            XCTAssertTrue(MediaKind.isVisible(entry: entry(name)), name)
        }
    }

    func testMarkdownExtensions() {
        XCTAssertEqual(entry("swift.md").kind, .markdown)
        XCTAssertEqual(entry("swift.MARKDOWN").kind, .markdown)
        XCTAssertEqual(entry("swift.md").documentFormat, .markdown)
        XCTAssertTrue(MediaKind.isVisible(entry: entry("swift.md")))
    }

    func testPDFExtension() {
        XCTAssertEqual(entry("swift.pdf").kind, .pdf)
        XCTAssertEqual(entry("swift.PDF").documentFormat, .pdf)
        XCTAssertTrue(MediaKind.isVisible(entry: entry("swift.pdf")))
    }

    func testImageExtensions() {
        let expectations: [(String, ImageFormat)] = [
            ("photo.jpg", .jpeg),
            ("photo.JPEG", .jpeg),
            ("photo.png", .png),
            ("photo.HEIC", .heic),
            ("photo.heif", .heic),
            ("photo.LIVP", .livePhoto),
        ]
        for (name, format) in expectations {
            let item = entry(name)
            XCTAssertEqual(item.kind, .image, name)
            XCTAssertEqual(item.imageFormat, format, name)
            XCTAssertTrue(item.isImage, name)
            XCTAssertTrue(MediaKind.isVisible(entry: item), name)
        }
        XCTAssertEqual(entry("photo.LIVP").isLivePhoto, true)
        XCTAssertEqual(entry("photo.jpg").isLivePhoto, false)
    }

    func testUnsupportedImageExtensionsStayHidden() {
        for name in ["anim.gif", "photo.webp", "raw.dng", "scan.tiff"] {
            let item = entry(name)
            XCTAssertEqual(item.kind, .other, name)
            XCTAssertFalse(item.isImage, name)
            XCTAssertFalse(MediaKind.isVisible(entry: item), name)
        }
    }

    func testOtherExtensionsAreNotDocuments() {
        for name in ["notes.txt", "script.py", "download.torrent", "show.ass", "README"] {
            let item = entry(name)
            XCTAssertEqual(item.kind, .other, name)
            XCTAssertFalse(item.isDocument, name)
            XCTAssertFalse(MediaKind.isVisible(entry: item), name)
        }
    }

    func testDocumentLimitsAndLabels() {
        XCTAssertEqual(DocumentFormat.markdown.displayLabel, "MD")
        XCTAssertEqual(DocumentFormat.pdf.displayLabel, "PDF")
        XCTAssertEqual(DocumentFormat.markdown.maxByteCount, 5 * 1024 * 1024)
        XCTAssertEqual(DocumentFormat.pdf.maxByteCount, 30 * 1024 * 1024)
    }

    private func entry(_ name: String, directory: Bool = false) -> MediaEntry {
        MediaEntry(
            path: name,
            name: name,
            isDirectory: directory,
            size: directory ? 0 : 100,
            modified: nil
        )
    }
}
