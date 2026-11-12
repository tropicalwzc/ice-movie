import Foundation
import IceCore
import zlib

public enum LivePhotoPackageError: LocalizedError, Sendable {
    case invalidArchive
    case zip64Unsupported
    case encryptedEntry
    case unsupportedCompression(UInt16)
    case entryTooLarge
    case checksumMismatch
    case missingStillImage
    case missingMotion
    case readFailed

    public var errorDescription: String? {
        switch self {
        case .invalidArchive: "LIVP 不是有效的 ZIP 包"
        case .zip64Unsupported: "暂不支持 ZIP64 格式的 LIVP"
        case .encryptedEntry: "LIVP 内含加密条目，暂不支持"
        case .unsupportedCompression(let method): "LIVP 使用了不支持的压缩方式（\(method)）"
        case .entryTooLarge: "LIVP 条目超过可处理大小"
        case .checksumMismatch: "LIVP 条目校验失败"
        case .missingStillImage: "LIVP 内没有可解码的静态图"
        case .missingMotion: "LIVP 内没有动态视频条目"
        case .readFailed: "LIVP 读取失败"
        }
    }
}

public struct ZipEntry: Sendable, Equatable {
    public let name: String
    public let compressionMethod: UInt16
    public let compressedSize: Int64
    public let uncompressedSize: Int64
    public let localHeaderOffset: Int64
    public let crc32: UInt32

    public var isDirectory: Bool { name.hasSuffix("/") }

    public var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }
}

/// LIVP（ZIP）解析结果。静态图与动态 MOV 各自保留条目信息，按需读取。
public struct LivePhotoPackage: Sendable {
    public let entries: [ZipEntry]
    public let stillEntry: ZipEntry?
    public let motionEntry: ZipEntry?

    public var hasStill: Bool { stillEntry != nil }
    public var hasMotion: Bool { motionEntry != nil }
    public var isLivePhoto: Bool { stillEntry != nil && motionEntry != nil }

    private static let maxEntrySize: Int64 = 256 * 1024 * 1024
    private static let maxCentralDirectorySize: Int64 = 16 * 1024 * 1024
    private static let maxEntryCount = 512
    private static let eocdSignature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
    private static let centralSignature: UInt32 = 0x0201_4B50
    private static let localSignature: UInt32 = 0x0403_4B50

