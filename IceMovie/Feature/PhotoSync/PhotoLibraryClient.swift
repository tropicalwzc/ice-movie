import Foundation
import IceCore
import MediaLibraryKit
import Photos

/// 系统相册读取授权。只在用户首次开始同步时请求，不放在启动阶段。
enum PhotoLibraryAuthorization {
    static func currentStatus() -> PhotoLibraryAuthorizationStatus {
        map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    static func request() async -> PhotoLibraryAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: map(status))
            }
        }
    }

    static func map(_ status: PHAuthorizationStatus) -> PhotoLibraryAuthorizationStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        case .limited: .limited
        @unknown default: .denied
        }
    }
}

enum PhotoLibraryClientError: LocalizedError, Sendable {
    case authorizationDenied
    case assetNotFound
    case exportFailed(String)
    case tooLarge(Int64)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            "没有读取系统相册的权限，请在系统设置中允许 IceMovie 访问照片"
        case .assetNotFound:
            "系统相册中找不到这张照片，可能已被删除"
        case .exportFailed(let detail):
            "读取照片失败：\(detail)"
        case .tooLarge(let bytes):
            "照片过大（\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))），已跳过"
        case .cancelled:
            "照片读取已取消"
        }
    }
}

/// 系统相册的最小接口。单元测试与 UI 验收可以注入假实现。
protocol PhotoLibraryClient: Sendable {
    func authorizationStatus() async -> PhotoLibraryAuthorizationStatus
    func requestAuthorization() async -> PhotoLibraryAuthorizationStatus
    func fetchSkippedVideoCount() async -> Int
    func fetchImageAssets(
        skippingMetadataFor ids: Set<String>
    ) async throws -> [PhotoAssetDescriptor]
    func exportImage(for assetID: String) async throws -> PhotoExport
}

extension PhotoLibraryClient {
    func fetchSkippedVideoCount() async -> Int { 0 }
}

/// 真实 PhotoKit 实现。只读取图片；视频只做计数，不进入同步候选。
struct PhotoKitLibraryClient: PhotoLibraryClient {
    static let maxImageBytes: Int64 = 128 * 1024 * 1024
    private let metadataConcurrency = 4

    func authorizationStatus() async -> PhotoLibraryAuthorizationStatus {
        PhotoLibraryAuthorization.currentStatus()
    }

    func requestAuthorization() async -> PhotoLibraryAuthorizationStatus {
        await PhotoLibraryAuthorization.request()
    }

