import Foundation
import IceCore
import MediaLibraryKit
import Observation
import PersistenceKit
import SwiftUI
import UIKit

@MainActor
@Observable
final class PhotoSyncModel {
    struct Target: Equatable, Sendable {
        let key: String
        let host: String
        let share: String
        let path: String
        let lastSyncedAt: Date?

        var displayPath: String { path.isEmpty ? "/" : path }

        init(_ record: PhotoLibraryTarget) {
            self.key = record.key
            self.host = record.host
            self.share = record.share
            self.path = record.path
            self.lastSyncedAt = record.lastSyncedAt
        }

        init(
            key: String,
            host: String,
            share: String,
            path: String,
            lastSyncedAt: Date? = nil
        ) {
            self.key = key
            self.host = host
            self.share = share
            self.path = path
            self.lastSyncedAt = lastSyncedAt
        }
    }

    /// 目标存储适配器。生产环境封装 SwiftData，测试可注入纯内存实现，
    /// 避免单元测试宿主重复链接静态框架时触发 SwiftData 的跨模块 cast 问题。
    struct TargetStore {
        let target: @MainActor (String, String) -> Target?
        let mark: @MainActor (String, String, String) throws -> Target
        let unmark: @MainActor (String, String) throws -> Void
        let markSynced: @MainActor (String, String, Date) -> Void

        @MainActor
        static func swiftData(_ store: PhotoLibraryTargetStore) -> TargetStore {
            TargetStore(
                target: { host, share in
                    store.target(host: host, share: share).map(Target.init)
                },
                mark: { host, share, path in
                    Target(try store.mark(host: host, share: share, path: path))
                },
                unmark: { host, share in
                    try store.unmark(host: host, share: share)
                },
                markSynced: { host, share, date in
                    store.markSynced(host: host, share: share, at: date)
                }
            )
        }
    }

    enum Phase: Equatable {
        case idle
        case scanning
        case review
        case uploading
        case summary
        case upToDate
        case interrupted
    }

    enum Alert: Identifiable, Equatable {
        case authorization
        case targetMissing
        case scanFailed(String)
        case markFailed(String)

        var id: String {
            switch self {
            case .authorization: "authorization"
            case .targetMissing: "targetMissing"
            case .scanFailed(let message): "scanFailed|\(message)"
            case .markFailed(let message): "markFailed|\(message)"
            }
        }

        var title: String {
            switch self {
            case .authorization: "需要照片权限"
            case .targetMissing: "照片库路径不可用"
            case .scanFailed: "无法检查系统相册"
            case .markFailed: "无法保存照片库路径"
            }
        }

        var message: String {
            switch self {
            case .authorization:
                "IceMovie 需要读取系统相册才能把照片同步到 SMB。请前往系统设置允许访问照片。"
            case .targetMissing:
                "当前目录不是照片库路径，或目标目录已经不可用。请重新标记一个目录。"
            case .scanFailed(let detail):
                detail
            case .markFailed(let detail):
                detail
            }
        }

        var showsSettings: Bool {
            if case .authorization = self { return true }
            return false
        }
    }

    let store: LibraryStore
    let targetStore: TargetStore
    let client: any PhotoLibraryClient
    private let manifestDirectory: URL?
    private let timeZone: TimeZone
    private let uploadLimit: Int?

    private(set) var target: Target?
    private(set) var phase: Phase = .idle
    private(set) var plan: PhotoSyncPlan?
    private(set) var summary: PhotoSyncSummary?
    private(set) var processed = 0
    private(set) var total = 0
    private(set) var bytesPerSecond: Double = 0
    private(set) var uploadedBytes: Int64 = 0
    private(set) var currentFileName: String?
    private(set) var isExporting = false
    private(set) var failureCount = 0
    private(set) var authorizationStatus: PhotoLibraryAuthorizationStatus = .notDetermined
    private(set) var isLimitedAccess = false
    private(set) var isCancelling = false

    var isSheetPresented = false
    var alert: Alert?
    var isReplaceConfirmationPresented = false
    private(set) var pendingMarkPath: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var rateTask: Task<Void, Never>?
    @ObservationIgnored private var autoHideTask: Task<Void, Never>?
    @ObservationIgnored private var manifestStore: PhotoSyncManifestStore?
    @ObservationIgnored private let rateMeter = TransferRateMeter()
    @ObservationIgnored private let cancellation = PhotoSyncCancellationFlag()
    @ObservationIgnored private var didSetIdleTimer = false
    @ObservationIgnored private var interruptedByBackground = false
    @ObservationIgnored private var autoStartAfterScan = false