    public static func parse(
        source: any ByteSource,
        label: String = ""
    ) async throws -> LivePhotoPackage {
        guard let length = source.length, length >= 22 else {
            throw LivePhotoPackageError.invalidArchive
        }

        let tailLength = min(Int64(128 * 1024), length)
        let tailStart = length - tailLength
        let tail = try await readExactly(
            source: source,
            offset: tailStart,
            count: Int(tailLength)
        )
        guard let range = tail.range(of: Data(eocdSignature), options: .backwards) else {
            throw LivePhotoPackageError.invalidArchive
        }
        let eocd = range.lowerBound
        guard eocd + 22 <= tail.count else {
            throw LivePhotoPackageError.invalidArchive
        }

        let diskNumber = uint16(tail, eocd + 4)
        let centralDisk = uint16(tail, eocd + 6)
        let entriesOnDisk = uint16(tail, eocd + 8)
        let totalEntries = uint16(tail, eocd + 10)
        let centralSize = uint32(tail, eocd + 12)
        let centralOffset = uint32(tail, eocd + 16)

        guard diskNumber == 0, centralDisk == 0 else {
            throw LivePhotoPackageError.zip64Unsupported
        }
        guard totalEntries != 0xFFFF,
              entriesOnDisk != 0xFFFF,
              centralSize != 0xFFFF_FFFF,
              centralOffset != 0xFFFF_FFFF else {
            throw LivePhotoPackageError.zip64Unsupported
        }
        guard totalEntries > 0,
              totalEntries <= maxEntryCount,
              centralSize > 0,
              Int64(centralSize) <= maxCentralDirectorySize,
              Int64(centralOffset) + Int64(centralSize) <= length else {
            throw LivePhotoPackageError.invalidArchive
        }

        let central = try await readExactly(
            source: source,
            offset: Int64(centralOffset),
            count: Int(centralSize)
        )

        var entries: [ZipEntry] = []
        var cursor = 0
        while cursor + 46 <= central.count, entries.count < Int(totalEntries) {
            guard uint32(central, cursor) == centralSignature else {
                throw LivePhotoPackageError.invalidArchive
            }
            let flags = uint16(central, cursor + 8)
            guard flags & 0x0001 == 0 else {
                throw LivePhotoPackageError.encryptedEntry
            }
            let method = uint16(central, cursor + 10)
            guard method == 0 || method == 8 else {
                throw LivePhotoPackageError.unsupportedCompression(method)
            }

            let checksum = uint32(central, cursor + 16)
            let compressedSize = uint32(central, cursor + 20)
            let uncompressedSize = uint32(central, cursor + 24)
            let nameLength = Int(uint16(central, cursor + 28))
            let extraLength = Int(uint16(central, cursor + 30))
            let commentLength = Int(uint16(central, cursor + 32))
            let localOffset = uint32(central, cursor + 42)

            guard compressedSize != 0xFFFF_FFFF,
                  uncompressedSize != 0xFFFF_FFFF,
                  localOffset != 0xFFFF_FFFF,
                  Int64(compressedSize) <= maxEntrySize,
                  Int64(uncompressedSize) <= maxEntrySize else {
                throw LivePhotoPackageError.entryTooLarge
            }

            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= central.count else {
                throw LivePhotoPackageError.invalidArchive
            }
            let nameData = central.subdata(in: nameStart..<nameEnd)
            let name = String(data: nameData, encoding: .utf8)
                ?? String(decoding: nameData, as: UTF8.self)

            entries.append(
                ZipEntry(
                    name: name,
                    compressionMethod: method,
                    compressedSize: Int64(compressedSize),
                    uncompressedSize: Int64(uncompressedSize),
                    localHeaderOffset: Int64(localOffset),
                    crc32: checksum
                )
            )
            cursor = nameEnd + extraLength + commentLength
        }

        guard !entries.isEmpty else {
            throw LivePhotoPackageError.invalidArchive
        }

        let stillExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg"]
        let motionExtensions: Set<String> = ["mov", "mp4"]
        let still = entries
            .filter { !$0.isDirectory && stillExtensions.contains($0.fileExtension) }
            .max { $0.uncompressedSize < $1.uncompressedSize }
        let motion = entries
            .filter { !$0.isDirectory && motionExtensions.contains($0.fileExtension) }
            .max { $0.uncompressedSize < $1.uncompressedSize }

        Log.info(
            .thumbnail,
            "LIVP 解析 \(Log.shortPath(label)) 条目=\(entries.count) "
                + "静态=\(still?.name ?? "无") 动态=\(motion?.name ?? "无")"
        )
        return LivePhotoPackage(entries: entries, stillEntry: still, motionEntry: motion)
    }

    public func stillImageData(
        source: any ByteSource,
        label: String = ""
    ) async throws -> Data {
        guard let entry = stillEntry else {
            throw LivePhotoPackageError.missingStillImage
        }
        return try await extract(
            entry: entry,
            source: source,
            label: label
        )
    }

    /// 动态 MOV 的完整数据。用于内存 resource loader；不写本地临时文件。
    public func motionData(
        source: any ByteSource,
        label: String = ""
    ) async throws -> Data {
        guard let entry = motionEntry else {
            throw LivePhotoPackageError.missingMotion
        }
        return try await extract(entry: entry, source: source, label: label)
    }

    /// 动态 MOV 的随机可读源。stored 条目直接映射 range，deflate 条目解压到内存。
    public func motionByteSource(
        source: any ByteSource,
        label: String = ""
    ) async throws -> any ByteSource {
        guard let entry = motionEntry else {
            throw LivePhotoPackageError.missingMotion
        }
        let offset = try await dataOffset(
            for: entry,
            source: source,
            label: label
        )
        if entry.compressionMethod == 0 {
            return ZipEntryByteSource(
                base: source,
                dataOffset: offset,
                length: entry.compressedSize,
                label: label
            )
        }
        let data = try await extract(entry: entry, source: source, label: label)
        return MemoryByteSource(data: data)
    }

