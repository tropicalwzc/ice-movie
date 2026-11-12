import Foundation

/// 一张系统相册资产在同步链路中的内容类型。
///
/// v1 只产出 `.still` 与 `.livePhotoStill`；`.livePhoto` 与 `.animated`
/// 是给后续动态图扩展预留的值，当前同步引擎不会生成。
public enum PhotoContentKind: String, Codable, Sendable, Equatable, CaseIterable {
    case still
    case livePhotoStill
    case livePhoto
    case animated

    public var isLivePhoto: Bool {
        self == .livePhotoStill || self == .livePhoto
    }

    public var displayName: String {
        switch self {
        case .still: "静态照片"
        case .livePhotoStill: "Live Photo（静态图）"
        case .livePhoto: "Live Photo"
        case .animated: "动态图"
        }
    }
}

/// 一个远端文件在同步记录中的角色。
public enum RemoteFileRole: String, Codable, Sendable, Equatable {
    case still
    case motion
}

/// 已上传到 SMB 的一个文件。
public struct RemoteFile: Codable, Sendable, Equatable, Identifiable {
    public let name: String
    public let role: RemoteFileRole
    public let size: Int64

    public var id: String { "\(role.rawValue)|\(name)" }

    public init(name: String, role: RemoteFileRole, size: Int64) {
        self.name = name
        self.role = role
        self.size = size
    }
}

/// 待写入 SMB 的一个文件。v1 每个资产只有一个 still 文件；
/// 未来 Live Photo 可以产出 `.livp` 或 HEIC+MOV 两项。
public struct UploadFile: Sendable, Equatable {
    public let name: String
    public let data: Data
    public let modified: Date?
    public let role: RemoteFileRole

    public init(name: String, data: Data, modified: Date?, role: RemoteFileRole = .still) {
        self.name = name
        self.data = data
        self.modified = modified
        self.role = role
    }
}

/// 从系统相册导出的原始数据。
public struct PhotoResource: Sendable, Equatable {
    public let data: Data
    public let uniformTypeIdentifier: String?
    public let originalFilename: String?

    public init(data: Data, uniformTypeIdentifier: String?, originalFilename: String?) {
        self.data = data
        self.uniformTypeIdentifier = uniformTypeIdentifier
        self.originalFilename = originalFilename
    }
}

/// 一次资产导出的结果。v1 只填 `still`；`motion` 是后续动态图扩展口。
public struct PhotoExport: Sendable, Equatable {
    public let still: PhotoResource
    public let motion: PhotoResource?

    public init(still: PhotoResource, motion: PhotoResource?) {
        self.still = still
        self.motion = motion
    }
}

/// PhotoKit 资产的轻量描述。已知资产可以不读取资源元数据，
/// 因此 `originalFilename` / `uniformTypeIdentifier` 允许为 nil。
public struct PhotoAssetDescriptor: Sendable, Equatable, Identifiable {
    public let id: String
    public let creationDate: Date?
    public let modificationDate: Date?
    public let originalFilename: String?
    public let uniformTypeIdentifier: String?
    public let contentKind: PhotoContentKind
    public let isHidden: Bool

    public var captureDate: Date? {
        creationDate ?? modificationDate
    }

    public init(
        id: String,
        creationDate: Date?,
        modificationDate: Date?,
        originalFilename: String?,
        uniformTypeIdentifier: String?,
        contentKind: PhotoContentKind,
        isHidden: Bool = false
    ) {
        self.id = id
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.originalFilename = originalFilename
        self.uniformTypeIdentifier = uniformTypeIdentifier
        self.contentKind = contentKind
        self.isHidden = isHidden
    }
}

/// 计划上传的一张照片。
public struct PhotoSyncCandidate: Sendable, Equatable, Identifiable {
    public let asset: PhotoAssetDescriptor
    public let remoteName: String
    public let contentKind: PhotoContentKind

    public var id: String { asset.id }

    public init(asset: PhotoAssetDescriptor, remoteName: String, contentKind: PhotoContentKind) {
        self.asset = asset
        self.remoteName = remoteName
        self.contentKind = contentKind
    }
}

/// 预览页展示的计数。
public struct PhotoSyncCounts: Sendable, Equatable {
    public var accessible: Int
    public var livePhotos: Int
    public var videos: Int
    public var unsupported: Int
    public var missingDate: Int
    public var missingMetadata: Int
    public var remoteImages: Int
    public var matched: Int
    public var pending: Int
    public var limitedAccess: Bool
    public var latestCaptureDate: Date?
    public var oldestCaptureDate: Date?

