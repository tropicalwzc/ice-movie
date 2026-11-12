import Foundation
import IceCore
import MediaLibraryKit
import XCTest
@testable import IceMovie

/// 文档加载测试用的数据源。读取内容固定，便于精确控制大小与失败点。
actor DocumentLoaderTestSource: LibrarySource {
    nonisolated let hostName = "document-test-host"
    nonisolated let shareName = "document-test-share"
    let byteSource: CountingDocumentByteSource
    private(set) var openCount = 0

    init(data: Data, declaredLength: Int64? = nil, readError: (any Error)? = nil) {
        self.byteSource = CountingDocumentByteSource(
            data: data,
            declaredLength: declaredLength,
            readError: readError
        )
    }

    func listDirectory(path: String) async throws -> [MediaEntry] { [] }
    func listAllEntries(path: String) async throws -> [MediaEntry] { [] }
    func openByteSource(path: String) async throws -> any ByteSource { byteSource }

    func openDocumentByteSource(path: String) async throws -> any ByteSource {
        openCount += 1
        return byteSource
    }
}

actor CountingDocumentByteSource: ByteSource {
    nonisolated let length: Int64?
    private let data: Data
    private let readError: (any Error)?
    private(set) var closeCount = 0
    private(set) var readCount = 0

    init(data: Data, declaredLength: Int64?, readError: (any Error)? = nil) {
        self.data = data
        self.length = declaredLength ?? Int64(data.count)
        self.readError = readError
    }

    func read(at offset: Int64, count: Int) async throws -> Data {
        try Task.checkCancellation()
        if let readError { throw readError }
        readCount += 1
        let start = Int(offset)
        guard start < data.count else { return Data() }
        let end = min(data.count, start + max(0, count))
        return data.subdata(in: start..<end)
    }

    func close() async {
        closeCount += 1
    }
}

struct StaticDocumentByteSource: ByteSource {
    let data: Data
    let length: Int64?

    init(_ data: Data) {
        self.data = data
        self.length = Int64(data.count)
    }

    func read(at offset: Int64, count: Int) async throws -> Data {
        let start = Int(offset)
        guard start < data.count else { return Data() }
        let end = min(data.count, start + max(0, count))
        return data.subdata(in: start..<end)
    }

    func close() async {}
}

func makeDocumentEntry(
    _ name: String,
    size: Int64 = 0,
    path: String? = nil
) -> MediaEntry {
    MediaEntry(
        path: path ?? name,
        name: name,
        isDirectory: false,
        size: size,
        modified: nil
    )
}
