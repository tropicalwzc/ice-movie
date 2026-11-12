import MediaLibraryKit
import XCTest

final class LibraryContentSectioningTests: XCTestCase {
    func testMixedDirectoryKeepsFoldersAndVideosInGrid() {
        let section = LibraryContentSectioning(entries: [
            entry("iOS", directory: true),
            entry("Episode 01.mkv"),
            entry("guide.pdf"),
            entry("notes.md"),
        ])

        XCTAssertEqual(section.presentation, .mixed)
        XCTAssertTrue(section.hasVideos)
        XCTAssertEqual(section.gridItems.map(\.name), ["iOS", "Episode 01.mkv"])
        XCTAssertEqual(section.documentItems.map(\.name), ["guide.pdf", "notes.md"])
        XCTAssertEqual(section.documentListItems.map(\.name), ["iOS", "guide.pdf", "notes.md"])
    }

    func testDocumentsOnlyDirectoryUsesListWithFoldersFirst() {
        let section = LibraryContentSectioning(entries: [
            entry("iOS", directory: true),
            entry("notes.md"),
            entry("guide.pdf"),
        ])

        XCTAssertEqual(section.presentation, .documentsOnly)
        XCTAssertFalse(section.hasVideos)
        XCTAssertEqual(section.documentListItems.first?.name, "iOS")
        XCTAssertEqual(section.documentListItems.map(\.name), ["iOS", "guide.pdf", "notes.md"])
    }

    func testVideoOnlyDirectoryKeepsExistingGrid() {
        let section = LibraryContentSectioning(entries: [
            entry("iOS", directory: true),
            entry("Episode 01.mkv"),
        ])

        XCTAssertEqual(section.presentation, .mediaGrid)
        XCTAssertTrue(section.hasVideos)
        XCTAssertTrue(section.documentItems.isEmpty)
        XCTAssertEqual(section.gridItems.map(\.name), ["iOS", "Episode 01.mkv"])
    }

    func testFolderOnlyDirectoryStillUsesGrid() {
        let section = LibraryContentSectioning(entries: [
            entry("iOS", directory: true),
            entry("skills", directory: true),
        ])

        XCTAssertEqual(section.presentation, .mediaGrid)
        XCTAssertFalse(section.hasVideos)
        XCTAssertEqual(section.gridItems.count, 2)
    }

    func testImagesOnlyDirectoryUsesGrid() {
        let section = LibraryContentSectioning(entries: [
            entry("Photos", directory: true),
            entry("IMG_0001.HEIC"),
            entry("IMG_0002.JPG"),
        ])

        XCTAssertEqual(section.presentation, .mediaGrid)
        XCTAssertFalse(section.hasVideos)
        XCTAssertTrue(section.hasImages)
        XCTAssertTrue(section.hasGridMedia)
        XCTAssertEqual(
            section.gridItems.map(\.name),
            ["Photos", "IMG_0001.HEIC", "IMG_0002.JPG"]
        )
    }

    func testImagesAndDocumentsUseMixedPresentation() {
        let section = LibraryContentSectioning(entries: [
            entry("iOS", directory: true),
            entry("IMG_0001.HEIC"),
            entry("notes.md"),
        ])

        XCTAssertEqual(section.presentation, .mixed)
        XCTAssertTrue(section.hasImages)
        XCTAssertFalse(section.hasVideos)
        XCTAssertEqual(section.gridItems.map(\.name), ["iOS", "IMG_0001.HEIC"])
        XCTAssertEqual(section.documentItems.map(\.name), ["notes.md"])
    }

    func testVideosImagesAndDocumentsUseMixedPresentation() {
        let section = LibraryContentSectioning(entries: [
            entry("Episode 01.mkv"),
            entry("IMG_0001.HEIC"),
            entry("guide.pdf"),
        ])

        XCTAssertEqual(section.presentation, .mixed)
        XCTAssertTrue(section.hasVideos)
        XCTAssertTrue(section.hasImages)
        XCTAssertTrue(section.hasGridMedia)
        XCTAssertEqual(Set(section.gridItems.map(\.name)), ["Episode 01.mkv", "IMG_0001.HEIC"])
        XCTAssertEqual(section.documentItems.map(\.name), ["guide.pdf"])
    }

    func testPureDocumentDirectoryStaysDocumentsOnly() {
        let section = LibraryContentSectioning(entries: [
            entry("iOS", directory: true),
            entry("notes.md"),
        ])

        XCTAssertEqual(section.presentation, .documentsOnly)
        XCTAssertFalse(section.hasGridMedia)
        XCTAssertEqual(section.documentListItems.map(\.name), ["iOS", "notes.md"])
    }

    func testEmptyDirectory() {
        let section = LibraryContentSectioning(entries: [])
        XCTAssertEqual(section.presentation, .empty)
        XCTAssertTrue(section.isEmpty)
        XCTAssertFalse(section.hasDocuments)
    }

    func testDocumentsSortNaturally() {
        let section = LibraryContentSectioning(entries: [
            entry("Doc - 10.md"),
            entry("Doc - 2.md"),
            entry("Doc - 1.md"),
        ])
        XCTAssertEqual(section.documentItems.map(\.name), ["Doc - 1.md", "Doc - 2.md", "Doc - 10.md"])
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
