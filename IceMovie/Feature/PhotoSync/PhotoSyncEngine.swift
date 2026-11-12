import Foundation
import IceCore
import MediaLibraryKit
import SMBSession

enum PhotoSyncEngineError: LocalizedError, Sendable {
    case authorizationDenied
    case noTarget

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            "没有读取系统相册的权限"
        case .noTarget:
            "尚未标记照片库路径"
        }
    }
}

struct PhotoSyncProgress: Sendable {
    enum Phase: Sendable {
        case exporting
        case uploading
        case processed
    }

    let phase: Phase
    let fileName: String?
    let processed: Int
    let total: Int
}

struct PhotoSyncUploadResult: Sendable {
    var successCount = 0
    var skippedCount = 0
    var processedCount = 0
    var failures: [PhotoSyncFailure] = []
    var cancelled = false
    var interrupted = false
    var errorMessage: String?
    var uploadedBytes: Int64 = 0
    var elapsed: TimeInterval = 0
}

/// 同步引擎。只负责授权后的扫描与逐张上传；UI 状态由 PhotoSyncModel 持有。
@MainActor
struct PhotoSyncEngine {
    let source: any LibrarySource
    let client: any PhotoLibraryClient
    let targetPath: String
    let timeZone: TimeZone
    let maxConsecutiveUploadFailures: Int

    init(
        source: any LibrarySource,
        client: any PhotoLibraryClient,
        targetPath: String,
        timeZone: TimeZone = .current,
        maxConsecutiveUploadFailures: Int = 3
    ) {
        self.source = source
        self.client = client
        self.targetPath = targetPath
        self.timeZone = timeZone
        self.maxConsecutiveUploadFailures = maxConsecutiveUploadFailures
    }

    func scan(
        manifest: PhotoSyncManifest,
        authorization: PhotoLibraryAuthorizationStatus
    ) async throws -> PhotoSyncPlan {
        guard authorization.canRead else {
            throw PhotoSyncEngineError.authorizationDenied
        }

        let entries = try await source.listDirectory(path: targetPath)
        let remoteIndex = RemotePhotoIndex(entries: entries)
        let knownValidIDs = Set(
            manifest.assets.compactMap { assetID, record -> String? in
                guard !record.remoteFiles.isEmpty else { return nil }
                let allPresent = record.remoteFiles.allSatisfy {
                    remoteIndex.containsRemoteFile(named: $0.name)
                }
                return allPresent ? assetID : nil
            }
        )

        let videoCount = await client.fetchSkippedVideoCount()
        let assets = try await client.fetchImageAssets(
            skippingMetadataFor: knownValidIDs
        )
        try Task.checkCancellation()

        let plan = PhotoSyncPlanner.plan(
            assets: assets,
            remoteIndex: remoteIndex,
            manifest: manifest,
            videoCount: videoCount,
            timeZone: timeZone,
            limitedAccess: authorization.isLimited
        )
        Log.info(
            .app,
            "照片同步扫描完成 目标=\(targetPath.isEmpty ? "/" : Log.shortPath(targetPath)) "
                + "可访问=\(plan.counts.accessible) 动态=\(plan.counts.livePhotos) "
                + "视频=\(plan.counts.videos) 不支持=\(plan.counts.unsupported) "
                + "缺时间=\(plan.counts.missingDate) 远端图片=\(plan.counts.remoteImages) "
                + "已匹配=\(plan.counts.matched) 待同步=\(plan.counts.pending)"
        )
        return plan
    }

