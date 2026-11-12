import Foundation
import IceCore
import MediaLibraryKit
import XCTest
@testable import IceMovie

@MainActor
final class PhotoSyncPerformanceTests: XCTestCase {
    func testHundredPhotoLocalBatchCompletesWithinBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "photo-sync-perf-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let manifestDirectory = root.appendingPathComponent("Manifest", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Photos", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: manifestDirectory,
            withIntermediateDirectories: true
        )

        let client = HundredPhotoClient(count: 100)
        let engine = PhotoSyncEngine(
            source: LocalLibrarySource(rootURL: root),
            client: client,
            targetPath: "Photos",
            timeZone: TimeZone(identifier: "Asia/Shanghai")!
        )
        let store = try PhotoSyncManifestStore(
            target: "local|photos-perf",
            directory: manifestDirectory
        )
        let plan = try await engine.scan(
            manifest: PhotoSyncManifest(target: "local|photos-perf"),
            authorization: .authorized
        )
        XCTAssertEqual(plan.candidates.count, 100)

        MemoryFootprint.resetPeak()
        let started = Date()
        let result = await engine.upload(
            plan: plan,
            manifestStore: store,
            rateMeter: TransferRateMeter(),
            cancellation: PhotoSyncCancellationFlag(),
            progress: { _ in }
        )
        let elapsed = Date().timeIntervalSince(started)
        _ = MemoryFootprint.currentMB

        XCTAssertEqual(result.successCount, 100)
        XCTAssertEqual(result.failures.count, 0)
        XCTAssertLessThan(elapsed, 20, "100 张本地小图应快速完成")
        XCTAssertLessThan(MemoryFootprint.peakMB, 1024, "批量同步不应造成异常内存峰值")
        let names = try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("Photos").path
        )
        XCTAssertEqual(names.count, 100)
        print(
            "PHOTO_SYNC_PERF 100张 耗时=\(String(format: "%.3f", elapsed))s "
                + "峰值=\(MemoryFootprint.peakMB)MB"
        )
    }

    func testPlannerHandlesThousandsOfAssetsWithinBudget() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyyMMddHHmmss"
        let base = formatter.date(from: "20200101000000")!

        let assets = (0..<5_000).map { index in
            PhotoAssetDescriptor(
                id: "asset-\(index)",
                creationDate: base.addingTimeInterval(Double(index)),
                modificationDate: nil,
                originalFilename: "IMG_\(String(format: "%05d", index)).JPG",
                uniformTypeIdentifier: "public.jpeg",
                contentKind: .still,
                isHidden: false
            )
        }

        let started = Date()
        let plan = PhotoSyncPlanner.plan(
            assets: assets,
            remoteIndex: RemotePhotoIndex(entries: []),
            manifest: PhotoSyncManifest(target: "local|photos-perf"),
            videoCount: 12,
            timeZone: TimeZone(identifier: "Asia/Shanghai")!
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(plan.counts.accessible, 5_000)
        XCTAssertEqual(plan.counts.pending, 5_000)
        XCTAssertLessThan(elapsed, 5, "5000 张规划应保持在秒级")
        print(
            "PHOTO_SYNC_PERF 5000张规划 耗时=\(String(format: "%.3f", elapsed))s"
        )
    }
}

private actor HundredPhotoClient: PhotoLibraryClient {
    nonisolated let data = Data(repeating: 0x5A, count: 1024)
    private let count: Int

    init(count: Int) {
        self.count = count
    }

    func authorizationStatus() async -> PhotoLibraryAuthorizationStatus {
        .authorized
    }

    func requestAuthorization() async -> PhotoLibraryAuthorizationStatus {
        .authorized
    }

    func fetchSkippedVideoCount() async -> Int { 0 }

    func fetchImageAssets(
        skippingMetadataFor ids: Set<String>
    ) async throws -> [PhotoAssetDescriptor] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let base = calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: 2020,
                month: 1,
                day: 1
            )
        ) ?? Date()

        return (0..<count).map { index in
            PhotoAssetDescriptor(
                id: "perf-\(index)",
                creationDate: base.addingTimeInterval(Double(index)),
                modificationDate: nil,
                originalFilename: "IMG_\(String(format: "%05d", index)).JPG",
                uniformTypeIdentifier: "public.jpeg",
                contentKind: .still,
                isHidden: false
            )
        }
    }

    func exportImage(for assetID: String) async throws -> PhotoExport {
        PhotoExport(
            still: PhotoResource(
                data: data,
                uniformTypeIdentifier: "public.jpeg",
                originalFilename: nil
            ),
            motion: nil
        )
    }
}
