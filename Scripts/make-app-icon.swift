import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size: CGFloat = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: Int(size),
    height: Int(size),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    fatalError("context")
}


// 背景：深夜蓝到冰青的对角渐变
let background = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 0.02, green: 0.07, blue: 0.16, alpha: 1),
        CGColor(red: 0.04, green: 0.18, blue: 0.32, alpha: 1),
        CGColor(red: 0.05, green: 0.36, blue: 0.48, alpha: 1),
    ] as CFArray,
    locations: [0, 0.55, 1]
)!
context.drawLinearGradient(
    background,
    start: CGPoint(x: 120, y: 940),
    end: CGPoint(x: 940, y: 80),
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
)

// 中央冷光
let glow = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 0.55, green: 0.95, blue: 1.0, alpha: 0.55),
        CGColor(red: 0.18, green: 0.55, blue: 0.75, alpha: 0.0),
    ] as CFArray,
    locations: [0, 1]
)!
context.drawRadialGradient(
    glow,
    startCenter: CGPoint(x: 520, y: 560),
    startRadius: 20,
    endCenter: CGPoint(x: 520, y: 560),
    endRadius: 470,
    options: []
)

// 背景冰裂纹
context.saveGState()
context.setLineCap(.round)
let cracks: [(CGPoint, CGPoint, CGFloat)] = [
    (CGPoint(x: 60, y: 780), CGPoint(x: 250, y: 690), 2.5),
    (CGPoint(x: 250, y: 690), CGPoint(x: 330, y: 760), 1.8),
    (CGPoint(x: 790, y: 250), CGPoint(x: 900, y: 160), 2.2),
    (CGPoint(x: 860, y: 840), CGPoint(x: 760, y: 740), 1.6),
]
for (a, b, width) in cracks {
    context.setStrokeColor(CGColor(red: 0.75, green: 0.96, blue: 1, alpha: 0.14))
    context.setLineWidth(width)
    context.move(to: a)
    context.addLine(to: b)
    context.strokePath()
}
context.restoreGState()

// 六边形冰晶环
func hexagon(center: CGPoint, radius: CGFloat, rotation: CGFloat) -> CGPath {
    let path = CGMutablePath()
    for index in 0..<6 {
        let angle = rotation + CGFloat(index) * .pi / 3
        let point = CGPoint(
            x: center.x + cos(angle) * radius,
            y: center.y + sin(angle) * radius
        )
        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

let center = CGPoint(x: 512, y: 512)
context.saveGState()
context.setStrokeColor(CGColor(red: 0.72, green: 0.95, blue: 1, alpha: 0.28))
context.setLineWidth(10)
context.addPath(hexagon(center: center, radius: 348, rotation: .pi / 6))
context.strokePath()
context.setStrokeColor(CGColor(red: 0.72, green: 0.95, blue: 1, alpha: 0.10))
context.setLineWidth(2)
context.addPath(hexagon(center: center, radius: 372, rotation: .pi / 6))
context.strokePath()
context.restoreGState()

// 雪花短枝
context.saveGState()
context.setLineCap(.round)
for index in 0..<6 {
    let angle = CGFloat(index) * .pi / 3 + .pi / 6
    let base = CGPoint(
        x: center.x + cos(angle) * 300,
        y: center.y + sin(angle) * 300
    )
    let tip = CGPoint(
        x: center.x + cos(angle) * 360,
        y: center.y + sin(angle) * 360
    )
    context.setStrokeColor(CGColor(red: 0.78, green: 0.97, blue: 1, alpha: 0.32))
    context.setLineWidth(7)
    context.move(to: base)
    context.addLine(to: tip)
    context.strokePath()
}
context.restoreGState()

// 播放三角：冰晶切面
let a = CGPoint(x: 408, y: 316)
let b = CGPoint(x: 408, y: 708)
let c = CGPoint(x: 742, y: 512)
let mid = CGPoint(x: (a.x + c.x) / 2, y: (a.y + c.y) / 2)

func triangle(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, color: CGColor) {
    context.setFillColor(color)
    context.move(to: p1)
    context.addLine(to: p2)
    context.addLine(to: p3)
    context.closePath()
    context.fillPath()
}

context.saveGState()
context.setShadow(offset: .zero, blur: 46, color: CGColor(red: 0.45, green: 0.95, blue: 1, alpha: 0.75))
// 外轮廓微光
context.setFillColor(CGColor(red: 0.86, green: 0.98, blue: 1, alpha: 1))
let outer = CGMutablePath()
outer.move(to: CGPoint(x: a.x - 6, y: a.y - 6))
outer.addLine(to: b)
outer.addLine(to: CGPoint(x: c.x + 4, y: c.y))
outer.closeSubpath()
context.addPath(outer)
context.fillPath()
context.restoreGState()

// 主体两个切面
triangle(a, b, c, color: CGColor(red: 0.92, green: 0.99, blue: 1, alpha: 1))
triangle(a, c, mid, color: CGColor(red: 0.70, green: 0.92, blue: 1, alpha: 1))
triangle(b, c, mid, color: CGColor(red: 0.82, green: 0.97, blue: 1, alpha: 1))

// 高光棱线
context.saveGState()
context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.55))
context.setLineWidth(4)
context.setLineCap(.round)
context.move(to: a)
context.addLine(to: c)
context.strokePath()
context.setStrokeColor(CGColor(red: 0.25, green: 0.65, blue: 0.85, alpha: 0.22))
context.setLineWidth(3)
context.move(to: a)
context.addLine(to: mid)
context.strokePath()
context.restoreGState()

// 星芒
func sparkle(_ p: CGPoint, radius: CGFloat, alpha: CGFloat) {
    context.saveGState()
    context.setFillColor(CGColor(red: 0.88, green: 0.99, blue: 1, alpha: alpha))
    let path = CGMutablePath()
    let thin = radius * 0.18
    path.move(to: CGPoint(x: p.x, y: p.y + radius))
    path.addQuadCurve(
        to: CGPoint(x: p.x + radius, y: p.y),
        control: CGPoint(x: p.x + thin, y: p.y + thin)
    )
    path.addQuadCurve(
        to: CGPoint(x: p.x, y: p.y - radius),
        control: CGPoint(x: p.x + thin, y: p.y - thin)
    )
    path.addQuadCurve(
        to: CGPoint(x: p.x - radius, y: p.y),
        control: CGPoint(x: p.x - thin, y: p.y - thin)
    )
    path.addQuadCurve(
        to: CGPoint(x: p.x, y: p.y + radius),
        control: CGPoint(x: p.x - thin, y: p.y + thin)
    )
    context.addPath(path)
    context.fillPath()
    context.restoreGState()
}

sparkle(CGPoint(x: 238, y: 742), radius: 34, alpha: 0.9)
sparkle(CGPoint(x: 790, y: 284), radius: 26, alpha: 0.75)
sparkle(CGPoint(x: 754, y: 786), radius: 18, alpha: 0.55)
sparkle(CGPoint(x: 296, y: 238), radius: 15, alpha: 0.5)

guard let image = context.makeImage() else { fatalError("image") }
let output = URL(fileURLWithPath: CommandLine.arguments[1])
guard let destination = CGImageDestinationCreateWithURL(
    output as CFURL,
    UTType.png.identifier as CFString,
    1,
    nil
) else {
    fatalError("destination")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("finalize") }
print("wrote \(output.path)")
