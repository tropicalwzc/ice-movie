import BackgroundTasks
import Foundation
import IceCore
import UIKit

/// 充电/空闲时继续当前目录的缩略图预热。
@MainActor
enum ThumbnailPrewarmBackground {
    nonisolated static let identifier = "com.wangzicheng.icemovie.thumbnail-prewarm"

    nonisolated(unsafe) private static weak var store: LibraryStore?

    static func attach(_ store: LibraryStore) {
        self.store = store
    }

    nonisolated static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil
        ) { @Sendable task in
            // BGTaskScheduler 在后台队列回调；这里不能继承 @MainActor，
            // 否则 Swift 6 会在回调入口直接触发 dispatch_assert_queue 崩溃。
            // BGTask 由系统保证可跨队列传递，装箱后显式送进主线程。
            let box = TaskBox(task: task)
            Task { @MainActor in
                let task = box.task
                guard let processing = task as? BGProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                await handle(processing)
            }
        }
    }

    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date().addingTimeInterval(60)
        do {
            try BGTaskScheduler.shared.submit(request)
            Log.debug(.thumbnail, "已登记缩略图后台预热任务")
        } catch {
            Log.debug(
                .thumbnail,
                "缩略图后台预热任务登记失败：\(error.localizedDescription)"
            )
        }
    }

    private static func handle(_ task: BGProcessingTask) async {
        let expired = ExpirationFlag()
        task.expirationHandler = { @Sendable in
            // 过期回调同样来自后台队列；只置标志，回主线程再暂停控制器。
            expired.mark()
            Task { @MainActor in
                store?.pauseThumbnailPrewarm()
            }
        }

        guard let store, let controller = store.prewarmController, controller.isActive else {
            task.setTaskCompleted(success: true)
            return
        }

        store.resumeThumbnailPrewarm()
        Log.info(
            .thumbnail,
            "后台预热开始 进度=\(controller.completed)/\(controller.total) "
                + "内存=\(String(format: "%.0f", MemoryFootprint.currentMB))MB"
        )
        var ticks = 0
        while controller.isActive, !expired.isMarked, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            ticks += 1
            if ticks % 10 == 0 {
                Log.info(
                    .thumbnail,
                    "后台预热采样 进度=\(controller.completed)/\(controller.total) "
                        + "内存=\(String(format: "%.0f", MemoryFootprint.currentMB))MB "
                        + "峰值=\(String(format: "%.0f", MemoryFootprint.peakMB))MB"
                )
            }
        }
        if controller.isActive {
            store.pauseThumbnailPrewarm()
        }
        Log.info(
            .thumbnail,
            "后台预热结束 进度=\(controller.completed)/\(controller.total) "
                + "内存=\(String(format: "%.0f", MemoryFootprint.currentMB))MB "
                + "峰值=\(String(format: "%.0f", MemoryFootprint.peakMB))MB "
                + "过期=\(expired.isMarked)"
        )
        task.setTaskCompleted(success: true)
        if controller.isActive {
            schedule()
        }
    }
}

/// BGTask 由系统在后台队列创建并回调，跨 actor 传递前显式装箱。
private struct TaskBox: @unchecked Sendable {
    let task: BGTask
}

/// BGTask 过期回调在后台线程触发，用一个带锁标志避免跨 actor 直接读写局部变量。
private final class ExpirationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false

    var isMarked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return marked
    }

    func mark() {
        lock.lock()
        marked = true
        lock.unlock()
    }
}
