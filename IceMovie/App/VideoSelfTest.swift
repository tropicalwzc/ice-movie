import DemuxKit
import Foundation
import IceCore
import RenderKit
import SMBSession

/// 视频通路自检（任务 5.1–5.4 的可自动化部分）。
///
/// - `-videoTest <本地路径> [-videoTestSeconds N] [-videoPauseAfter S]`：本地文件
/// - `-videoSmb <共享内路径> [-videoTestSeconds N]`：配合 `-smbHost/-smbShare/-smbUser/-smbPassword`
///   直接从 SMB 读取并播放，验证「不下载到本地」的完整链路
///
/// 与音频自检的区别：长片不可能等到结尾，所以播固定时长后主动采样。
enum VideoSelfTest {
    static func run(path: String, seconds: Double, pauseAfter: Double = 0) async {
        do {
            let reader = try MediaReader.open(path: path)
            await play(
                reader: reader,
                label: (path as NSString).lastPathComponent,
                seconds: seconds,
                pauseAfter: pauseAfter
            )
        } catch {
            Log.error(.render, "VIDEO TEST 失败：\(error.localizedDescription)")
        }
    }

    static func runOverSMB(
        host: String,
        share: String,
        path: String,
        user: String,
        password: String,
        seconds: Double
    ) async {
        let client = SMBClient()
        do {
            let began = ProcessInfo.processInfo.systemUptime
            try await client.connect(host: host, user: user, password: password, share: share)
            let source = try await client.openByteSource(path: path)
            let reader = try MediaReader.open(source: source, label: "smb://\(host)/\(share)")
            let openMilliseconds = Int((ProcessInfo.processInfo.systemUptime - began) * 1000)
            Log.info(.smb, "SMB 视频就绪 连接+打开=\(openMilliseconds)ms")
            await play(
                reader: reader,
                label: (path as NSString).lastPathComponent,
                seconds: seconds,
                pauseAfter: 0
            )
        } catch {
            Log.error(.render, "VIDEO TEST SMB 失败：\(error.localizedDescription)")
        }
        try? await client.disconnect()
    }

    private static func play(
        reader: MediaReader,
        label: String,
        seconds: Double,
        pauseAfter: Double
    ) async {
        do {
            let engine = try PlaybackEngine(reader: reader)
            await MainActor.run {
                VideoTestSession.shared.engine = engine
                VideoTestSession.shared.label = label
            }
            // 等 SwiftUI 建好视图并把显示层绑上。
            try? await Task.sleep(nanoseconds: 900_000_000)

            engine.play()

            if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-videoSeekBefore"),
               ProcessInfo.processInfo.arguments.indices.contains(index + 1),
               let target = Double(ProcessInfo.processInfo.arguments[index + 1]) {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    engine.seek(to: target)
                    Log.info(.render, "自检：起播后定位到 \(target)s")
                }
            }

            if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-videoSimulateFailureAfter"),
               ProcessInfo.processInfo.arguments.indices.contains(index + 1),
               let delay = Double(ProcessInfo.processInfo.arguments[index + 1]) {
                Task {
                    try? await Task.sleep(for: .seconds(delay))
                    await MainActor.run {
                        engine.videoRenderer?.simulateDecodeFailureForTesting()
                    }
                }
            }

            if pauseAfter > 0 {
                try? await Task.sleep(nanoseconds: UInt64(pauseAfter * 1_000_000_000))
                engine.pause()
                let pausedAt = engine.clock.currentTime
                Log.info(.render, "VIDEO PAUSE 已暂停 位置=\(fmt(pausedAt))s")
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                let afterPause = engine.clock.currentTime
                Log.info(
                    .render,
                    "VIDEO PAUSE 暂停 6 秒后 位置=\(fmt(afterPause))s "
                        + "跳变=\(fmt(abs(afterPause - pausedAt)))s"
                )
                engine.play()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                Log.info(.render, "VIDEO PAUSE 恢复后 位置=\(fmt(engine.clock.currentTime))s")
            }

            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))

            let stats = engine.statistics
            let video = engine.videoRenderer?.metrics
            let enqueued = video?.enqueued ?? 0
            Log.info(
                .render,
                "VIDEO TEST 结果 文件=\(label) "
                    + "音频=\(engine.audioCodecName) 视频=\(engine.videoCodecName) "
                    + "播放=\(fmt(seconds))s 位置=\(fmt(engine.clock.currentTime))s "
                    + "视频包=\(stats.videoPackets) 入队=\(enqueued) "
                    + "首帧视频=\(stats.firstVideoMilliseconds)ms 首帧音频=\(stats.startupMilliseconds)ms "
                    + "音频偏差=\(fmt(stats.maxDrift))s 显示偏差=\(fmt(stats.maxVideoOffset))s "
                    + "刷新=\(video?.flushes ?? 0) 重建=\(video?.recoveries ?? 0) "
                    + "结论=\(verdict(stats, enqueued: enqueued))"
            )
            engine.stop()
        } catch {
            Log.error(.render, "VIDEO TEST 失败：\(error.localizedDescription)")
        }
    }

    private static func verdict(_ stats: PlaybackEngine.Statistics, enqueued: Int) -> String {
        if let failure = stats.failure { return "失败：\(failure)" }
        if enqueued < 10 { return "未出帧" }
        if stats.maxVideoOffset > 0.05 { return "显示偏差过大" }
        if stats.maxDrift > 0.05 { return "音频偏差过大" }
        return "通过"
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
