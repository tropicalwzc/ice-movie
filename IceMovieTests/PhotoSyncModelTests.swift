import Foundation
import MediaLibraryKit
import PersistenceKit
import XCTest
@testable import IceMovie

@MainActor
final class PhotoSyncModelTests: XCTestCase {
    private var root: URL!
    private var manifestDirectory: URL!
    private var libraryStore: LibraryStore!
    private var targetBackend: InMemoryTargetStore!
    private var client: ModelPhotoClient!
    private var model: PhotoSyncModel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "photo-sync-model-\(UUID().uuidString)",
            isDirectory: true
        )
        manifestDirectory = root.appendingPathComponent("Manifest", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Photos", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Other", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: manifestDirectory,
            withIntermediateDirectories: true
        )

        libraryStore = try LibraryStore(
            source: LocalLibrarySource(rootURL: root),
            initialPath: ""
        )
        targetBackend = InMemoryTargetStore()
        client = ModelPhotoClient()
        let targetStore = PhotoSyncModel.TargetStore(
            target: { [weak targetBackend] host, share in
                targetBackend?.target
            },
            mark: { [weak targetBackend] host, share, path in
                let target = PhotoSyncModel.Target(
                    key: PhotoLibraryTargetStore.key(host: host, share: share),
                    host: host,
                    share: share,
                    path: path.trimmingCharacters(
                        in: CharacterSet(charactersIn: "/ ")
                    )
                )
                targetBackend?.target = target
                return target
            },
            unmark: { [weak targetBackend] _, _ in
                targetBackend?.target = nil
            },
            markSynced: { [weak targetBackend] _, _, date in
                targetBackend?.lastSyncedAt = date
            }
        )
        model = PhotoSyncModel(
            store: libraryStore,
            targetStore: targetStore,
            client: client,
            manifestDirectory: manifestDirectory,
            timeZone: TimeZone(identifier: "Asia/Shanghai")!
        )
    }

    override func tearDownWithError() throws {
        model?.cancelForDisconnect()
        model = nil
        client = nil
        targetBackend = nil
        libraryStore = nil
        try? FileManager.default.removeItem(at: root)
        root = nil
        manifestDirectory = nil
        try super.tearDownWithError()
    }

    func testMarkReviewUploadAndRefresh() async throws {
        model.requestMark(path: "Photos")
        libraryStore.move(to: "Photos")
        XCTAssertTrue(model.isCurrentDirectoryTarget)

        model.beginSync()
        let enteredReview = await waitUntil { self.model.phase == .review }
        XCTAssertTrue(enteredReview)
        XCTAssertEqual(model.plan?.counts.pending, 2)
        XCTAssertTrue(model.isSheetPresented)

        model.startUpload()
        let finished = await waitUntil(timeout: 15) {
            self.model.phase == .summary && self.model.summary != nil
        }
        XCTAssertTrue(finished)
        XCTAssertEqual(model.summary?.successCount, 2)
        XCTAssertEqual(model.failureCount, 0)
        XCTAssertFalse(model.isSheetPresented)

        let photos = root.appendingPathComponent("Photos")
        let names = try FileManager.default.contentsOfDirectory(atPath: photos.path)
            .sorted()
        XCTAssertEqual(
            names,
            [
                "IMG_2001_20260505222609.jpg",
                "IMG_2002_20260506100000.jpg",
            ]
        )

        let refreshed = await waitUntil {
            self.libraryStore.currentEntries.count == 2
        }
        XCTAssertTrue(refreshed)
        XCTAssertEqual(libraryStore.currentEntries.filter { $0.isImage }.count, 2)
        XCTAssertTrue(libraryStore.hasPhotoCalendar)
    }

    func testDeniedAuthorizationShowsAlert() async throws {
        await client.setAuthorizationStatus(.denied)
        model.requestMark(path: "Photos")
        model.beginSync()

        let alerted = await waitUntil { self.model.alert != nil }
        XCTAssertTrue(alerted)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.alert, .authorization)
        XCTAssertFalse(model.isSheetPresented)
    }

    func testReplaceTargetRequiresConfirmation() async throws {
        model.requestMark(path: "Photos")
        XCTAssertEqual(model.target?.path, "Photos")

        model.requestMark(path: "Other")
        XCTAssertTrue(model.isReplaceConfirmationPresented)
        XCTAssertEqual(model.target?.path, "Photos")
        XCTAssertEqual(model.pendingMarkPath, "Other")

        model.confirmReplaceTarget()
        XCTAssertFalse(model.isReplaceConfirmationPresented)
        XCTAssertEqual(model.target?.path, "Other")
    }

    func testRetryFailedOnlyUploadsRemaining() async throws {
        await client.setExportFailures(["m2"])
        model.requestMark(path: "Photos")
        model.beginSync()
        let enteredReview = await waitUntil { self.model.phase == .review }
        XCTAssertTrue(enteredReview)
        model.startUpload()
        let firstFinished = await waitUntil(timeout: 15) {
            self.model.phase == .summary && self.model.summary != nil
        }
        XCTAssertTrue(firstFinished)
        XCTAssertEqual(model.failureCount, 1)
        XCTAssertTrue(model.isSheetPresented)

        await client.clearExportFailures()
        model.retryFailed()
        let retried = await waitUntil(timeout: 15) {
            self.model.phase == .summary
                && self.model.summary?.successCount == 1
                && self.model.failureCount == 0
        }
        XCTAssertTrue(retried)
        XCTAssertEqual(model.summary?.totalCount, 1)
        let snapshot = await manifestSnapshot()
        XCTAssertEqual(snapshot.recordCount, 2)
    }

    func testCancelDuringReviewReturnsIdle() async throws {
        model.requestMark(path: "Photos")
        model.beginSync()
        let enteredReview = await waitUntil { self.model.phase == .review }
        XCTAssertTrue(enteredReview)

        model.cancelSync()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertFalse(model.isSheetPresented)
        XCTAssertNil(model.plan)
    }

    func testAuthorizationAlertIsActionable() {
        let alert = PhotoSyncModel.Alert.authorization
        XCTAssertEqual(alert.title, "需要照片权限")
        XCTAssertTrue(alert.message.contains("系统设置"))
        XCTAssertTrue(alert.showsSettings)
        XCTAssertEqual(PhotoSyncModel.Alert.targetMissing.title, "照片库路径不可用")
        XCTAssertFalse(PhotoSyncModel.Alert.targetMissing.showsSettings)
    }

    private func manifestSnapshot() async -> PhotoSyncManifest {
        let key = PhotoLibraryTargetStore.key(
            host: libraryStore.source.hostName,
            share: libraryStore.source.shareName
        )
        guard let store = try? PhotoSyncManifestStore(
            target: key,
            directory: manifestDirectory
        ) else {
            return PhotoSyncManifest(target: key)
        }
        return await store.snapshot()
    }

    private func waitUntil(
        timeout: TimeInterval = 10,
        _ predicate: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return predicate()
    }
}

