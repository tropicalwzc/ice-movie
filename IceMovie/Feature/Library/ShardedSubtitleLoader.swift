import DemuxKit
import Foundation
import IceCore
import MediaLibraryKit
import RenderKit
import SubtitleKit

/// 大文件内封字幕的分片加载器。
///
/// 整文件提取在 SMB 上要顺序读完整个 MKV；这里只按播放位置读取前后窗口，
/// 先让当前时间附近有字幕，再在后台预取下一段。窗口内的事件立即转成时间轴，
/// 用系统文字层显示，避免等待整集扫描。
@MainActor
final class ShardedSubtitleLoader {
    private let engine: PlaybackEngine
    private let source: any LibrarySource
    private let entry: MediaEntry
    private let streamIndex: Int
    private let windowSeconds: Double = 60
    private let firstWindowSeconds: Double = 4
    private let secondWindowSeconds: Double = 16
    private let lookbackSeconds: Double = 3
    private let prefetchLeadSeconds: Double = 20

    var onCues: (([SubtitleCue]) -> Void)?
    var onLoadingChange: ((Bool) -> Void)?
    var onError: ((String?) -> Void)?

    private var task: Task<Void, Never>?
    private var cueByKey: [String: SubtitleCue] = [:]
    private var coverageStart: Double = 0
    private var coverageEnd: Double = 0
    private var hasCoverage = false
    private var consecutiveFailures = 0
    private var startPosition: Double?
    private var windowsSinceSeek = 0

    init(
        engine: PlaybackEngine,
        source: any LibrarySource,
        entry: MediaEntry,
        streamIndex: Int
    ) {
        self.engine = engine
        self.source = source
        self.entry = entry
        self.streamIndex = streamIndex
    }

    func start() {
        start(at: engine.clock.currentTime)
    }

