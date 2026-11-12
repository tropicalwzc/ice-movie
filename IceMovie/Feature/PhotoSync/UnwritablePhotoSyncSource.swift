import Foundation
import IceCore
import MediaLibraryKit
import ThumbnailKit

/// 自动化验收用：读取正常，但创建文件总是失败，模拟只读目标。
actor UnwritablePhotoSyncSource: LibrarySource {
    private let base: any LibrarySource
    private let hostNameValue: String
    private let shareNameValue: String

    nonisolated var hostName: String { hostNameValue }
    nonisolated var shareName: String { shareNameValue }

    init(base: any LibrarySource) {
        self.base = base
        self.hostNameValue = base.hostName
        self.shareNameValue = base.shareName
    }

    func listDirectory(path: String) async throws -> [MediaEntry] {
        try await base.listDirectory(path: path)
    }

    func listAllEntries(path: String) async throws -> [MediaEntry] {
        try await base.listAllEntries(path: path)
    }

    func openByteSource(path: String) async throws -> any ByteSource {
        try await base.openByteSource(path: path)
    }

    func createFile(
        path: String,
        data: Data,
        modified: Date?,
        onProgress: (@Sendable (Int64) -> Bool)?
    ) async throws {
        throw LibrarySourceError.writeFailed("fixture 目标不可写")
    }
}