@MainActor
private final class InMemoryTargetStore {
    var target: PhotoSyncModel.Target?
    var lastSyncedAt: Date?
}

private actor ModelPhotoClient: PhotoLibraryClient {
    nonisolated let data = Data([0x0A, 0x0B, 0x0C])
    private var status: PhotoLibraryAuthorizationStatus = .authorized
    private var failures: Set<String> = []

    func setAuthorizationStatus(_ status: PhotoLibraryAuthorizationStatus) {
        self.status = status
    }

    func setExportFailures(_ ids: Set<String>) {
        failures = ids
    }

    func clearExportFailures() {
        failures.removeAll()
    }

    func authorizationStatus() async -> PhotoLibraryAuthorizationStatus {
        status
    }

    func requestAuthorization() async -> PhotoLibraryAuthorizationStatus {
        status
    }

    func fetchSkippedVideoCount() async -> Int {
        0
    }

    func fetchImageAssets(
        skippingMetadataFor ids: Set<String>
    ) async throws -> [PhotoAssetDescriptor] {
        [
            descriptor("m1", "IMG_2001.JPG", 2026, 5, 5, 22, 26, 9),
            descriptor("m2", "IMG_2002.JPG", 2026, 5, 6, 10, 0, 0),
        ]
    }

    func exportImage(for assetID: String) async throws -> PhotoExport {
        if failures.contains(assetID) {
            throw PhotoLibraryClientError.exportFailed("fake model export failure")
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
