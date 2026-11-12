import Foundation
import IceCore
import MediaLibraryKit
import XCTest
@testable import IceMovie

@MainActor
final class LibraryMediaFilterTests: XCTestCase {
    func testMixedDirectoryDefaultsToBothSelected() async throws {
        let store = try await makeStore([
            entry("Show", directory: true),
            entry("Episode 01.mkv"),
            entry("IMG_0001.HEIC"),
        ])

        XCTAssertTrue(store.showsVideos)
        XCTAssertTrue(store.showsImages)
        XCTAssertTrue(store.mediaFilterIsApplicable)
        XCTAssertEqual(
            Set(store.visibleGridItems.map(\.name)),
            ["Show", "Episode 01.mkv", "IMG_0001.HEIC"]
        )
    }

    func testHidingVideosLeavesImagesAndDirectories() async throws {
        let store = try await makeStore([
            entry("Show", directory: true),
            entry("Episode 01.mkv"),
            entry("IMG_0001.HEIC"),
        ])
        store.showsVideos = false

        XCTAssertEqual(Set(store.visibleGridItems.map(\.name)), ["Show", "IMG_0001.HEIC"])
    }

    func testHidingImagesLeavesVideosAndDirectories() async throws {
        let store = try await makeStore([
            entry("Show", directory: true),
            entry("Episode 01.mkv"),
            entry("IMG_0001.HEIC"),
        ])
        store.showsImages = false

        XCTAssertEqual(Set(store.visibleGridItems.map(\.name)), ["Show", "Episode 01.mkv"])
    }

    func testHidingBothLeavesOnlyDirectories() async throws {
        let store = try await makeStore([
            entry("Show", directory: true),
            entry("Episode 01.mkv"),
            entry("IMG_0001.HEIC"),
        ])
        store.showsVideos = false
        store.showsImages = false

        XCTAssertEqual(store.visibleGridItems.map(\.name), ["Show"])
    }

    func testSingleTypeDirectoryIgnoresFilterState() async throws {
        let store = try await makeStore([
            entry("Episode 01.mkv"),
            entry("Episode 02.mkv"),
        ])
        store.showsVideos = false

        XCTAssertFalse(store.mediaFilterIsApplicable)
        XCTAssertEqual(Set(store.visibleGridItems.map(\.name)), ["Episode 01.mkv", "Episode 02.mkv"])
    }

    func testSwitchingShareResetsFilter() async throws {
        let store = try await makeStore([
            entry("Episode 01.mkv"),
            entry("IMG_0001.HEIC"),
        ])
        store.showsVideos = false

        await store.switchShare("Other")

        XCTAssertTrue(store.showsVideos)
        XCTAssertTrue(store.showsImages)
    }

    func testImageActivationRequestsGalleryAndNotPlayback() async throws {
        let store = try await makeStore([
            entry("Episode 01.mkv"),
            entry("IMG_0001.HEIC"),
            entry("IMG_0002.JPG"),
        ])
        var requested: ImageGallerySession?
        store.onImageGalleryRequested = { requested = $0 }
        let image = store.currentEntries.first { $0.kind == .image }!

        store.activate(image)

        XCTAssertEqual(requested?.entries.count, 2)
        XCTAssertEqual(requested?.initialEntry?.name, "IMG_0001.HEIC")
        let prepared = await store.preparePlayback(image)
        XCTAssertNil(prepared, "图片不得进入播放准备")
    }

    private func makeStore(_ entries: [MediaEntry]) async throws -> LibraryStore {
        let store = try LibraryStore(
            source: FilterStubSource(entries: entries),
            cacheCapacityBytes: 1024
        )
        await store.loadCurrent()
        return store
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

private struct FilterStubSource: LibrarySource {
    let hostName = "stub-host"
    let shareName = "share"
    let entries: [MediaEntry]

    func listDirectory(path: String) async throws -> [MediaEntry] {
        path.isEmpty ? entries : []
    }

    func listAllEntries(path: String) async throws -> [MediaEntry] {
        path.isEmpty ? entries : []
    }

    func availableShares() async throws -> [String] { ["share", "Other"] }

    func changeShare(_ share: String) async throws {}

    func openByteSource(path: String) async throws -> any ByteSource {
        throw ByteSourceError.underlying("stub")
    }

    func openThumbnailByteSource(path: String) async throws -> any ByteSource {
        throw ByteSourceError.underlying("stub")
    }
}