    private func extract(
        entry: ZipEntry,
        source: any ByteSource,
        label: String
    ) async throws -> Data {
        guard entry.uncompressedSize <= Self.maxEntrySize,
              entry.compressedSize <= Self.maxEntrySize else {
            throw LivePhotoPackageError.entryTooLarge
        }
        let offset = try await dataOffset(for: entry, source: source, label: label)
        let compressed = try await Self.readExactly(
            source: source,
            offset: offset,
            count: Int(entry.compressedSize)
        )
        let data: Data
        if entry.compressionMethod == 0 {
            data = compressed
        } else {
            data = try Self.inflateRaw(
                compressed,
                expectedSize: Int(entry.uncompressedSize)
            )
        }
        guard data.count == Int(entry.uncompressedSize) else {
            throw LivePhotoPackageError.readFailed
        }
        guard Self.checksum(data) == entry.crc32 else {
            throw LivePhotoPackageError.checksumMismatch
        }
        return data
    }

    private func dataOffset(
        for entry: ZipEntry,
        source: any ByteSource,
        label: String
    ) async throws -> Int64 {
        let header = try await Self.readExactly(
            source: source,
            offset: entry.localHeaderOffset,
            count: 30
        )
        guard Self.uint32(header, 0) == Self.localSignature else {
            throw LivePhotoPackageError.invalidArchive
        }
        let nameLength = Int(Self.uint16(header, 26))
        let extraLength = Int(Self.uint16(header, 28))
        let offset = entry.localHeaderOffset + 30 + Int64(nameLength + extraLength)
        guard offset >= 0 else {
            throw LivePhotoPackageError.invalidArchive
        }
        if let length = source.length, offset + entry.compressedSize > length {
            throw LivePhotoPackageError.invalidArchive
        }
        return offset
    }

    private static func readExactly(
        source: any ByteSource,
        offset: Int64,
        count: Int
    ) async throws -> Data {
        guard count > 0 else { return Data() }
        var result = Data()
        result.reserveCapacity(count)
        var position = offset
        while result.count < count {
            let chunk = try await source.read(
                at: position,
                count: min(256 * 1024, count - result.count)
            )
            guard !chunk.isEmpty else { break }
            result.append(chunk)
            position += Int64(chunk.count)
        }
        guard result.count == count else {
            throw LivePhotoPackageError.readFailed
        }
        return result
    }

    private static func inflateRaw(_ input: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0, Int64(expectedSize) <= maxEntrySize else {
            throw LivePhotoPackageError.entryTooLarge
        }
        var output = [UInt8](repeating: 0, count: expectedSize)
        var stream = z_stream()
        let initResult = inflateInit2_(
            &stream,
            -MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initResult == Z_OK else {
            throw LivePhotoPackageError.invalidArchive
        }
        defer { inflateEnd(&stream) }

        var result: Int32 = Z_OK
        let outputCount = output.count
        try input.withUnsafeBytes { inputRaw in
            guard let inputBase = inputRaw.bindMemory(to: Bytef.self).baseAddress else {
                throw LivePhotoPackageError.invalidArchive
            }
            stream.next_in = UnsafeMutablePointer(mutating: inputBase)
            stream.avail_in = uInt(input.count)

            try output.withUnsafeMutableBytes { outputRaw in
                guard let outputBase = outputRaw.bindMemory(to: Bytef.self).baseAddress else {
                    throw LivePhotoPackageError.invalidArchive
                }
                stream.next_out = outputBase
                stream.avail_out = uInt(outputCount)
                result = inflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END else {
            throw LivePhotoPackageError.readFailed
        }
        return Data(output)
    }

    private static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return 0 }
            return UInt32(crc32(0, base, uInt(data.count)))
        }
    }

    private static func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
