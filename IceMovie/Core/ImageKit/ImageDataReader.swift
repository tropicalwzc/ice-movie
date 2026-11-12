import Foundation
import IceCore

public enum ImageDataError: LocalizedError, Sendable {
    case tooLarge(Int64, Int64)
    case truncated(Int64, Int64)
    case readFailed

    public var errorDescription: String? {
        switch self {
        case .tooLarge(let size, let limit):
            "图片过大（\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))，上限 \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))）"
        case .truncated(let received, let expected):
            "图片读取不完整（\(received)/\(expected) 字节）"
        case .readFailed:
            "图片读取失败"
        }
    }
}

/// 顺序读取完整图片数据，带大小上限与取消检查。
public enum ImageDataReader {
    public static func readAll(
        source: any ByteSource,
        maxBytes: Int64 = 64 * 1024 * 1024,
        label: String = ""
    ) async throws -> Data {
        guard let length = source.length else {
            throw ImageDataError.readFailed
        }
        guard length >= 0, length <= maxBytes else {
            throw ImageDataError.tooLarge(length, maxBytes)
        }

        var data = Data()
        data.reserveCapacity(Int(length))
        var offset: Int64 = 0
        while offset < length {
            try Task.checkCancellation()
            let chunk = try await source.read(
                at: offset,
                count: min(1024 * 1024, Int(length - offset))
            )
            guard !chunk.isEmpty else { break }
            data.append(chunk)
            offset += Int64(chunk.count)
        }
        guard data.count == Int(length) else {
            throw ImageDataError.truncated(Int64(data.count), length)
        }
        Log.debug(.thumbnail, "图片整图读取 \(Log.shortPath(label)) \(data.count)B")
        return data
    }
}
