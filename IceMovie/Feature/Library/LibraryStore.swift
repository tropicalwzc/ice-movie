import DemuxKit
import Foundation
import IceCore
import MediaLibraryKit
import Observation
import PersistenceKit
import RenderKit
import SubtitleKit
import ThumbnailKit
import UIKit

struct StartupDiagnostics: Sendable {
    var playerPresentedMilliseconds = 0
    var openBytesRead: Int64 = 0
    var openReadCount = 0
    var avioFillCount = 0
    var attachmentBytes = 0
    var attachmentFontBytes = 0
    var skippedFontCount = 0
    var headerCacheHitBytes: Int64 = 0
    var headerCacheHitRatio: Double = 0
    var subtitleScanMilliseconds = 0
    var startupPrerollMode = "fast"
    var startupBufferStalls = 0
    var resumeLocated = true
}

/// 目录封面上次选中的内部视频。持久化后，启动时可直接计算缓存键并读本地封面，
/// 不必先枚举目录和子目录，避免“命中缓存但仍像在现生成”。
private struct FolderCoverSelection: Codable, Sendable {
    var videoPath: String
    var videoName: String
    var size: Int64
    var modified: TimeInterval
    var resolvedAt: TimeInterval

    init(video: MediaEntry, resolvedAt: Date = Date()) {
        self.videoPath = video.path
        self.videoName = video.name
        self.size = video.size
        self.modified = video.modified?.timeIntervalSince1970 ?? 0
        self.resolvedAt = resolvedAt.timeIntervalSince1970
    }

    var isFresh: Bool {
        Date().timeIntervalSince1970 - resolvedAt < 24 * 60 * 60
    }

    var mediaEntry: MediaEntry {
        MediaEntry(
            path: videoPath,
            name: videoName,
            isDirectory: false,
            size: size,
            modified: modified > 0 ? Date(timeIntervalSince1970: modified) : nil
        )
    }
}

struct PreparedPlayback {
    let engine: PlaybackEngine
    let tracks: [SubtitleTrack]
    let selectedTrack: SubtitleTrack?
    let timeline: SubtitleTimeline?
    let loader: SubtitleLoader
    let sourceOpenMilliseconds: Int
    let probeMilliseconds: Int
    let subtitleMilliseconds: Int
    let engineMilliseconds: Int
    let openInputMilliseconds: Int
    let streamInfoMilliseconds: Int
    var startup = StartupDiagnostics()
    /// 外挂字幕的后台扫描；不阻塞起播，完成后由播放会话合并。
    let externalTracksTask: Task<[SubtitleTrack], Never>
}

/// 媒体库视图模型。
///
/// 目录导航、条目缓存、检索索引与缩略图都放在这里，两种宽度外壳只是它的投影；
/// 切换外壳或重新创建视图不会重建状态（design.md D12）。
@MainActor
@Observable
final class LibraryStore {
    enum PhotoCalendarJump: Equatable {
        case day(PhotoDay)
        case month(year: Int, month: Int)

        var title: String {
            switch self {
            case .day(let day):
                day.title
            case .month(let year, let month):
                "\(year)年\(month)月"
            }
        }

        var compactTitle: String {
            switch self {
            case .day(let day):
                "\(day.month)月\(day.day)日"
            case .month(_, let month):
                "\(month)月"
            }
        }
    }

    let source: any LibrarySource
    let thumbnailSidecarCache: SharedThumbnailCache?

    private(set) var presentation: LibraryPresentation
    private(set) var entriesByPath: [String: [MediaEntry]] = [:]
    private(set) var currentEntries: [MediaEntry] = []
    private(set) var photoCalendar = PhotoCalendarIndex()
    private(set) var photoCalendarJump: PhotoCalendarJump?
    private(set) var pendingScrollTarget: String?
    private let favoriteProvider: (any FavoritePhotoProviding)?
    private(set) var favoritesOnly = false
    private(set) var favoritePaths: Set<String> = []
    private(set) var favoriteEntries: [MediaEntry] = []
    private(set) var isLoading = true
    private(set) var errorMessage: String?
    private(set) var playbackFailure: PlaybackFailure?
    private(set) var lastUpdated: Date?
    /// 正在准备起播的条目。对应的媒体库单元格据此显示加载态，
    /// 让用户知道点击已经生效、播放器正在拉起。
    private(set) var preparingPlaybackID: String?

    var searchText = ""
    /// 目录网格的媒体类型过滤。默认都选中；只在同时含视频和图片的目录生效。
    var showsVideos = true
    var showsImages = true
    private(set) var searchHits: [LibrarySearchHit] = []
    private(set) var isIndexing = false
    private(set) var indexedDirectoryCount = 0
    private(set) var indexTruncated = false
    /// 目录成功加载后回调，用于把最近路径写回 SwiftData。
    var onPathChanged: ((String) -> Void)?
    /// 切换共享前回调，用于停止仍在使用旧共享的播放会话。
    var onShareWillChange: (() -> Void)?
    /// 共享切换完成后回调，用于刷新照片同步目标。
    var onShareChanged: (() -> Void)?
    /// 当前 host + share 的照片库目标路径；nil 表示未标记。
    private(set) var photoLibraryTargetPath: String?
    private(set) var availableShares: [String] = []
    private(set) var isSwitchingShare = false

    private let thumbnails: ThumbnailService
    /// 目录封面独立单并发，避免读取内部视频时挤占可见视频封面的并发槽。
    private let folderCoverThumbnails: ThumbnailService
    /// 512px 覆盖 3x iPhone 两列（约 520px）的单元格宽度；再大对 iPad 预热带宽收益很小。
    private static let thumbnailMaxWidth = SharedThumbnailCache.maxPixelSize
    /// 缩略图生成逻辑版本；变化时换命名空间并清掉旧文件。
    private static let thumbnailVariant = "thumb\(thumbnailMaxWidth)p4"
    /// 缩略图分辨率/生成逻辑变化后必须换缓存命名空间，避免继续命中旧文件。
    private var thumbnailNamespace: String {
        "\(source.cacheNamespace)|\(Self.thumbnailVariant)"
    }

    private let imageCache = NSCache<NSString, UIImage>()
    /// 图片宽高比（宽/高），用于瀑布流单元格高度；按共享命名空间 + 路径缓存。
    @ObservationIgnored private var aspectRatios: [String: CGFloat] = [:]
    @ObservationIgnored private var aspectRatiosDirty = false
    @ObservationIgnored private var aspectPersistTask: Task<Void, Never>?
    /// 空闲时向前预取瀑布流封面；滑动开始会取消，避免和可见单元格抢并发槽。
    @ObservationIgnored private var prefetchTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var prefetchingIDs: Set<String> = []
    /// 目录封面：进行中请求、候选缓存、目录枚举缓存与上次选中的内部视频。
    @ObservationIgnored private var folderCoverTasks: [String: Task<UIImage?, Never>] = [:]
    @ObservationIgnored private var folderCoverCandidatesByPath: [String: [MediaEntry]] = [:]
    @ObservationIgnored private var folderCoverCandidateTimestamps: [String: Date] = [:]
    @ObservationIgnored private var folderCoverSelections: [String: FolderCoverSelection] = [:]
    @ObservationIgnored private var folderCoverSelectionPersistTask: Task<Void, Never>?
    @ObservationIgnored private var folderCoverDirectoryCache: [String: [MediaEntry]] = [:]
    @ObservationIgnored private var folderCoverDirectoryTimestamps: [String: Date] = [:]
    @ObservationIgnored private var folderCoverPrefetchTask: Task<Void, Never>?
    @ObservationIgnored private var gridIsScrolling = false
    /// 当前目录的全量预热；仅在有共享侧车且存在缺失缩略图时创建。
    private(set) var prewarmController: ThumbnailPrewarmController?
    @ObservationIgnored private var prewarmTask: Task<Void, Never>?
    /// 相册/播放等独占浏览态会暂停预热；即使预热还处在启动延迟里也要生效。
    @ObservationIgnored private var prewarmSuspended = false
    @ObservationIgnored private var prewarmWasPausedBeforeSuspend = false
    @ObservationIgnored private var prewarmDeferred = false
    private var loadGeneration = 0
    private var indexTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var preparationGeneration = 0

