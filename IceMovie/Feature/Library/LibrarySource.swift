import DemuxKit
import Foundation
import IceCore
import MediaLibraryKit
import SMBSession
import ThumbnailKit

/// 媒体库数据源：目录列举、缩略图字节源与播放字节源共用同一条会话。
protocol LibrarySource: LibraryDirectoryLoading, ThumbnailByteSourceProvider, Sendable {
    var hostName: String { get }
    var shareName: String { get }

    /// 缓存命名空间：必须能区分不同主机/共享/本地根目录，
    /// 否则相同相对路径、大小与修改时间会在切换数据源后错误命中。
    var cacheNamespace: String { get }

    /// 当前主机上可切换的共享。本地示例只有当前目录。
    func availableShares() async throws -> [String]
    /// 在同一主机上切换共享，不重新走连接页。
    func changeShare(_ share: String) async throws

    /// 列出目录中的全部条目（含字幕等非媒体文件），供字幕发现使用。
    func listAllEntries(path: String) async throws -> [MediaEntry]

    /// 字幕读取使用的字节源。SMB 实现用较低优先级，避免整文件扫描拖慢播放。
    func openSubtitleByteSource(path: String) async throws -> any ByteSource

    /// 文档读取使用的字节源。默认复用字幕优先级：用户可见，但低于播放预读。
    func openDocumentByteSource(path: String) async throws -> any ByteSource

    /// 图片相册大图读取。SMB 实现使用字幕级优先级，避免占用播放的 512MB 预读环。
    func openImageByteSource(path: String) async throws -> any ByteSource

    /// 用新的图片数据覆盖远端原文件。成功后才应更新界面缓存。
    func overwriteImage(path: String, data: Data, modified: Date?) async throws

    /// 共享/本地侧车缩略图缓存；不支持时返回 nil。
    var thumbnailSidecar: (any ThumbnailSidecarProviding)? { get }

    /// 创建一个新文件。实现必须保证不覆盖已有文件，并在失败时清理临时文件。
    /// `onProgress` 收到约每 MiB 的已写入字节，返回 `false` 表示中止。
    func createFile(
        path: String,
        data: Data,
        modified: Date?,
        onProgress: (@Sendable (Int64) -> Bool)?
    ) async throws

    /// 删除共享内的单个文件。调用方必须先做用户确认。
    func deleteFile(path: String) async throws

    /// 仅用于诊断：模拟会话掉线，验证心跳与退避重连。
    func simulateDropForTesting() async
    /// 仅用于带宽验收：限制读取速率，0 表示不限制。
    func setReadLimitForTesting(kbps: Int) async
}

enum LibrarySourceError: LocalizedError {
    case unsupportedShareSwitch
    case unsupportedWrite
    case fileExists(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedShareSwitch: "当前数据源不支持切换共享"
        case .unsupportedWrite: "当前数据源不支持写入"
        case .fileExists(let path): "目标文件已存在，未覆盖：\(path)"
        case .writeFailed(let detail): "写入失败：\(detail)"
        }
    }
}

extension LibrarySource {
    var cacheNamespace: String { "\(hostName)|\(shareName)" }
    var thumbnailSidecar: (any ThumbnailSidecarProviding)? { nil }
    func simulateDropForTesting() async {}
    func setReadLimitForTesting(kbps: Int) async {}
    func availableShares() async throws -> [String] { [shareName] }
    func changeShare(_ share: String) async throws {
        throw LibrarySourceError.unsupportedShareSwitch
    }
    func openSubtitleByteSource(path: String) async throws -> any ByteSource {
        try await openByteSource(path: path)
    }
    func openDocumentByteSource(path: String) async throws -> any ByteSource {
        try await openSubtitleByteSource(path: path)
    }
    func openImageByteSource(path: String) async throws -> any ByteSource {
        try await openSubtitleByteSource(path: path)
    }
    func overwriteImage(path: String, data: Data, modified: Date?) async throws {
        throw LibrarySourceError.unsupportedWrite
    }
    func createFile(
        path: String,
        data: Data,
        modified: Date?,
        onProgress: (@Sendable (Int64) -> Bool)?
    ) async throws {
        throw LibrarySourceError.unsupportedWrite
    }
    func deleteFile(path: String) async throws {
        throw LibrarySourceError.unsupportedWrite
    }
}

