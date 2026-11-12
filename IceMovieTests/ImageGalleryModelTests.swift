import IceCore
import MediaLibraryKit
import XCTest
@testable import IceMovie

@MainActor
final class ImageGalleryModelTests: XCTestCase {
    func testSessionClampsInitialIndex() {
        let entries = [entry("A.JPG"), entry("B.JPG")]
        let session = ImageGallerySession(
            entries: entries,
            initialIndex: 99,
            source: GalleryStubSource(fixtureName: "sample.jpg"),
            title: "A"
        )
        XCTAssertEqual(session.initialIndex, 1)
        XCTAssertEqual(session.initialEntry?.name, "B.JPG")
    }

    func testEmptySessionHasNoInitialEntry() {
        let session = ImageGallerySession(
            entries: [],
            initialIndex: 0,
            source: GalleryStubSource(fixtureName: "sample.jpg"),
            title: ""
        )
        XCTAssertNil(session.initialEntry)
    }

    func testPageModelLoadsThumbnailThenFullImage() async throws {
        let source = GalleryStubSource(fixtureName: "sample.jpg")
        let store = try LibraryStore(source: source, cacheCapacityBytes: 4 * 1024 * 1024)
        let image = entry("Photos/IMG_0001.JPG")
        let session = ImageGallerySession(
            entries: [image],
            initialIndex: 0,
            source: source,
            title: "IMG_0001"
        )
        let model = ImagePageModel(entry: image, session: session, store: store)

        await model.loadThumbnail()
        XCTAssertNotNil(model.thumbnail)

        model.loadFullImage(targetPixelSize: 64)
        for _ in 0..<80 where model.image == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotNil(model.image)
        XCTAssertNil(model.errorMessage)
        model.cancelLoading()
    }

    private func entry(_ name: String) -> MediaEntry {
        MediaEntry(path: name, name: name, isDirectory: false, size: 1, modified: nil)
    }
}

private struct GalleryStubSource: LibrarySource {
    let hostName = "gallery-host"
    let shareName = "gallery-share"
    let fixtureName: String

    func listDirectory(path: String) async throws -> [MediaEntry] { [] }
    func listAllEntries(path: String) async throws -> [MediaEntry] { [] }

    func openByteSource(path: String) async throws -> any ByteSource {
        throw ByteSourceError.underlying("playback not used")
    }

    func openThumbnailByteSource(path: String) async throws -> any ByteSource {
        try LocalFileByteSource(url: fixtureURL())
    }

    func openImageByteSource(path: String) async throws -> any ByteSource {
        try LocalFileByteSource(url: fixtureURL())
    }

    private func fixtureURL() throws -> URL {
        let bundle = Bundle(for: ImageGalleryModelTests.self)
        let pathExtension = (fixtureName as NSString).pathExtension
        let base = (fixtureName as NSString).deletingPathExtension
        if let url = bundle.url(
            forResource: base,
            withExtension: pathExtension,
            subdirectory: "ImageGallery"
        ) {
            return url
        }
        if let url = bundle.url(forResource: base, withExtension: pathExtension) {
            return url
        }
        throw XCTSkip("缺少测试 fixture：\(fixtureName)")
    }
}
