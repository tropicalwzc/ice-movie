import DemuxKit
import Foundation
import IceCore
import MediaLibraryKit
import SMBSession
import ThumbnailKit

/// 媒体库数据源：目录列举、缩略图字节源与播放字节源共用同一条会话。
protocol LibrarySource: LibraryDirectoryLoading, ThumbnailByteSourceProvider {
    var hostName: String { get }
    var shareName: String { get }

    /// 当前主机上可切换的共享。本地示例只有当前目录。
    func availableShares() async throws -> [String]
    /// 在同一主机上切换共享，不重新走连接页。
    func changeShare(_ share: String) async throws

    /// 列出目录中的全部条目（含字幕等非媒体文件），供字幕发现使用。
    func listAllEntries(path: String) async throws -> [MediaEntry]

    /// 仅用于诊断：模拟会话掉线，验证心跳与退避重连。
    func simulateDropForTesting() async
    /// 仅用于带宽验收：限制读取速率，0 表示不限制。
    func setReadLimitForTesting(kbps: Int) async
}

enum LibrarySourceError: LocalizedError {
    case unsupportedShareSwitch

    var errorDescription: String? {
        switch self {
        case .unsupportedShareSwitch: "当前数据源不支持切换共享"
        }
    }
}

extension LibrarySource {
    func simulateDropForTesting() async {}
    func setReadLimitForTesting(kbps: Int) async {}
    func availableShares() async throws -> [String] { [shareName] }
    func changeShare(_ share: String) async throws {
        throw LibrarySourceError.unsupportedShareSwitch
    }
}

/// SMB 数据源。连接可以复用连接页已经建立的会话，也可以按需懒连接。
actor SMBLibrarySource: LibrarySource {
    private let client: SMBClient
    private let hostNameValue: String
    nonisolated(unsafe) private var shareNameValue: String
    private let credentials: Credentials?
    private var connected: Bool

    struct Credentials: Sendable {
        let host: String
        let user: String
        let password: String
        let share: String
    }

    nonisolated var hostName: String { hostNameValue }
    nonisolated var shareName: String { shareNameValue }

    init(client: SMBClient, host: String, share: String) {
        self.client = client
        self.hostNameValue = host
        self.shareNameValue = share
        self.credentials = nil
        self.connected = true
    }

    init(host: String, share: String, user: String, password: String, heartbeatInterval: Duration = .seconds(20), readLimitKBps: Int = 0) {
        self.client = SMBClient(
            heartbeatInterval: heartbeatInterval,
            readLimitKBps: readLimitKBps
        )
        self.hostNameValue = host
        self.shareNameValue = share
        self.credentials = Credentials(host: host, user: user, password: password, share: share)
        self.connected = false
    }

    func listDirectory(path: String) async throws -> [MediaEntry] {
        try await ensureConnected()
        let items = try await client.listDirectory(path: path)
        return LibraryEntryBuilder.build(
            directoryPath: path,
            items: items.map {
                (name: $0.name, isDirectory: $0.isDirectory, size: $0.size, modified: $0.modified)
            }
        )
    }

    func listAllEntries(path: String) async throws -> [MediaEntry] {
        try await ensureConnected()
        let items = try await client.listDirectory(path: path)
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

    init(rootURL: URL) {
        self.rootURL = rootURL
        self.hostNameValue = "本地示例"
        self.shareNameValue = rootURL.lastPathComponent.isEmpty ? "媒体库" : rootURL.lastPathComponent
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
}
