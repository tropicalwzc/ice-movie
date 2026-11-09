import DemuxKit
import Foundation
import IceCore
import RenderKit

/// 连续拖动自检（任务 6.3）：快速发起一串反向跳转，只有最后一次应当落地。
enum SeekBurstTest {
    static func run(path: String) async {
        do {
            let reader = try MediaReader.open(path: path)
            let engine = try PlaybackEngine(reader: reader)
            await MainActor.run {
                VideoTestSession.shared.engine = engine
                VideoTestSession.shared.label = (path as NSString).lastPathComponent
            }
            try? await Task.sleep(nanoseconds: 900_000_000)
            engine.play()
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            let targets: [Double] = [600, 540, 480, 420, 360, 300, 240, 180, 120, 60]
            let began = ProcessInfo.processInfo.systemUptime
            for target in targets {
                engine.seek(to: target)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            Log.info(.render, "SEEK BURST 已发起 \(targets.count) 次反向跳转，最后一次=60.00s")

            try? await Task.sleep(nanoseconds: 2_500_000_000)
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            let stats = engine.statistics
            let position = engine.clock.currentTime
            Log.info(
                .render,
                "SEEK BURST 结果 位置=\(String(format: "%.2f", position))s "
                    + "预期≈\(String(format: "%.2f", 60 + elapsed))s "
                    + "丢弃=\(stats.droppedSeeks) 执行=\(stats.seekCount) "
                    + "首帧偏差=\(String(format: "%.2f", stats.lastSeekDrift))s "
                    + "结论=\(abs(position - (60 + elapsed)) < 2 ? "通过" : "失败")"
            )
            engine.stop()
        } catch {
            Log.error(.render, "SEEK BURST 失败：\(error.localizedDescription)")
        }
    }
}
