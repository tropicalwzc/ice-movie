import Foundation
import IceCore
import SwiftData

/// 一条主机连接记录。
///
/// `address` 保存用户填写的原始字符串，绝不替换成解析后的 IP（design.md D11）；
/// 密码不在这里，只存在钥匙串。
@Model
public final class SavedHost {
    @Attribute(.unique) public var address: String
    public var username: String
    public var share: String
    public var recentPath: String
    public var lastConnectedAt: Date

    public init(
        address: String,
        username: String,
        share: String,
        recentPath: String,
        lastConnectedAt: Date = Date()
    ) {
        self.address = address
        self.username = username
        self.share = share
        self.recentPath = recentPath
        self.lastConnectedAt = lastConnectedAt
    }

    public var displayTitle: String {
        address
    }

    public var displaySubtitle: String {
        let path = recentPath.isEmpty ? "/" : recentPath
        return "\(share) · \(path)"
    }
}

/// 一条视频的续播记录。`key` 由路径、大小与修改时间组成，文件变化后自动失效。
@Model
public final class PlaybackProgressRecord {
    @Attribute(.unique) public var key: String
    public var path: String
    public var position: Double
    public var duration: Double
    public var updatedAt: Date

    public init(
        key: String,
        path: String,
        position: Double,
        duration: Double,
        updatedAt: Date = Date()
    ) {
        self.key = key
        self.path = path
        self.position = position
        self.duration = duration
        self.updatedAt = updatedAt
    }
}

/// 续播规则：距结尾 30 秒内视为看完；过短的位置不值得续播。
public enum PlaybackProgressPolicy {
    public static let finishedThreshold: Double = 30
    public static let minimumResume: Double = 5

    public static func isFinished(position: Double, duration: Double) -> Bool {
        guard duration > 0, position.isFinite else { return false }
        return position >= duration - finishedThreshold
    }

    public static func resumePosition(position: Double, duration: Double) -> Double? {
        guard position.isFinite, position >= minimumResume else { return nil }
        guard !isFinished(position: position, duration: duration) else { return nil }
        return position
    }

    public static func key(path: String, size: Int64, modified: Date?) -> String {
        let stamp = modified.map { Int64($0.timeIntervalSince1970) } ?? 0
        return "\(path)|\(size)|\(stamp)"
    }
}

/// SwiftData 续播进度读写。
@MainActor
public final class PlaybackProgressStore {
    private let context: ModelContext
    private let now: () -> Date

    public init(context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.now = now
    }

    /// 可续播的位置；已看完或太短时返回 nil。
    public func resumePosition(for key: String) -> Double? {
        guard let record = try? find(key) else { return nil }
        return PlaybackProgressPolicy.resumePosition(
            position: record.position,
            duration: record.duration
        )
    }

    /// 记录进度。距结尾不足 30 秒时删除记录，下次从头开始。
    public func record(
        key: String,
        path: String,
        position: Double,
        duration: Double
    ) {
        guard position.isFinite, position > 0, duration > 0 else { return }
        do {
            if PlaybackProgressPolicy.isFinished(position: position, duration: duration) {
                if let record = try find(key) {
                    context.delete(record)
                    try context.save()
                    Log.info(.app, "播放进度完成，清除记录 \(Log.shortPath(path))")
                }
                return
            }
            let record: PlaybackProgressRecord
            if let existing = try find(key) {
                record = existing
            } else {
                record = PlaybackProgressRecord(
                    key: key,
                    path: path,
                    position: position,
                    duration: duration,
                    updatedAt: now()
                )
                context.insert(record)
            }
            record.position = position
            record.duration = duration
            record.updatedAt = now()
            try context.save()
            Log.info(
                .app,
                "播放进度已记录 \(Log.shortPath(path)) 位置=\(String(format: "%.1f", position))s "
                    + "时长=\(String(format: "%.1f", duration))s"
            )
        } catch {
            Log.error(.app, "播放进度写入失败 \(Log.shortPath(path)) \(error.localizedDescription)")
        }
    }

    public func clear(key: String) {
        guard let record = try? find(key) else { return }
        context.delete(record)
        try? context.save()
    }

    public func removeAll() {
        let records = (try? context.fetch(FetchDescriptor<PlaybackProgressRecord>())) ?? []
        for record in records {
            context.delete(record)
        }
        try? context.save()
    }

    private func find(_ key: String) throws -> PlaybackProgressRecord? {
        var descriptor = FetchDescriptor<PlaybackProgressRecord>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

/// SwiftData 主机记录读写。
///
/// 业务数据（地址原文、账号、共享、最近路径）放这里，密码由调用方同步维护钥匙串。
@MainActor
public final class HostRecordStore {
    private let context: ModelContext
    private let now: () -> Date

    public init(context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.now = now
    }

    /// 新增或更新一条主机记录。地址原文是身份。
    @discardableResult
    public func remember(
        address: String,
        username: String,
        share: String,
        path: String
    ) throws -> SavedHost {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let record: SavedHost
        if let existing = try find(trimmedAddress) {
            existing.username = username
            existing.share = share
            existing.recentPath = path
            existing.lastConnectedAt = now()
            record = existing
        } else {
            record = SavedHost(
                address: trimmedAddress,
                username: username,
                share: share,
                recentPath: path,
                lastConnectedAt: now()
            )
            context.insert(record)
        }
        try context.save()
        Log.info(
            .app,
            "主机记录已保存 host=\(trimmedAddress) share=\(share) path=\(Log.shortPath(path.isEmpty ? "/" : path))"
        )
        return record
    }

    /// 只更新最近路径，不改动连接时间。用于目录浏览过程中的轻量写回。
    public func updatePath(address: String, share: String, path: String) {
        do {
            guard let record = try find(address) else { return }
            guard record.share != share || record.recentPath != path else { return }
            record.share = share
            record.recentPath = path
            try context.save()
        } catch {
            Log.error(.app, "最近路径写回失败 host=\(address) \(error.localizedDescription)")
        }
    }

    public func mostRecent() -> SavedHost? {
        var descriptor = FetchDescriptor<SavedHost>(
            sortBy: [SortDescriptor(\.lastConnectedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    public func all() -> [SavedHost] {
        let descriptor = FetchDescriptor<SavedHost>(
            sortBy: [SortDescriptor(\.lastConnectedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// 忘记主机：删除本地记录。钥匙串由调用方一起清理。
    public func forget(address: String) throws {
        let matches = try context.fetch(
            FetchDescriptor<SavedHost>(predicate: #Predicate { $0.address == address })
        )
        for record in matches {
            context.delete(record)
        }
        try context.save()
        Log.info(.app, "主机记录已删除 host=\(address)")
    }

    public func removeAll() throws {
        for record in all() {
            context.delete(record)
        }
        try context.save()
    }

    private func find(_ address: String) throws -> SavedHost? {
        var descriptor = FetchDescriptor<SavedHost>(
            predicate: #Predicate { $0.address == address }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
