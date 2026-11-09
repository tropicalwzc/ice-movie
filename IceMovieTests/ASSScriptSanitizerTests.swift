import DemuxKit
import SubtitleKit
import XCTest

final class ASSScriptSanitizerTests: XCTestCase {
    private func makeHeavyScript() -> String {
        var lines = [
            "[Script Info]",
            "ScriptType: v4.00+",
            "PlayResX: 1920",
            "PlayResY: 1080",
            "[V4+ Styles]",
            "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding",
            "Style: CHI,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,20,1",
            "Style: OP 1 jpn,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,20,1",
            "[Events]",
            "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
        ]
        for index in 0..<6_000 {
            let time = String(format: "0:00:%02d.00", (index / 100) % 60)
            lines.append(
                "Dialogue: 1,\(time),\(time),OP 1 jpn,,0,0,0,fx,{\\p1}m 0 0 l 100 0 100 10 0 10"
            )
        }
        for index in 0..<20 {
            lines.append(
                "Dialogue: 0,0:02:\(String(format: "%02d", index)).00,0:02:\(String(format: "%02d", index + 1)).00,CHI,,0,0,0,,第\(index)句对白"
            )
        }
        return lines.joined(separator: "\n")
    }

    func testHeavyScriptKeepsDialogueOnly() {
        let result = ASSScriptSanitizer.sanitizeIfNeeded(makeHeavyScript())
        XCTAssertTrue(result.applied)
        XCTAssertEqual(result.originalEvents, 6_020)
        XCTAssertEqual(result.keptEvents, 20)
        XCTAssertTrue(result.script.contains("[V4+ Styles]"))
        XCTAssertTrue(result.script.contains("第19句对白"))
        XCTAssertFalse(result.script.contains("\\p1"))
        XCTAssertFalse(result.script.contains(",OP 1 jpn,"))
    }

    func testNormalScriptNotTouched() {
        let normal = [
            "[Script Info]",
            "ScriptType: v4.00+",
            "[Events]",
            "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
            "Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,普通字幕",
        ].joined(separator: "\n")
        let result = ASSScriptSanitizer.sanitizeIfNeeded(normal)
        XCTAssertFalse(result.applied)
        XCTAssertEqual(result.script, normal)
    }

    func testAprilRealHeavyScript() throws {
        let path = "/private/tmp/recentw/四月/[Haruhana] Shigatsu wa Kimi no Uso [01][HEVC-10bit FLAC][CHS_CHT_JPN].mkv"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("四月样本未挂载")
        }
        let reader = try MediaReader.open(path: path)
        let script = try reader.readSubtitleScript(streamIndex: 2)
        reader.close()
        let result = ASSScriptSanitizer.sanitizeIfNeeded(script)
        XCTAssertTrue(result.applied, "170k 事件的特效字幕应触发降级")
        XCTAssertLessThan(result.keptEvents, 2_000)
        let cues = SubtitleParser.parse(result.script, format: .ass)
        XCTAssertGreaterThan(cues.count, 100)
        XCTAssertLessThan(cues.count, 2_000)
    }
}
