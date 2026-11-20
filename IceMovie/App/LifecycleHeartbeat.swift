import Foundation
import IceCore

/// 进程存活心跳：把「上次进程还活着的时间」持续落盘。
///
/// 用途：排查「播放中退后台，很久之后回来发现 App 重新启动」时，区分三种情况——
/// - 真崩溃：设备系统日志里会出现 .ips（`devicectl` 可直接拉取定位）；
/// - 挂起后被系统回收（最常见却最像闪退）：**不产生任何崩溃日志**，只有
///   「最后心跳 ↔ 下次冷启动」的时间差能证明进程是在后台被收走的，
///   而不是回前台那一刻才挂；
/// - 正常前后台切换：心跳持续，下次回前台不会出现冷启动。
///
/// 前后台切换立即记一次；进程存活期间每 30 秒补记一次（挂起时任务冻结，
/// 恢复后继续，因此心跳始终代表「进程确实活着」的时刻）。
enum LifecycleHeartbeat {
    private static let lastAliveKey = "lifecycle.lastAliveAt"

    /// 冷启动时调用：打印与上次心跳的间隔，再把心跳重置为当前时间。
    /// 间隔超过 1 分钟即说明进程曾被系统回收（或被脚本重装后首启）。
    static func noteLaunchAndLog() {
        let now = Date()
        if let previous = lastAliveAt {
            let gap = now.timeIntervalSince(previous)
            if gap > 60 {
                Log.notice(
                    .app,
                    "冷启动：上次存活 \(stamp(previous))，距今 "
                        + "\(formattedGap(gap))；期间进程曾被系统回收或手动结束（回前台时看到的重启并非当时崩溃）"
                )
            } else {
                Log.info(.app, "冷启动：上次存活 \(stamp(previous))，间隔 \(Int(gap))s")
            }
        } else {
            Log.info(.app, "冷启动：没有历史心跳记录（首次安装或重装）")
        }
        markAlive(now)
    }

    /// 供启动快照（ice-launch.json）附带：上次存活时间与距本次启动的间隔。
    /// 崩溃/回收取证不依赖控制台日志，拉容器即可读。
    static func lastAliveSummary() -> [String: String] {
        guard let previous = lastAliveAt else { return [:] }
        return [
            "lastAliveAt": stamp(previous),
            "lastAliveGapSeconds": String(format: "%.0f", Date().timeIntervalSince(previous)),
        ]
    }

    /// 前后台切换时调用：立即落盘一次。
    static func markAliveNow() {
        markAlive(Date())
    }

    /// 进程存活期间持续补记。
    static func startAliveLoop() {
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                markAliveNow()
            }
        }
    }

    private static var lastAliveAt: Date? {
        UserDefaults.standard.object(forKey: lastAliveKey) as? Date
    }

    private static func markAlive(_ date: Date) {
        UserDefaults.standard.set(date, forKey: lastAliveKey)
    }

    private static func formattedGap(_ seconds: TimeInterval) -> String {
        if seconds >= 3600 {
            return String(format: "%.1f 小时", seconds / 3600)
        }
        return String(format: "%.1f 分钟", seconds / 60)
    }

    private static func stamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
