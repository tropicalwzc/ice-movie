import DemuxKit
import Foundation
import IceCore
import RenderKit
import SubtitleKit

/// 字幕渲染自检：本地视频 + 本地字幕文件，验证按时间出字幕。
enum SubtitleOverlayTest {
    static func run(video: String, subtitle: String, format: String, seconds: Double) async {
        do {
            let text = try String(contentsOfFile: subtitle, encoding: .utf8)
            let subtitleFormat: SubtitleFormat = format == "ass" ? .ass : .srt
            let cues = SubtitleParser.parse(text, format: subtitleFormat)
            let timeline = SubtitleTimeline(cues: cues)
            let reader = try MediaReader.open(path: video)
            let engine = try PlaybackEngine(reader: reader)

            await MainActor.run {
                VideoTestSession.shared.engine = engine
                VideoTestSession.shared.label = (video as NSString).lastPathComponent
                VideoTestSession.shared.subtitle = timeline
            }
            try? await Task.sleep(nanoseconds: 900_000_000)
            engine.play()
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))

            let active = timeline.active(at: engine.clock.currentTime).count
            Log.info(
                .subtitle,
                "SUBTITLE TEST 结果 文件=\(subtitle) 行数=\(cues.count) "
                    + "当前=\(active) 时间=\(String(format: "%.2f", engine.clock.currentTime))s "
                    + "首条=\(String(format: "%.2f", cues.first?.start ?? -1))s"
            )
            engine.stop()
        } catch {
            Log.error(.subtitle, "SUBTITLE TEST 失败：\(error.localizedDescription)")
        }
    }
}
