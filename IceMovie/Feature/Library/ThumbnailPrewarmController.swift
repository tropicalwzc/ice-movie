import Foundation
import IceCore
import MediaLibraryKit
import Observation

/// 单目录缩略图预热。只维护内存进度，真正的缩略图生成由外部闭包完成。
@MainActor
@Observable
final class ThumbnailPrewarmController {
    private(set) var total: Int
    private(set) var completed = 0
    private(set) var isRunning = false
    private(set) var isPaused = false
    private(set) var isFinished = false
    private(set) var currentName: String?

    var progress: Double {
        total > 0 ? min(1, Double(completed) / Double(total)) : 0
    }

    /// 顶部进度条只在有任务且尚未结束/取消时显示。
    var isActive: Bool {
        total > 0 && !isFinished && (isRunning || isPaused || completed < total)
    }

    @ObservationIgnored private var entries: [MediaEntry]
    @ObservationIgnored private var nextIndex = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var isScrolling = false
    @ObservationIgnored private let generate: (MediaEntry) async -> Bool
    @ObservationIgnored private let onFlush: (() async -> Void)?

    init(
        entries: [MediaEntry],
        onFlush: (() async -> Void)? = nil,
        generate: @escaping (MediaEntry) async -> Bool
    ) {
        self.entries = entries
        self.total = entries.count
        self.onFlush = onFlush
        self.generate = generate
    }

    func start() {
        guard !isRunning, !isFinished, !entries.isEmpty else { return }
        isRunning = true
        isPaused = false
        task = Task { [weak self] in
            await self?.run()
        }
    }

    func pause() {
        guard !isFinished else { return }
        isPaused = true
        Task { [weak self] in
            await self?.onFlush?()
        }
    }

    func resume() {
        guard !isFinished else { return }
        isPaused = false
        if !isRunning {
            start()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        isPaused = false
        isFinished = true
        currentName = nil
        Task { [weak self] in
            await self?.onFlush?()
        }
    }

    /// 滚动期间暂停 P2，优先保证可见单元格。
    func setScrolling(_ scrolling: Bool) {
        isScrolling = scrolling
    }

    /// 把当前可见条目移动到待处理区最前，避免用户跳到远处后仍按旧顺序预热。
    func prioritize(_ ids: [String]) {
        guard !ids.isEmpty, nextIndex < entries.count else { return }
        let visible = Set(ids)
        let pending = Array(entries[nextIndex...])
        let prioritized = pending.filter { visible.contains($0.id) }
        guard !prioritized.isEmpty else { return }
        let rest = pending.filter { !visible.contains($0.id) }
        entries = Array(entries[..<nextIndex]) + prioritized + rest
    }

    private func run() async {
        while !Task.isCancelled, nextIndex < entries.count {
            if isPaused || isScrolling {
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            let entry = entries[nextIndex]
            nextIndex += 1
            currentName = entry.name
            _ = await generate(entry)
            completed += 1
            if completed % 20 == 0 {
                await onFlush?()
            }
            if completed % 100 == 0 {
                Log.info(
                    .thumbnail,
                    "缩略图预热进度 \(completed)/\(total)"
                )
            }
        }
        currentName = nil
        isRunning = false
        if nextIndex >= entries.count, !isPaused {
            isFinished = true
        }
        if isFinished || isPaused {
            await onFlush?()
        }
        task = nil
    }
}