    init(
        store: LibraryStore,
        targetStore: TargetStore,
        client: any PhotoLibraryClient = PhotoKitLibraryClient(),
        manifestDirectory: URL? = nil,
        timeZone: TimeZone = .current,
        uploadLimit: Int? = nil
    ) {
        self.store = store
        self.targetStore = targetStore
        self.client = client
        self.manifestDirectory = manifestDirectory
        self.timeZone = timeZone
        self.uploadLimit = uploadLimit
        store.onShareChanged = { [weak self] in
            self?.refreshTarget()
        }
        refreshTarget()
    }

    var isStatusStripVisible: Bool {
        phase == .uploading || phase == .summary || phase == .interrupted
    }

    var isBusy: Bool {
        phase == .scanning || phase == .uploading
    }

    var isCurrentDirectoryTarget: Bool {
        target?.path == store.currentPath
    }

    var targetDisplayName: String {
        guard let target else { return "照片库" }
        if !target.path.isEmpty {
            return (target.path as NSString).lastPathComponent
        }
        return target.share
    }

    var progressFraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(processed) / Double(total)))
    }

    var formattedSpeed: String {
        guard phase == .uploading else { return "" }
        if isExporting { return "正在读取照片…" }
        guard bytesPerSecond >= 1 else { return "等待网络" }
        let value = ByteCountFormatter.string(
            fromByteCount: Int64(bytesPerSecond),
            countStyle: .file
        )
        return "↑ \(value)/s"
    }

    var formattedUploadedBytes: String {
        ByteCountFormatter.string(fromByteCount: uploadedBytes, countStyle: .file)
    }

    var formattedAverageSpeed: String {
        guard let summary, summary.averageBytesPerSecond >= 1 else { return "-" }
        let value = ByteCountFormatter.string(
            fromByteCount: Int64(summary.averageBytesPerSecond),
            countStyle: .file
        )
        return "\(value)/s"
    }

    var formattedElapsed: String {
        guard let summary else { return "-" }
        let total = Int(summary.elapsed.rounded())
        let minutes = total / 60
        let seconds = total % 60
        if minutes > 0 {
            return "\(minutes) 分 \(seconds) 秒"
        }
        return "\(seconds) 秒"
    }

    var titleText: String {
        switch phase {
        case .scanning: return "正在检查系统相册…"
        case .review: return "准备同步"
        case .uploading: return "同步到 \(targetDisplayName)"
        case .summary:
            if summary?.cancelled == true { return "同步已取消" }
            if summary?.failureCount ?? 0 > 0 { return "同步完成 · 失败 \(summary?.failureCount ?? 0)" }
            return "同步完成"
        case .upToDate: return "已是最新"
        case .interrupted: return "同步中断"
        case .idle: return ""
        }
    }

    // MARK: - 目标标记

    func refreshTarget() {
        let updated = targetStore.target(
            store.source.hostName,
            store.source.shareName
        )
        if target?.key != updated?.key || target?.path != updated?.path {
            target = updated
            store.setPhotoLibraryTargetPath(updated?.path)
        }
    }

    func isTarget(path: String) -> Bool {
        target?.path == path
    }

    func requestMarkCurrentDirectory() {
        requestMark(path: store.currentPath)
    }

    func requestMark(path: String) {
        if let target, target.path != path {
            pendingMarkPath = path
            isReplaceConfirmationPresented = true
            return
        }
        performMark(path: path)
    }

    func confirmReplaceTarget() {
        defer {
            pendingMarkPath = nil
            isReplaceConfirmationPresented = false
        }
        guard let pendingMarkPath else { return }
        performMark(path: pendingMarkPath)
    }

    func cancelReplaceTarget() {
        pendingMarkPath = nil
        isReplaceConfirmationPresented = false
    }

    func unmarkCurrentDirectory() {
        unmark(path: store.currentPath)
    }

    func unmark(path: String) {
        guard target?.path == path else { return }
        do {
            try targetStore.unmark(
                store.source.hostName,
                store.source.shareName
            )
            target = nil
            store.setPhotoLibraryTargetPath(nil)
            if phase != .uploading {
                phase = .idle
                isSheetPresented = false
            }
        } catch {
            alert = .markFailed(error.localizedDescription)
        }
    }

    private func performMark(path: String) {
        do {
            let record = try targetStore.mark(
                store.source.hostName,
                store.source.shareName,
                path
            )
            target = record
            store.setPhotoLibraryTargetPath(record.path)
        } catch {
            alert = .markFailed(error.localizedDescription)
        }
    }

    // MARK: - 同步流程

    func beginSync() {
        guard target != nil else {
            alert = .targetMissing
            return
        }
        guard phase != .uploading else {
            isSheetPresented = true
            return
        }
        guard !isBusy else {
            isSheetPresented = true
            return
        }

        autoHideTask?.cancel()
        cancelActiveTask()
        plan = nil
        summary = nil
        processed = 0
        total = 0
        failureCount = 0
        uploadedBytes = 0
        bytesPerSecond = 0
        currentFileName = nil
        isCancelling = false
        isExporting = false
        isLimitedAccess = false
        rateMeter.reset()
        cancellation.reset()
        interruptedByBackground = false
        phase = .scanning
        isSheetPresented = true

        task = Task { [weak self] in
            await self?.scanForSync()
        }
    }

    private func scanForSync() async {
        var status = await client.authorizationStatus()
        if status == .notDetermined {
            status = await client.requestAuthorization()
        }
        authorizationStatus = status
        isLimitedAccess = status.isLimited
        Log.info(
            .app,
            "照片同步授权 status=\(status.rawValue) limited=\(status.isLimited)"
        )

        guard status.canRead else {
            autoStartAfterScan = false
            dismissSheetAndShowAlert(.authorization)
            return
        }
        guard let target else {
            autoStartAfterScan = false
            dismissSheetAndShowAlert(.targetMissing)
            return
        }

        do {
            let manifestStore = try PhotoSyncManifestStore(
                target: PhotoLibraryTargetStore.key(
                    host: store.source.hostName,
                    share: store.source.shareName
                ),
                directory: manifestDirectory
            )
            self.manifestStore = manifestStore
            let manifest = await manifestStore.snapshot()
            if let warning = await manifestStore.warning() {
                Log.notice(.app, "照片同步清单重建 \(warning)")
            }

            let engine = PhotoSyncEngine(
                source: store.source,
                client: client,
                targetPath: target.path,
                timeZone: timeZone
            )
            let plan = try await engine.scan(
                manifest: manifest,
                authorization: status
            )
            try Task.checkCancellation()
            self.plan = plan
            self.total = plan.candidates.count
            self.processed = 0

            if plan.candidates.isEmpty {
                autoStartAfterScan = false
                phase = .upToDate
                isSheetPresented = true
            } else {
                phase = .review
                isSheetPresented = true
                if autoStartAfterScan {
                    autoStartAfterScan = false
                    startUpload()
                }
            }
        } catch is CancellationError {
            autoStartAfterScan = false
            phase = .idle
            isSheetPresented = false
        } catch {
            autoStartAfterScan = false
            dismissSheetAndShowAlert(.scanFailed(error.localizedDescription))
            Log.error(.app, "照片同步扫描失败 \(error.localizedDescription)")
        }
    }

    /// 关闭扫描弹层后再展示提示，避免 SwiftUI 在 sheet 退场动画期间吞掉 alert。
    private func dismissSheetAndShowAlert(_ value: Alert) {
        phase = .idle
        isSheetPresented = false
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self else { return }
            alert = value
        }
    }

    func startUpload() {
        guard let plan, let target, let manifestStore else {
            alert = .targetMissing
            return
        }
        guard !plan.candidates.isEmpty else {
            phase = .upToDate
            isSheetPresented = true
            return
        }

        let effectivePlan: PhotoSyncPlan
        if let uploadLimit, uploadLimit > 0, plan.candidates.count > uploadLimit {
            var limited = plan
            limited.candidates = Array(plan.candidates.prefix(uploadLimit))
            limited.counts.pending = limited.candidates.count
            effectivePlan = limited
        } else {
            effectivePlan = plan
        }

        self.plan = effectivePlan
        self.total = effectivePlan.candidates.count
        processed = 0
        failureCount = 0
        uploadedBytes = 0
        bytesPerSecond = 0
        currentFileName = nil
        isCancelling = false
        isExporting = false
        summary = nil
        cancellation.reset()
        rateMeter.reset()
        phase = .uploading
        isSheetPresented = false
        setIdleTimer(true)
        startRateTask()

        let engine = PhotoSyncEngine(
            source: store.source,
            client: client,
            targetPath: target.path,
            timeZone: timeZone
        )
        task = Task { [weak self] in
            guard let self else { return }
            let result = await engine.upload(
                plan: effectivePlan,
                manifestStore: manifestStore,
                rateMeter: rateMeter,
                cancellation: cancellation,
                progress: { event in
                    self.apply(event)
                }
            )
            await self.finish(result)
        }
    }

    private func apply(_ event: PhotoSyncProgress) {
        currentFileName = event.fileName
        switch event.phase {
        case .exporting:
            isExporting = true
        case .uploading:
            isExporting = false
        case .processed:
            isExporting = false
            processed = event.processed
            total = max(total, event.total)
        }
    }

    private func finish(_ result: PhotoSyncUploadResult) async {
        stopRateTask()
        setIdleTimer(false)

        let elapsed = result.elapsed
        let average = elapsed > 0
            ? Double(result.uploadedBytes) / elapsed
            : 0
        let interrupted = result.interrupted || interruptedByBackground
        let cancelled = result.cancelled && !interruptedByBackground
        let errorMessage = result.errorMessage
            ?? (interruptedByBackground ? "应用进入后台，同步已中断" : nil)
        let summary = PhotoSyncSummary(
            successCount: result.successCount,
            processedCount: result.processedCount,
            totalCount: total,
            skippedCount: plan?.counts.skipped ?? 0,
            elapsed: elapsed,
            averageBytesPerSecond: average,
            uploadedBytes: result.uploadedBytes,
            failures: result.failures,
            cancelled: cancelled,
            interrupted: interrupted,
            errorMessage: errorMessage
        )
        self.summary = summary
        processed = result.processedCount
        uploadedBytes = result.uploadedBytes
        failureCount = result.failures.count
        bytesPerSecond = 0
        currentFileName = nil
        isCancelling = false
        isExporting = false
        phase = interrupted ? .interrupted : .summary
        isSheetPresented = interrupted || !result.failures.isEmpty

        targetStore.markSynced(
            store.source.hostName,
            store.source.shareName,
            Date()
        )
        if let targetPath = target?.path {
            await store.refreshDirectoryAfterPhotoSync(path: targetPath)
        }

        if interrupted {
            Log.error(
                .app,
                "照片同步中断 \(errorMessage ?? "未知错误") "
                    + "成功=\(result.successCount) 失败=\(result.failures.count)"
            )
        } else if cancelled {
            Log.info(
                .app,
                "照片同步已取消 处理=\(result.processedCount)/\(total) "
                    + "成功=\(result.successCount)"
            )
        } else if result.failures.isEmpty {
            scheduleAutoHide()
        }
    }

    func cancelSync() {
        switch phase {
        case .scanning:
            cancelActiveTask()
            phase = .idle
            isSheetPresented = false
        case .uploading:
            isCancelling = true
            cancellation.cancel()
            task?.cancel()
        case .review, .upToDate:
            cancelActiveTask()
            phase = .idle
            isSheetPresented = false
            plan = nil
        case .summary, .interrupted:
            dismissStatus()
        case .idle:
            break
        }
    }

    func retryFailed() {
        isSheetPresented = false
        summary = nil
        phase = .idle
        autoStartAfterScan = true
        beginSync()
    }

    func dismissSheet() {
        switch phase {
        case .scanning:
            cancelActiveTask()
            phase = .idle
            isSheetPresented = false
        case .review, .upToDate:
            phase = .idle
            isSheetPresented = false
            plan = nil
        case .summary, .interrupted:
            isSheetPresented = false
            if failureCount == 0 && phase == .summary {
                phase = .idle
                summary = nil
            }
        case .uploading:
            isSheetPresented = false
        case .idle:
            isSheetPresented = false
        }
    }

    func dismissStatus() {
        guard phase == .summary || phase == .interrupted else { return }
        autoHideTask?.cancel()
        isSheetPresented = false
        phase = .idle
        summary = nil
        plan = nil
        failureCount = 0
    }

    func showDetails() {
        guard isStatusStripVisible else { return }
        isSheetPresented = true
    }

    /// 断开连接或退出媒体库时停止同步，避免后台继续持有 SMB 会话和屏幕常亮。
    func cancelForDisconnect() {
        cancelActiveTask()
        phase = .idle
        isSheetPresented = false
        summary = nil
        plan = nil
        isCancelling = false
        isExporting = false
        currentFileName = nil
        processed = 0
        total = 0
        bytesPerSecond = 0
    }

    func handleScenePhase(_ scenePhase: ScenePhase) {
        guard phase == .uploading else { return }
        if scenePhase != .active {
            interruptedByBackground = true
            isCancelling = true
            cancellation.cancel()
            task?.cancel()
        }
    }

    private func cancelActiveTask() {
        cancellation.cancel()
        task?.cancel()
        task = nil
        stopRateTask()
        setIdleTimer(false)
    }

    private func startRateTask() {
        rateTask?.cancel()
        rateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                bytesPerSecond = rateMeter.rate()
                if rateMeter.totalBytes() > uploadedBytes {
                    uploadedBytes = rateMeter.totalBytes()
                }
            }
        }
    }

    private func stopRateTask() {
        rateTask?.cancel()
        rateTask = nil
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            guard phase == .summary, failureCount == 0, !isSheetPresented else { return }
            phase = .idle
            summary = nil
        }
    }

    private func setIdleTimer(_ enabled: Bool) {
        if enabled {
            UIApplication.shared.isIdleTimerDisabled = true
            didSetIdleTimer = true
        } else if didSetIdleTimer {
            UIApplication.shared.isIdleTimerDisabled = false
            didSetIdleTimer = false
        }
    }
}