    func upload(
        plan: PhotoSyncPlan,
        manifestStore: PhotoSyncManifestStore,
        rateMeter: TransferRateMeter,
        cancellation: PhotoSyncCancellationFlag,
        progress: (PhotoSyncProgress) -> Void
    ) async -> PhotoSyncUploadResult {
        let startedAt = Date()
        let total = plan.candidates.count
        var result = PhotoSyncUploadResult()
        var consecutiveUploadFailures = 0

        Log.info(
            .app,
            "照片同步开始 目标=\(targetPath.isEmpty ? "/" : Log.shortPath(targetPath)) "
                + "待同步=\(total)"
        )

        for candidate in plan.candidates {
            if cancellation.isCancelled || Task.isCancelled {
                result.cancelled = true
                break
            }

            let fileName = candidate.remoteName
            progress(
                PhotoSyncProgress(
                    phase: .exporting,
                    fileName: fileName,
                    processed: result.processedCount,
                    total: total
                )
            )

            let export: PhotoExport
            do {
                export = try await client.exportImage(for: candidate.asset.id)
            } catch is CancellationError {
                result.cancelled = true
                break
            } catch {
                result.failures.append(
                    PhotoSyncFailure(
                        fileName: fileName,
                        reason: error.localizedDescription,
                        category: .export
                    )
                )
                result.processedCount += 1
                progress(
                    PhotoSyncProgress(
                        phase: .processed,
                        fileName: fileName,
                        processed: result.processedCount,
                        total: total
                    )
                )
                Log.error(
                    .app,
                    "照片同步导出失败 \(Log.shortPath(fileName)) \(error.localizedDescription)"
                )
                continue
            }

            if cancellation.isCancelled || Task.isCancelled {
                result.cancelled = true
                break
            }

            let file = UploadFile(
                name: candidate.remoteName,
                data: export.still.data,
                modified: candidate.asset.captureDate,
                role: .still
            )
            let remotePath = targetPath.isEmpty
                ? file.name
                : targetPath + "/" + file.name
            let progressSink = PhotoSyncUploadProgressSink(
                meter: rateMeter,
                baseBytes: result.uploadedBytes
            )

            progress(
                PhotoSyncProgress(
                    phase: .uploading,
                    fileName: file.name,
                    processed: result.processedCount,
                    total: total
                )
            )

            do {
                try await source.createFile(
                    path: remotePath,
                    data: file.data,
                    modified: file.modified,
                    onProgress: { bytes in
                        progressSink.record(bytes)
                        return !cancellation.isCancelled && !Task.isCancelled
                    }
                )

                let record = PhotoSyncManifestRecord(
                    contentKind: candidate.contentKind,
                    remoteFiles: [
                        RemoteFile(
                            name: file.name,
                            role: .still,
                            size: Int64(file.data.count)
                        ),
                    ],
                    syncedAt: Date()
                )
                do {
                    try await manifestStore.record(
                        assetID: candidate.asset.id,
                        record: record
                    )
                } catch {
                    Log.error(
                        .app,
                        "照片同步清单写入失败 \(Log.shortPath(file.name)) \(error.localizedDescription)"
                    )
                }

                result.successCount += 1
                result.uploadedBytes += Int64(file.data.count)
                consecutiveUploadFailures = 0
            } catch is CancellationError {
                result.cancelled = true
                break
            } catch LibrarySourceError.fileExists {
                result.skippedCount += 1
                Log.notice(
                    .app,
                    "照片同步跳过已存在文件 \(Log.shortPath(remotePath))"
                )
            } catch {
                if cancellation.isCancelled || Task.isCancelled {
                    result.cancelled = true
                    break
                }
                let category = Self.failureCategory(for: error)
                result.failures.append(
                    PhotoSyncFailure(
                        fileName: file.name,
                        reason: error.localizedDescription,
                        category: category
                    )
                )
                consecutiveUploadFailures += 1
                Log.error(
                    .app,
                    "照片同步上传失败 \(Log.shortPath(remotePath)) \(error.localizedDescription)"
                )

                if Self.isFatal(error)
                    || consecutiveUploadFailures >= maxConsecutiveUploadFailures {
                    result.interrupted = true
                    result.errorMessage = Self.interruptionMessage(for: error)
                    result.processedCount += 1
                    progress(
                        PhotoSyncProgress(
                            phase: .processed,
                            fileName: file.name,
                            processed: result.processedCount,
                            total: total
                        )
                    )
                    break
                }
            }

            result.processedCount += 1
            progress(
                PhotoSyncProgress(
                    phase: .processed,
                    fileName: file.name,
                    processed: result.processedCount,
                    total: total
                )
            )
        }

        do {
            try await manifestStore.flush()
        } catch {
            Log.error(.app, "照片同步清单收尾写入失败 \(error.localizedDescription)")
        }

        result.elapsed = Date().timeIntervalSince(startedAt)
        Log.info(
            .app,
            "照片同步结束 成功=\(result.successCount) 失败=\(result.failures.count) "
                + "跳过=\(result.skippedCount) 处理=\(result.processedCount)/\(total) "
                + "取消=\(result.cancelled) 中断=\(result.interrupted) "
                + "耗时=\(String(format: "%.1f", result.elapsed))s"
        )
        return result
    }

    private static func failureCategory(for error: any Error) -> PhotoSyncFailureCategory {
        if error is PhotoLibraryClientError {
            return .export
        }
        if let sourceError = error as? LibrarySourceError {
            switch sourceError {
            case .unsupportedWrite:
                return .targetUnavailable
            case .writeFailed, .fileExists:
                return .upload
            case .unsupportedShareSwitch:
                return .unknown
            }
        }
        if let smbError = error as? SMBConnectionError {
            switch smbError {
            case .authenticationFailed, .nameNotResolved, .invalidAddress, .notConnected:
                return .targetUnavailable
            default:
                return .upload
            }
        }
        return .unknown
    }

    private static func isFatal(_ error: any Error) -> Bool {
        if let sourceError = error as? LibrarySourceError {
            switch sourceError {
            case .unsupportedWrite:
                return true
            case .writeFailed, .fileExists, .unsupportedShareSwitch:
                return false
            }
        }
        if let smbError = error as? SMBConnectionError {
            switch smbError {
            case .authenticationFailed, .invalidAddress, .nameNotResolved:
                return true
            default:
                return false
            }
        }
        return false
    }

    private static func interruptionMessage(for error: any Error) -> String {
        if let sourceError = error as? LibrarySourceError {
            switch sourceError {
            case .unsupportedWrite:
                return "目标不支持写入，请检查 SMB 权限"
            case .writeFailed(let detail):
                return "目标目录不可写：\(detail)"
            default:
                break
            }
        }
        if let smbError = error as? SMBConnectionError {
            return smbError.localizedDescription
        }
        return error.localizedDescription
    }
}

private final class PhotoSyncUploadProgressSink: @unchecked Sendable {
    private let meter: TransferRateMeter
    private let baseBytes: Int64

    init(meter: TransferRateMeter, baseBytes: Int64) {
        self.meter = meter
        self.baseBytes = baseBytes
    }

    func record(_ bytes: Int64) {
        meter.record(totalBytes: baseBytes + bytes)
    }
}
