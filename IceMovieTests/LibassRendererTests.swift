import CoreGraphics
import DemuxKit
import IceCore
import ImageIO
import SubtitleKit
import UniformTypeIdentifiers
import XCTest

final class LibassRendererTests: XCTestCase {
    private let subtitleDirectory =
        "/private/tmp/animi/强风吹拂/[Kamigami] Kaze ga Tsuyoku Fuiteiru - Sub"

    func testRendersChineseDialogueAndPositionedOP() throws {
        let path = subtitleDirectory + "/Kaze ga Tsuyoku Fuiteiru 01.cht.ass"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("ASS 样本缺失")
        }
        let script = try String(contentsOfFile: path, encoding: .utf8)
        guard let renderer = LibassSubtitleRenderer(
            script: script,
            fonts: [],
            fontScale: 1,
            bottomMargin: 100
        ) else {
            return XCTFail("libass 渲染器初始化失败")
        }

        let dialogue = try XCTUnwrap(renderer.image(at: 7), "7 秒处应有中文字幕")
        XCTAssertEqual(dialogue.width, LibassSubtitleRenderer.frameWidth)
        XCTAssertEqual(dialogue.height, LibassSubtitleRenderer.frameHeight)
        try writePNG(dialogue, to: "/private/tmp/libass-dialogue-7s.png")

        let op = try XCTUnwrap(renderer.image(at: 76), "76 秒处应有带定位的 OP 字幕")
        try writePNG(op, to: "/private/tmp/libass-op-76s.png")
        Log.info(.subtitle, "libass 测试渲染完成，输出 /private/tmp/libass-dialogue-7s.png 与 /private/tmp/libass-op-76s.png")
    }

    func testContainerFontAttachments() throws {
        let path = "/private/tmp/animi/强风吹拂/[Kamigami] Kaze ga Tsuyoku Fuiteiru - 01 [BD 1080p x265 Ma10p AAC].mkv"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("MKV 样本缺失")
        }
        let reader = try MediaReader.open(path: path)
        defer { reader.close() }
        let fonts = reader.attachments().filter(\.isFont)
        for font in fonts {
            XCTAssertFalse(font.name.isEmpty)
            XCTAssertGreaterThan(font.data.count, 0)
        }
        Log.info(.subtitle, "容器字体附件 \(fonts.count) 个")
    }

    private func writePNG(_ image: CGImage, to path: String) throws {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let destination = CGImageDestinationCreateWithURL(
            url,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return XCTFail("无法创建 PNG 输出")
        }
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
