import Foundation
import MediaLibraryKit
import SubtitleKit
import XCTest
@testable import IceMovie

final class SubtitleFontPolicyTests: XCTestCase {
    func testMergeKeepsEmbeddedFirstDeduplicatesAndDropsBitmap() {
        let embedded = SubtitleTrack(
            source: .embedded(streamIndex: 2),
            title: "内封简体",
            language: .simplifiedChinese,
            format: .ass
        )
        let externalCHS = SubtitleTrack(
            source: .external(fileName: "ep.chs.ass"),
            title: "外挂简体",
            language: .simplifiedChinese,
            format: .ass
        )
        let externalCHT = SubtitleTrack(
            source: .external(fileName: "ep.cht.ass"),
            title: "外挂繁体",
            language: .traditionalChinese,
            format: .ass
        )
        let externalJPN = SubtitleTrack(
            source: .external(fileName: "ep.jpn.ass"),
            title: "外挂日文",
            language: .japanese,
            format: .ass
        )
        let bitmap = SubtitleTrack(
            source: .external(fileName: "ep.sup"),
            title: "位图",
            language: .simplifiedChinese,
            format: .bitmap
        )

        let merged = mergedSubtitleTracks(
            existing: [embedded],
            incoming: [externalCHS, externalCHS, externalCHT, externalJPN, bitmap]
        )

        XCTAssertEqual(merged.map(\.id), [
            embedded.id, externalCHS.id, externalCHT.id, externalJPN.id,
        ])
    }

    func testExternalASSDropsContainerFonts() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubtitleFontPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 1920
        PlayResY: 1080

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,方正兰亭黑,64,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,1,2,10,10,30,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:00.00,0:00:03.00,Default,,0,0,0,,你好，世界
        """
        try Data(script.utf8).write(to: directory.appendingPathComponent("episode.ass"))
        let entry = MediaEntry(
            path: "episode.mkv",
            name: "episode.mkv",
            isDirectory: false,
            size: 1024,
            modified: Date(timeIntervalSince1970: 100)
        )
        let source = LocalLibrarySource(rootURL: directory)
        let loader = SubtitleLoader(source: source, entry: entry)
        let track = SubtitleTrack(
            source: .external(fileName: "episode.ass"),
            title: "episode.ass",
            language: .simplifiedChinese,
            format: .ass
        )

        let loaded = try await loader.load(track)
        XCTAssertFalse(loaded.timeline.cues.isEmpty)
        XCTAssertTrue(loaded.fonts.isEmpty, "外挂 ASS 不应再读取容器字体附件")
    }
}
