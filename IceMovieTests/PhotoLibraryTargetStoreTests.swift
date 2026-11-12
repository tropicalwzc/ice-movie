import PersistenceKit
import SwiftData
import XCTest

@MainActor
final class PhotoLibraryTargetStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() {
        super.setUp()
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(
            for: PhotoLibraryTarget.self,
            configurations: configuration
        )
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
        super.tearDown()
    }

    func testMarkReadAndReplaceKeepsOneRecordPerShare() throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let store = PhotoLibraryTargetStore(context: context, now: { now })

        try store.mark(host: "tropical-advpc.lan", share: "Photos", path: "2026")
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(
            store.target(host: "tropical-advpc.lan", share: "Photos")?.path,
            "2026"
        )

        now = Date(timeIntervalSince1970: 2_000)
        try store.mark(host: "tropical-advpc.lan", share: "Photos", path: "照片库")
        XCTAssertEqual(store.all().count, 1, "同一共享必须替换而不是新增")
        XCTAssertEqual(
            store.target(host: "tropical-advpc.lan", share: "Photos")?.path,
            "照片库"
        )
        XCTAssertEqual(store.all()[0].updatedAt, now)
    }

    func testKeyIsCaseAndWhitespaceInsensitive() throws {
        let store = PhotoLibraryTargetStore(context: context)
        try store.mark(host: " TROPICAL-ADVPC.lan ", share: "Photos", path: "/2026/")

        XCTAssertEqual(
            store.target(host: "tropical-advpc.lan", share: "photos")?.path,
            "2026"
        )
        XCTAssertEqual(
            store.target(host: "Tropical-Advpc.LAN", share: "PHOTOS")?.host,
            "TROPICAL-ADVPC.lan"
        )
    }

    func testSharesAreIsolated() throws {
        let store = PhotoLibraryTargetStore(context: context)
        try store.mark(host: "nas.local", share: "Photos", path: "A")
        try store.mark(host: "nas.local", share: "Backup", path: "B")

        XCTAssertEqual(store.all().count, 2)
        XCTAssertEqual(store.target(host: "nas.local", share: "Photos")?.path, "A")
        XCTAssertEqual(store.target(host: "nas.local", share: "Backup")?.path, "B")
    }

    func testUnmarkAndRemoveAll() throws {
        let store = PhotoLibraryTargetStore(context: context)
        try store.mark(host: "nas.local", share: "Photos", path: "A")
        try store.unmark(host: "nas.local", share: "Photos")
        XCTAssertNil(store.target(host: "nas.local", share: "Photos"))

        try store.mark(host: "nas.local", share: "Photos", path: "A")
        try store.mark(host: "nas.local", share: "Backup", path: "B")
        try store.removeAll()
        XCTAssertTrue(store.all().isEmpty)
    }

    func testReopenWithNewContextKeepsTarget() throws {
        let store = PhotoLibraryTargetStore(context: context)
        try store.mark(host: "nas.local", share: "Photos", path: "2026")

        let reopenedContext = ModelContext(container)
        let reopenedStore = PhotoLibraryTargetStore(context: reopenedContext)
        XCTAssertEqual(
            reopenedStore.target(host: "nas.local", share: "Photos")?.path,
            "2026"
        )
    }

    func testMarkSyncedUpdatesTimestamp() throws {
        let now = Date(timeIntervalSince1970: 3_000)
        let store = PhotoLibraryTargetStore(context: context, now: { now })
        try store.mark(host: "nas.local", share: "Photos", path: "2026")
        store.markSynced(host: "nas.local", share: "Photos", at: now)

        XCTAssertEqual(
            store.target(host: "nas.local", share: "Photos")?.lastSyncedAt,
            now
        )
    }
}
