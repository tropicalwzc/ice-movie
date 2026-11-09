import DemuxKit
import Foundation
import IceCore
import RenderKit

/// 音频通路自检入口（任务 4.3 / 4.4 的可自动化部分）。
///
/// - `-audioTest <本地路径> [-audioTestSeconds N]`：循环播放至 N 秒，输出连续性统计
/// - `-audioPauseTest <本地路径>`：播放 5 秒 → 暂停 30 秒 → 恢复，校验时钟不跳变
enum AudioSelfTest {
    static func run(path: String, targetSeconds: Double) async {
        do {
            let reader = try MediaReader.open(path: path)
            let engine = try PlaybackEngine(reader: reader)
            let startedAt = ProcessInfo.processInfo.systemUptime
            var loops = 0

            engine.play()
            while ProcessInfo.processInfo.systemUptime - startedAt < targetSeconds {
                let remaining = targetSeconds - (ProcessInfo.processInfo.systemUptime - startedAt)
                let stats = engine.waitForFinish(timeout: min(reader.duration + 30, remaining + 60))
                if let failure = stats.failure {
                    Log.error(.render, "AUDIO TEST 失败：\(failure)")
                    return
                }
                guard stats.drained else {
                    Log.error(.render, "AUDIO TEST 超时未播完 已解码=\(fmt(stats.decodedSeconds))s")
                    return
                }
                loops += 1
                Log.info(
                    .render,
                    "AUDIO TEST 第 \(loops) 遍完成 已解码=\(fmt(stats.decodedSeconds))s "
                        + "滞后=\(stats.underruns) 启动=\(stats.startupMilliseconds)ms"
                )
                guard ProcessInfo.processInfo.systemUptime - startedAt < targetSeconds else { break }
                engine.seek(to: 0)
                await sleep(0.3)
                engine.play()
            }

            let wall = ProcessInfo.processInfo.systemUptime - startedAt
            let stats = engine.statistics
            let coverage = wall > 0 ? stats.decodedSeconds / wall : 0
            Log.info(
                .render,
                "AUDIO TEST 结果 文件=\((path as NSString).lastPathComponent) codec=\(engine.audioCodecName) "
                    + "循环=\(loops) 墙钟=\(fmt(wall))s 解码=\(fmt(stats.decodedSeconds))s "
                    + "覆盖率=\(String(format: "%.3f", coverage)) 供给滞后=\(stats.underruns) "
                    + "时钟校正=\(stats.clockCorrections) 最大偏差=\(fmt(stats.maxDrift))s "
                    + "启动=\(stats.startupMilliseconds)ms 结论=\(verdict(stats, coverage: coverage))"
            )
            engine.stop()
        } catch {
            Log.error(.render, "AUDIO TEST 失败：\(error.localizedDescription)")
        }
    }

    /// 暂停 30 秒后恢复：时钟必须停在原处，恢复后从同一点继续，不追赶。
    static func runPauseTest(path: String) async {
        do {
            let reader = try MediaReader.open(path: path)
            let engine = try PlaybackEngine(reader: reader)
            engine.play()

            let deadline = Date().addingTimeInterval(15)
            while engine.clock.currentTime < 5, Date() < deadline {
                await sleep(0.1)
            }
            let before = engine.clock.currentTime
            engine.pause()
            let pausedAt = ProcessInfo.processInfo.systemUptime

            await sleep(30)
            let afterPause = engine.clock.currentTime
            let pauseDrift = abs(afterPause - before)
            let pausedWall = ProcessInfo.processInfo.systemUptime - pausedAt

            engine.play()
            let resumedAt = ProcessInfo.processInfo.systemUptime
            await sleep(3)
            let afterResume = engine.clock.currentTime
            let advanced = afterResume - afterPause
            let resumeWall = ProcessInfo.processInfo.systemUptime - resumedAt

            let pauseOK = pauseDrift < 0.05
            let resumeOK = abs(advanced - resumeWall) < 0.3
            Log.info(
                .render,
                "AUDIO TEST 暂停恢复 暂停前=\(fmt(before))s 暂停后=\(fmt(afterPause))s "
                    + "墙钟=\(fmt(pausedWall))s 跳变=\(fmt(pauseDrift))s "
                    + "恢复前进=\(fmt(advanced))s 实际=\(fmt(resumeWall))s "
                    + "结论=\(pauseOK && resumeOK ? "通过" : "失败")"
            )
            engine.stop()
        } catch {
            Log.error(.render, "AUDIO TEST 暂停恢复失败：\(error.localizedDescription)")
        }
    }

    private static func verdict(_ stats: PlaybackEngine.Statistics, coverage: Double) -> String {
        if stats.underruns > 0 { return "有供给滞后" }
        if coverage < 0.98 { return "覆盖率不足" }
        if stats.maxDrift > 0.25 { return "时钟偏差过大" }
        return "通过"
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