    var currentPath: String { presentation.navigation.currentPath }
    var canGoBack: Bool { presentation.navigation.canGoBack }
    var breadcrumb: [(name: String, path: String)] { presentation.navigation.breadcrumb }
    var subdirectories: [MediaEntry] { currentEntries.filter(\.isDirectory) }
    /// 当前目录的分区结果：视频/图片网格 + 文档列表。
    var contentSections: LibraryContentSectioning {
        LibraryContentSectioning(entries: favoritesOnly ? favoriteEntries : currentEntries)
    }

    /// 过滤器只在视频与图片同时存在时有意义；单类型目录忽略过滤状态。
    var mediaFilterIsApplicable: Bool {
        let section = contentSections
        return section.hasVideos && section.hasImages
    }

    var hasPhotoCalendar: Bool {
        photoCalendar.hasDates
    }

    /// 当前目录是否是照片库目标。
    var isCurrentDirectoryPhotoLibraryTarget: Bool {
        photoLibraryTargetPath == currentPath
    }

    func isPhotoLibraryTarget(path: String) -> Bool {
        photoLibraryTargetPath == path
    }

    /// 由 PhotoSyncModel 在启动、切换共享、标记或取消标记后写回。
    func setPhotoLibraryTargetPath(_ path: String?) {
        guard photoLibraryTargetPath != path else { return }
        photoLibraryTargetPath = path
        Log.info(
            .app,
            "照片库目标状态更新 host=\(source.hostName) share=\(source.shareName) "
                + "路径=\(path.map { $0.isEmpty ? "/" : Log.shortPath($0) } ?? "无")"
        )
    }

    /// 当前网格真正显示的条目：目录始终保留，视频/图片按过滤状态裁剪。
    var visibleGridItems: [MediaEntry] {
        let items = contentSections.gridItems
        if favoritesOnly { return items }
        guard mediaFilterIsApplicable else { return items }
        return items.filter { entry in
            if entry.isDirectory { return true }
            if entry.kind == .video { return showsVideos }
            if entry.kind == .image { return showsImages }
            return false
        }
    }

    func resetMediaFilter() {
        showsVideos = true
        showsImages = true
    }

    /// 从本机收藏记录重建当前共享的收藏路径与全局收藏夹条目。
    func reloadFavorites() {
        let records = favoriteProvider?.snapshots(
            host: source.hostName,
            share: source.shareName
        ) ?? []
        favoritePaths = Set(records.map(\.path))
        favoriteEntries = MediaOrdering.sorted(
            records.map {
                MediaEntry(
                    path: $0.path,
                    name: $0.name,
                    isDirectory: false,
                    size: $0.size,
                    modified: $0.modified
                )
            }
        )
    }

    func toggleFavoritesOnly() {
        favoritesOnly.toggle()
        if favoritesOnly {
            reloadFavorites()
            pendingScrollTarget = nil
        }
        Log.info(
            .app,
            favoritesOnly
                ? "进入收藏夹 数量=\(favoriteEntries.count)"
                : "退出收藏夹"
        )
    }

    func isFavorite(_ entry: MediaEntry) -> Bool {
        favoritePaths.contains(entry.path)
    }

    func toggleFavorite(_ entry: MediaEntry) {
        guard let favoriteProvider else { return }
        favoriteProvider.toggle(
            host: source.hostName,
            share: source.shareName,
            path: entry.path,
            name: entry.name,
            size: entry.size,
            modified: entry.modified
        )
        reloadFavorites()
        Log.info(
            .app,
            "\(isFavorite(entry) ? "收藏" : "取消收藏")照片 \(Log.shortPath(entry.path))"
        )
    }

    /// 删除 SMB 原文件；成功后刷新目录、检索索引与收藏夹。
    func delete(entry: MediaEntry) async throws {
        try await source.deleteFile(path: entry.path)
        favoriteProvider?.remove(
            host: source.hostName,
            share: source.shareName,
            path: entry.path
        )
        let directory = entry.directoryPath
        if let cached = entriesByPath[directory] {
            entriesByPath[directory] = cached.filter { $0.path != entry.path }
        }
        if directory == currentPath {
            currentEntries.removeAll { $0.path == entry.path }
            rebuildPhotoCalendar()
            updateIndex(directoryPath: directory, entries: currentEntries)
        }
        await reloadDirectoryIfNeeded(path: directory)
        reloadFavorites()
        Log.info(.app, "照片已删除 \(Log.shortPath(entry.path))")
    }

    private func rebuildPhotoCalendar() {
        photoCalendar = PhotoCalendarIndex(entries: currentEntries)
    }

    /// 从日历跳到某一天的第一张照片；若图片被过滤则先恢复图片类型。
    func requestPhotoJump(to day: PhotoDay) {
        guard let entry = photoCalendar.firstEntry(for: day) else { return }
        if !showsImages {
            showsImages = true
        }
        photoCalendarJump = .day(day)
        pendingScrollTarget = entry.id
        Log.info(
            .app,
            "照片日历跳转 \(day.title) → \(Log.shortPath(entry.path))"
        )
    }

    /// 从日历跳到某个月的最新一张照片。
    func requestPhotoJump(toYear year: Int, month: Int) {
        guard let entry = photoCalendar.firstEntry(in: year, month: month) else { return }
        if !showsImages {
            showsImages = true
        }
        photoCalendarJump = .month(year: year, month: month)
        pendingScrollTarget = entry.id
        Log.info(
            .app,
            "照片日历整月跳转 \(year)年\(month)月 → \(Log.shortPath(entry.path))"
        )
    }

    /// 取消日历日期选择，恢复图片显示并滚回网格顶部（全部照片）。
    func clearPhotoCalendarJump() {
        photoCalendarJump = nil
        if !showsImages {
            showsImages = true
        }
        pendingScrollTarget = visibleGridItems.first?.id
        Log.info(
            .app,
            "照片日历跳转已清除，回到全部照片"
        )
    }

    func consumePendingScrollTarget() {
        pendingScrollTarget = nil
    }
    var currentTitle: String {
        if favoritesOnly { return "收藏夹" }
        guard let last = presentation.navigation.stack.last else {
            return presentation.navigation.share
        }
        return MediaTitleParser.directoryDisplayName(last)
    }

    var displayBreadcrumb: [(name: String, path: String)] {
        breadcrumb.map {
            (name: MediaTitleParser.directoryDisplayName($0.name), path: $0.path)
        }
    }

    var searchScopeNote: String? {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if indexedDirectoryCount == 0 {
            return "正在建立索引，结果会随扫描补全"
        }
        if isIndexing {
            return "仅覆盖已索引的 \(indexedDirectoryCount) 个目录，后台正在补全"
        }
        if indexTruncated {
            return "仅覆盖已索引的 \(indexedDirectoryCount) 个目录（已达本次扫描上限）"
        }
        return "仅覆盖已索引的 \(indexedDirectoryCount) 个目录"
    }

    init(
        source: any LibrarySource,
        initialPath: String = "",
        cacheCapacityBytes: Int64 = ThumbnailStore.maximumDiskBytes,
        favoriteProvider: (any FavoritePhotoProviding)? = nil
    ) throws {
        self.source = source
        self.favoriteProvider = favoriteProvider
        let components = initialPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        self.presentation = LibraryPresentation(
            shell: .compact,
            navigation: LibraryNavigationState(
                host: source.hostName,
                share: source.shareName,
                stack: components
            )
        )
        let thumbnailStore = try ThumbnailStore(capacityBytes: cacheCapacityBytes)
        let thumbnails = ThumbnailService(
            store: thumbnailStore,
            maxWidth: Self.thumbnailMaxWidth
        )
        self.thumbnails = thumbnails
        // 目录封面单独占 16MB：视频预热持续写入 64MB 主缓存时，
        // 不会把目录封面当成旧条目淘汰掉。
        let folderCoverStore = try ThumbnailStore(
            directory: ThumbnailStore.folderCoverDirectory(),
            capacityBytes: ThumbnailStore.folderCoverCapacityBytes
        )
        self.folderCoverThumbnails = ThumbnailService(
            store: folderCoverStore,
            maxWidth: Self.thumbnailMaxWidth,
            maxConcurrent: 1
        )
        self.thumbnailSidecarCache = source.thumbnailSidecar.map {
            SharedThumbnailCache(provider: $0)
        }
        Task { await thumbnails.trimToCapacity() }
        Task { await folderCoverThumbnails.trimToCapacity() }
        if ProcessInfo.processInfo.arguments.contains("-clearLocalThumbnailCache") {
            Task {
                await thumbnails.removeAll()
                await folderCoverThumbnails.removeAll()
                Log.info(.thumbnail, "诊断：本地缩略图缓存已清空")
            }
        }
        imageCache.totalCostLimit = 64 * 1024 * 1024
        aspectRatios = Self.loadAspectRatios()
        folderCoverSelections = Self.loadFolderCoverSelections()
        Self.purgeThumbnailsIfVariantChanged(stores: [thumbnailStore, folderCoverStore])
        reloadFavorites()
        ThumbnailPrewarmBackground.attach(self)
    }

