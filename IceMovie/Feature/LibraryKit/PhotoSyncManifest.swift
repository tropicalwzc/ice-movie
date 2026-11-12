import CryptoKit
import Foundation

/// 单个照片库目标的本地同步记录。
public struct PhotoSyncManifest: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var target: String
    public var assets: [String: PhotoSyncManifestRecord]

    public init(
        target: String,
        version: Int = PhotoSyncManifest.currentVersion,
        assets: [String: PhotoSyncManifestRecord] = [:]
    ) {
        self.target = target
        self.version = version
        self.assets = assets
    }

    public var recordCount: Int { assets.count }

    public func record(for assetID: String) -> PhotoSyncManifestRecord? {
        assets[assetID]
    }

    public mutating func setRecord(_ record: PhotoSyncManifestRecord, for assetID: String) {
        assets[assetID] = record
    }
}

public struct PhotoSyncManifestRecord: Codable, Sendable, Equatable {
    public var contentKind: PhotoContentKind
    public var remoteFiles: [RemoteFile]
    public var syncedAt: Date

    public init(
        contentKind: PhotoContentKind,
        remoteFiles: [RemoteFile],
        syncedAt: Date
    ) {
        self.contentKind = contentKind
        self.remoteFiles = remoteFiles
        self.syncedAt = syncedAt
    }
}

/// 按目标隔离的 JSON 清单。整表加载、批量原子写，适合数千条照片记录。
public actor PhotoSyncManifestStore {
    public let fileURL: URL
    private let batchSize: Int
    private var manifest: PhotoSyncManifest
    private var pendingWrites = 0
    private var loadWarning: String?

    public init(
        target: String,
        directory: URL? = nil,
        batchSize: Int = 20
    ) throws {
        let base = try directory ?? Self.defaultDirectory()
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )
        self.fileURL = base.appendingPathComponent(
            "manifest-\(Self.hash(target)).json",
            isDirectory: false
        )
        self.batchSize = max(1, batchSize)
        self.manifest = PhotoSyncManifest(target: target)

        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(PhotoSyncManifest.self, from: data)
            guard decoded.version == PhotoSyncManifest.currentVersion else {
                loadWarning = "清单版本 \(decoded.version) 与当前版本不一致，已重建"
                return
            }
            guard decoded.target == target else {
                loadWarning = "清单目标不匹配，已重建"
                return
            }
            manifest = decoded
        } catch {
            loadWarning = "清单读取失败，已重建：\(error.localizedDescription)"
        }
    }

    public func snapshot() -> PhotoSyncManifest {
        manifest
    }

    public func warning() -> String? {
        loadWarning
    }

    public func record(
        assetID: String,
        record: PhotoSyncManifestRecord
    ) throws {
        manifest.setRecord(record, for: assetID)
        pendingWrites += 1
        if pendingWrites >= batchSize {
            try save()
        }
    }

    public func flush() throws {
        guard pendingWrites > 0 else { return }
        try save()
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: fileURL, options: .atomic)
        pendingWrites = 0
    }

    private static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("PhotoSync", isDirectory: true)
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
