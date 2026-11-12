import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageEncoderError: LocalizedError, Sendable {
    case unsupportedFormat
    case decodeFailed
    case encodeFailed
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "该图片格式不支持旋转保存"
        case .decodeFailed: "图片解码失败，无法旋转"
        case .encodeFailed: "图片编码失败，无法保存"
        case .tooLarge: "图片尺寸过大，无法旋转保存"
        }
    }
}

/// 图片旋转与重新编码。
///
/// 保存时按原图像素尺寸解码（上限 8192），旋转后使用原格式编码；
/// 不是拿屏幕尺寸的预览图覆盖原图。
public enum ImageEncoder {
    private static let maxSavePixelSize = 8192

    public static func rotate(
        _ image: CGImage,
        quarterTurns: Int,
        background: CGColor? = nil
    ) -> CGImage? {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }

        let swapped = turns % 2 == 1
        let width = swapped ? image.height : image.width
        let height = swapped ? image.width : image.height
        guard width > 0, height > 0 else { return nil }

        let colorSpace: CGColorSpace
        if let source = image.colorSpace, source.model == .rgb {
            colorSpace = source
        } else {
            colorSpace = CGColorSpaceCreateDeviceRGB()
        }
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        if let background {
            context.setFillColor(background)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.interpolationQuality = .high
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        // Core Graphics 正角度为逆时针；取负值实现用户直觉的顺时针旋转。
        context.rotate(by: -CGFloat(turns) * .pi / 2)
        context.translateBy(
            x: -CGFloat(image.width) / 2,
            y: -CGFloat(image.height) / 2
        )
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        return context.makeImage()
    }

    /// 从原始压缩数据生成旋转后的完整图片数据，保留原格式并尽量保留元数据。
    public static func rotatedImageData(
        originalData: Data,
        type: UTType,
        quarterTurns: Int,
        quality: CGFloat = 0.95
    ) throws -> Data {
        guard let source = CGImageSourceCreateWithData(
            originalData as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw ImageEncoderError.decodeFailed
        }

        let originalProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any] ?? [:]
        let pixelWidth = (originalProperties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let pixelHeight = (originalProperties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let maxDimension = max(pixelWidth, pixelHeight)
        guard maxDimension > 0 else { throw ImageEncoderError.decodeFailed }
        guard maxDimension <= maxSavePixelSize * 2 else {
            throw ImageEncoderError.tooLarge
        }

        let targetDimension = min(maxDimension, maxSavePixelSize)
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: targetDimension,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: false,
        ]
        guard let upright = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            decodeOptions as CFDictionary
        ) else {
            throw ImageEncoderError.decodeFailed
        }

        let background: CGColor? = type == .png
            ? nil
            : CGColor(gray: 1, alpha: 1)
        guard let rotated = rotate(
            upright,
            quarterTurns: quarterTurns,
            background: background
        ) else {
            throw ImageEncoderError.encodeFailed
        }

        var properties = originalProperties
        properties[kCGImagePropertyOrientation] = 1
        properties.removeValue(forKey: kCGImagePropertyPixelWidth)
        properties.removeValue(forKey: kCGImagePropertyPixelHeight)
        guard let encoded = encode(
            rotated,
            type: type,
            properties: properties,
            quality: quality
        ) else {
            throw ImageEncoderError.encodeFailed
        }
        return encoded
    }

    public static func encode(
        _ image: CGImage,
        type: UTType,
        properties: [CFString: Any]? = nil,
        quality: CGFloat = 0.95
    ) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            type.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let destinationProperties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationSetProperties(
            destination,
            destinationProperties as CFDictionary
        )
        CGImageDestinationAddImage(
            destination,
            image,
            properties as CFDictionary?
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
