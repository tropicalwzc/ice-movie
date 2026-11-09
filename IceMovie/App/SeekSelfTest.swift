import DemuxKit
import Foundation
import IceCore
import RenderKit

/// 跳转自检（任务 6.1）。
///
/// - `-seekTest <本地路径> [-seekTargets 60,300,600]`：依次跳到指定位置，
///   每次停 2.5 秒，记录出画耗时、预滚帧数与首帧偏差。
enum SeekSelfTest {
    static func run(path: String, targets: [Double]) async {
        do {
            let reader = try MediaReader.open(path: path)
            let engine = try PlaybackEngine(reader: reader)

            await MainActor.run {
                VideoTestSession.shared.engine = engine
                VideoTestSession.shared.label = (path as NSString).lastPathComponent
            }
            try? await Task.sleep(nanoseconds: 900_000_000)
            engine.play()
            try? await Task.sleep(nanoseconds: 3_000_000_000)

            for target in targets {
                engine.seek(to: target)
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                let stats = engine.statistics
                Log.info(
                    .render,
                    "SEEK TEST 目标=\(fmt(target))s 时钟=\(fmt(engine.clock.currentTime))s "
                        + "出画耗时=\(stats.lastSeekLatencyMilliseconds)ms "
                        + "预滚帧=\(stats.lastSeekPrerollFrames) 首帧偏差=\(fmt(stats.lastSeekDrift))s"
                )
            }

            let stats = engine.statistics
            let video = engine.videoRenderer?.metrics
            Log.info(
                .render,
                "SEEK TEST 结果 跳转次数=\(stats.seekCount) 视频包=\(stats.videoPackets) "
                    + "入队=\(video?.enqueued ?? 0) 显示偏差=\(fmt(stats.maxVideoOffset))s "
                    + "刷新=\(video?.flushes ?? 0) 重建=\(video?.recoveries ?? 0)"
            )
            engine.stop()
        } catch {
            Log.error(.render, "SEEK TEST 失败：\(error.localizedDescription)")
        }
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