    /// 缩略图算法/尺寸升级后旧文件可能包含半截图或旧分辨率，首次启动直接清空。
    private static func purgeThumbnailsIfVariantChanged(stores: [ThumbnailStore]) {
        let url = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("ThumbnailVariant.txt")
        let stored = try? String(contentsOf: url, encoding: .utf8)
        guard stored != thumbnailVariant else { return }
        Log.info(.thumbnail, "缩略图版本变化，清空旧缓存 variant=\(thumbnailVariant)")
        Task {
            for store in stores {
                await store.removeAll()
            }
            try? thumbnailVariant.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 导航

    /// 枚举当前主机上的共享。失败时至少保留当前共享，不影响播放与浏览。
    func refreshShares() async {
        do {
            let names = try await source.availableShares()
            availableShares = names.contains(source.shareName)
                ? names
                : [source.shareName] + names
            Log.info(.app, "可用共享 host=\(source.hostName) 数量=\(availableShares.count)")
        } catch {
            availableShares = [source.shareName]
            Log.notice(.app, "共享枚举不可用，仅保留当前共享：\(error.localizedDescription)")
        }
    }

    /// 在同一主机内切换共享：复用凭据，清空旧共享的目录/检索/封面缓存后回到新共享根。
    func switchShare(_ share: String) async {
        let target = share.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, target != source.shareName, !isSwitchingShare else { return }
        isSwitchingShare = true
        defer { isSwitchingShare = false }
        onShareWillChange?()
        do {
            try await source.changeShare(target)
            presentation.navigation.changeShare(target)
            loadGeneration += 1
            indexTask?.cancel()
            indexTask = nil
            isIndexing = false
            cancelThumbnailPrewarm()
            entriesByPath.removeAll()
            currentEntries = []
            photoCalendar = PhotoCalendarIndex()
            photoCalendarJump = nil
            pendingScrollTarget = nil
            errorMessage = nil
            lastUpdated = nil
            searchText = ""
            searchHits = []
            searchIndex = LibrarySearchIndex()
            indexedDirectoryCount = 0
            indexTruncated = false
            resetMediaFilter()
            photoLibraryTargetPath = nil
            favoritesOnly = false
            reloadFavorites()
            imageCache.removeAllObjects()
            onPathChanged?("")
            onShareChanged?()
            Log.info(.app, "已切换共享 host=\(source.hostName) share=\(target)")
            await loadCurrent(force: true)
        } catch {
            errorMessage = error.localizedDescription
            Log.error(.app, "切换共享失败 share=\(target) \(error.localizedDescription)")
        }
    }

    func updateShell(_ shell: LibraryShell) {
        guard presentation.shell != shell else { return }
        presentation.switchShell(to: shell)
        Log.info(
            .app,
            "媒体库外壳切换 shell=\(shell.rawValue) 目录=\(Log.shortPath(currentPath.isEmpty ? "/" : currentPath))"
        )
    }

    func loadCurrent(force: Bool = false) async {
        let requestedPath = currentPath
        loadGeneration += 1
        let generation = loadGeneration

        if let cached = entriesByPath[requestedPath] {
            await mergeSidecarAspects()
            currentEntries = cached
            rebuildPhotoCalendar()
            startThumbnailPrewarmIfNeeded()
            isLoading = false
            updateIndex(directoryPath: requestedPath, entries: cached)
            if !force { return }
        } else {
            currentEntries = []
            photoCalendar = PhotoCalendarIndex()
            isLoading = true
        }
        errorMessage = nil

        do {
            let entries = try await source.listDirectory(path: requestedPath)
            guard generation == loadGeneration, requestedPath == currentPath else { return }
            await mergeSidecarAspects()
            entriesByPath[requestedPath] = entries
            currentEntries = entries
            rebuildPhotoCalendar()
            startThumbnailPrewarmIfNeeded()
            isLoading = false
            lastUpdated = Date()
            updateIndex(directoryPath: requestedPath, entries: entries)
            onPathChanged?(requestedPath)
            Log.info(
                .app,
                "媒体库目录 \(requestedPath.isEmpty ? "/" : Log.shortPath(requestedPath)) "
                    + "条目=\(entries.count) 目录=\(entries.filter(\.isDirectory).count)"
            )
        } catch {
            guard generation == loadGeneration, requestedPath == currentPath else { return }
            isLoading = false
            if currentEntries.isEmpty {
                errorMessage = error.localizedDescription
            }
            Log.error(
                .app,
                "媒体库目录加载失败 \(Log.shortPath(requestedPath.isEmpty ? "/" : requestedPath)) "
                    + "\(error.localizedDescription)"
            )
        }
    }

    func refresh() async {
        // 下拉刷新/重试通常意味着网络已恢复；清掉上一轮的超时失败，
        // 让“无预览”的条目有机会重新生成。
        await thumbnails.clearFailures()
        await folderCoverThumbnails.clearFailures()
        await loadCurrent(force: true)
    }

    /// 覆盖远端图片后更新本地列表与检索索引。
    func overwriteImage(path: String, data: Data, modified: Date?) async throws {
        try await source.overwriteImage(path: path, data: data, modified: modified)
        await reloadDirectoryIfNeeded(path: (path as NSString).deletingLastPathComponent)
    }

    /// 同步完成、取消或中断后刷新目标目录缓存；当前就在目标目录时网格与日历会就地更新。
    func refreshDirectoryAfterPhotoSync(path: String) async {
        // 让仍在飞的目录加载失效，避免它用同步前的空列表覆盖刚上传的结果。
        loadGeneration += 1
        entriesByPath.removeValue(forKey: path)
        await reloadDirectoryIfNeeded(path: path)
    }

    private func reloadDirectoryIfNeeded(path: String) async {
        do {
            let entries = try await source.listDirectory(path: path)
            entriesByPath[path] = entries
            if path == currentPath {
                await mergeSidecarAspects()
                currentEntries = entries
                rebuildPhotoCalendar()
                startThumbnailPrewarmIfNeeded()
            }
            updateIndex(directoryPath: path, entries: entries)
        } catch {
            Log.error(
                .app,
                "刷新覆盖后的目录失败 \(Log.shortPath(path.isEmpty ? "/" : path)) \(error.localizedDescription)"
            )
        }
    }

    func enter(_ entry: MediaEntry) {
        guard entry.isDirectory else { return }
        presentation.navigation.enter(entry.name)
        prepareForPathChange()
    }

    func goBack() {
        guard presentation.navigation.goBack() else { return }
        prepareForPathChange()
    }

    func move(to path: String) {
        presentation.navigation.move(to: path)
        prepareForPathChange()
    }

    private func prepareForPathChange() {
        errorMessage = nil
        pendingScrollTarget = nil
        photoCalendarJump = nil
        favoritesOnly = false
        folderCoverPrefetchTask?.cancel()
        folderCoverPrefetchTask = nil
        if let cached = entriesByPath[currentPath] {
            currentEntries = cached
            rebuildPhotoCalendar()
            startThumbnailPrewarmIfNeeded()
            isLoading = false
        } else {
            currentEntries = []
            photoCalendar = PhotoCalendarIndex()
            isLoading = true
        }
    }

    func activate(_ entry: MediaEntry) {
        if entry.isDirectory {
            enter(entry)
        } else if entry.isDocument {
            // 文档由文档列表的 NavigationLink 打开，不能落入视频播放路径。
            Log.debug(.app, "忽略通过播放入口打开文档 \(Log.shortPath(entry.path))")
        } else if entry.isImage {
            requestImageGallery(startingAt: entry)
        } else if preparingPlaybackID == entry.id {
            // 起播准备中，忽略同一个条目的重复点按，避免重复打开 SMB 文件。
            Log.debug(.app, "起播准备中，忽略重复点按 \(Log.shortPath(entry.path))")
        } else if let onPlaybackRequested {
            onPlaybackRequested(entry)
        } else {
            play(entry)
        }
    }

    /// 从搜索结果打开图片相册；目录未加载时先读取该目录。
    @discardableResult
    func openImageGallery(for hit: LibrarySearchHit) async -> Bool {
        let directory = hit.entry.directoryPath
        let entries: [MediaEntry]
        if let cached = entriesByPath[directory] {
            entries = cached
        } else {
            do {
                entries = try await source.listDirectory(path: directory)
                entriesByPath[directory] = entries
                updateIndex(directoryPath: directory, entries: entries)
            } catch {
                errorMessage = error.localizedDescription
                Log.error(
                    .app,
                    "打开图片搜索结果失败 \(Log.shortPath(hit.entry.path)) \(error.localizedDescription)"
                )
                return false
            }
        }

        let images = entries.filter { $0.kind == .image }
        guard !images.isEmpty else { return false }
        // 搜索索引是累积的，命中项可能已被删除或改名；此时不能退回到第一张图。
        guard let index = images.firstIndex(where: { $0.path == hit.entry.path }) else {
            errorMessage = "这张图片已不在目录中"
            Log.info(
                .app,
                "搜索图片已失效 \(Log.shortPath(hit.entry.path))"
            )
            return false
        }
        let session = ImageGallerySession(
            entries: images,
            initialIndex: index,
            source: source,
            title: displayTitle(for: hit.entry)
        )
        guard let onImageGalleryRequested else { return false }
        onImageGalleryRequested(session)
        return true
    }

    private func requestImageGallery(startingAt entry: MediaEntry) {
        let images = contentSections.gridItems.filter { $0.kind == .image }
        let entries = images.isEmpty ? [entry] : images
        let index = entries.firstIndex(where: { $0.path == entry.path }) ?? 0
        let session = ImageGallerySession(
            entries: entries,
            initialIndex: index,
            source: source,
            title: displayTitle(for: entry)
        )
        onImageGalleryRequested?(session)
    }

    func setScrollAnchor(_ entryID: String?) {
        presentation.navigation.setScrollAnchor(entryID, for: currentPath)
    }

    func scrollAnchor(for path: String) -> String? {
        presentation.navigation.scrollAnchor(for: path)
    }

    // MARK: - 检索

    func applySearch(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if favoritesOnly, !trimmed.isEmpty {
            favoritesOnly = false
        }
        searchText = text
        guard !trimmed.isEmpty else {
            searchHits = []
            return
        }
        searchHits = searchIndex.search(trimmed)
        startIndexingIfNeeded()
    }

    private var searchIndex = LibrarySearchIndex()

    private func updateIndex(directoryPath: String, entries: [MediaEntry]) {
        searchIndex.index(directoryPath: directoryPath, entries: entries)
        indexedDirectoryCount = searchIndex.indexedDirectoryCount
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            searchHits = searchIndex.search(trimmed)
        }
    }

    /// 检索时在后台补全索引。只追加，不清空已有结果。
    private func startIndexingIfNeeded() {
        guard indexTask == nil, !indexTruncated else { return }
        isIndexing = true
        indexTask = Task { [weak self] in
            await self?.indexShareInBackground()
        }
    }

    private func indexShareInBackground() async {
        defer {
            isIndexing = false
            indexTask = nil
        }
        var queue: [String] = [""]
        var visited: Set<String> = []

        while !queue.isEmpty, !Task.isCancelled {
            let path = queue.removeFirst()
            guard !visited.contains(path) else { continue }
            visited.insert(path)
            guard visited.count <= 600 else {
                indexTruncated = true
                Log.notice(.app, "媒体库索引达到本次扫描上限 目录数=\(visited.count)")
                break
            }

            let entries: [MediaEntry]
            if let cached = entriesByPath[path] {
                entries = cached
            } else {
                do {
                    entries = try await source.listDirectory(path: path)
                    entriesByPath[path] = entries
                } catch {
                    Log.error(.app, "索引目录失败 \(Log.shortPath(path.isEmpty ? "/" : path)) \(error.localizedDescription)")
                    continue
                }
            }

            updateIndex(directoryPath: path, entries: entries)
            queue.append(contentsOf: entries.filter(\.isDirectory).map(\.path))
            indexedDirectoryCount = searchIndex.indexedDirectoryCount
            await Task.yield()
        }
        Log.info(
            .app,
            "媒体库索引结束 目录=\(indexedDirectoryCount) 条目=\(searchIndex.indexedEntryCount)"
        )
    }

    func reveal(_ hit: LibrarySearchHit) {
        if hit.entry.kind == .video, mediaFilterIsApplicable, !showsVideos {
            // 搜索结果不受目录过滤影响；定位被隐藏的视频时自动恢复该类型。
            showsVideos = true
        }
        let directory = hit.entry.directoryPath
        presentation.navigation.move(to: directory)
        presentation.navigation.setScrollAnchor(hit.entry.id, for: directory)
        prepareForPathChange()
        searchText = ""
        searchHits = []
    }

    // MARK: - 缩略图

    /// 只读内存里已经加载过的缩略图，供播放页/相册占位使用；绝不触发新的读取。
    func cachedThumbnail(for entry: MediaEntry) -> UIImage? {
        guard entry.kind == .video || entry.kind == .image else { return nil }
        return imageCache.object(forKey: thumbnailCacheKey(for: entry))
    }

    private func thumbnailCacheKey(for entry: MediaEntry) -> NSString {
        ThumbnailCacheKey.make(
            path: entry.path,
            size: entry.size,
            modified: entry.modified,
            namespace: thumbnailNamespace
        ) as NSString
    }

    /// 图片宽高比；未知时返回 nil，由单元格缩略图加载后回填。
    func aspectRatio(for entry: MediaEntry) -> CGFloat? {
        guard entry.kind == .image else { return nil }
        return aspectRatios[aspectKey(for: entry)]
    }

    func rememberAspectRatio(_ ratio: CGFloat, for entry: MediaEntry) {
        guard entry.kind == .image, ratio.isFinite, ratio > 0 else { return }
        let clamped = min(2.5, max(0.4, ratio))
        let key = aspectKey(for: entry)
        if let existing = aspectRatios[key], abs(existing - clamped) < 0.01 {
            return
        }
        aspectRatios[key] = clamped
        aspectRatiosDirty = true
        aspectPersistTask?.cancel()
        aspectPersistTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.persistAspectRatiosIfNeeded()
        }
    }