/// SMB 数据源。连接可以复用连接页已经建立的会话，也可以按需懒连接。
actor SMBLibrarySource: LibrarySource {
    private let client: SMBClient
    private let hostNameValue: String
    nonisolated(unsafe) private var shareNameValue: String
    private let credentials: Credentials?
    private var connected: Bool
    /// 最近一次浏览目录的原始条目；字幕扫描直接复用，避免再走一次 SMB 枚举。
    private var rawEntryCache: [String: (items: [SMBEntry], at: Date)] = [:]

    struct Credentials: Sendable {
        let host: String
        let user: String
        let password: String
        let share: String
    }

    nonisolated var hostName: String { hostNameValue }
    nonisolated var shareName: String { shareNameValue }
    nonisolated let thumbnailSidecar: (any ThumbnailSidecarProviding)?

    init(client: SMBClient, host: String, share: String) {
        self.client = client
        self.hostNameValue = host
        self.shareNameValue = share
        self.credentials = nil
        self.connected = true
        self.thumbnailSidecar = SMBThumbnailSidecar(client: client)
    }

    init(host: String, share: String, user: String, password: String, heartbeatInterval: Duration = .seconds(20), readLimitKBps: Int = 0) {
        let client = SMBClient(
            heartbeatInterval: heartbeatInterval,
            readLimitKBps: readLimitKBps
        )
        self.client = client
        self.hostNameValue = host
        self.shareNameValue = share
        self.credentials = Credentials(host: host, user: user, password: password, share: share)
        self.connected = false
        self.thumbnailSidecar = SMBThumbnailSidecar(client: client)
    }

    func listDirectory(path: String) async throws -> [MediaEntry] {
        try await ensureConnected()
        let items = try await client.listDirectory(path: path)
        rawEntryCache[path] = (items, Date())
        return LibraryEntryBuilder.build(
            directoryPath: path,
            items: items.map {
                (name: $0.name, isDirectory: $0.isDirectory, size: $0.size, modified: $0.modified)
            }
        )
    }

    func listAllEntries(path: String) async throws -> [MediaEntry] {
        try await ensureConnected()
        let items: [SMBEntry]
        if let cached = rawEntryCache[path], Date().timeIntervalSince(cached.at) < 30 {
            items = cached.items
        } else {
            items = try await client.listDirectory(path: path)
            rawEntryCache[path] = (items, Date())
        }
        let prefix = path.isEmpty ? "" : path + "/"
        return items.map {
            MediaEntry(
                path: prefix + $0.name,
                name: $0.name,
                isDirectory: $0.isDirectory,
                size: $0.size,
                modified: $0.modified
            )
        }
    }

    func availableShares() async throws -> [String] {
        try await ensureConnected()
        let shares = try await client.listShares()
        let names = shares.map(\.name).filter { name in
            name == shareNameValue || !name.hasSuffix("$")
        }
        Log.info(.smb, "共享列表 host=\(hostNameValue) 可切换=\(names.count)")
        return names
    }

    func changeShare(_ share: String) async throws {
        let target = share.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !target.isEmpty, target != shareNameValue else { return }
        try await ensureConnected()
        try await client.changeShare(target)
        shareNameValue = target
        Log.info(.smb, "媒体库切换共享 host=\(hostNameValue) share=\(target)")
    }

    /// 冷启动自动恢复时先显式连接，成功后再进入媒体库，失败则回到连接页。
    func connect() async throws {
        try await ensureConnected()
    }

    func openByteSource(path: String) async throws -> any ByteSource {
        try await ensureConnected()
        return try await client.openByteSource(path: path, priority: .playback)
    }

    func openSubtitleByteSource(path: String) async throws -> any ByteSource {
        try await ensureConnected()
        // 字幕窗口优先于播放预读，避免首屏字幕排在 24MB 预读之后。
        return try await client.openByteSource(path: path, priority: .subtitle)
    }

    func openImageByteSource(path: String) async throws -> any ByteSource {
        try await ensureConnected()
        // 相册大图是用户主动操作，高于枚举/缩略图，但不使用播放的 512MB 预读环。
        return try await client.openByteSource(path: path, priority: .subtitle)
    }

    func overwriteImage(path: String, data: Data, modified: Date?) async throws {
        try await ensureConnected()
        try await client.overwriteFile(path: path, data: data, modified: modified)
    }

    func createFile(
        path: String,
        data: Data,
        modified: Date?,
        onProgress: (@Sendable (Int64) -> Bool)?
    ) async throws {
        try await ensureConnected()
        try await client.createFile(
            path: path,
            data: data,
            modified: modified,
            onProgress: onProgress
        )
    }

    func deleteFile(path: String) async throws {
        try await ensureConnected()
        try await client.removeFile(path: path)
    }

    func openThumbnailByteSource(path: String) async throws -> any ByteSource {
        try await ensureConnected()
        return try await client.openByteSource(path: path, priority: .thumbnail)
    }

    func disconnect() async {
        await client.disconnect()
        connected = false
    }

    func simulateDropForTesting() async {
        await client.simulateDropForTesting()
    }

    func setReadLimitForTesting(kbps: Int) async {
        await client.setReadLimit(kbps: kbps)
    }

    private func ensureConnected() async throws {
        guard !connected else { return }
        guard let credentials else { throw SMBConnectionError.notConnected }
        try await client.connect(
            host: credentials.host,
            user: credentials.user,
            password: credentials.password,
            share: credentials.share
        )
        connected = true
    }
}

