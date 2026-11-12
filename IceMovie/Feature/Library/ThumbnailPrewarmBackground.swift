import BackgroundTasks
import Foundation
import IceCore
import UIKit

/// 充电/空闲时继续当前目录的缩略图预热。
@MainActor
enum ThumbnailPrewarmBackground {
    static let identifier = "com.wangzicheng.icemovie.thumbnail-prewarm"

    nonisolated(unsafe) private static weak var store: LibraryStore?

    static func attach(_ store: LibraryStore) {
        self.store = store
    }

    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil
        ) { task in
            guard let processing = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
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
        var expired = false
        task.expirationHandler = {
            Task { @MainActor in
                expired = true
                store?.pauseThumbnailPrewarm()
            }
        }

        guard let store, let controller = store.prewarmController, controller.isActive else {
            task.setTaskCompleted(success: true)
            return
        }

        store.resumeThumbnailPrewarm()
        while controller.isActive, !expired, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
        }
        if controller.isActive {
            store.pauseThumbnailPrewarm()
        }
        task.setTaskCompleted(success: true)
        if controller.isActive {
            schedule()
        }
    }
}