    /// 从指定位置开始加载，续播时直接读目标时间附近，不再先扫 0 秒。
    func start(at position: Double) {
        startPosition = position
        windowsSinceSeek = 0
        task?.cancel()
        task = Task { @MainActor [weak self] in
            await self?.run()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        onCues = nil
        onLoadingChange = nil
        onError = nil
    }

    private func run() async {
        while !Task.isCancelled {
            let duration = engine.duration
            let limit = duration > 0 ? duration : .greatestFiniteMagnitude
            let time = startPosition ?? engine.clock.currentTime
            startPosition = nil
            let needsSeek = !hasCoverage
                || time < coverageStart - 2
                || time > coverageEnd + 5
            // 窗口已经顶到片尾时不再预取：否则 loadWindow 的 to > from 保护
            // 会立即返回，循环会空转并把主线程占满（自动连播、进度保存全部停摆）。
            let needsPrefetch = hasCoverage
                && coverageEnd < limit - 0.5
                && time > coverageEnd - prefetchLeadSeconds

            if needsSeek {
                // 4s → 16s → 60s：先用很小的窗口让当前对白尽快上屏，再拉长预取，
                // 避免为等待整段 60s 的混流数据而空屏十几秒。
                let span = windowSpan(for: windowsSinceSeek)
                let from = max(0, time - lookbackSeconds)
                let to = duration > 0
                    ? min(duration, time + span)
                    : time + span
                onLoadingChange?(consecutiveFailures == 0)
                let loaded = await loadWindow(from: from, to: to, resetsCoverage: true)
                onLoadingChange?(false)
                if loaded {
                    windowsSinceSeek = 1
                } else {
                    await backoff()
                }
            } else if needsPrefetch {
                let before = coverageEnd
                let span = windowSpan(for: windowsSinceSeek)
                let loaded = await loadWindow(
                    from: coverageEnd,
                    to: min(limit, coverageEnd + span),
                    resetsCoverage: false
                )
                if !loaded {
                    await backoff()
                } else {
                    windowsSinceSeek += 1
                    if coverageEnd <= before {
                        // 兜底：没有推进窗口时让出主线程，避免任何边界条件造成空转。
                        try? await Task.sleep(for: .milliseconds(400))
                    }
                }
            } else {
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private func windowSpan(for index: Int) -> Double {
        switch index {
        case 0: firstWindowSeconds
        case 1: secondWindowSeconds
        default: windowSeconds
        }
    }

    /// 失败后按 2/4/6/8 秒退避，避免对 SMB 反复 open/重连；连续失败时把错误暴露到播放器。
    private func backoff() async {
        consecutiveFailures += 1
        if consecutiveFailures == 3, !hasCoverage {
            onError?("分片字幕连续加载失败")
        }
        let delay = min(8, Double(consecutiveFailures) * 2)
        try? await Task.sleep(for: .seconds(delay))
    }

    private func loadWindow(from: Double, to: Double, resetsCoverage: Bool) async -> Bool {
        guard to > from, !Task.isCancelled else { return false }
        let began = ProcessInfo.processInfo.systemUptime
        do {
            let readTask = Task.detached(priority: .utility) { [source, entry, streamIndex] in
                let byteSource = try await source.openSubtitleByteSource(path: entry.path)
                do {
                    // 字幕窗口只需要流参数，不做完整探测；否则每个 60s 窗口都会
                    // 在 SMB 上重复读取大量容器数据。
                    let reader = try MediaReader.open(
                        source: byteSource,
                        label: entry.path,
                        fastProbe: true
                    )
                    defer { reader.close() }
                    let events = try reader.readSubtitleEvents(
                        streamIndex: streamIndex,
                        from: from,
                        to: to
                    )
                    await byteSource.close()
                    return events
                } catch {
                    await byteSource.close()
                    throw error
                }
            }
            // 外层 stop()/切集时取消本次窗口读取，让 readSubtitleEvents 在
            // 下一个包边界退出，避免旧窗口继续和播放读抢 SMB 带宽。
            let events = try await withTaskCancellationHandler {
                try await readTask.value
            } onCancel: {
                readTask.cancel()
            }
            guard !Task.isCancelled else { return false }

            if consecutiveFailures > 0 {
                consecutiveFailures = 0
                onError?(nil)
            }
            var changed = false
            for event in events {
                guard let cue = Self.makeCue(event) else { continue }
                let key = "\(cue.start)|\(cue.end)|\(cue.text)"
                if cueByKey[key] == nil {
                    cueByKey[key] = cue
                    changed = true
                }
            }
            if resetsCoverage {
                coverageStart = from
                coverageEnd = to
                hasCoverage = true
            } else if hasCoverage {
                coverageStart = min(coverageStart, from)
                coverageEnd = max(coverageEnd, to)
            } else {
                coverageStart = from
                coverageEnd = to
                hasCoverage = true
            }
            if changed {
                let cues = cueByKey.values.sorted {
                    $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
                }
                onCues?(cues)
            }
            Log.info(
                .subtitle,
                "分片字幕就绪 \(String(format: "%.0f", from))-\(String(format: "%.0f", to))s "
                    + "事件=\(events.count) 累计=\(cueByKey.count) "
                    + "耗时=\(Int((ProcessInfo.processInfo.systemUptime - began) * 1000))ms"
            )
            return true
        } catch {
            if !Task.isCancelled {
                Log.error(
                    .subtitle,
                    "分片字幕失败 \(String(format: "%.0f", from))-\(String(format: "%.0f", to))s "
                        + error.localizedDescription
                )
            }
            return false
        }
    }

    static func makeCue(_ event: SubtitlePacketEvent) -> SubtitleCue? {
        let text: String?
        if event.isASS {
            guard !ASSScriptSanitizer.isEffectEvent(style: event.style, body: event.text) else {
                return nil
            }
            text = ASSScriptSanitizer.plainText(event.text)
        } else {
            text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let text, !text.isEmpty else { return nil }
        return SubtitleCue(start: event.start, end: event.end, text: text)
    }
}
