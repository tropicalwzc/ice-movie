import MediaLibraryKit
import XCTest

final class PhotoSyncManifestTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "photo-sync-manifest-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    func testRoundTripAndTargetIsolation() async throws {
        let store = try PhotoSyncManifestStore(
            target: "nas.local|photos",
            directory: directory
        )
        let syncedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.record(
            assetID: "asset-1",
            record: PhotoSyncManifestRecord(
                contentKind: .livePhotoStill,
                remoteFiles: [
                    RemoteFile(
                        name: "IMG_0001_20260505222609.heic",
                        role: .still,
                        size: 1234
                    ),
                ],
                syncedAt: syncedAt
            )
        )
        try await store.flush()

        let reopened = try PhotoSyncManifestStore(
            target: "nas.local|photos",
            directory: directory
        )
        let snapshot = await reopened.snapshot()
        XCTAssertEqual(snapshot.recordCount, 1)
        XCTAssertEqual(snapshot.assets["asset-1"]?.contentKind, .livePhotoStill)
        XCTAssertEqual(snapshot.assets["asset-1"]?.remoteFiles.first?.size, 1234)

        let otherTarget = try PhotoSyncManifestStore(
            target: "nas.local|backup",
            directory: directory
        )
        let otherSnapshot = await otherTarget.snapshot()
        XCTAssertEqual(otherSnapshot.recordCount, 0)
    }

    func testCorruptFileFallsBackToEmptyManifest() async throws {
        let store = try PhotoSyncManifestStore(
            target: "nas.local|photos",
            directory: directory
        )
        let url = await store.fileURL
        try Data("not-json".utf8).write(to: url)

        let reopened = try PhotoSyncManifestStore(
            target: "nas.local|photos",
            directory: directory
        )
        let snapshot = await reopened.snapshot()
        XCTAssertEqual(snapshot.recordCount, 0)
        let warning = await reopened.warning()
        XCTAssertNotNil(warning)
    }

    func testBatchSaveWritesAfterBatchSize() async throws {
        let store = try PhotoSyncManifestStore(
            target: "nas.local|photos",
            directory: directory,
            batchSize: 2
        )
        let record = PhotoSyncManifestRecord(
            contentKind: .still,
            remoteFiles: [
                RemoteFile(name: "a_20260101000000.jpg", role: .still, size: 1),
            ],
            syncedAt: Date()
        )
        let url = await store.fileURL
        try await store.record(assetID: "a", record: record)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        try await store.record(assetID: "b", record: record)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testVersionAndTargetMismatchRebuildManifest() async throws {
        let store = try PhotoSyncManifestStore(
            target: "nas.local|photos",
            directory: directory
        )
        let url = await store.fileURL
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let mismatched = PhotoSyncManifest(
            target: "nas.local|other",
            assets: [
                "x": PhotoSyncManifestRecord(
                    contentKind: .still,
                    remoteFiles: [],
                    syncedAt: Date()
                ),
            ]
        )
        try encoder.encode(mismatched).write(to: url, options: .atomic)

        let reopened = try PhotoSyncManifestStore(
            target: "nas.local|photos",
            directory: directory
        )
        let snapshot = await reopened.snapshot()
        XCTAssertEqual(snapshot.recordCount, 0)
        let warning = await reopened.warning()
        XCTAssertNotNil(warning)
    }
}
