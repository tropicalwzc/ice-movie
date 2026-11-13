import CoreGraphics
import Foundation
import IceCore
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
    /// 旋转保存的工作位图上限。48MP 原图旋转时源图 + 目标图会各占约 195MB，
    /// 在旧机型/后台内存紧张时会被 jetsam；限制到 24MP（约 96MB/份）。
    /// 4032×3024 及以下仍按原像素保存。
    private static let maxSavePixelCount = 24_000_000

    public static func rotate(
        _ image: CGImage,
        quarterTurns: Int,
        background: CGColor? = nil
    ) -> CGImage? {
        rotate(
            image,
            quarterTurns: quarterTurns,
            background: background,
            maxPixelSize: nil
        )
    }

    /// 相册预览专用：旋转的同时把最长边限制到屏幕尺寸，只分配一张目标位图。
    public static func rotatedPreview(
        _ image: CGImage,
        quarterTurns: Int,
        maxPixelSize: Int
    ) -> CGImage? {
        rotate(
            image,
            quarterTurns: quarterTurns,
            background: nil,
            maxPixelSize: max(1, maxPixelSize)
        )
    }

    private static func rotate(
        _ image: CGImage,
        quarterTurns: Int,
        background: CGColor?,
        maxPixelSize: Int?
    ) -> CGImage? {
        let turns = ((quarterTurns % 4) + 4) % 4
        // 0 度且未要求限尺寸时才可直接复用原图；否则仍要进入下面的缩放路径，
        // 保证 rotatedPreview 的“最长边不超过 maxPixelSize”契约始终成立。
        if turns == 0 {
            guard let maxPixelSize, max(image.width, image.height) > maxPixelSize else {
                return image
            }
        }

        let swapped = turns % 2 == 1
        let width = swapped ? image.height : image.width
        let height = swapped ? image.width : image.height
        guard width > 0, height > 0 else { return nil }

        var outputWidth = width
        var outputHeight = height
        if let maxPixelSize {
            let longest = max(width, height)
            if longest > maxPixelSize {
                let scale = CGFloat(maxPixelSize) / CGFloat(longest)
                outputWidth = max(1, Int((CGFloat(width) * scale).rounded(.down)))
                outputHeight = max(1, Int((CGFloat(height) * scale).rounded(.down)))
            }
        }

        let colorSpace: CGColorSpace
        if let source = image.colorSpace, source.model == .rgb {
            colorSpace = source
        } else {
            colorSpace = CGColorSpaceCreateDeviceRGB()
        }
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        // 先缩放，后续的填充/旋转都用未缩放的输出坐标，避免旋转后留下透明边。
        context.scaleBy(
            x: CGFloat(outputWidth) / CGFloat(width),
            y: CGFloat(outputHeight) / CGFloat(height)
        )
        if let background {
            context.setFillColor(background)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
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

        let targetDimension = saveTargetDimension(
            width: pixelWidth,
            height: pixelHeight,
            maxDimension: maxDimension
        )
        if targetDimension < maxDimension {
            Log.notice(
                .thumbnail,
                "旋转保存按内存上限下采样 \(pixelWidth)x\(pixelHeight) -> 最长边\(targetDimension)px"
            )
        }

        let background: CGColor? = type == .png
            ? nil
            : CGColor(gray: 1, alpha: 1)
        // 解码图在 helper 返回时释放，编码阶段只保留旋转后的目标位图。
        let rotated = try decodeAndRotate(
            source: source,
            targetDimension: targetDimension,
            quarterTurns: quarterTurns,
            background: background
        )

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

    /// 同时受最长边和总像素数约束；普通 12MP/24MP 照片不会被缩小。
    static func saveTargetDimension(
        width: Int,
        height: Int,
        maxDimension: Int
    ) -> Int {
        var scale = min(1, Double(maxSavePixelSize) / Double(maxDimension))
        let pixelCount = Double(width) * Double(height)
        if pixelCount > Double(maxSavePixelCount) {
            scale = min(scale, (Double(maxSavePixelCount) / pixelCount).squareRoot())
        }
        return max(1, Int((Double(maxDimension) * scale).rounded(.down)))
    }

    private static func decodeAndRotate(
        source: CGImageSource,
        targetDimension: Int,
        quarterTurns: Int,
        background: CGColor?
    ) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: targetDimension,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: false,
        ]
        guard let upright = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw ImageEncoderError.decodeFailed
        }
        guard let rotated = rotate(
            upright,
            quarterTurns: quarterTurns,
            background: background
        ) else {
            throw ImageEncoderError.encodeFailed
        }
        return rotated
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
