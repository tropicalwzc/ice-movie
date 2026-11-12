import Foundation

/// 纯逻辑增量计划：把系统相册资产、远端文件名索引与本地清单合成待上传列表。
public enum PhotoSyncPlanner {
    public static func plan(
        assets: [PhotoAssetDescriptor],
        remoteIndex: RemotePhotoIndex,
        manifest: PhotoSyncManifest,
        videoCount: Int = 0,
        timeZone: TimeZone = .current,
        limitedAccess: Bool = false
    ) -> PhotoSyncPlan {
        let visible = assets.filter { !$0.isHidden }
        var counts = PhotoSyncCounts(
            accessible: visible.count,
            livePhotos: visible.filter { $0.contentKind.isLivePhoto }.count,
            videos: videoCount,
            remoteImages: remoteIndex.imageCount,
            limitedAccess: limitedAccess
        )
        let captureDates = visible.compactMap(\.captureDate)
        counts.latestCaptureDate = captureDates.max()
        counts.oldestCaptureDate = captureDates.min()

        var ownerByRemoteName: [String: String] = [:]
        for (assetID, record) in manifest.assets {
            for file in record.remoteFiles {
                ownerByRemoteName[file.name.lowercased()] = assetID
            }
        }

        var usedNames = remoteIndex.exactNames
        var candidates: [PhotoSyncCandidate] = []

        let sorted = visible.sorted { lhs, rhs in
            let left = lhs.captureDate ?? .distantPast
            let right = rhs.captureDate ?? .distantPast
            if left != right { return left > right }
            return lhs.id < rhs.id
        }

        for asset in sorted {
            // 本地记录有效且远端文件仍在：直接跳过，不再读取资源元数据。
            if let record = manifest.assets[asset.id],
               !record.remoteFiles.isEmpty,
               record.remoteFiles.allSatisfy({
                   remoteIndex.containsRemoteFile(named: $0.name)
               }) {
                counts.matched += 1
                continue
            }

            guard let captureDate = asset.captureDate else {
                counts.missingDate += 1
                continue
            }
            guard let originalFilename = asset.originalFilename, !originalFilename.isEmpty else {
                counts.missingMetadata += 1
                continue
            }
            guard PhotoFileName.resolvedExtension(
                originalFilename: originalFilename,
                uniformTypeIdentifier: asset.uniformTypeIdentifier
            ) != nil else {
                counts.unsupported += 1
                continue
            }

            let timestamp = PhotoFileName.timestampString(
                for: captureDate,
                timeZone: timeZone
            )
            let base = PhotoFileName.sanitizedBase(
                PhotoFileName.baseName(from: originalFilename)
            )

            if remoteIndex.matches(base: base, timestamp: timestamp) {
                counts.matched += 1
                continue
            }

            guard let remoteName = assignName(
                originalFilename: originalFilename,
                captureDate: captureDate,
                uniformTypeIdentifier: asset.uniformTypeIdentifier,
                assetID: asset.id,
                usedNames: &usedNames,
                ownerByRemoteName: &ownerByRemoteName,
                timeZone: timeZone
            ) else {
                counts.missingMetadata += 1
                continue
            }

            candidates.append(
                PhotoSyncCandidate(
                    asset: asset,
                    remoteName: remoteName,
                    contentKind: asset.contentKind
                )
            )
        }

        counts.pending = candidates.count
        return PhotoSyncPlan(counts: counts, candidates: candidates)
    }

    private static func assignName(
        originalFilename: String,
        captureDate: Date,
        uniformTypeIdentifier: String?,
        assetID: String,
        usedNames: inout Set<String>,
        ownerByRemoteName: inout [String: String],
        timeZone: TimeZone
    ) -> String? {
        guard let ext = PhotoFileName.resolvedExtension(
            originalFilename: originalFilename,
            uniformTypeIdentifier: uniformTypeIdentifier
        ) else {
            return nil
        }

        for index in 0..<1000 {
            let name = PhotoFileName.fileName(
                originalFilename: originalFilename,
                captureDate: captureDate,
                fileExtension: ext,
                collisionIndex: index,
                timeZone: timeZone
            )
            let lower = name.lowercased()
            if usedNames.contains(lower) {
                if ownerByRemoteName[lower] == assetID {
                    return name
                }
                continue
            }
            usedNames.insert(lower)
            ownerByRemoteName[lower] = assetID
            return name
        }
        return nil
    }
}
