import Foundation
import IceCore
import SwiftData

/// 一条收藏照片记录。按 host + share + path 唯一，只存本机。
@Model
public final class FavoritePhoto {
    @Attribute(.unique) public var key: String
    public var host: String
    public var share: String
    public var path: String
    public var name: String
    public var size: Int64
    public var modified: Date?
    public var favoritedAt: Date

    public init(
        key: String,
        host: String,
        share: String,
        path: String,
        name: String,
        size: Int64,
        modified: Date?,
        favoritedAt: Date = Date()
    ) {
        self.key = key
        self.host = host
        self.share = share
        self.path = path
        self.name = name
        self.size = size
        self.modified = modified
        self.favoritedAt = favoritedAt
    }
}

/// 收藏数据的值快照，供 LibraryStore 不直接持有 SwiftData 模型。
public struct FavoritePhotoSnapshot: Sendable, Equatable {
    public let path: String
    public let name: String
    public let size: Int64
    public let modified: Date?

    public init(path: String, name: String, size: Int64, modified: Date?) {
        self.path = path
        self.name = name
        self.size = size
        self.modified = modified
    }
}

@MainActor
public protocol FavoritePhotoProviding: AnyObject {
    func snapshots(host: String, share: String) -> [FavoritePhotoSnapshot]
    @discardableResult
    func toggle(
        host: String,
        share: String,
        path: String,
        name: String,
        size: Int64,
        modified: Date?
    ) -> Bool
    func remove(host: String, share: String, path: String)
}

@MainActor
public final class FavoritePhotoStore: FavoritePhotoProviding {
    private let context: ModelContext
    private let now: () -> Date

    public init(context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.now = now
    }

    public static func key(host: String, share: String, path: String) -> String {
        "\(host.lowercased())|\(share.lowercased())|\(path)"
    }

    public func snapshots(host: String, share: String) -> [FavoritePhotoSnapshot] {
        favorites(host: host, share: share).map {
            FavoritePhotoSnapshot(
                path: $0.path,
                name: $0.name,
                size: $0.size,
                modified: $0.modified
            )
        }
    }

    public func favorites(host: String, share: String) -> [FavoritePhoto] {
        let hostKey = host.lowercased()
        let shareKey = share.lowercased()
        let descriptor = FetchDescriptor<FavoritePhoto>(
            sortBy: [SortDescriptor(\.favoritedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor))?.filter {
            $0.host.lowercased() == hostKey && $0.share.lowercased() == shareKey
        } ?? []
    }

    public func isFavorite(host: String, share: String, path: String) -> Bool {
        (try? find(host: host, share: share, path: path)) != nil
    }

    /// 返回切换后的状态：true 表示现在已收藏。
    @discardableResult
    public func toggle(
        host: String,
        share: String,
        path: String,
        name: String,
        size: Int64,
        modified: Date?
    ) -> Bool {
        let key = Self.key(host: host, share: share, path: path)
        if let existing = try? find(key: key) {
            context.delete(existing)
            try? context.save()
            Log.info(.app, "照片取消收藏 \(Log.shortPath(path))")
            return false
        }
        let record = FavoritePhoto(
            key: key,
            host: host,
            share: share,
            path: path,
            name: name,
            size: size,
            modified: modified,
            favoritedAt: now()
        )
        context.insert(record)
        try? context.save()
        Log.info(.app, "照片已收藏 \(Log.shortPath(path))")
        return true
    }

    public func remove(host: String, share: String, path: String) {
        guard let record = try? find(host: host, share: share, path: path) else { return }
        context.delete(record)
        try? context.save()
    }

    public func removeAll() {
        let records = (try? context.fetch(FetchDescriptor<FavoritePhoto>())) ?? []
        for record in records {
            context.delete(record)
        }
        try? context.save()
    }

    private func find(host: String, share: String, path: String) throws -> FavoritePhoto? {
        try find(key: Self.key(host: host, share: share, path: path))
    }

    private func find(key: String) throws -> FavoritePhoto? {
        var descriptor = FetchDescriptor<FavoritePhoto>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
