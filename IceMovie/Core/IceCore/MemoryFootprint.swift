import Darwin
import Foundation

/// 进程物理内存占用（`phys_footprint`）。
///
/// `phys_footprint` 是系统判断内存压力与 jetsam 的依据，含脏页与压缩内存，
/// 比 `resident_size` 更接近“这个进程现在吃掉多少内存”。播放器的状态条与
/// 压测采样都读它：跨会话泄漏（引擎/显示层没释放）在播放指标上完全看不出来，
/// 只有内存曲线会露馅，所以要把这条线一直摆在眼前。
public enum MemoryFootprint {

    /// 当前进程物理内存占用（MB）。读取失败返回 -1。
    public static var currentMB: Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        let megabytes = Double(info.phys_footprint) / 1_048_576
        peakBox.observe(megabytes)
        return megabytes
    }

    /// 自上次 `resetPeak()` 以来的峰值（MB）。读取不会刷新峰值。
    public static var peakMB: Double { peakBox.value }

    /// 会话开始时调用，把峰值基线归零，便于按文件对比泄漏。
    public static func resetPeak() { peakBox.reset() }

    /// 展示用格式：不足 1GB 用 MB，超过用 GB；读取失败显示 `--`。
    public static func label(_ megabytes: Double) -> String {
        guard megabytes >= 0 else { return "--" }
        if megabytes >= 1024 {
            return String(format: "%.2f GB", megabytes / 1024)
        }
        return String(format: "%.0f MB", megabytes)
    }

    /// 内存压力分级，状态条据此变色提示。
    public enum Level: Sendable {
        case normal
        case warning
        case critical
    }

    /// 判定当前内存压力。
    ///
    /// 两个维度都要看：绝对值高（进程历史累积）与相对进入时增长（本会话泄漏）。
    /// 阈值按真机实测留余量——4K HEVC 会话峰值约 300–500MB 属正常，
    /// 跨越 700MB 或单会话涨过 250MB 就已经不像正常播放了。
    ///
    /// - Parameter baselineMB: 进入播放页时的占用；传 nil 只看绝对值。
    public static func level(currentMB: Double, baselineMB: Double?) -> Level {
        guard currentMB >= 0 else { return .normal }
        let grown = baselineMB.map { max(0, currentMB - $0) } ?? 0
        if currentMB >= 1200 || grown >= 500 { return .critical }
        if currentMB >= 700 || grown >= 250 { return .warning }
        return .normal
    }

    private static let peakBox = PeakBox()

    /// 峰值只由 `currentMB` 的读取推动，锁内做一次比较即可。
    private final class PeakBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Double = 0

        var value: Double {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func observe(_ megabytes: Double) {
            guard megabytes >= 0 else { return }
            lock.lock()
            if megabytes > stored { stored = megabytes }
            lock.unlock()
        }

        func reset() {
            lock.lock()
            stored = 0
            lock.unlock()
        }
    }
}

/// 进程 CPU 使用率（单核百分比，100 = 占满一个核心）。
///
/// 读取 `TASK_THREAD_TIMES_INFO` 的 user+system 时间，除以两次采样的间隔。
/// 播放器状态条和压测采样都读它：EOF 后泵线程空转、解码线程失控这类问题
/// 在帧率/同步指标上不一定可见，但 CPU 会直接顶到 100%。
public enum CPUUsage {
    private static let sampler = CPUSampler()

    /// 自上次调用以来的 CPU 使用率；100 表示占满一个核心。
    /// 读取失败返回 -1。
    public static func currentPercent() -> Double {
        var info = task_thread_times_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_thread_times_info>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_THREAD_TIMES_INFO),
                    $0,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return -1 }

        let user = Double(info.user_time.seconds)
            + Double(info.user_time.microseconds) / 1_000_000
        let system = Double(info.system_time.seconds)
            + Double(info.system_time.microseconds) / 1_000_000
        return sampler.next(
            user: user,
            system: system,
            now: ProcessInfo.processInfo.systemUptime
        )
    }

    /// 展示用格式：单核百分比。
    public static func label(_ percent: Double) -> String {
        guard percent >= 0 else { return "--" }
        return String(format: "%.0f%%", percent)
    }
}

private final class CPUSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var lastUserSeconds: Double = 0
    private var lastSystemSeconds: Double = 0
    private var lastSampleTime: Double = 0
    private var lastValue: Double = 0

    func next(user: Double, system: Double, now: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard lastSampleTime > 0 else {
            lastUserSeconds = user
            lastSystemSeconds = system
            lastSampleTime = now
            return 0
        }
        let elapsed = now - lastSampleTime
        // 状态条可能每秒多次刷新；低于 250ms 的重复调用沿用上次值，
        // 避免把极短窗口的抖动放大成 0%/100% 闪烁。
        if elapsed < 0.25 { return lastValue }
        let delta = (user + system) - (lastUserSeconds + lastSystemSeconds)
        lastUserSeconds = user
        lastSystemSeconds = system
        lastSampleTime = now
        guard elapsed > 0, delta >= 0 else { return lastValue }
        let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
        lastValue = min(100 * cores, max(0, 100 * delta / elapsed))
        return lastValue
    }
}
