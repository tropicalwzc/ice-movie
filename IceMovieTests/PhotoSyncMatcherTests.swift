import MediaLibraryKit
import XCTest

final class PhotoSyncMatcherTests: XCTestCase {
    private let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    func testMatchesExactAndPrefixedLegacyNames() {
        let index = makeIndex([
            "IMG_9399_20260505222609.jpg",
            "2025-02-16 210732IMG_1241_20180526143955.livp",
            "other_20260505222609.jpg",
            ".hidden_20260505222609.jpg",
            "temp.icemovie-tmp-ABC.jpg",
        ])

        XCTAssertTrue(index.matches(base: "IMG_9399", timestamp: "20260505222609"))
        XCTAssertTrue(index.matches(base: "img_1241", timestamp: "20180526143955"))
        XCTAssertFalse(index.matches(base: "IMG_1241", timestamp: "20260505222609"))
        XCTAssertFalse(index.matches(base: "IMG_0001", timestamp: "20260505222609"))
        XCTAssertEqual(index.imageCount, 3)
    }

    func testShortBaseOnlyMatchesExactly() {
        let index = makeIndex(["IMG_123_20260505222609.jpg"])
        XCTAssertFalse(index.matches(base: "IMG_12", timestamp: "20260505222609"))
        XCTAssertTrue(index.matches(base: "IMG_123", timestamp: "20260505222609"))
    }

    func testRemoteFileLookupIsCaseInsensitiveAndIgnoresTemporaryFiles() {
        let index = makeIndex([
            "IMG_9399_20260505222609.JPG",
            "IMG_0001_20260505222609.jpg.icemovie-tmp-123",
        ])
        XCTAssertTrue(
            index.containsRemoteFile(named: "img_9399_20260505222609.jpg")
        )
        XCTAssertFalse(
            index.containsRemoteFile(named: "IMG_0001_20260505222609.jpg.icemovie-tmp-123")
        )
    }

    func testPlannerCountsAndLivePhotoStill() {
        let remote = makeIndex([
            "IMG_9399_20260505222609.jpg",
            "2025-02-16 210732IMG_1241_20180526143955.livp",
            "IMG_7777_20240101000000.jpg",
        ])
        let manifest = PhotoSyncManifest(
            target: "nas|photos",
            assets: [
                "asset-7": PhotoSyncManifestRecord(
                    contentKind: .still,
                    remoteFiles: [
                        RemoteFile(
                            name: "IMG_7777_20240101000000.jpg",
                            role: .still,
                            size: 1
                        ),
                    ],
                    syncedAt: Date()
                ),
                "asset-8": PhotoSyncManifestRecord(
                    contentKind: .still,
                    remoteFiles: [
                        RemoteFile(
                            name: "IMG_8888_20240101000000.jpg",
                            role: .still,
                            size: 1
                        ),
                    ],
                    syncedAt: Date()
                ),
            ]
        )

        let assets = [
            asset("a1", "IMG_9399.HEIC", date(2026, 5, 5, 22, 26, 9), "public.heic"),
            asset("a2", "IMG_1241.JPG", date(2018, 5, 26, 14, 39, 55), "public.jpeg"),
            asset("a3", "IMG_0002.HEIC", date(2024, 1, 1, 0, 0, 0), "public.heic"),
            asset("a4", "IMG_0003.GIF", date(2024, 1, 1, 0, 0, 0), "com.compuserve.gif"),
            asset("a5", "IMG_0004.HEIC", date(2024, 1, 1, 0, 0, 0), "public.heic", hidden: true),
            asset("a6", "IMG_0005.HEIC", nil, "public.heic"),
            asset("a7", "IMG_7777.HEIC", date(2024, 1, 1, 0, 0, 0), "public.heic"),
            asset("a8", "IMG_8888.HEIC", date(2024, 1, 1, 0, 0, 0), "public.heic"),
            asset(
                "a9",
                "IMG_0006.HEIC",
                date(2024, 2, 2, 1, 2, 3),
                "public.heic",
                kind: .livePhotoStill
            ),
        ]

        let plan = PhotoSyncPlanner.plan(
            assets: assets,
            remoteIndex: remote,
            manifest: manifest,
            videoCount: 2,
            timeZone: timeZone
        )

        XCTAssertEqual(plan.counts.accessible, 8)
        XCTAssertEqual(plan.counts.livePhotos, 1)
        XCTAssertEqual(plan.counts.videos, 2)
        XCTAssertEqual(plan.counts.unsupported, 1)
        XCTAssertEqual(plan.counts.missingDate, 1)
        XCTAssertEqual(plan.counts.matched, 3)
        XCTAssertEqual(plan.counts.remoteImages, 3)
        XCTAssertEqual(plan.counts.pending, 3)
        XCTAssertEqual(plan.candidates.map(\.asset.id), ["a9", "a3", "a8"])
        XCTAssertEqual(
            plan.candidates.first(where: { $0.asset.id == "a9" })?.contentKind,
            .livePhotoStill
        )
        XCTAssertEqual(
            plan.candidates.first(where: { $0.asset.id == "a3" })?.remoteName,
            "IMG_0002_20240101000000.heic"
        )
    }

    func testPlannerAssignsStableCollisionSuffix() {
        let date = date(2026, 5, 5, 22, 26, 9)
        let assets = [
            asset("b", "IMG_0001.HEIC", date, "public.heic"),
            asset("a", "IMG_0001.HEIC", date, "public.heic"),
        ]
        let plan = PhotoSyncPlanner.plan(
            assets: assets,
            remoteIndex: makeIndex([]),
            manifest: PhotoSyncManifest(target: "nas|photos"),
            timeZone: timeZone
        )
        XCTAssertEqual(
            plan.candidates.map(\.remoteName),
            ["IMG_0001_20260505222609.heic", "IMG_0001_2_20260505222609.heic"]
        )
    }

    func testPlannerReuploadsWhenManifestRemoteFileIsGone() {
        let manifest = PhotoSyncManifest(
            target: "nas|photos",
            assets: [
                "gone": PhotoSyncManifestRecord(
                    contentKind: .still,
                    remoteFiles: [
                        RemoteFile(name: "IMG_0001_20240101000000.jpg", role: .still, size: 1),
                    ],
                    syncedAt: Date()
                ),
            ]
        )
        let plan = PhotoSyncPlanner.plan(
            assets: [asset("gone", "IMG_0001.HEIC", date(2024, 1, 1, 0, 0, 0), "public.heic")],
            remoteIndex: makeIndex([]),
            manifest: manifest,
            timeZone: timeZone
        )
        XCTAssertEqual(plan.candidates.count, 1)
        XCTAssertEqual(plan.candidates[0].asset.id, "gone")
    }

    private func asset(
        _ id: String,
        _ filename: String,
        _ date: Date?,
        _ uti: String?,
        hidden: Bool = false,
        kind: PhotoContentKind = .still
    ) -> PhotoAssetDescriptor {
        PhotoAssetDescriptor(
            id: id,
            creationDate: date,
            modificationDate: nil,
            originalFilename: filename,
            uniformTypeIdentifier: uti,
            contentKind: kind,
            isHidden: hidden
        )
    }

    private func makeIndex(_ names: [String]) -> RemotePhotoIndex {
        RemotePhotoIndex(
            entries: names.map {
                MediaEntry(
                    path: $0,
                    name: $0,
                    isDirectory: false,
                    size: 1,
                    modified: nil
                )
            }
        )
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        _ second: Int
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: timeZone,
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute,
                second: second
            )
        )!
    }
}
