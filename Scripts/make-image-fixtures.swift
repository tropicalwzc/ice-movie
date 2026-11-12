import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let out = "IceMovieTests/Fixtures/ImageGallery"

func makeImage(width: Int, height: Int, alpha: Bool, fill: CGColor, inset: CGFloat) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = alpha
        ? CGImageAlphaInfo.premultipliedLast.rawValue
        : CGImageAlphaInfo.noneSkipLast.rawValue
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    )!
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    if alpha {
        context.clear(bounds)
    } else {
        context.setFillColor(CGColor(red: 0.08, green: 0.16, blue: 0.24, alpha: 1))
        context.fill(bounds)
    }
    context.setFillColor(fill)
    context.fill(bounds.insetBy(dx: inset, dy: inset))
    return context.makeImage()!
}

func write(_ image: CGImage, name: String, type: UTType, properties: [CFString: Any]? = nil) {
    let url = URL(fileURLWithPath: "\(out)/\(name)")
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        type.identifier as CFString,
        1,
        nil
    ) else {
        fatalError("无法创建 \(name)")
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary?)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("无法写入 \(name)")
    }
}

try FileManager.default.createDirectory(
    at: URL(fileURLWithPath: out),
    withIntermediateDirectories: true
)

write(
    makeImage(width: 64, height: 64, alpha: true, fill: CGColor(red: 0.95, green: 0.35, blue: 0.2, alpha: 0.8), inset: 14),
    name: "sample-alpha.png",
    type: .png
)

write(
    makeImage(width: 96, height: 48, alpha: false, fill: CGColor(red: 0.2, green: 0.7, blue: 0.9, alpha: 1), inset: 6),
    name: "sample-landscape.png",
    type: .png
)

write(
    makeImage(width: 48, height: 96, alpha: false, fill: CGColor(red: 0.9, green: 0.6, blue: 0.2, alpha: 1), inset: 6),
    name: "sample-portrait.png",
    type: .png
)

write(
    makeImage(width: 80, height: 40, alpha: false, fill: CGColor(red: 0.7, green: 0.2, blue: 0.6, alpha: 1), inset: 5),
    name: "sample-orientation.jpg",
    type: .jpeg,
    properties: [kCGImagePropertyOrientation: 6]
)

print("image fixtures written")