    private func aspectKey(for entry: MediaEntry) -> String {
        aspectKey(path: entry.path)
    }

    private func aspectKey(path: String) -> String {
        // 缩略图版本变化时旧的宽高比可能来自半截图，必须一起失效。
        "\(source.cacheNamespace)|a3|\(path)"
    }

    /// 侧车索引已预热过的照片可以直接拿到宽高比，首屏不再按 2:3 占位后再改。
    private func mergeSidecarAspects() async {
        guard let sidecar = thumbnailSidecarCache else { return }
        let aspects = await sidecar.aspectRatios()
        guard !aspects.isEmpty else { return }
        Log.debug(.thumbnail, "侧车宽高比合并 数量=\(aspects.count)")
        for (path, ratio) in aspects {
            let key = aspectKey(path: path)
            if aspectRatios[key] == nil {
                aspectRatios[key] = min(2.5, max(0.4, ratio))
            }
        }
    }

    func persistAspectRatiosIfNeeded() {
        guard aspectRatiosDirty else { return }
        aspectRatiosDirty = false
        guard let data = try? JSONEncoder().encode(aspectRatios) else { return }
        try? data.write(to: Self.aspectCacheURL, options: .atomic)
    }

    private static var folderCoverSelectionsURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FolderCoverSelections.json")
    }

    private static func loadFolderCoverSelections() -> [String: FolderCoverSelection] {
        guard let data = try? Data(contentsOf: folderCoverSelectionsURL),
              let decoded = try? JSONDecoder().decode(
                [String: FolderCoverSelection].self,
                from: data
              ) else {
            return [:]
        }
        return decoded
    }

    private func persistFolderCoverSelectionsIfNeeded() {
        guard let data = try? JSONEncoder().encode(folderCoverSelections) else { return }
        try? data.write(to: Self.folderCoverSelectionsURL, options: .atomic)
    }

    private static var aspectCacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ThumbnailAspects.json")
    }

    private static func loadAspectRatios() -> [String: CGFloat] {
        guard let data = try? Data(contentsOf: aspectCacheURL),
              let decoded = try? JSONDecoder().decode([String: CGFloat].self, from: data) else {
            return [:]
        }
        return decoded
    }

    /// 已知失败条目不需要再等 400ms 重试；刷新/重连会清空失败集合。
    func isKnownThumbnailFailure(for entry: MediaEntry) async -> Bool {
        guard entry.kind == .video || entry.kind == .image else { return false }
        return await thumbnails.isKnownFailure(
            path: entry.path,
            size: entry.size,
            modified: entry.modified,
            namespace: thumbnailNamespace
        )
    }

    func thumbnail(
        for entry: MediaEntry,
        ensureSidecar: Bool = false
    ) async -> UIImage? {
        guard entry.kind == .video || entry.kind == .image else { return nil }
        let key = thumbnailCacheKey(for: entry)
        if let cached = imageCache.object(forKey: key) {
            if ensureSidecar, let sidecar = thumbnailSidecarCache {
                await storeSidecarIfNeeded(image: cached, entry: entry, sidecar: sidecar)
            }
            return cached
        }
        let contentKind: ThumbnailContentKind
        if entry.isLivePhoto {
            contentKind = .livePhoto
        } else if entry.isImage {
            contentKind = .image
        } else {
            contentKind = .video
        }
        let namespace = thumbnailNamespace
        let outcome = await withTaskCancellationHandler {
            await thumbnails.thumbnail(
                path: entry.path,
                size: entry.size,
                modified: entry.modified,
                namespace: namespace,
                contentKind: contentKind,
                sidecar: thumbnailSidecarCache,
                provider: source
            )
        } onCancel: {
            // 单元格快速滑出屏幕时，别让这次 SMB 读取继续占用缩略图并发槽。
            Task {
                await thumbnails.cancel(
                    path: entry.path,
                    size: entry.size,
                    modified: entry.modified,
                    namespace: namespace
                )
            }
        }
        guard let outcome else {
            return nil
        }
        // PNG 解码/prepare 放到后台，避免滚动时多个封面在主线程解码造成卡顿。
        let data = outcome.data
        let decoded = await Task.detached(priority: .userInitiated) {
            DecodedThumbnail(data: data)
        }.value
        guard let image = decoded.image else { return nil }
        imageCache.setObject(image, forKey: key, cost: outcome.data.count)
        if ensureSidecar, let sidecar = thumbnailSidecarCache {
            // 本地磁盘缓存命中时 ThumbnailService 不会再写侧车；这里补一次。
            await storeSidecarIfNeeded(image: image, entry: entry, sidecar: sidecar)
        }
        return image
    }

    // MARK: - 目录封面

    /// 进入目录后提前生成可见子目录的封面，第二次进入时首屏直接命中缓存。
    private func scheduleFolderCoverPrefetch() {
        folderCoverPrefetchTask?.cancel()
        let directories = Array(currentEntries.filter(\.isDirectory).prefix(12))
        guard !directories.isEmpty else {
            folderCoverPrefetchTask = nil
            return
        }
        folderCoverPrefetchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            for directory in directories {
                if Task.isCancelled { return }
                // 滚动时让路，停止后继续，避免目录封面和可见视频抢带宽。
                while self.gridIsScrolling, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                if Task.isCancelled { return }
                _ = await self.folderCover(for: directory)
            }
        }
    }

    /// 目录封面：取内部视频的中间帧。无视频或全部失败时返回 nil，由界面回退文件夹图标。
    func folderCover(for entry: MediaEntry) async -> UIImage? {
        guard entry.isDirectory else { return nil }
        let folderPath = entry.path
        // 跨启动快速路径：上次选中的内部视频已持久化，直接计算缓存键读本地封面，
        // 完全不枚举 SMB 目录；只有缓存文件被淘汰时才重新解析候选。
        if let selection = folderCoverSelections[folderPath], selection.isFresh {
            let selected = selection.mediaEntry
            let key = folderCoverCacheKey(folderPath: folderPath, video: selected)
            if let cached = imageCache.object(forKey: key) {
                return cached
            }
            let namespace = folderCoverNamespace(folderPath: folderPath)
            if let data = await folderCoverThumbnails.cachedData(
                path: selected.path,
                size: selected.size,
                modified: selected.modified,
                namespace: namespace
            ) {
                let decoded = await Task.detached(priority: .utility) {
                    DecodedThumbnail(data: data)
                }.value
                if Task.isCancelled { return nil }
                if let image = decoded.image {
                    imageCache.setObject(image, forKey: key, cost: data.count)
                    Log.debug(
                        .thumbnail,
                        "目录封面缓存命中（免枚举） \(Log.shortPath(folderPath))"
                    )
                    return image
                }
            }
        }
        if let running = folderCoverTasks[folderPath] {
            return await withTaskCancellationHandler {
                await running.value
            } onCancel: {
                running.cancel()
            }
        }

        let task = Task<UIImage?, Never> { @MainActor [weak self] in
            guard let self else { return nil }
            // 先让可见视频封面和首屏布局稳定，再读目录内部视频。
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return nil }
            return await self.generateFolderCover(for: entry)
        }
        folderCoverTasks[folderPath] = task
        let image = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        folderCoverTasks[folderPath] = nil
        return image
    }

    private func generateFolderCover(for entry: MediaEntry) async -> UIImage? {
        let folderPath = entry.path
        let candidates = await folderCoverCandidates(for: folderPath)
        guard !Task.isCancelled else { return nil }
        guard !candidates.isEmpty else {
            Log.debug(.thumbnail, "目录封面跳过：没有内部视频 \(Log.shortPath(folderPath))")
            return nil
        }

        let namespace = folderCoverNamespace(folderPath: folderPath)
        let service = folderCoverThumbnails
        for candidate in candidates {
            if Task.isCancelled { return nil }
            let key = folderCoverCacheKey(folderPath: folderPath, video: candidate)
            if let cached = imageCache.object(forKey: key) {
                return cached
            }

            let outcome = await withTaskCancellationHandler {
                await service.thumbnail(
                    path: candidate.path,
                    size: candidate.size,
                    modified: candidate.modified,
                    namespace: namespace,
                    contentKind: .video,
                    sidecar: nil,
                    positionFraction: 0.5,
                    provider: source
                )
            } onCancel: {
                Task {
                    await service.cancel(
                        path: candidate.path,
                        size: candidate.size,
                        modified: candidate.modified,
                        namespace: namespace
                    )
                }
            }
            guard !Task.isCancelled else { return nil }
            guard let outcome else { continue }

            let decoded = await Task.detached(priority: .utility) {
                DecodedThumbnail(data: outcome.data)
            }.value
            guard !Task.isCancelled, let image = decoded.image else { continue }
            imageCache.setObject(image, forKey: key, cost: outcome.data.count)
            Log.debug(
                .thumbnail,
                outcome.fromCache
                    ? "目录封面缓存命中 \(Log.shortPath(folderPath))"
                    : "目录封面生成 \(Log.shortPath(folderPath)) <- \(Log.shortPath(candidate.path))"
            )
            return image
        }
        return nil
    }

    /// 直接子视频优先；没有时最多向下两层、扫描 4 个子目录，每个目录最多 3 个候选。
    /// 候选缓存 30 秒，过期后重新枚举以发现内部视频变化。
    private func folderCoverCandidates(for folderPath: String) async -> [MediaEntry] {
        if let cached = folderCoverCandidatesByPath[folderPath],
           let resolvedAt = folderCoverCandidateTimestamps[folderPath],
           Date().timeIntervalSince(resolvedAt) < 30 {
            return cached
        }
        let entries = await folderCoverEntries(for: folderPath)
        var candidates = sortedVideos(in: entries)

        if candidates.isEmpty {
            let subdirectories = entries
                .filter(\.isDirectory)
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                .prefix(4)
            for subdirectory in subdirectories {
                if Task.isCancelled { return [] }
                let subEntries = await folderCoverEntries(for: subdirectory.path)
                if let first = sortedVideos(in: subEntries).first {
                    candidates.append(first)
                }
                if candidates.count >= 3 { break }
            }
        }

        let limited = Array(candidates.prefix(3))
        folderCoverCandidatesByPath[folderPath] = limited
        folderCoverCandidateTimestamps[folderPath] = Date()
        rememberFolderCoverSelection(folderPath: folderPath, video: limited.first)
        return limited
    }

    private func rememberFolderCoverSelection(folderPath: String, video: MediaEntry?) {
        if let video {
            folderCoverSelections[folderPath] = FolderCoverSelection(video: video)
        } else {
            folderCoverSelections[folderPath] = nil
        }
        folderCoverSelectionPersistTask?.cancel()
        folderCoverSelectionPersistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.persistFolderCoverSelectionsIfNeeded()
        }
    }

    /// 候选顺序必须跨启动稳定，否则同一目录每次可能选中不同视频，
    /// 缓存键随之变化，看起来就像“每次都在现生成”。
    private func sortedVideos(in entries: [MediaEntry]) -> [MediaEntry] {
        entries
            .filter { $0.kind == .video }
            .sorted { lhs, rhs in
                if MediaOrdering.areInIncreasingOrder(lhs, rhs) { return true }
                if MediaOrdering.areInIncreasingOrder(rhs, lhs) { return false }
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
    }

    private func folderCoverEntries(for path: String) async -> [MediaEntry] {
        if let cached = folderCoverDirectoryCache[path],
           let resolvedAt = folderCoverDirectoryTimestamps[path],
           Date().timeIntervalSince(resolvedAt) < 30 {
            return cached
        }
        // 已浏览过的目录优先复用主列表；它会在目录重新加载时更新。
        if let cached = entriesByPath[path] {
            folderCoverDirectoryCache[path] = cached
            folderCoverDirectoryTimestamps[path] = Date()
            return cached
        }
        do {
            Log.debug(.thumbnail, "目录封面枚举 \(Log.shortPath(path))")
            let entries = try await source.listDirectory(path: path)
            folderCoverDirectoryCache[path] = entries
            folderCoverDirectoryTimestamps[path] = Date()
            return entries
        } catch {
            Log.debug(
                .thumbnail,
                "目录封面枚举失败 \(Log.shortPath(path)) \(error.localizedDescription)"
            )
            folderCoverDirectoryCache[path] = []
            folderCoverDirectoryTimestamps[path] = Date()
            return []
        }
    }

    func folderCoverCacheKey(folderPath: String, video: MediaEntry) -> NSString {
        ThumbnailCacheKey.make(
            path: video.path,
            size: video.size,
            modified: video.modified,
            namespace: folderCoverNamespace(folderPath: folderPath)
        ) as NSString
    }

    private func folderCoverNamespace(folderPath: String) -> String {
        "\(thumbnailNamespace)|foldercover1|\(folderPath)"
    }

    /// 空闲时预取即将进入视口的封面：网络生成和 PNG 解码都在后台完成，
    /// 真正滚到该条目时直接命中内存缓存。
    func prefetchThumbnails(for entries: [MediaEntry], limit: Int = 8) {
        guard !entries.isEmpty else { return }
        // 全局限流：预取只能占少量后台任务，不能淹没可见单元格或主线程。
        let available = max(0, 12 - prefetchTasks.count)
        guard available > 0 else { return }
        var scheduled = 0
        for entry in entries {
            guard scheduled < min(limit, available) else { break }
            guard entry.kind == .image || entry.kind == .video else { continue }
            if imageCache.object(forKey: thumbnailCacheKey(for: entry)) != nil {
                continue
            }
            if prefetchingIDs.contains(entry.id) { continue }

            prefetchingIDs.insert(entry.id)
            scheduled += 1
            let task = Task { [weak self] in
                // 先让可见单元格进入缩略图并发队列，再启动预取。
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                _ = await self.thumbnail(for: entry)
                self.prefetchingIDs.remove(entry.id)
                self.prefetchTasks[entry.id] = nil
            }
            prefetchTasks[entry.id] = task
        }
        if scheduled > 0 {
            Log.debug(
                .thumbnail,
                "缩略图预取 新增=\(scheduled) 队列=\(prefetchTasks.count)"
            )
        }
    }

    func cancelThumbnailPrefetches() {
        guard !prefetchTasks.isEmpty else { return }
        let count = prefetchTasks.count
        for task in prefetchTasks.values {
            task.cancel()
        }
        prefetchTasks.removeAll()
        prefetchingIDs.removeAll()
        Log.debug(.thumbnail, "缩略图预取 已取消 数量=\(count)")
    }

    private func storeSidecarIfNeeded(
        image: UIImage,
        entry: MediaEntry,
        sidecar: SharedThumbnailCache
    ) async {
        let exists = await sidecar.hasThumbnail(
            path: entry.path,
            size: entry.size,
            modified: entry.modified
        )
        if exists { return }
        let width = Int(image.size.width * image.scale)
        let height = Int(image.size.height * image.scale)
        guard width > 0, height > 0 else { return }
        // 本地缓存回填侧车时也要在后台做 JPEG 编码，避免预热拖慢主线程。
        let encoded = await Task.detached(priority: .utility) {
            SidecarJPEG(image: image)
        }.value
        guard let data = encoded.data else { return }
        await sidecar.store(
            thumbnailData: data,
            width: width,
            height: height,
            path: entry.path,
            size: entry.size,
            modified: entry.modified
        )
    }

    // MARK: - 全量预热

    func setGridScrolling(_ scrolling: Bool) {
        gridIsScrolling = scrolling
        prewarmController?.setScrolling(scrolling)
    }

    func noteVisibleGridEntry(_ id: String) {
        prewarmController?.prioritize([id])
    }

    func pauseThumbnailPrewarm() {
        prewarmController?.pause()
    }

    func resumeThumbnailPrewarm() {
        prewarmController?.resume()
    }

    /// 全屏相册/播放等独占浏览态：暂停预热，关闭后只恢复本态打开前正在运行的任务，
    /// 不覆盖用户手动点下的“暂停”。
    func suspendThumbnailPrewarmForOverlay() {
        guard !prewarmSuspended else { return }
        prewarmSuspended = true
        prewarmWasPausedBeforeSuspend = prewarmController?.isPaused ?? false
        prewarmController?.pause()
    }

    func resumeThumbnailPrewarmAfterOverlay() {
        guard prewarmSuspended else { return }
        prewarmSuspended = false
        if !prewarmWasPausedBeforeSuspend {
            prewarmController?.resume()
        }
        prewarmWasPausedBeforeSuspend = false
        if prewarmDeferred {
            prewarmDeferred = false
            startThumbnailPrewarmIfNeeded()
        }
    }

    func cancelThumbnailPrewarm() {
        prewarmTask?.cancel()
        prewarmTask = nil
        prewarmDeferred = false
        prewarmController?.cancel()
        prewarmController = nil
        folderCoverPrefetchTask?.cancel()
        folderCoverPrefetchTask = nil
    }

    func startThumbnailPrewarmIfNeeded() {
        guard !prewarmSuspended else {
            prewarmDeferred = true
            return
        }
        scheduleFolderCoverPrefetch()
        guard let sidecar = thumbnailSidecarCache else {
            Log.debug(.thumbnail, "缩略图预热跳过：数据源没有共享侧车")
            return
        }
        prewarmTask?.cancel()
        prewarmTask = Task { [weak self] in
            // 先让首屏可见封面抢到 SMB，再开始全量队列。
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            guard !self.prewarmSuspended else {
                self.prewarmDeferred = true
                return
            }
            let available = await sidecar.isAvailable
            let writable = await sidecar.isWritable
            guard available, writable else {
                Log.debug(
                    .thumbnail,
                    "缩略图预热跳过：available=\(available) writable=\(writable)"
                )
                return
            }

            let directoryPath = self.currentPath
            let entries = self.currentEntries.filter {
                $0.kind == .image || $0.kind == .video
            }
            guard !entries.isEmpty else { return }

            // 只清理当前目录范围内的失效条目，不碰其他目录。
            let prefix = directoryPath.isEmpty ? "" : directoryPath + "/"
            let known = await sidecar.entries()
            let currentPaths = Set(entries.map(\.path))
            for stalePath in known.keys
            where stalePath.hasPrefix(prefix) && !currentPaths.contains(stalePath) {
                await sidecar.remove(path: stalePath)
            }

            var missing: [MediaEntry] = []
            missing.reserveCapacity(entries.count)
            for entry in entries {
                let exists = await sidecar.hasThumbnail(
                    path: entry.path,
                    size: entry.size,
                    modified: entry.modified
                )
                if !exists {
                    missing.append(entry)
                }
            }

            guard !Task.isCancelled, self.currentPath == directoryPath else {
                return
            }
            guard !missing.isEmpty else {
                Log.debug(.thumbnail, "缩略图预热跳过：当前目录没有缺失封面")
                self.prewarmController?.cancel()
                self.prewarmController = nil
                self.prewarmTask = nil
                return
            }
            Log.info(
                .thumbnail,
                "缩略图预热启动 缺失=\(missing.count) 目录=\(Log.shortPath(directoryPath))"
            )

            self.prewarmController?.cancel()
            let testDelay = ProcessInfo.processInfo.arguments
                .firstIndex(of: "-prewarmTestDelayMs")
                .flatMap { index -> Int? in
                    let next = ProcessInfo.processInfo.arguments.index(after: index)
                    guard next < ProcessInfo.processInfo.arguments.endIndex else { return nil }
                    return Int(ProcessInfo.processInfo.arguments[next])
                } ?? 0
            let controller = ThumbnailPrewarmController(
                entries: missing,
                onFlush: { await sidecar.flush() }
            ) { [weak self] entry in
                guard let self else { return false }
                if testDelay > 0 {
                    try? await Task.sleep(for: .milliseconds(testDelay))
                }
                return await self.thumbnail(for: entry, ensureSidecar: true) != nil
            }
            self.prewarmController = controller
            controller.start()
            ThumbnailPrewarmBackground.schedule()
        }
    }

    private struct SidecarJPEG: @unchecked Sendable {
        let data: Data?

        init(image: UIImage) {
            data = image.jpegData(compressionQuality: 0.8)
        }
    }

    private struct DecodedThumbnail: @unchecked Sendable {
        let image: UIImage?

        init(data: Data) {
            guard let image = UIImage(data: data) else {
                self.image = nil
                return
            }
            self.image = image.preparingForDisplay() ?? image
        }
    }

    // MARK: - 播放

    /// 视图层决定内联还是全屏；未设置时回落到全屏自检播放。
    var onPlaybackRequested: ((MediaEntry) -> Void)?
    /// 图片点击进入相册；由 LibraryView 绑定全屏覆盖层。
    var onImageGalleryRequested: ((ImageGallerySession) -> Void)?

    /// 为媒体库内联播放创建引擎，并完成字幕轨发现与默认轨加载。
    func preparePlayback(_ entry: MediaEntry, startAt: Double? = nil) async -> PreparedPlayback? {
        guard entry.kind == .video else {
            Log.debug(.app, "拒绝为非视频条目准备播放 \(Log.shortPath(entry.path))")
            return nil
        }
        preparationGeneration += 1
        let generation = preparationGeneration
        preparingPlaybackID = entry.id
        defer {
            // 连续切换条目时，先结束的旧请求不能清掉新条目的加载态。
            if generation == preparationGeneration {
                preparingPlaybackID = nil
            }
        }
        do {
            let source = self.source
            let path = entry.path
            let began = ProcessInfo.processInfo.systemUptime
            let baseSource = try await source.openByteSource(path: path)
            let byteSource: any ByteSource
            if let cache = ContainerHeaderCache.shared {
                let cached = CachedByteSource(
                    base: baseSource,
                    cache: cache,
                    namespace: source.cacheNamespace,
                    path: entry.path,
                    size: entry.size,
                    modified: entry.modified
                )
                await cached.prepare()
                byteSource = cached
            } else {
                byteSource = baseSource
            }
            let sourceOpenMilliseconds = Int(
                (ProcessInfo.processInfo.systemUptime - began) * 1000
            )
            // FFmpeg 的自定义 AVIO 读回调会同步等待 SMB 网络读取（每次预读 4MB），
            // 而等待期间它还要把真正的读操作投递到 Swift 并发池。这里必须用独立线程：
            // 如果占着并发池线程等信号量，读任务可能抢不到线程，大文件时容易卡住。
            let probeBegan = ProcessInfo.processInfo.systemUptime
            let opened = try await Self.openReader(
                byteSource: byteSource,
                path: path,
                fastProbe: true
            )
            let probeMilliseconds = Int(
                (ProcessInfo.processInfo.systemUptime - probeBegan) * 1000
            )
            let openMilliseconds = Int(
                (ProcessInfo.processInfo.systemUptime - began) * 1000
            )
            Log.info(
                .app,
                "播放容器就绪 \(Log.shortPath(entry.path)) 打开探测耗时=\(openMilliseconds)ms "
                    + "SMB打开=\(sourceOpenMilliseconds)ms 探测=\(probeMilliseconds)ms "
                    + "流=\(opened.streams.count)"
            )
            guard !Task.isCancelled else { return nil }

            let embedded = SubtitleDiscovery.embedded(
                opened.streams
                    .filter { $0.kind == .subtitle }
                    .map {
                        SubtitleDiscovery.EmbeddedSource(
                            streamIndex: $0.index,
                            codec: $0.codec,
                            languageTag: $0.language,
                            title: $0.title
                        )
                    }
            )
            let subtitleBegan = ProcessInfo.processInfo.systemUptime
            // 外挂字幕扫描移到起播之后：内封轨先可用，播放不等目录枚举。
            let externalTracksTask = Task { [weak self] in
                await self?.discoverExternalSubtitles(for: entry) ?? []
            }
            let discovered = embedded
            let tracks = discovered.filter { $0.format != .bitmap }
            if tracks.count != discovered.count {
                Log.info(
                    .subtitle,
                    "忽略位图字幕 \(discovered.count - tracks.count) 条（暂不支持）"
                )
            }

            let loader = SubtitleLoader(source: source, entry: entry)
            let candidates = tracks
                .filter { !$0.isForced }
                .sorted { SubtitleDiscovery.order($0.language) < SubtitleDiscovery.order($1.language) }
            Log.info(
                .subtitle,
                "播放字幕发现 文件=\(Log.shortPath(entry.path)) 轨道=\(tracks.count) "
                    + "首选=\(candidates.first?.title ?? "无")（异步加载）"
            )

            let subtitleMilliseconds = Int(
                (ProcessInfo.processInfo.systemUptime - subtitleBegan) * 1000
            )
            // 引擎仍在主线程创建，保持 AVAudioEngine/渲染器的原有线程语义。
            let engineBegan = ProcessInfo.processInfo.systemUptime
            let engine = try PlaybackEngine(reader: opened.reader)
            let openSeconds = Double(
                opened.reader.openInputMilliseconds + opened.reader.streamInfoMilliseconds
            ) / 1000
            // 容器头命中或只读了很小一段时，openBytes/耗时不能代表链路速度；
            // 这时保持“未知”，让引擎用快速档，避免热打开被误判成慢链路。
            let measuredThroughput: Double
            if opened.reader.headerCacheHitRatio > 0.5
                || opened.reader.openBytesRead < 512 * 1024
                || openSeconds <= 0 {
                measuredThroughput = 0
            } else {
                measuredThroughput = Double(opened.reader.openBytesRead) / openSeconds
            }
            if measuredThroughput > 0 {
                engine.setStartupThroughput(bytesPerSecond: measuredThroughput)
            }
            var resumeLocated = true
            if let startAt, startAt > 0 {
                resumeLocated = await engine.prepareSeek(to: startAt)
                Log.info(
                    .app,
                    "续播定位 \(resumeLocated ? "成功" : "失败") "
                        + "目标=\(String(format: "%.1f", startAt))s "
                        + "文件=\(Log.shortPath(entry.path))"
                )
            }
            let engineMilliseconds = Int(
                (ProcessInfo.processInfo.systemUptime - engineBegan) * 1000
            )
            Log.info(
                .app,
                "播放准备拆分 \(Log.shortPath(entry.path)) "
                    + "SMB=\(sourceOpenMilliseconds)ms 探测=\(probeMilliseconds)ms "
                    + "字幕=\(subtitleMilliseconds)ms 引擎=\(engineMilliseconds)ms "
                    + "读取=\(opened.reader.openBytesRead)B/\(opened.reader.openReadCount)次 "
                    + "AVIO填充=\(opened.reader.avioFillCount) "
                    + "附件=\(opened.reader.attachmentBytes)B 字体=\(opened.reader.attachmentFontBytes)B"
            )
            var startup = StartupDiagnostics()
            startup.openBytesRead = opened.reader.openBytesRead
            startup.openReadCount = opened.reader.openReadCount
            startup.avioFillCount = opened.reader.avioFillCount
            startup.attachmentBytes = opened.reader.attachmentBytes
            startup.attachmentFontBytes = opened.reader.attachmentFontBytes
            startup.skippedFontCount = opened.reader.skippedFontCount
            startup.headerCacheHitBytes = opened.reader.headerCacheHitBytes
            startup.headerCacheHitRatio = opened.reader.headerCacheHitRatio
            startup.subtitleScanMilliseconds = subtitleMilliseconds
            // 档位在 play() 时才真正决定；这里先解析，保证验收快照记录的是实际档位。
            engine.resolveStartupPrerollMode()
            startup.startupPrerollMode = engine.startupPrerollMode
            startup.resumeLocated = resumeLocated
            return PreparedPlayback(
                engine: engine,
                tracks: tracks,
                selectedTrack: nil,
                timeline: nil,
                loader: loader,
                sourceOpenMilliseconds: sourceOpenMilliseconds,
                probeMilliseconds: probeMilliseconds,
                subtitleMilliseconds: subtitleMilliseconds,
                engineMilliseconds: engineMilliseconds,
                openInputMilliseconds: opened.reader.openInputMilliseconds,
                streamInfoMilliseconds: opened.reader.streamInfoMilliseconds,
                startup: startup,
                externalTracksTask: externalTracksTask
            )
        } catch {
            playbackFailure = PlaybackFailure.classify(error)
            Log.error(
                .app,
                "打开视频失败 \(Log.shortPath(entry.path)) 类型=\(playbackFailure?.kind.rawValue ?? "other") "
                    + error.localizedDescription
            )
            return nil
        }
    }

    private struct OpenedMediaReader: Sendable {
        let reader: MediaReader
        let streams: [MediaStreamInfo]
    }

    /// 在独立线程上打开容器并读取流信息。
    ///
    /// `MediaReader.open` 是同步调用，内部的 `AVIOBridge` 会用信号量等待 SMB 读结果；
    /// 等待期间读任务本身还要投递到 Swift 并发池。若打开动作直接跑在 `Task.detached`
    /// 上，就会占住并发池线程和读任务抢线程，大文件偶尔会长时间卡住甚至死等。
    /// 因此和播放泵一样，给这段同步阻塞准备一条专用线程。
    private nonisolated static func openReader(
        byteSource: any ByteSource,
        path: String,
        fastProbe: Bool
    ) async throws -> OpenedMediaReader {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                autoreleasepool {
                    do {
                        let reader = try MediaReader.open(
                            source: byteSource,
                            label: path,
                            fastProbe: fastProbe
                        )
                        continuation.resume(
                            returning: OpenedMediaReader(
                                reader: reader,
                                streams: reader.info.streams
                            )
                        )
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            thread.name = "icemovie.library.open"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    func dismissPlaybackFailure() {
        playbackFailure = nil
    }

    private func discoverExternalSubtitles(for entry: MediaEntry) async -> [SubtitleTrack] {
        do {
            let all = try await source.listAllEntries(path: entry.directoryPath)
            var filesByDirectory: [String: [String]] = [
                "": all.filter { !$0.isDirectory }.map(\.name)
            ]
            for directory in all where directory.isDirectory
                && SubtitleDiscovery.isSubtitleDirectory(directory.name) {
                let children = try await source.listAllEntries(path: directory.path)
                filesByDirectory[directory.name] = children
                    .filter { !$0.isDirectory }
                    .map(\.name)
            }
            let tracks = SubtitleDiscovery.external(
                videoFileName: entry.name,
                filesByDirectory: filesByDirectory
            )
            // 诊断：外挂字幕没匹配上时，先看目录里到底有哪些字幕候选文件。
            let candidates = filesByDirectory.flatMap { directory, names in
                names
                    .filter { ["ass", "ssa", "srt", "vtt", "sup", "sub"]
                        .contains(($0 as NSString).pathExtension.lowercased()) }
                    .map { directory.isEmpty ? $0 : "\(directory)/\($0)" }
            }
            Log.debug(
                .subtitle,
                "外挂字幕扫描 目录条目=\(all.count) 候选=\(candidates.count) "
                    + "文件=\(candidates.prefix(12).joined(separator: " / "))"
            )
            for track in tracks {
                Log.info(
                    .subtitle,
                    "外挂匹配 语言=\(track.language.displayName) 文件=\(track.title) 强制=\(track.isForced ? "是" : "否")"
                )
            }
            return tracks
        } catch {
            Log.error(.subtitle, "外挂字幕扫描失败 \(error.localizedDescription)")
            return []
        }
    }

    func play(_ entry: MediaEntry) {
        guard entry.kind == .video else {
            Log.debug(.app, "拒绝播放非视频条目 \(Log.shortPath(entry.path))")
            return
        }
        playbackTask?.cancel()
        playbackTask = Task { [weak self] in
            guard let self else { return }
            guard let prepared = await self.preparePlayback(entry) else { return }
            await MainActor.run {
                VideoTestSession.shared.label = MediaTitleParser.parse(entry.name).title
                VideoTestSession.shared.subtitle = prepared.timeline
                VideoTestSession.shared.engine = prepared.engine
            }
            try? await Task.sleep(for: .milliseconds(600))
            prepared.engine.play()
        }
    }

    func clearCaches() async {
        cancelThumbnailPrewarm()
        imageCache.removeAllObjects()
        aspectRatios.removeAll()
        aspectRatiosDirty = false
        aspectPersistTask?.cancel()
        try? FileManager.default.removeItem(at: Self.aspectCacheURL)
        await thumbnails.removeAll()
        await folderCoverThumbnails.removeAll()
        folderCoverSelections.removeAll()
        folderCoverSelectionPersistTask?.cancel()
        try? FileManager.default.removeItem(at: Self.folderCoverSelectionsURL)
        SubtitleScriptCache.removeAll()
        await ContainerHeaderCache.shared?.clear()
        Log.info(.app, "本地缓存已清空（缩略图 + 目录封面 + 宽高比 + 字幕脚本 + 容器头）")
    }

    func displayTitle(for entry: MediaEntry) -> String {
        if let image = ImageMetadata(entry: entry) {
            return image.title
        }
        if let document = DocumentMetadata(entry: entry) {
            return document.title
        }
        return entry.isDirectory
            ? MediaTitleParser.directoryDisplayName(entry.name)
            : MediaTitleParser.parse(entry.name).title
    }

    /// 播放页标题：文件条目保留集数并放在末尾，方便长标题从头部截断。
    func playbackTitle(for entry: MediaEntry) -> String {
        if entry.isDocument || entry.isImage { return displayTitle(for: entry) }
        return entry.isDirectory
            ? displayTitle(for: entry)
            : MediaTitleParser.playbackTitle(for: entry.name)
    }

    func subtitle(for entry: MediaEntry) -> String {
        if let image = ImageMetadata(entry: entry) {
            var parts = [image.sizeText]
            // 优先使用文件名里的拍摄时间；文件修改时间只是同步/复制时间，
            // 直接展示会让整批照片都变成同一天。
            if let timestamp = entry.captureTimestamp {
                parts.append(timestamp.displayDay)
            } else if let modified = image.modified {
                parts.append(modified.formatted(.dateTime.year().month().day()))
            }
            return parts.joined(separator: " · ")
        }
        if let document = DocumentMetadata(entry: entry) {
            var parts = [document.typeLabel, document.sizeText]
            if let modified = document.modified {
                parts.append(modified.formatted(.dateTime.year().month().day()))
            }
            return parts.joined(separator: " · ")
        }
        if entry.isDirectory {
            if isPhotoLibraryTarget(path: entry.path) {
                return "照片库路径"
            }
            return "文件夹"
        }
        let size = ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
        if let episode = MediaTitleParser.parse(entry.name).episode {
            let formatted = episode.rounded() == episode
                ? String(Int(episode))
                : String(format: "%.1f", episode)
            return "第 \(formatted) 集 · \(size)"
        }
        return size
    }
}
