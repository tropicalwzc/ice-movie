import Foundation
import IceCore
import SMBSession
import ThumbnailKit

private enum SidecarLayout {
    static let root = ".icemovie"
    static let version = ".icemovie/version"
    static let index = ".icemovie/index.json"
    static let thumbs = ".icemovie/thumbs"
    /// 2：512px 缩略图；版本变化时丢弃旧索引并重写缩略图文件。
    static let versionValue = "2"
}

/// SMB 共享侧的缩略图缓存。
struct SMBThumbnailSidecar: ThumbnailSidecarProviding {
    let client: SMBClient

    func prepare() async throws {
        try await client.createDirectory(path: SidecarLayout.root)
        try await client.createDirectory(path: SidecarLayout.thumbs)

        if try await client.fileExists(path: SidecarLayout.version) {
            let data = try await client.readFile(
                path: SidecarLayout.version,
                maxBytes: 32
            )
            let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if value != SidecarLayout.versionValue {
                try? await client.removeFile(path: SidecarLayout.index)
                try await client.overwriteFile(
                    path: SidecarLayout.version,
                    data: Data(SidecarLayout.versionValue.utf8),
                    modified: Date()
                )
            }
        } else {
            try await client.createFile(
                path: SidecarLayout.version,
                data: Data(SidecarLayout.versionValue.utf8),
                modified: Date(),
                onProgress: nil
            )
        }
    }

    func loadIndex() async throws -> Data? {
        guard try await client.fileExists(path: SidecarLayout.index) else {
            return nil
        }
        // 索引有 3 万条上限；放宽到 16MB，避免长路径条目把合法索引误判为损坏。
        return try await client.readFile(
            path: SidecarLayout.index,
            maxBytes: 16 * 1024 * 1024
        )
    }

    func storeIndex(_ data: Data) async throws {
        if try await client.fileExists(path: SidecarLayout.index) {
            try await client.overwriteFile(
                path: SidecarLayout.index,
                data: data,
                modified: Date()
            )
        } else {
            try await client.createFile(
                path: SidecarLayout.index,
                data: data,
                modified: Date(),
                onProgress: nil
            )
        }
    }

    func loadThumbnail(relativePath: String) async throws -> Data? {
        let path = "\(SidecarLayout.root)/\(relativePath)"
        guard try await client.fileExists(path: path) else { return nil }
        return try await client.readFile(
            path: path,
            maxBytes: 2 * 1024 * 1024
        )
    }

    func storeThumbnail(_ data: Data, relativePath: String) async throws {
        let path = "\(SidecarLayout.root)/\(relativePath)"
        let parent = (path as NSString).deletingLastPathComponent
        try await client.createDirectory(path: parent)
        if try await client.fileExists(path: path) {
            // 索引版本升级后旧文件可能仍是 384px；必须覆盖，不能因为文件存在就跳过。
            try await client.overwriteFile(
                path: path,
                data: data,
                modified: Date()
            )
            return
        }
        try await client.createFile(
            path: path,
            data: data,
            modified: Date(),
            onProgress: nil
        )
    }

    func removeThumbnail(relativePath: String) async throws {
        try await client.removeFile(path: "\(SidecarLayout.root)/\(relativePath)")
    }

    func removeAll() async throws {
        try? await client.removeFile(path: SidecarLayout.index)
        try? await client.removeFile(path: SidecarLayout.version)
    }
}

/// 本地源使用同一套侧车协议，便于模拟器 UI 测试与单元测试。
struct LocalThumbnailSidecar: ThumbnailSidecarProviding {
    let rootURL: URL

    private var cacheURL: URL {
        rootURL.appendingPathComponent(SidecarLayout.root, isDirectory: true)
    }

    private var indexURL: URL {
        cacheURL.appendingPathComponent("index.json")
    }

    func prepare() async throws {
        try FileManager.default.createDirectory(
            at: cacheURL.appendingPathComponent("thumbs", isDirectory: true),
            withIntermediateDirectories: true
        )
        let versionURL = cacheURL.appendingPathComponent("version")
        if !FileManager.default.fileExists(atPath: versionURL.path) {
            try Data(SidecarLayout.versionValue.utf8).write(
                to: versionURL,
                options: .atomic
            )
        }
    }

    func loadIndex() async throws -> Data? {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return nil
        }
        return try Data(contentsOf: indexURL)
    }

    func storeIndex(_ data: Data) async throws {
        try FileManager.default.createDirectory(
            at: cacheURL,
            withIntermediateDirectories: true
        )
        try data.write(to: indexURL, options: .atomic)
    }

    func loadThumbnail(relativePath: String) async throws -> Data? {
        let url = cacheURL.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func storeThumbnail(_ data: Data, relativePath: String) async throws {
        let url = cacheURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // 与 SMB 侧一致：索引重建时必须覆盖旧的 384px 文件。
        try data.write(to: url, options: .atomic)
    }

    func removeThumbnail(relativePath: String) async throws {
        try? FileManager.default.removeItem(
            at: cacheURL.appendingPathComponent(relativePath)
        )
    }

    func removeAll() async throws {
        try? FileManager.default.removeItem(at: cacheURL)
    }
}
