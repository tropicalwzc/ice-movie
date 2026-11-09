import PersistenceKit
import SwiftData
import XCTest

final class PlaybackProgressPolicyTests: XCTestCase {
    func testFinishedWithinThirtySecondsOfEnd() {
        XCTAssertFalse(PlaybackProgressPolicy.isFinished(position: 1_000, duration: 1_200))
        XCTAssertFalse(PlaybackProgressPolicy.isFinished(position: 1_169.9, duration: 1_200))
        XCTAssertTrue(PlaybackProgressPolicy.isFinished(position: 1_170, duration: 1_200))
        XCTAssertTrue(PlaybackProgressPolicy.isFinished(position: 1_200, duration: 1_200))
    }

    func testResumeSkipsShortAndFinishedPositions() {
        XCTAssertNil(PlaybackProgressPolicy.resumePosition(position: 0, duration: 1_200))
        XCTAssertNil(PlaybackProgressPolicy.resumePosition(position: 4.9, duration: 1_200))
        XCTAssertEqual(
            PlaybackProgressPolicy.resumePosition(position: 5, duration: 1_200),
            5
        )
        XCTAssertEqual(
            PlaybackProgressPolicy.resumePosition(position: 720, duration: 1_200),
            720
        )
        XCTAssertNil(PlaybackProgressPolicy.resumePosition(position: 1_180, duration: 1_200))
    }

    func testUnknownDurationNeverFinishes() {
        XCTAssertFalse(PlaybackProgressPolicy.isFinished(position: 100, duration: 0))
        XCTAssertEqual(
            PlaybackProgressPolicy.resumePosition(position: 100, duration: 0),
            100
        )
    }

    func testKeyChangesWithFileIdentity() {
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let a = PlaybackProgressPolicy.key(path: "Animi/a.mkv", size: 10, modified: modified)
        let b = PlaybackProgressPolicy.key(path: "Animi/a.mkv", size: 11, modified: modified)
        let c = PlaybackProgressPolicy.key(
            path: "Animi/a.mkv",
            size: 10,
            modified: modified.addingTimeInterval(60)
        )
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}

@MainActor
final class PlaybackProgressStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var store: PlaybackProgressStore!

    override func setUp() {
        super.setUp()
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try? ModelContainer(
            for: PlaybackProgressRecord.self,
            configurations: configuration
        )
        context = ModelContext(container)
        store = PlaybackProgressStore(context: context)
    }

    override func tearDown() {
        store = nil
        context = nil
        container = nil
        super.tearDown()
    }

    func testRecordAndResume() {
        store.record(key: "k1", path: "Animi/a.mkv", position: 720, duration: 1_200)
        XCTAssertEqual(store.resumePosition(for: "k1"), 720)
        XCTAssertNil(store.resumePosition(for: "k2"), "不同视频互不影响")
    }

    func testOverwriteKeepsSingleRecord() {
        store.record(key: "k1", path: "Animi/a.mkv", position: 100, duration: 1_200)
        store.record(key: "k1", path: "Animi/a.mkv", position: 300, duration: 1_200)
        let count = (try? context.fetch(FetchDescriptor<PlaybackProgressRecord>()))?.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.resumePosition(for: "k1"), 300)
    }

    func testFinishedDeletesRecord() {
        store.record(key: "k1", path: "Animi/a.mkv", position: 720, duration: 1_200)
        store.record(key: "k1", path: "Animi/a.mkv", position: 1_180, duration: 1_200)
        XCTAssertNil(store.resumePosition(for: "k1"))
        let count = (try? context.fetch(FetchDescriptor<PlaybackProgressRecord>()))?.count
        XCTAssertEqual(count, 0)
    }

    func testInvalidInputIgnored() {
        store.record(key: "k1", path: "Animi/a.mkv", position: 0, duration: 1_200)
        store.record(key: "k1", path: "Animi/a.mkv", position: 100, duration: 0)
        XCTAssertNil(store.resumePosition(for: "k1"))
    }

    func testClearAndRemoveAll() {
        store.record(key: "k1", path: "a.mkv", position: 100, duration: 1_200)
        store.record(key: "k2", path: "b.mkv", position: 200, duration: 1_200)
        store.clear(key: "k1")
        XCTAssertNil(store.resumePosition(for: "k1"))
        XCTAssertEqual(store.resumePosition(for: "k2"), 200)

        store.removeAll()
        XCTAssertNil(store.resumePosition(for: "k2"))
    }
}