/// 本地目录数据源。用于模拟器验证、预览与离线样本浏览。
actor LocalLibrarySource: LibrarySource {
    private let rootURL: URL
    private let hostNameValue: String
    private let shareNameValue: String

    nonisolated var hostName: String { hostNameValue }
    nonisolated var shareName: String { shareNameValue }
    /// 本地源用绝对根路径，避免两个同名目录（如都叫“媒体库”）共用缓存。
    nonisolated var cacheNamespace: String { "local|\(rootURL.path)" }
    nonisolated let thumbnailSidecar: (any ThumbnailSidecarProviding)?

    init(rootURL: URL) {
        self.rootURL = rootURL
        self.hostNameValue = "本地示例"
        self.shareNameValue = rootURL.lastPathComponent.isEmpty ? "媒体库" : rootURL.lastPathComponent
        // 侧车缓存默认只对 SMB 开启；模拟器/UI 测试通过启动参数显式启用。
        self.thumbnailSidecar = ProcessInfo.processInfo.arguments.contains(
            "-enableLocalThumbnailSidecar"
        ) ? LocalThumbnailSidecar(rootURL: rootURL) : nil
    }

    func listDirectory(path: String) async throws -> [MediaEntry] {
        let directory = path.isEmpty
            ? rootURL
            : rootURL.appending(path: path, directoryHint: .isDirectory)
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles]
        )
        let items: [(name: String, isDirectory: Bool, size: Int64, modified: Date?)] = urls.map { url in
            let values = try? url.resourceValues(forKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            ])
            return (
                name: url.lastPathComponent,
                isDirectory: values?.isDirectory ?? false,
                size: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate
            )
        }
        return LibraryEntryBuilder.build(directoryPath: path, items: items)
    }

    func listAllEntries(path: String) async throws -> [MediaEntry] {
        let directory = path.isEmpty
            ? rootURL
            : rootURL.appending(path: path, directoryHint: .isDirectory)
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles]
        )
        let prefix = path.isEmpty ? "" : path + "/"
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            ])
            return MediaEntry(
                path: prefix + url.lastPathComponent,
                name: url.lastPathComponent,
                isDirectory: values?.isDirectory ?? false,
                size: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate
            )
        }
    }

    func openByteSource(path: String) async throws -> any ByteSource {
        let url = rootURL.appending(path: path)
        return try LocalFileByteSource(url: url)
    }

    func overwriteImage(path: String, data: Data, modified: Date?) async throws {
        let url = rootURL.appending(path: path)
        try data.write(to: url, options: .atomic)
        if let modified {
            try? FileManager.default.setAttributes(
                [.modificationDate: modified],
                ofItemAtPath: url.path
            )
        }
    }

    func createFile(
        path: String,
        data: Data,
        modified: Date?,
        onProgress: (@Sendable (Int64) -> Bool)?
    ) async throws {
        let targetURL = rootURL.appending(path: path)
        let directory = targetURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw LibrarySourceError.writeFailed("目标目录不存在：\(directory.path)")
        }
        guard !FileManager.default.fileExists(atPath: targetURL.path) else {
            throw LibrarySourceError.fileExists(path)
        }

        let temporaryURL = directory.appendingPathComponent(
            "\(targetURL.lastPathComponent).icemovie-tmp-\(UUID().uuidString)",
            isDirectory: false
        )
        do {
            try data.write(to: temporaryURL, options: [])
            let attributes = try FileManager.default.attributesOfItem(
                atPath: temporaryURL.path
            )
            let size = (attributes[.size] as? NSNumber)?.int64Value
                ?? Int64(data.count)
            guard size == Int64(data.count) else {
                throw LibrarySourceError.writeFailed(
                    "写入后大小不一致：\(size)/\(data.count) 字节"
                )
            }
            if let onProgress, !onProgress(Int64(data.count)) {
                throw CancellationError()
            }
            guard !FileManager.default.fileExists(atPath: targetURL.path) else {
                throw LibrarySourceError.fileExists(path)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: targetURL)
            if let modified {
                try? FileManager.default.setAttributes(
                    [.modificationDate: modified],
                    ofItemAtPath: targetURL.path
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    func deleteFile(path: String) async throws {
        let url = rootURL.appending(path: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LibrarySourceError.writeFailed("文件不存在：\(path)")
        }
        try FileManager.default.removeItem(at: url)
    }
}
