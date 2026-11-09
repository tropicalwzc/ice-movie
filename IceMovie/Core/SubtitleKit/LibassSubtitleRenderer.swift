import CLibass
import CoreGraphics
import Foundation
import IceCore

/// 一条可供 libass 使用的字体。容器附件与内置字体都走这里。
public struct SubtitleFont: Sendable, Equatable {
    public let name: String
    public let data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }

    /// 内置中文字体兜底（OFL 许可的 Noto Sans CJK SC）。
    public static let builtinCJK: SubtitleFont? = {
        guard let url = Bundle.main.url(
            forResource: "NotoSansCJKsc-Regular",
            withExtension: "otf"
        ), let data = try? Data(contentsOf: url) else {
            return nil
        }
        return SubtitleFont(name: "NotoSansCJKsc-Regular.otf", data: data)
    }()
}

/// libass 渲染器：把 ASS/SSA 脚本按时间渲染成透明位图。
///
/// 使用 CoreText 字体提供器解析 iOS 系统字体（苹方/冬青黑体等），
/// 容器内附件字体先通过 `ass_add_font` 注册，会优先参与匹配。
public final class LibassSubtitleRenderer {
    public static let frameWidth = 1280
    public static let frameHeight = 720

    private let library: OpaquePointer
    private let renderer: OpaquePointer
    private let track: UnsafeMutablePointer<ASS_Track>
    private var lastTime: Double = -.infinity
    private var cachedImage: CGImage?
    private var cachedDetect: Int32 = 0

    /// 返回 nil 表示脚本无法解析或渲染器初始化失败，调用方应回退到系统文字渲染。
    public init?(
        script: String,
        fonts: [SubtitleFont],
        fontScale: Double = 1,
        bottomMargin: Int = 0
    ) {
        guard let library = ass_library_init() else { return nil }
        self.library = library

        for font in ([SubtitleFont.builtinCJK].compactMap { $0 } + fonts) {
            font.data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                font.name.withCString { name in
                    ass_add_font(
                        library,
                        name,
                        base.assumingMemoryBound(to: CChar.self),
                        Int32(font.data.count)
                    )
                }
            }
        }

        var bytes = Array(script.utf8).map { CChar(bitPattern: $0) }
        guard let track = bytes.withUnsafeMutableBufferPointer({ buffer -> UnsafeMutablePointer<ASS_Track>? in
            guard let base = buffer.baseAddress else { return nil }
            return ass_read_memory(
                library,
                base,
                buffer.count,
                nil
            )
        }) else {
            ass_library_done(library)
            return nil
        }
        self.track = track

        guard let renderer = ass_renderer_init(library) else {
            ass_free_track(track)
            ass_library_done(library)
            return nil
        }
        self.renderer = renderer

        ass_set_frame_size(renderer, Int32(Self.frameWidth), Int32(Self.frameHeight))
        ass_set_fonts(
            renderer,
            nil,
            "Noto Sans CJK SC",
            // ASS_FONTPROVIDER_CORETEXT：系统字体兜底；中文再叠加内置 Noto Sans CJK。
            2,
            nil,
            1
        )
        ass_set_font_scale(renderer, fontScale)
        if bottomMargin > 0 {
            ass_set_margins(renderer, 0, Int32(bottomMargin), 0, 0)
            ass_set_use_margins(renderer, 1)
        }
        Log.info(
            .subtitle,
            "libass 渲染器就绪 字体=\(fonts.count) 字号比例=\(String(format: "%.2f", fontScale)) "
                + "底部边距=\(bottomMargin)px"
        )
    }

    deinit {
        ass_renderer_done(renderer)
        ass_free_track(track)
        ass_library_done(library)
    }

    public func setFontScale(_ scale: Double) {
        ass_set_font_scale(renderer, min(max(scale, 0.5), 2.0))
        invalidate()
    }

    public func setBottomMargin(_ pixels: Int) {
        ass_set_margins(renderer, 0, Int32(max(0, pixels)), 0, 0)
        ass_set_use_margins(renderer, pixels > 0 ? 1 : 0)
        invalidate()
    }

    public func invalidate() {
        lastTime = -.infinity
        cachedImage = nil
    }

    /// 取指定媒体时间（秒）的画面。相同时间点复用缓存。
    public func image(at seconds: Double) -> CGImage? {
        let clamped = max(0, seconds)
        if abs(clamped - lastTime) < 0.03, cachedDetect == 0 {
            return cachedImage
        }
        lastTime = clamped
        var detect: Int32 = 0
        let start = ProcessInfo.processInfo.systemUptime
        let list = ass_render_frame(renderer, track, Int64(clamped * 1000), &detect)
        cachedDetect = detect
        cachedImage = Self.compose(list)
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        if elapsed > 8 {
            Log.debug(.subtitle, "libass 渲染耗时 \(Int(elapsed))ms 时间=\(String(format: "%.2f", clamped))s")
        }
        return cachedImage
    }

    private static func compose(_ list: UnsafeMutablePointer<ASS_Image>?) -> CGImage? {
        guard let list else { return nil }
        let width = frameWidth
        let height = frameHeight
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        var image: UnsafeMutablePointer<ASS_Image>? = list
        while let current = image {
            let entry = current.pointee
            if let bitmap = entry.bitmap, entry.w > 0, entry.h > 0 {
                let color = entry.color
                let alpha = 255 - Int(color & 0xFF)
                let red = Int((color >> 24) & 0xFF)
                let green = Int((color >> 16) & 0xFF)
                let blue = Int((color >> 8) & 0xFF)
                for y in 0..<Int(entry.h) {
                    let destinationY = Int(entry.dst_y) + y
                    guard destinationY >= 0, destinationY < height else { continue }
                    let row = bitmap.advanced(by: y * Int(entry.stride))
                    for x in 0..<Int(entry.w) {
                        let destinationX = Int(entry.dst_x) + x
                        guard destinationX >= 0, destinationX < width else { continue }
                        let mask = Int(row[x]) * alpha / 255
                        guard mask > 0 else { continue }
                        let index = (destinationY * width + destinationX) * 4
                        let inverse = 255 - mask
                        pixels[index] = UInt8((red * mask + Int(pixels[index]) * inverse) / 255)
                        pixels[index + 1] = UInt8((green * mask + Int(pixels[index + 1]) * inverse) / 255)
                        pixels[index + 2] = UInt8((blue * mask + Int(pixels[index + 2]) * inverse) / 255)
                        pixels[index + 3] = UInt8(mask + Int(pixels[index + 3]) * inverse / 255)
                    }
                }
            }
            image = entry.next
        }

        guard pixels.contains(where: { $0 != 0 }) else { return nil }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
