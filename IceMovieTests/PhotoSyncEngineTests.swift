import Foundation
import MediaLibraryKit
import XCTest
@testable import IceMovie

@MainActor
final class PhotoSyncEngineTests: XCTestCase {
    private var root: URL!
    private var manifestDirectory: URL!
    private let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "photo-sync-engine-\(UUID().uuidString)",
            isDirectory: true
        )
        manifestDirectory = root.appendingPathComponent("Manifest", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Photos", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: manifestDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        manifestDirectory = nil
        try super.tearDownWithError()
    }

    func testScanDoesNotWriteBeforeConfirmation() async throws {
        let client = FakePhotoClient()
        let engine = makeEngine(client: client)
        let plan = try await engine.scan(
            manifest: PhotoSyncManifest(target: "local|photos"),
            authorization: .authorized
        )

        XCTAssertEqual(plan.counts.accessible, 3)
        XCTAssertEqual(plan.counts.pending, 3)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: root.appendingPathComponent("Photos").path
            ).count,
            0,
            "预览确认前不得写文件"
        )
    }

    func testUploadWritesFilesAndSecondScanIsUpToDate() async throws {
        let client = FakePhotoClient()
        let engine = makeEngine(client: client)
        let store = try PhotoSyncManifestStore(
            target: "local|photos",
            directory: manifestDirectory
        )
        let manifest = await store.snapshot()
        let plan = try await engine.scan(
            manifest: manifest,
            authorization: .authorized
        )
        let result = await engine.upload(
            plan: plan,
            manifestStore: store,
            rateMeter: TransferRateMeter(),
            cancellation: PhotoSyncCancellationFlag(),
            progress: { _ in }
        )

        XCTAssertFalse(result.interrupted)
        XCTAssertFalse(result.cancelled)
        XCTAssertEqual(result.successCount, 3)
        XCTAssertEqual(result.failures.count, 0)

        let photos = root.appendingPathComponent("Photos")
        let names = try FileManager.default.contentsOfDirectory(atPath: photos.path)
            .sorted()
        XCTAssertEqual(
            names,
            [
                "IMG_1001_20260505222609.jpg",
                "IMG_1002_20260506100000.jpg",
                "IMG_1003_20260507113000.jpg",
            ]
        )
        for name in names {
            XCTAssertEqual(
                try Data(contentsOf: photos.appendingPathComponent(name)),
                client.data
            )
        }
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.recordCount, 3)

        let secondPlan = try await engine.scan(
            manifest: snapshot,
            authorization: .authorized
        )
        XCTAssertEqual(secondPlan.counts.pending, 0)
        XCTAssertEqual(secondPlan.counts.matched, 3)
    }

    func testSingleExportFailureContinuesAndOnlyRecordsSuccesses() async throws {
        let client = FakePhotoClient()
        await client.setExportFailures(["a2"])
        let engine = makeEngine(client: client)
        let store = try PhotoSyncManifestStore(
            target: "local|photos",
            directory: manifestDirectory
        )
        let plan = try await engine.scan(
            manifest: PhotoSyncManifest(target: "local|photos"),
            authorization: .authorized
        )
        let result = await engine.upload(
            plan: plan,
            manifestStore: store,
            rateMeter: TransferRateMeter(),
            cancellation: PhotoSyncCancellationFlag(),
            progress: { _ in }
        )

        XCTAssertEqual(result.successCount, 2)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures[0].fileName, "IMG_1002_20260506100000.jpg")
        XCTAssertFalse(result.interrupted)

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.recordCount, 2)
        XCTAssertNil(snapshot.assets["a2"])
        XCTAssertNotNil(snapshot.assets["a1"])
    }

    func testCancelBeforeUploadWritesNothing() async throws {
        let client = FakePhotoClient()
        let engine = makeEngine(client: client)
        let store = try PhotoSyncManifestStore(
            target: "local|photos",
            directory: manifestDirectory
        )
        let plan = try await engine.scan(
            manifest: PhotoSyncManifest(target: "local|photos"),
            authorization: .authorized
        )
        let cancellation = PhotoSyncCancellationFlag()
        cancellation.cancel()

        let result = await engine.upload(
            plan: plan,
            manifestStore: store,
            rateMeter: TransferRateMeter(),
            cancellation: cancellation,
            progress: { _ in }
        )

        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.successCount, 0)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: root.appendingPathComponent("Photos").path
            ).count,
            0
        )
    }

    func testConsecutiveWriteFailuresAbort() async throws {
        let client = FakePhotoClient()
        let engine = makeEngine(client: client)
        let store = try PhotoSyncManifestStore(
            target: "local|photos",
            directory: manifestDirectory
        )
        let plan = try await engine.scan(
            manifest: PhotoSyncManifest(target: "local|photos"),
            authorization: .authorized
        )
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("Photos")
        )

        let result = await engine.upload(
            plan: plan,
            manifestStore: store,
            rateMeter: TransferRateMeter(),
            cancellation: PhotoSyncCancellationFlag(),
            progress: { _ in }
        )

        XCTAssertTrue(result.interrupted)
        XCTAssertEqual(result.successCount, 0)
        XCTAssertEqual(result.failures.count, 3)
        XCTAssertFalse(result.errorMessage?.isEmpty ?? true)
    }

    private func makeEngine(client: FakePhotoClient) -> PhotoSyncEngine {
        PhotoSyncEngine(
            source: LocalLibrarySource(rootURL: root),
            client: client,
            targetPath: "Photos",
            timeZone: timeZone
        )
    }
}

private actor FakePhotoClient: PhotoLibraryClient {
    nonisolated let data = Data([0x01, 0x02, 0x03, 0x04, 0x05])
    private var exportFailures: Set<String> = []
    private var exportCount = 0

    func setExportFailures(_ ids: Set<String>) {
        exportFailures = ids
    }

    func authorizationStatus() async -> PhotoLibraryAuthorizationStatus {
        .authorized
    }

    func requestAuthorization() async -> PhotoLibraryAuthorizationStatus {
        .authorized
    }

    func fetchSkippedVideoCount() async -> Int {
        1
    }

    func fetchImageAssets(
        skippingMetadataFor ids: Set<String>
    ) async throws -> [PhotoAssetDescriptor] {
        [
            descriptor("a1", "IMG_1001.JPG", 2026, 5, 5, 22, 26, 9),
            descriptor("a2", "IMG_1002.JPG", 2026, 5, 6, 10, 0, 0),
            descriptor("a3", "IMG_1003.JPG", 2026, 5, 7, 11, 30, 0),
        ]
    }

    func exportImage(for assetID: String) async throws -> PhotoExport {
        exportCount += 1
        if exportFailures.contains(assetID) {
            throw PhotoLibraryClientError.exportFailed("fake export failure")
        }
        return PhotoExport(
            still: PhotoResource(
                data: data,
                uniformTypeIdentifier: "public.jpeg",
                originalFilename: nil
            ),
            motion: nil
        )
    }

    private func descriptor(
        _ id: String,
        _ filename: String,
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        _ second: Int
    ) -> PhotoAssetDescriptor {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let date = calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute,
                second: second
            )
        ) ?? Date()
        return PhotoAssetDescriptor(
            id: id,
            creationDate: date,
            modificationDate: nil,
            originalFilename: filename,
            uniformTypeIdentifier: "public.jpeg",
            contentKind: .still,
            isHidden: false
        )
    }
}
