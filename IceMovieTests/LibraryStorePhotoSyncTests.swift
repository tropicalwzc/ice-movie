import Foundation
import IceCore
import MediaLibraryKit
import PersistenceKit
import SwiftData
import XCTest
@testable import IceMovie

@MainActor
final class LibraryStorePhotoSyncTests: XCTestCase {
    func testTargetSubtitleAndCurrentDirectoryState() throws {
        let source = PhotoSyncStoreStubSource()
        let store = try LibraryStore(
            source: source,
            initialPath: "",
            cacheCapacityBytes: 1024 * 1024
        )
        store.setPhotoLibraryTargetPath("Photos")

        let photos = MediaEntry(
            path: "Photos",
            name: "Photos",
            isDirectory: true,
            size: 0,
            modified: nil
        )
        let other = MediaEntry(
            path: "Other",
            name: "Other",
            isDirectory: true,
            size: 0,
            modified: nil
        )

        XCTAssertTrue(store.isPhotoLibraryTarget(path: "Photos"))
        XCTAssertFalse(store.isPhotoLibraryTarget(path: "Other"))
        XCTAssertEqual(store.subtitle(for: photos), "照片库路径")
        XCTAssertEqual(store.subtitle(for: other), "文件夹")
        XCTAssertFalse(store.isCurrentDirectoryPhotoLibraryTarget)

        store.move(to: "Photos")
        XCTAssertTrue(store.isCurrentDirectoryPhotoLibraryTarget)
    }

    func testRefreshDirectoryAfterPhotoSyncUpdatesCurrentEntries() async throws {
        let source = PhotoSyncStoreStubSource()
        let store = try LibraryStore(
            source: source,
            initialPath: "Photos",
            cacheCapacityBytes: 1024 * 1024
        )
        store.setPhotoLibraryTargetPath("Photos")
        store.move(to: "Photos")
        await store.loadCurrent(force: true)
        XCTAssertTrue(store.currentEntries.isEmpty)

        await source.addImage("IMG_0001_20260505222609.jpg")
        await store.refreshDirectoryAfterPhotoSync(path: "Photos")

        XCTAssertEqual(store.currentEntries.count, 1)
        XCTAssertTrue(store.currentEntries[0].isImage)
        XCTAssertTrue(store.hasPhotoCalendar)
    }

    func testCalendarDayJumpCanBeClearedBackToAllPhotos() async throws {
        let source = PhotoSyncStoreStubSource()
        await source.addImage("IMG_0001_20260505222609.jpg")
        let store = try LibraryStore(
            source: source,
            initialPath: "Photos",
            cacheCapacityBytes: 1024 * 1024
        )
        store.move(to: "Photos")
        await store.loadCurrent(force: true)
        XCTAssertEqual(store.currentEntries.count, 1)

        let day = PhotoDay(year: 2026, month: 5, day: 5)
        store.requestPhotoJump(to: day)
        XCTAssertEqual(store.photoCalendarJump, .day(day))
        XCTAssertEqual(
            store.pendingScrollTarget,
            "Photos/IMG_0001_20260505222609.jpg"
        )

        store.clearPhotoCalendarJump()
        XCTAssertNil(store.photoCalendarJump)
        XCTAssertEqual(
            store.pendingScrollTarget,
            store.visibleGridItems.first?.id,
            "清除后应滚回全部照片顶部"
        )
    }

    func testFavoriteFilterUsesCrossDirectoryEntries() async throws {
        let source = PhotoSyncStoreStubSource()
        await source.addImage("IMG_0001_20260505222609.jpg")
        let favorites = FakeFavoriteProvider()
        let store = try LibraryStore(
            source: source,
            initialPath: "Photos",
            cacheCapacityBytes: 1024 * 1024,
            favoriteProvider: favorites
        )
        store.move(to: "Photos")
        await store.loadCurrent(force: true)

        let entry = try XCTUnwrap(store.currentEntries.first)
        store.toggleFavorite(entry)
        XCTAssertTrue(store.isFavorite(entry))
        XCTAssertEqual(favorites.count(host: source.hostName, share: source.shareName), 1)

        store.toggleFavoritesOnly()
        XCTAssertTrue(store.favoritesOnly)
        XCTAssertEqual(store.currentTitle, "收藏夹")
        XCTAssertEqual(store.visibleGridItems.map(\.path), [entry.path])

        store.toggleFavorite(entry)
        XCTAssertFalse(store.isFavorite(entry))
        XCTAssertTrue(store.visibleGridItems.isEmpty)
    }
}

@MainActor
private final class FakeFavoriteProvider: FavoritePhotoProviding {
    private var records: [String: FavoritePhotoSnapshot] = [:]

    private func key(host: String, share: String, path: String) -> String {
        "\(host.lowercased())|\(share.lowercased())|\(path)"
    }

    func snapshots(host: String, share: String) -> [FavoritePhotoSnapshot] {
        records.values.filter {
            // Path is enough for this test; host/share are encoded in the key.
            $0.path.hasPrefix("")
        }
    }

    func toggle(
        host: String,
        share: String,
        path: String,
        name: String,
        size: Int64,
        modified: Date?
    ) -> Bool {
        let key = key(host: host, share: share, path: path)
        if records[key] != nil {
            records[key] = nil
            return false
        }
        records[key] = FavoritePhotoSnapshot(
            path: path,
            name: name,
            size: size,
            modified: modified
        )
        return true
    }

    func remove(host: String, share: String, path: String) {
        records[key(host: host, share: share, path: path)] = nil
    }

    func count(host: String, share: String) -> Int {
        snapshots(host: host, share: share).count
    }
}

private actor PhotoSyncStoreStubSource: LibrarySource {
    nonisolated let hostName = "photo-sync-store-host"
    nonisolated let shareName = "Photos"
    private var images: [MediaEntry] = []

    func addImage(_ name: String) {
        images = [
            MediaEntry(
                path: "Photos/\(name)",
                name: name,
                isDirectory: false,
                size: 1,
                modified: nil
            ),
        ]
    }

    func listDirectory(path: String) async throws -> [MediaEntry] {
        if path.isEmpty {
            return [
                MediaEntry(
                    path: "Photos",
                    name: "Photos",
                    isDirectory: true,
                    size: 0,
                    modified: nil
                ),
                MediaEntry(
                    path: "Other",
                    name: "Other",
                    isDirectory: true,
                    size: 0,
                    modified: nil
                ),
            ]
        }
        if path == "Photos" {
            return images
        }
        return []
    }

    func listAllEntries(path: String) async throws -> [MediaEntry] {
        try await listDirectory(path: path)
    }

    func openByteSource(path: String) async throws -> any ByteSource {
        throw LibrarySourceError.unsupportedWrite
    }
}
