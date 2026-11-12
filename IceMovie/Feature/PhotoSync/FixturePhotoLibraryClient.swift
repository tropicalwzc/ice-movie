import Foundation
import MediaLibraryKit
import UIKit

/// 自动化与模拟器冒烟用的系统相册替身。
///
/// 只在 `-photoSyncFixture` 启动参数下启用；不申请真实照片权限，也不读写用户相册。
struct FixturePhotoLibraryClient: PhotoLibraryClient {
    private let slow: Bool
    private let failFirst: Bool
    private let denied: Bool

    init(slow: Bool = false, failFirst: Bool = false, denied: Bool = false) {
        self.slow = slow
        self.failFirst = failFirst
        self.denied = denied
    }
    private struct Fixture {
        let id: String
        let filename: String
        let date: Date
        let kind: PhotoContentKind
        let color: UIColor
    }

    private var fixtures: [Fixture] {
        [
            Fixture(
                id: "photo-sync-fixture-1",
                filename: "IMG_9001.JPG",
                date: makeDate(2026, 5, 5, 22, 26, 9),
                kind: .still,
                color: .systemBlue
            ),
            Fixture(
                id: "photo-sync-fixture-2",
                filename: "IMG_9002.PNG",
                date: makeDate(2026, 5, 6, 10, 0, 0),
                kind: .still,
                color: .systemGreen
            ),
            Fixture(
                id: "photo-sync-fixture-3",
                filename: "IMG_9003.HEIC",
                date: makeDate(2026, 5, 7, 11, 30, 0),
                kind: .livePhotoStill,
                color: .systemOrange
            ),
        ]
    }

    func authorizationStatus() async -> PhotoLibraryAuthorizationStatus {
        denied ? .denied : .authorized
    }

    func requestAuthorization() async -> PhotoLibraryAuthorizationStatus {
        denied ? .denied : .authorized
    }

    func fetchSkippedVideoCount() async -> Int {
        1
    }

    func fetchImageAssets(
        skippingMetadataFor ids: Set<String>
    ) async throws -> [PhotoAssetDescriptor] {
        fixtures.map { fixture in
            PhotoAssetDescriptor(
                id: fixture.id,
                creationDate: fixture.date,
                modificationDate: nil,
                originalFilename: fixture.filename,
                uniformTypeIdentifier: "public.jpeg",
                contentKind: fixture.kind,
                isHidden: false
            )
        }
    }

    func exportImage(for assetID: String) async throws -> PhotoExport {
        if slow {
            try? await Task.sleep(for: .milliseconds(700))
        }
        if failFirst, assetID == "photo-sync-fixture-1" {
            throw PhotoLibraryClientError.exportFailed("fixture 模拟导出失败")
        }
        guard let fixture = fixtures.first(where: { $0.id == assetID }) else {
            throw PhotoLibraryClientError.assetNotFound
        }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96))
        let image = renderer.image { context in
            fixture.color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
            UIColor.white.withAlphaComponent(0.85).setFill()
            context.fill(CGRect(x: 12, y: 12, width: 72, height: 72))
        }
        guard let data = image.jpegData(compressionQuality: 0.8) else {
            throw PhotoLibraryClientError.exportFailed("fixture 图片编码失败")
        }
        return PhotoExport(
            still: PhotoResource(
                data: data,
                uniformTypeIdentifier: "public.jpeg",
                originalFilename: fixture.filename
            ),
            motion: nil
        )
    }

    private func makeDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        _ second: Int
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: .current,
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute,
                second: second
            )
        ) ?? Date()
    }
}