    public var skipped: Int {
        videos + unsupported + missingDate + missingMetadata + matched
    }

    public init(
        accessible: Int = 0,
        livePhotos: Int = 0,
        videos: Int = 0,
        unsupported: Int = 0,
        missingDate: Int = 0,
        missingMetadata: Int = 0,
        remoteImages: Int = 0,
        matched: Int = 0,
        pending: Int = 0,
        limitedAccess: Bool = false,
        latestCaptureDate: Date? = nil,
        oldestCaptureDate: Date? = nil
    ) {
        self.accessible = accessible
        self.livePhotos = livePhotos
        self.videos = videos
        self.unsupported = unsupported
        self.missingDate = missingDate
        self.missingMetadata = missingMetadata
        self.remoteImages = remoteImages
        self.matched = matched
        self.pending = pending
        self.limitedAccess = limitedAccess
        self.latestCaptureDate = latestCaptureDate
        self.oldestCaptureDate = oldestCaptureDate
    }
}

/// 只读扫描的结果。确认前不会写任何文件。
public struct PhotoSyncPlan: Sendable, Equatable {
    public var counts: PhotoSyncCounts
    public var candidates: [PhotoSyncCandidate]

    public init(counts: PhotoSyncCounts, candidates: [PhotoSyncCandidate]) {
        self.counts = counts
        self.candidates = candidates
    }
}

/// 单张照片失败的原因分类。
public enum PhotoSyncFailureCategory: String, Sendable, Equatable {
    case authorization
    case export
    case upload
    case targetUnavailable
    case unsupported
    case unknown
}

public struct PhotoSyncFailure: Sendable, Equatable, Identifiable {
    public let id: String
    public let fileName: String
    public let reason: String
    public let category: PhotoSyncFailureCategory

    public init(
        id: String = UUID().uuidString,
        fileName: String,
        reason: String,
        category: PhotoSyncFailureCategory
    ) {
        self.id = id
        self.fileName = fileName
        self.reason = reason
        self.category = category
    }
}

/// 同步结束后的汇总。
public struct PhotoSyncSummary: Sendable, Equatable {
    public var successCount: Int
    public var processedCount: Int
    public var totalCount: Int
    public var skippedCount: Int
    public var elapsed: TimeInterval
    public var averageBytesPerSecond: Double
    public var uploadedBytes: Int64
    public var failures: [PhotoSyncFailure]
    public var cancelled: Bool
    public var interrupted: Bool
    public var errorMessage: String?

    public var failureCount: Int { failures.count }
    public var remainingCount: Int { max(0, totalCount - processedCount) }

    public init(
        successCount: Int = 0,
        processedCount: Int = 0,
        totalCount: Int = 0,
        skippedCount: Int = 0,
        elapsed: TimeInterval = 0,
        averageBytesPerSecond: Double = 0,
        uploadedBytes: Int64 = 0,
        failures: [PhotoSyncFailure] = [],
        cancelled: Bool = false,
        interrupted: Bool = false,
        errorMessage: String? = nil
    ) {
        self.successCount = successCount
        self.processedCount = processedCount
        self.totalCount = totalCount
        self.skippedCount = skippedCount
        self.elapsed = elapsed
        self.averageBytesPerSecond = averageBytesPerSecond
        self.uploadedBytes = uploadedBytes
        self.failures = failures
        self.cancelled = cancelled
        self.interrupted = interrupted
        self.errorMessage = errorMessage
    }
}

/// 系统相册读取授权的稳定状态，供 UI 与测试使用。
public enum PhotoLibraryAuthorizationStatus: String, Sendable, Equatable, Codable, CaseIterable {
    case notDetermined
    case denied
    case restricted
    case limited
    case authorized

    public var canRead: Bool {
        self == .authorized || self == .limited
    }

    public var isLimited: Bool {
        self == .limited
    }

    public var needsSettings: Bool {
        self == .denied || self == .restricted
    }

    public var displayText: String {
        switch self {
        case .notDetermined: "尚未授权"
        case .denied: "照片权限已拒绝"
        case .restricted: "照片权限受限"
        case .limited: "有限照片权限"
        case .authorized: "全部照片权限"
        }
    }
}

/// 可跨线程检查的取消标记。SMB 写入进度回调在后台线程执行。
public final class PhotoSyncCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public func reset() {
        lock.lock()
        cancelled = false
        lock.unlock()
    }
}
