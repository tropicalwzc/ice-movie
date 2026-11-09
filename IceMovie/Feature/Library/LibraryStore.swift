import DemuxKit
import Foundation
import IceCore
import MediaLibraryKit
import Observation
import RenderKit
import SubtitleKit
import ThumbnailKit
import UIKit

struct PreparedPlayback {
    let engine: PlaybackEngine
    let tracks: [SubtitleTrack]
    let selectedTrack: SubtitleTrack?
    let timeline: SubtitleTimeline?
    let loader: SubtitleLoader
}

/// 媒体库视图模型。
///
/// 目录导航、条目缓存、检索索引与缩略图都放在这里，两种宽度外壳只是它的投影；
/// 切换外壳或重新创建视图不会重建状态（design.md D12）。
@MainActor
@Observable
final class LibraryStore {
    let source: any LibrarySource

    private(set) var presentation: LibraryPresentation
    private(set) var entriesByPath: [String: [MediaEntry]] = [:]
    private(set) var currentEntries: [MediaEntry] = []
    private(set) var isLoading = true
    private(set) var errorMessage: String?
    private(set) var playbackFailure: PlaybackFailure?
    private(set) var lastUpdated: Date?

    var searchText = ""
    private(set) var searchHits: [LibrarySearchHit] = []
    private(set) var isIndexing = false
    private(set) var indexedDirectoryCount = 0
    private(set) var indexTruncated = false
    /// 目录成功加载后回调，用于把最近路径写回 SwiftData。
    var onPathChanged: ((String) -> Void)?
    /// 切换共享前回调，用于停止仍在使用旧共享的播放会话。
    var onShareWillChange: (() -> Void)?
    private(set) var availableShares: [String] = []
    private(set) var isSwitchingShare = false

    private let thumbnails: ThumbnailService
    private let imageCache = NSCache<NSString, UIImage>()
    private var loadGeneration = 0
    private var indexTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?

    var currentPath: String { presentation.navigation.currentPath }
    var canGoBack: Bool { presentation.navigation.canGoBack }
    var breadcrumb: [(name: String, path: String)] { presentation.navigation.breadcrumb }
    var subdirectories: [MediaEntry] { currentEntries.filter(\.isDirectory) }
    var currentTitle: String {
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
        cacheCapacityBytes: Int64 = 150 * 1024 * 1024
    ) throws {
        self.source = source
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
        let thumbnails = ThumbnailService(
            store: try ThumbnailStore(capacityBytes: cacheCapacityBytes)
        )
        self.thumbnails = thumbnails
        Task { await thumbnails.trimToCapacity() }
        imageCache.totalCostLimit = 64 * 1024 * 1024
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
            entriesByPath.removeAll()
            currentEntries = []
            errorMessage = nil
            lastUpdated = nil
            searchText = ""
            searchHits = []
            searchIndex = LibrarySearchIndex()
            indexedDirectoryCount = 0
            indexTruncated = false
            imageCache.removeAllObjects()
            onPathChanged?("")
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
            currentEntries = cached
            isLoading = false
            updateIndex(directoryPath: requestedPath, entries: cached)
            if !force { return }
        } else {
            currentEntries = []
            isLoading = true
        }
        errorMessage = nil

        do {
            let entries = try await source.listDirectory(path: requestedPath)
            guard generation == loadGeneration, requestedPath == currentPath else { return }
            entriesByPath[requestedPath] = entries
            currentEntries = entries
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
        await loadCurrent(force: true)
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
        if let cached = entriesByPath[currentPath] {
            currentEntries = cached
            isLoading = false
        } else {
            currentEntries = []
            isLoading = true
        }
    }

    func activate(_ entry: MediaEntry) {
        if entry.isDirectory {
            enter(entry)
        } else if let onPlaybackRequested {
            onPlaybackRequested(entry)
        } else {
            play(entry)
        }
    }

    func setScrollAnchor(_ entryID: String?) {
        presentation.navigation.setScrollAnchor(entryID, for: currentPath)
    }

    func scrollAnchor(for path: String) -> String? {
        presentation.navigation.scrollAnchor(for: path)
    }

    // MARK: - 检索

    func applySearch(_ text: String) {
        searchText = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let directory = hit.entry.directoryPath
        presentation.navigation.move(to: directory)
        presentation.navigation.setScrollAnchor(hit.entry.id, for: directory)
        prepareForPathChange()
        searchText = ""
        searchHits = []
    }

    // MARK: - 缩略图

    func thumbnail(for entry: MediaEntry) async -> UIImage? {
        guard !entry.isDirectory else { return nil }
        let key = ThumbnailCacheKey.make(
            path: entry.path,
            size: entry.size,
            modified: entry.modified,
            namespace: source.cacheNamespace
        ) as NSString
        if let cached = imageCache.object(forKey: key) {
            return cached
        }
        guard let outcome = await thumbnails.thumbnail(
            path: entry.path,
            size: entry.size,
            modified: entry.modified,
            namespace: source.cacheNamespace,
            provider: source
        ) else {
            return nil
        }
        guard let image = UIImage(data: outcome.data) else { return nil }
        imageCache.setObject(image, forKey: key, cost: outcome.data.count)
        return image
    }

    // MARK: - 播放

    /// 视图层决定内联还是全屏；未设置时回落到全屏自检播放。
    var onPlaybackRequested: ((MediaEntry) -> Void)?

    /// 为媒体库内联播放创建引擎，并完成字幕轨发现与默认轨加载。
    func preparePlayback(_ entry: MediaEntry) async -> PreparedPlayback? {
        do {
            let byteSource = try await self.source.openByteSource(path: entry.path)
            let reader = try MediaReader.open(source: byteSource, label: entry.path)

            let embedded = SubtitleDiscovery.embedded(
                reader.info.streams
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
            let external = await discoverExternalSubtitles(for: entry)
            // 位图字幕（PGS/DVD/DVB）当前没有可用的文本渲染路径，直接排除，
            // 避免默认选轨或用户手选后“已选中但始终不显示”。
            let discovered = embedded + external
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

            let engine = try PlaybackEngine(reader: reader)
            return PreparedPlayback(
                engine: engine,
                tracks: tracks,
                selectedTrack: nil,
                timeline: nil,
                loader: loader
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
        imageCache.removeAllObjects()
        await thumbnails.removeAll()
        SubtitleScriptCache.removeAll()
        Log.info(.app, "本地缓存已清空（缩略图 + 字幕脚本）")
    }

    func displayTitle(for entry: MediaEntry) -> String {
        entry.isDirectory
            ? MediaTitleParser.directoryDisplayName(entry.name)
            : MediaTitleParser.parse(entry.name).title
    }

    /// 播放页标题：文件条目保留集数并放在末尾，方便长标题从头部截断。
    func playbackTitle(for entry: MediaEntry) -> String {
        entry.isDirectory
            ? displayTitle(for: entry)
            : MediaTitleParser.playbackTitle(for: entry.name)
    }

    func subtitle(for entry: MediaEntry) -> String {
        if entry.isDirectory { return "文件夹" }
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
