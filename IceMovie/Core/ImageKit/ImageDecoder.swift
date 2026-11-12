import CoreGraphics
import Foundation
import IceCore
import ImageIO
import UniformTypeIdentifiers

public struct ThumbnailOutput: Sendable, Equatable {
    public let data: Data
    public let width: Int
    public let height: Int

    public init(data: Data, width: Int, height: Int) {
        self.data = data
        self.width = width
        self.height = height
    }
}

/// 使用 ImageIO 解码并下采样静态图片。
///
/// 所有入口都按目标像素尺寸生成缩略图，不会为了网格或相册解码全尺寸原图。
public enum ImageDecoder {
    public static func thumbnail(
        data: Data,
        maxPixelSize: Int,
        label: String = ""
    ) throws -> ThumbnailOutput {
        guard !data.isEmpty else { throw ImageDecodeError.emptyData }
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw ImageDecodeError.invalidImage
        }
        let image = try thumbnailImage(
            source: source,
            maxPixelSize: maxPixelSize,
            label: label
        )
        guard let png = encodePNG(image) else { throw ImageDecodeError.encodeFailed }
        return ThumbnailOutput(data: png, width: image.width, height: image.height)
    }

    public static func thumbnail(
        source: any ByteSource,
        maxPixelSize: Int,
        label: String
    ) throws -> ThumbnailOutput {
        let remote = try RemoteImageDataProvider(source: source, label: label)
        guard let imageSource = CGImageSourceCreateWithDataProvider(
            remote.provider,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw ImageDecodeError.invalidImage
        }
        let image = try thumbnailImage(
            source: imageSource,
            maxPixelSize: maxPixelSize,
            label: label
        )
        guard let png = encodePNG(image) else { throw ImageDecodeError.encodeFailed }
        Log.debug(
            .thumbnail,
            "图片缩略图 \(Log.shortPath(label)) \(image.width)x\(image.height) "
                + "读取=\(remote.bytesRead)B/\(remote.networkReadCount)次"
        )
        return ThumbnailOutput(data: png, width: image.width, height: image.height)
    }

    /// JPEG 快速路径：只读取文件前缀，直接解 EXIF 里那张完整的内嵌缩略图。
    ///
    /// 不能把“半张 JPEG”交给 ImageIO：它可能返回尺寸正确、但只解码了顶部扫描线的
    /// 图片，在瀑布流里表现为只剩一条边。这里自己解析 APP1/EXIF，只取完整的
    /// JPEGInterchangeFormat 缩略图数据，再单独解码。
    public static func thumbnailFromPrefix(
        source: any ByteSource,
        maxPixelSize: Int,
        label: String,
        prefixBytes: Int = 512 * 1024
    ) async throws -> ThumbnailOutput? {
        guard let length = source.length, length > 64 * 1024 else {
            return nil
        }
        let readCount = min(prefixBytes, Int(length))
        let prefix = try await source.read(at: 0, count: readCount)
        guard prefix.count >= 4 else { return nil }
        guard let thumbnailData = exifThumbnailData(in: [UInt8](prefix)) else {
            return nil
        }

        let output = try thumbnail(
            data: thumbnailData,
            maxPixelSize: maxPixelSize,
            label: label
        )
        let ratio = CGFloat(output.width) / CGFloat(max(1, output.height))
        guard output.width >= 48,
              output.height >= 48,
              ratio >= 0.2,
              ratio <= 5 else {
            return nil
        }
        Log.debug(
            .thumbnail,
            "图片 EXIF 缩略图 \(Log.shortPath(label)) \(output.width)x\(output.height) "
                + "前缀=\(prefix.count)B"
        )
        return output
    }

    /// 从 JPEG 前缀中解析 EXIF 的 JPEGInterchangeFormat 缩略图。
    private static func exifThumbnailData(in jpeg: [UInt8]) -> Data? {
        guard jpeg.count > 4, jpeg[0] == 0xFF, jpeg[1] == 0xD8 else { return nil }
        var index = 2
        while index + 1 < jpeg.count {
            guard jpeg[index] == 0xFF else { return nil }
            var markerIndex = index + 1
            while markerIndex < jpeg.count, jpeg[markerIndex] == 0xFF {
                markerIndex += 1
            }
            guard markerIndex < jpeg.count else { return nil }
            let marker = jpeg[markerIndex]
            index = markerIndex + 1

            if marker == 0xD8 || marker == 0xD9 || marker == 0x01 {
                continue
            }
            if marker == 0xDA { break }
            guard index + 1 < jpeg.count else { return nil }
            let segmentLength = Int(jpeg[index]) << 8 | Int(jpeg[index + 1])
            guard segmentLength >= 2, index + segmentLength <= jpeg.count else {
                return nil
            }
            let payloadStart = index + 2
            let payloadEnd = index + segmentLength
            if marker == 0xE1,
               payloadEnd - payloadStart >= 6,
               Array(jpeg[payloadStart..<payloadStart + 6]) == Array("Exif\0\0".utf8),
               let data = exifThumbnailDataFromTIFF(
                   jpeg,
                   tiffStart: payloadStart + 6,
                   end: payloadEnd
               ) {
                return data
            }
            index = payloadEnd
        }
        return nil
    }

    private static func exifThumbnailDataFromTIFF(
        _ bytes: [UInt8],
        tiffStart: Int,
        end: Int
    ) -> Data? {
        guard tiffStart + 8 <= end else { return nil }
        let littleEndian: Bool
        if bytes[tiffStart] == 0x49, bytes[tiffStart + 1] == 0x49 {
            littleEndian = true
        } else if bytes[tiffStart] == 0x4D, bytes[tiffStart + 1] == 0x4D {
            littleEndian = false
        } else {
            return nil
        }

        func read16(_ offset: Int) -> Int? {
            guard offset >= tiffStart, offset + 2 <= end else { return nil }
            return littleEndian
                ? Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
                : Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
        }

        func read32(_ offset: Int) -> Int? {
            guard offset >= tiffStart, offset + 4 <= end else { return nil }
            let b0 = Int(bytes[offset])
            let b1 = Int(bytes[offset + 1])
            let b2 = Int(bytes[offset + 2])
            let b3 = Int(bytes[offset + 3])
            return littleEndian
                ? b0 | b1 << 8 | b2 << 16 | b3 << 24
                : b0 << 24 | b1 << 16 | b2 << 8 | b3
        }

        guard read16(tiffStart + 2) == 42,
              let ifd0Offset = read32(tiffStart + 4) else {
            return nil
        }

        var ifd = tiffStart + ifd0Offset
        for _ in 0..<2 {
            guard let count = read16(ifd), count > 0, count < 512 else { break }
            var thumbOffset: Int?
            var thumbLength: Int?
            for entryIndex in 0..<count {
                let entry = ifd + 2 + entryIndex * 12
                guard entry + 12 <= end else { break }
                guard let tag = read16(entry), let value = read32(entry + 8) else {
                    continue
                }
                if tag == 0x0201 { thumbOffset = value }
                if tag == 0x0202 { thumbLength = value }
            }
            if let offset = thumbOffset, let length = thumbLength, length > 32 {
                let start = tiffStart + offset
                let finish = start + length
                if finish <= end, finish <= bytes.count {
                    return Data(bytes[start..<finish])
                }
            }
            let nextPointer = ifd + 2 + count * 12
            guard let nextOffset = read32(nextPointer), nextOffset != 0 else { break }
            ifd = tiffStart + nextOffset
        }
        return nil
    }

    public static func displayImage(
        data: Data,
        maxPixelSize: Int,
        label: String = ""
    ) throws -> CGImage {
        guard !data.isEmpty else { throw ImageDecodeError.emptyData }
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw ImageDecodeError.invalidImage
        }
        return try thumbnailImage(source: source, maxPixelSize: maxPixelSize, label: label)
    }

    public static func displayImage(
        source: any ByteSource,
        maxPixelSize: Int,
        label: String
    ) throws -> CGImage {
        let remote = try RemoteImageDataProvider(source: source, label: label)
        guard let imageSource = CGImageSourceCreateWithDataProvider(
            remote.provider,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw ImageDecodeError.invalidImage
        }
        return try thumbnailImage(source: imageSource, maxPixelSize: maxPixelSize, label: label)
    }

    /// 把已生成的 PNG 缩略图转成共享侧车使用的 JPEG。
    public static func encodeJPEG(_ data: Data, quality: CGFloat = 0.8) -> Data? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ),
        let image = CGImageSourceCreateImageAtIndex(
            source,
            0,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            return nil
        }
        if let data = encodeJPEGData(image, quality: quality) {
            return data
        }
        guard let normalized = normalized8Bit(image) else { return nil }
        return encodeJPEGData(normalized, quality: quality)
    }

    private static func encodeJPEGData(_ image: CGImage, quality: CGFloat) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    public static func encodePNG(_ image: CGImage) -> Data? {
        if let data = encodePNGData(image) {
            return data
        }
        // 10-bit/广色域 HEIC 解码出的 CGImage 可能无法直接写 PNG；
        // 转成 8-bit sRGB 后再编码。
        guard let normalized = normalized8Bit(image) else { return nil }
        return encodePNGData(normalized)
    }

    private static func encodePNGData(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func normalized8Bit(_ image: CGImage) -> CGImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        return context.makeImage()
    }

    private static func thumbnailImage(
        source: CGImageSource,
        maxPixelSize: Int,
        label: String
    ) throws -> CGImage {
        let size = max(1, maxPixelSize)
        let baseOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: size,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: false,
        ]

        var options = baseOptions
        options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw ImageDecodeError.decodeFailed
        }

        // 内嵌缩略图太小时重解主图，保证网格在 iPad 上也清晰。
        guard image.width < max(1, size / 2), image.height < max(1, size / 2) else {
            return image
        }
        var alwaysOptions = baseOptions
        alwaysOptions[kCGImageSourceCreateThumbnailFromImageAlways] = true
        guard let larger = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            alwaysOptions as CFDictionary
        ) else {
            return image
        }
        if larger.width > image.width || larger.height > image.height {
            Log.debug(
                .thumbnail,
                "图片内嵌缩略图偏小，回退主图 \(Log.shortPath(label)) "
                    + "\(image.width)x\(image.height) -> \(larger.width)x\(larger.height)"
            )
            return larger
        }
        return image
    }
}