    func fetchSkippedVideoCount() async -> Int {
        guard PhotoLibraryAuthorization.currentStatus().canRead else { return 0 }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d",
            PHAssetMediaType.video.rawValue
        )
        let result = PHAsset.fetchAssets(with: options)
        var count = 0
        result.enumerateObjects { asset, _, _ in
            if !asset.isHidden { count += 1 }
        }
        return count
    }

    func fetchImageAssets(
        skippingMetadataFor ids: Set<String>
    ) async throws -> [PhotoAssetDescriptor] {
        guard PhotoLibraryAuthorization.currentStatus().canRead else {
            throw PhotoLibraryClientError.authorizationDenied
        }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d",
            PHAssetMediaType.image.rawValue
        )
        options.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: false),
        ]
        let fetched = PHAsset.fetchAssets(with: options)

        var boxes: [AssetBox] = []
        boxes.reserveCapacity(fetched.count)
        fetched.enumerateObjects { asset, _, _ in
            guard !asset.isHidden else { return }
            boxes.append(AssetBox(asset: asset))
        }

        return try await withThrowingTaskGroup(
            of: PhotoAssetDescriptor.self
        ) { group in
            var descriptors: [PhotoAssetDescriptor] = []
            descriptors.reserveCapacity(boxes.count)
            var nextIndex = 0

            func addNext() {
                guard nextIndex < boxes.count else { return }
                let box = boxes[nextIndex]
                let skipMetadata = ids.contains(box.asset.localIdentifier)
                nextIndex += 1
                group.addTask {
                    try await Self.descriptor(
                        for: box.asset,
                        skippingMetadata: skipMetadata
                    )
                }
            }

            for _ in 0..<min(metadataConcurrency, boxes.count) {
                addNext()
            }
            while let descriptor = try await group.next() {
                descriptors.append(descriptor)
                addNext()
            }

            let sorted = descriptors.sorted { lhs, rhs in
                let left = lhs.creationDate ?? .distantPast
                let right = rhs.creationDate ?? .distantPast
                if left != right { return left > right }
                return lhs.id < rhs.id
            }
            let newest = sorted.first?.creationDate.map(Self.shortDate) ?? "-"
            let oldest = sorted.last?.creationDate.map(Self.shortDate) ?? "-"
            Log.info(
                .app,
                "系统相册图片 数量=\(sorted.count) 最新=\(newest) 最旧=\(oldest) "
                    + "授权=\(PhotoLibraryAuthorization.currentStatus().rawValue)"
            )
            return sorted
        }
    }

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    func exportImage(for assetID: String) async throws -> PhotoExport {
        guard PhotoLibraryAuthorization.currentStatus().canRead else {
            throw PhotoLibraryClientError.authorizationDenied
        }
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetID],
            options: nil
        ).firstObject else {
            throw PhotoLibraryClientError.assetNotFound
        }

        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        return try await withCheckedThrowingContinuation { continuation in
            let box = ExportContinuationBox(continuation)
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset,
                options: options
            ) { data, uniformTypeIdentifier, _, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                if degraded { return }

                if let data, !data.isEmpty {
                    let bytes = Int64(data.count)
                    guard bytes <= Self.maxImageBytes else {
                        box.resume(.failure(PhotoLibraryClientError.tooLarge(bytes)))
                        return
                    }
                    box.resume(
                        .success(
                            PhotoExport(
                                still: PhotoResource(
                                    data: data,
                                    uniformTypeIdentifier: uniformTypeIdentifier,
                                    originalFilename: nil
                                ),
                                motion: nil
                            )
                        )
                    )
                    return
                }

                if let error = info?[PHImageErrorKey] as? Error {
                    box.resume(
                        .failure(
                            PhotoLibraryClientError.exportFailed(error.localizedDescription)
                        )
                    )
                    return
                }
                if (info?[PHImageCancelledKey] as? Bool) == true {
                    box.resume(.failure(PhotoLibraryClientError.cancelled))
                    return
                }
                box.resume(
                    .failure(
                        PhotoLibraryClientError.exportFailed("系统相册没有返回图片数据")
                    )
                )
            }
        }
    }

    private static func descriptor(
        for asset: PHAsset,
        skippingMetadata: Bool
    ) async throws -> PhotoAssetDescriptor {
        try Task.checkCancellation()
        let isLivePhoto = asset.mediaSubtypes.contains(.photoLive)
        var originalFilename: String?
        var uniformTypeIdentifier: String?

        if !skippingMetadata {
            let resources = PHAssetResource.assetResources(for: asset)
            let resource = resources.first(where: { $0.type == .photo })
                ?? resources.first(where: { $0.type == .fullSizePhoto })
                ?? resources.first
            originalFilename = resource?.originalFilename
            uniformTypeIdentifier = resource?.uniformTypeIdentifier
        }

        return PhotoAssetDescriptor(
            id: asset.localIdentifier,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            originalFilename: originalFilename,
            uniformTypeIdentifier: uniformTypeIdentifier,
            contentKind: isLivePhoto ? .livePhotoStill : .still,
            isHidden: false
        )
    }
}

/// PHAsset 在 TaskGroup 中跨线程传递；PhotoKit 本身是线程安全的。
private struct AssetBox: @unchecked Sendable {
    let asset: PHAsset
}

/// 图片数据回调可能被调用多次；只允许第一次非降级结果恢复 continuation。
private final class ExportContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PhotoExport, Error>?

    init(_ continuation: CheckedContinuation<PhotoExport, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<PhotoExport, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}
