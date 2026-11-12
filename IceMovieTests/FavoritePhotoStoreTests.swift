import PersistenceKit
import SwiftData
import XCTest

@MainActor
final class FavoritePhotoStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() {
        super.setUp()
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(
            for: FavoritePhoto.self,
            configurations: configuration
        )
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
        super.tearDown()
    }

    func testToggleFavoriteAndPersistence() throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let store = FavoritePhotoStore(context: context, now: { now })

        XCTAssertFalse(
            store.isFavorite(host: "nas.local", share: "Photos", path: "Photos/a.jpg")
        )
        let favorited = store.toggle(
            host: "nas.local",
            share: "Photos",
            path: "Photos/a.jpg",
            name: "a.jpg",
            size: 123,
            modified: Date(timeIntervalSince1970: 900)
        )
        XCTAssertTrue(favorited)
        XCTAssertTrue(
            store.isFavorite(host: "nas.local", share: "Photos", path: "Photos/a.jpg")
        )
        XCTAssertEqual(store.favorites(host: "nas.local", share: "Photos").count, 1)

        now = Date(timeIntervalSince1970: 2_000)
        store.toggle(
            host: "nas.local",
            share: "Photos",
            path: "Photos/b.jpg",
            name: "b.jpg",
            size: 456,
            modified: nil
        )
        XCTAssertEqual(
            store.favorites(host: "nas.local", share: "Photos").map(\.name),
            ["b.jpg", "a.jpg"]
        )

        let reopened = ModelContext(container)
        let reopenedStore = FavoritePhotoStore(context: reopened)
        XCTAssertEqual(
            reopenedStore.favorites(host: "nas.local", share: "Photos").count,
            2
        )

        XCTAssertFalse(
            store.toggle(
                host: "nas.local",
                share: "Photos",
                path: "Photos/a.jpg",
                name: "a.jpg",
                size: 123,
                modified: nil
            )
        )
        XCTAssertEqual(store.favorites(host: "nas.local", share: "Photos").count, 1)
    }

    func testSharesAndHostsAreIsolated() {
        let store = FavoritePhotoStore(context: context)
        store.toggle(
            host: "nas.local",
            share: "Photos",
            path: "Photos/a.jpg",
            name: "a.jpg",
            size: 1,
            modified: nil
        )
        store.toggle(
            host: "nas.local",
            share: "Backup",
            path: "Photos/a.jpg",
            name: "a.jpg",
            size: 1,
            modified: nil
        )
        store.toggle(
            host: "other.local",
            share: "Photos",
            path: "Photos/a.jpg",
            name: "a.jpg",
            size: 1,
            modified: nil
        )

        XCTAssertEqual(store.favorites(host: "nas.local", share: "Photos").count, 1)
        XCTAssertEqual(store.favorites(host: "nas.local", share: "Backup").count, 1)
        XCTAssertEqual(store.favorites(host: "other.local", share: "Photos").count, 1)
    }

    func testRemoveAndRemoveAll() {
        let store = FavoritePhotoStore(context: context)
        store.toggle(
            host: "nas.local",
            share: "Photos",
            path: "Photos/a.jpg",
            name: "a.jpg",
            size: 1,
            modified: nil
        )
        store.toggle(
            host: "nas.local",
            share: "Photos",
            path: "Photos/b.jpg",
            name: "b.jpg",
            size: 1,
            modified: nil
        )
        store.remove(host: "nas.local", share: "Photos", path: "Photos/a.jpg")
        XCTAssertEqual(store.favorites(host: "nas.local", share: "Photos").count, 1)

        store.removeAll()
        XCTAssertTrue(store.favorites(host: "nas.local", share: "Photos").isEmpty)
    }
}
