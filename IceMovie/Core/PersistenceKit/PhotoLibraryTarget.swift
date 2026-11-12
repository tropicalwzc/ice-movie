import Foundation
import IceCore
import SwiftData

/// 每个 `host + share` 唯一的照片库目标目录。
@Model
public final class PhotoLibraryTarget {
    @Attribute(.unique) public var key: String
    public var host: String
    public var share: String
    public var path: String
    public var createdAt: Date
    public var updatedAt: Date
    public var lastSyncedAt: Date?

    public init(
        key: String,
        host: String,
        share: String,
        path: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastSyncedAt: Date? = nil
    ) {
        self.key = key
        self.host = host
        self.share = share
        self.path = path
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastSyncedAt = lastSyncedAt
    }

    public var displayPath: String {
        path.isEmpty ? "/" : path
    }
}

/// SwiftData 照片库目标读写。每个共享只保留一个目标，标记新目录即替换旧路径。
@MainActor
public final class PhotoLibraryTargetStore {
    private let context: ModelContext
    private let now: () -> Date

    public init(context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.now = now
    }

    public static func key(host: String, share: String) -> String {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedShare = share.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(normalizedHost)|\(normalizedShare)"
    }

    public func target(host: String, share: String) -> PhotoLibraryTarget? {
        try? find(key: Self.key(host: host, share: share))
    }

    @discardableResult
    public func mark(host: String, share: String, path: String) throws -> PhotoLibraryTarget {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedShare = share.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = path.trimmingCharacters(
            in: CharacterSet(charactersIn: "/ ")
        )
        let key = Self.key(host: normalizedHost, share: normalizedShare)
        let timestamp = now()

        let record: PhotoLibraryTarget
        if let existing = try find(key: key) {
            existing.host = normalizedHost
            existing.share = normalizedShare
            existing.path = normalizedPath
            existing.updatedAt = timestamp
            record = existing
        } else {
            record = PhotoLibraryTarget(
                key: key,
                host: normalizedHost,
                share: normalizedShare,
                path: normalizedPath,
                createdAt: timestamp,
                updatedAt: timestamp
            )
            context.insert(record)
        }
        try context.save()
        Log.info(
            .app,
            "照片库目标已保存 host=\(normalizedHost) share=\(normalizedShare) "
                + "路径=\(normalizedPath.isEmpty ? "/" : Log.shortPath(normalizedPath))"
        )
        return record
    }

    public func markSynced(host: String, share: String, at date: Date = Date()) {
        guard let record = target(host: host, share: share) else { return }
        record.lastSyncedAt = date
        record.updatedAt = date
        try? context.save()
    }

    public func unmark(host: String, share: String) throws {
        let key = Self.key(host: host, share: share)
        guard let record = try find(key: key) else { return }
        context.delete(record)
        try context.save()
        Log.info(.app, "照片库目标已移除 host=\(host) share=\(share)")
    }

    public func all() -> [PhotoLibraryTarget] {
        let descriptor = FetchDescriptor<PhotoLibraryTarget>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    public func removeAll() throws {
        for record in all() {
            context.delete(record)
        }
        try context.save()
    }

    private func find(key: String) throws -> PhotoLibraryTarget? {
        var descriptor = FetchDescriptor<PhotoLibraryTarget>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
