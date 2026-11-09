import DemuxKit
import IceCore
import MediaLibraryKit
import Observation
import PersistenceKit
import RenderKit
import SubtitleKit
import SwiftUI
import UIKit

@MainActor
@Observable
final class LibraryPlaybackSession: Identifiable {
    let id = UUID()
    let engine: PlaybackEngine
    let renderer: VideoRenderer
    let label: String
    let entry: MediaEntry
    let tracks: [SubtitleTrack]
    var selectedTrack: SubtitleTrack?
    var timeline: SubtitleTimeline?
    var subtitleScript: String?
    var subtitleFonts: [SubtitleFont] = []
    var subtitleError: String?
    var subtitleLoading = false
    var fontSize: Double = SubtitlePreferences.fontSize
    var bottomPadding: Double = SubtitlePreferences.bottomPadding
    var subtitleOffset: Double = SubtitlePreferences.offset
    var progressKey: String {
        PlaybackProgressPolicy.key(path: entry.path, size: entry.size, modified: entry.modified)
    }
    private let loader: SubtitleLoader
    private let source: any LibrarySource
    private var subtitleTask: Task<Void, Never>?
    private var shardedLoader: ShardedSubtitleLoader?
    private var collectedCues: [String: SubtitleCue] = [:]
    private var sawSubtitlePackets = false
    private let shardedThresholdBytes: Int64 = {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-shardedThresholdMB"),
           arguments.indices.contains(index + 1),
           let megabytes = Int64(arguments[index + 1]),
           megabytes > 0 {
            return megabytes * 1024 * 1024
        }
        return 800 * 1024 * 1024
    }()

    init(
        engine: PlaybackEngine,
        renderer: VideoRenderer,
        label: String,
        entry: MediaEntry,
        tracks: [SubtitleTrack],
        selectedTrack: SubtitleTrack?,
        timeline: SubtitleTimeline?,
        loader: SubtitleLoader
    ) {
        self.engine = engine
        self.renderer = renderer
        self.label = label
        self.entry = entry
        self.tracks = tracks
        self.selectedTrack = selectedTrack
        self.timeline = timeline
        self.loader = loader
        self.source = loader.source
    }

    private var subtitlesStarted = false

    /// 由播放会话在完成续播 seek 后调用，带上真实起播位置：
    /// 分片字幕直接读目标时间附近，不再先扫 0 秒、也不用空等起播稳定。
    func startSubtitles(at position: Double) {
        guard !subtitlesStarted else { return }
        subtitlesStarted = true
        loadInitialSubtitle(startPosition: position)
    }

    func loadInitialSubtitle(startPosition: Double = 0) {
        guard timeline == nil, SubtitlePreferences.enabled else { return }
        let candidates = SubtitleDiscovery.ordered(
            tracks,
            preferredLanguage: SubtitlePreferences.lastLanguage
        )
        guard !candidates.isEmpty else { return }
        Log.info(
            .subtitle,
            "字幕候选 \(candidates.count) 条 顺序=\(candidates.map(\.language.displayName).joined(separator: " > ")) 上次选择=\(SubtitlePreferences.lastLanguage?.displayName ?? "无")"
        )
        // 大文件 ASS 直接复用播放泵读到的字幕包：必须在 engine.play() 之前同步挂上，
        // 否则第一个 Cluster 的字幕包会被播放泵读掉而错过。
        if let first = candidates.first,
           let index = largeEmbeddedIndex(first) {
            selectedTrack = first
            SubtitlePreferences.lastLanguage = first.language
            startCollected(
                first,
                streamIndex: index,
                fallbackCandidates: Array(candidates.dropFirst())
            )
            return
        }
        loadCandidates(candidates, startPosition: startPosition)
    }

    /// 按顺序尝试候选轨；分片加载失败时也从这里回退到后续候选。
    private func loadCandidates(
        _ candidates: [SubtitleTrack],
        startPosition: Double? = nil
    ) {
        subtitleTask?.cancel()
        shardedLoader?.stop()
        shardedLoader = nil
        engine.setSubtitleCollector(streamIndex: nil, onEvents: nil)
        collectedCues.removeAll()
        sawSubtitlePackets = false
        let position = startPosition ?? engine.clock.currentTime
        subtitleTask = Task { @MainActor [weak self] in
            await self?.loadCandidatesInOrder(candidates, startPosition: position)
        }
    }

    private func loadCandidatesInOrder(
        _ candidates: [SubtitleTrack],
        startPosition: Double
    ) async {
        for (offset, candidate) in candidates.enumerated() {
            if Task.isCancelled { return }
            if let index = largeEmbeddedIndex(candidate) {
                selectedTrack = candidate
                SubtitlePreferences.lastLanguage = candidate.language
                let fallback = Array(candidates.dropFirst(offset + 1))
                startCollected(
                    candidate,
                    streamIndex: index,
                    fallbackCandidates: fallback
                )
                return
            }
            subtitleLoading = true
            do {
                let loaded = try await loader.load(candidate)
                // 取消后仍可能拿到旧任务的结果，不能再覆盖新选择。
                guard !Task.isCancelled else { return }
                guard !loaded.timeline.cues.isEmpty else {
                    subtitleLoading = false
                    continue
                }
                selectedTrack = candidate
                timeline = loaded.timeline
                subtitleScript = loaded.script
                subtitleFonts = loaded.fonts
                subtitleError = nil
                subtitleLoading = false
                SubtitlePreferences.lastLanguage = candidate.language
                Log.info(
                    .subtitle,
                    "默认字幕就绪 \(candidate.title) 语言=\(candidate.language.displayName) "
                        + "条目=\(loaded.timeline.cues.count) 渲染=\(loaded.script == nil ? "系统文字" : "libass")"
                )
                return
            } catch {
                guard !Task.isCancelled else { return }
                subtitleLoading = false
                subtitleError = "\(candidate.title)：\(error.localizedDescription)"
                Log.error(.subtitle, "默认字幕加载失败 \(candidate.title)：\(error.localizedDescription)")
            }
        }
        subtitleLoading = false
    }

    func select(_ track: SubtitleTrack?) {
        if let track, track.format == .bitmap {
            subtitleError = "\(track.title)：位图字幕暂不支持"
            Log.info(.subtitle, "忽略位图字幕选择 \(track.title)")
            return
        }
        subtitleTask?.cancel()
        shardedLoader?.stop()
        shardedLoader = nil
        engine.setSubtitleCollector(streamIndex: nil, onEvents: nil)
        collectedCues.removeAll()
        sawSubtitlePackets = false
        subtitleError = nil
        selectedTrack = track
        SubtitlePreferences.enabled = track != nil
        if let track {
            SubtitlePreferences.lastLanguage = track.language
        }
        guard let track else {
            subtitleTask?.cancel()
            subtitleTask = nil
            subtitleLoading = false
            timeline = nil
            subtitleScript = nil
            subtitleFonts = []
            Log.info(.subtitle, "字幕已关闭")
            return
        }
        if let index = largeEmbeddedIndex(track) {
            startCollected(track, streamIndex: index)
            return
        }
        subtitleLoading = true
        subtitleTask = Task { @MainActor in
            defer { if !Task.isCancelled { subtitleLoading = false } }
            do {
                let began = ProcessInfo.processInfo.systemUptime
                let loaded = try await loader.load(track)
                // 用户可能已经切到另一条字幕：旧结果必须丢弃。
                guard !Task.isCancelled else { return }
                timeline = loaded.timeline
                subtitleScript = loaded.script
                subtitleFonts = loaded.fonts
                subtitleError = nil
                let elapsed = Int((ProcessInfo.processInfo.systemUptime - began) * 1000)
                Log.info(
                    .subtitle,
                    "切换字幕 \(track.title) 语言=\(track.language.displayName) "
                        + "条目=\(loaded.timeline.cues.count) 耗时=\(elapsed)ms "
                        + "渲染=\(loaded.script == nil ? "系统文字" : "libass")"
                )
            } catch {
                guard !Task.isCancelled else { return }
                subtitleError = "\(track.title)：\(error.localizedDescription)"
                Log.error(.subtitle, "切换字幕失败 \(track.title)：\(error.localizedDescription)")
            }
        }
    }

    /// 大文件的内封字幕不再整集扫描，改为按播放位置分片加载。
    private func largeEmbeddedIndex(_ track: SubtitleTrack) -> Int? {
        guard case .embedded(let index) = track.source,
              track.format != .bitmap,
              entry.size >= shardedThresholdBytes else { return nil }
        return index
    }

    /// 大文件 ASS：直接复用播放泵已读到的字幕包，不再为字幕单独扫 SMB。
    private func startCollected(
        _ track: SubtitleTrack,
        streamIndex: Int,
        fallbackCandidates: [SubtitleTrack] = []
    ) {
        shardedLoader?.stop()
        shardedLoader = nil
        subtitleTask?.cancel()
        timeline = nil
        subtitleScript = nil
        subtitleFonts = []
        subtitleError = nil
        subtitleLoading = false
        collectedCues.removeAll()
        sawSubtitlePackets = false
        engine.setSubtitleCollector(streamIndex: streamIndex) { [weak self] events in
            Task { @MainActor [weak self] in
                self?.appendCollected(events)
            }
        }
        Log.info(
            .subtitle,
            "字幕随播放流采集 \(track.title) stream=\(streamIndex) "
                + "文件大小=\(entry.size / 1024 / 1024)MB"
        )
        // 45 秒内连一个字幕包都没读到才回退；冷开场长时间没有对白是正常的。
        subtitleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard let self, !Task.isCancelled else { return }
            guard !self.sawSubtitlePackets, self.collectedCues.isEmpty else { return }
            Log.notice(.subtitle, "播放流未采集到字幕包，回退分片加载")
            self.engine.setSubtitleCollector(streamIndex: nil, onEvents: nil)
            self.startSharded(
                track,
                streamIndex: streamIndex,
                startPosition: self.engine.clock.currentTime,
                fallbackCandidates: fallbackCandidates
            )
        }
    }

    private func appendCollected(_ events: [SubtitlePacketEvent]) {
        sawSubtitlePackets = true
        var changed = false
        for event in events {
            guard let cue = ShardedSubtitleLoader.makeCue(event) else { continue }
            let key = "\(cue.start)|\(cue.end)|\(cue.text)"
            if collectedCues[key] == nil {
                collectedCues[key] = cue
                changed = true
            }
        }
        guard changed else { return }
        let cues = collectedCues.values.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
        timeline = SubtitleTimeline(cues: cues)
        subtitleLoading = false
    }

    private func startSharded(
        _ track: SubtitleTrack,
        streamIndex: Int,
        startPosition: Double,
        fallbackCandidates: [SubtitleTrack] = []
    ) {
        engine.setSubtitleCollector(streamIndex: nil, onEvents: nil)
        collectedCues.removeAll()
        sawSubtitlePackets = false
        shardedLoader?.stop()
        timeline = nil
        subtitleScript = nil
        subtitleFonts = []
        subtitleError = nil
        let loader = ShardedSubtitleLoader(
            engine: engine,
            source: source,
            entry: entry,
            streamIndex: streamIndex
        )
        loader.onCues = { [weak self] cues in
            self?.timeline = SubtitleTimeline(cues: cues)
        }
        loader.onLoadingChange = { [weak self] loading in
            self?.subtitleLoading = loading
        }
        loader.onError = { [weak self] message in
            guard let self else { return }
            self.subtitleError = message.map { "\(track.title)：\($0)" }
            guard let message else { return }
            Log.error(.subtitle, "分片字幕错误：\(message)")
            self.subtitleLoading = false
            guard !fallbackCandidates.isEmpty else { return }
            Log.info(
                .subtitle,
                "分片字幕失败，回退后续候选 \(fallbackCandidates.count) 条 "
                    + "顺序=\(fallbackCandidates.map(\.language.displayName).joined(separator: " > "))"
            )
            self.selectedTrack = nil
            self.loadCandidates(fallbackCandidates)
        }
        shardedLoader = loader
        subtitleLoading = true
        Log.info(
            .subtitle,
            "分片字幕开始 \(track.title) stream=\(streamIndex) 文件大小=\(entry.size / 1024 / 1024)MB "
                + "起播=\(String(format: "%.1f", startPosition))s"
        )
        loader.start(at: startPosition)
    }

    func stopSubtitles() {
        subtitleTask?.cancel()
        subtitleTask = nil
        shardedLoader?.stop()
        shardedLoader = nil
        engine.setSubtitleCollector(streamIndex: nil, onEvents: nil)
        collectedCues.removeAll()
        sawSubtitlePackets = false
    }

    func adjustFontSize(_ delta: Double) {
        fontSize = SubtitlePreferences.clamp(fontSize + delta, 14, 36)
        SubtitlePreferences.fontSize = fontSize
        Log.info(.subtitle, "字幕字号=\(Int(fontSize))")
    }

    func adjustBottomPadding(_ delta: Double) {
        bottomPadding = SubtitlePreferences.clamp(bottomPadding + delta, 60, 260)
        SubtitlePreferences.bottomPadding = bottomPadding
        Log.info(.subtitle, "字幕底部距离=\(Int(bottomPadding))")
    }

    func adjustSubtitleOffset(_ delta: Double) {
        subtitleOffset = SubtitlePreferences.clamp(subtitleOffset + delta, -10, 10)
        SubtitlePreferences.offset = subtitleOffset
        Log.info(.subtitle, "字幕偏移=\(String(format: "%+.1f", subtitleOffset))s")
    }
}

/// 媒体库入口：按实际可用宽度选择单栈或分栏外壳。
/// 两种外壳共享同一个 `LibraryStore`，切换时不重建目录与滚动状态。
struct LibraryView: View {
    @Bindable var store: LibraryStore
    var onDisconnect: (() -> Void)?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var showDiagnostics = ProcessInfo.processInfo.arguments.contains("-diagnostics")
    @State private var appliedLaunchSearch = false
    @State private var appliedLaunchPlayback = false
    @State private var appliedLaunchSeek = false
    @State private var appliedLaunchClose = false
    @State private var playback: LibraryPlaybackSession?
    @State private var isPlayerFullscreen = false
    @State private var inlineGeneration = 0
    @State private var currentShell: LibraryShell = .compact
    @State private var playbackTask: Task<Void, Never>?
    @State private var progressTask: Task<Void, Never>?
    @State private var throughputTask: Task<Void, Never>?
    @State private var autoAdvanceTask: Task<Void, Never>?
    @State private var resumeNotice: String?
    @State private var resumeNoticeTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                let shell = forcedShell
                    ?? (proxy.size.width >= LibraryBreakpoint.regularWidth ? .split : .compact)

                Group {
                    if shell == .split {
                        splitShell
                    } else {
                        compactShell
                    }
                }
                .task(id: shell) {
                    currentShell = shell
                    store.updateShell(shell)
                }
                .task {
                    store.onPlaybackRequested = { entry in
                        openPlayback(entry)
                    }
                    store.onShareWillChange = {
                        closePlayback()
                    }
                    applyLaunchSearchIfNeeded()
                    openLaunchPlaybackIfNeeded()
                }
            }

            // iPhone / 紧凑布局直接用根视图内的全屏层，不经过 fullScreenCover：
            // 系统弹层的视图控制器只报告竖屏，会拒绝 requestGeometryUpdate 的横屏请求。
            if currentShell == .compact, let playback, isPlayerFullscreen {
                fullscreenPlayer
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .zIndex(10)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .environment(store)
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView()
        }
        .onChange(of: scenePhase) { _, phase in
            // 退到后台或切换应用时立即落盘，避免依赖下一次 5 秒轮询。
            if phase != .active { saveProgress() }
        }
        .alert(
            store.playbackFailure?.title ?? "无法播放",
            isPresented: Binding(
                get: { store.playbackFailure != nil },
                set: { if !$0 { store.dismissPlaybackFailure() } }
            ),
            presenting: store.playbackFailure
        ) { _ in
            Button("返回媒体库", role: .cancel) {
                store.dismissPlaybackFailure()
            }
        } message: { failure in
            Text(failure.message)
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { isPlayerFullscreen && currentShell != .compact },
                set: { isPlayerFullscreen = $0 }
            ),
            onDismiss: {
                // 全屏覆盖层持有过渲染器的弱引用；退出后重建内联画面并重新 bind。
                inlineGeneration += 1
            }
        ) {
            fullscreenPlayer
                .onAppear { Log.debug(.app, "全屏播放器已出现") }
                .onDisappear { Log.debug(.app, "全屏播放器已消失") }
        }
        .onChange(of: isPlayerFullscreen) { _, value in
            Log.debug(.app, "全屏状态变化=\(value) 会话=\(playback != nil)")
        }
    }

    @ViewBuilder
    private var fullscreenPlayer: some View {
        if let playback {
            PlayerScreen(
                engine: playback.engine,
                renderer: playback.renderer,
                label: playback.label,
                subtitle: playback.timeline,
                isFullscreen: true,
                onToggleFullscreen: {
                    Log.info(.app, "退出全屏请求，返回内联")
                    if currentShell == .compact {
                        closePlayback()
                    } else {
                        isPlayerFullscreen = false
                    }
                },
                onClose: { closePlayback() },
                subtitleTracks: playback.tracks,
                selectedSubtitle: playback.selectedTrack,
                subtitleScript: playback.subtitleScript,
                subtitleFonts: playback.subtitleFonts,
                subtitleLoading: playback.subtitleLoading,
                subtitleError: playback.subtitleError,
                subtitleFontSize: playback.fontSize,
                subtitleBottomPadding: playback.bottomPadding,
                subtitleOffset: playback.subtitleOffset,
                onSelectSubtitle: { playback.select($0) },
                onAdjustFontSize: { playback.adjustFontSize($0) },
                onAdjustBottomPadding: { playback.adjustBottomPadding($0) },
                onAdjustOffset: { playback.adjustSubtitleOffset($0) },
                resumeNotice: resumeNotice,
                onRestartFromBeginning: { restartPlayback() }
            )
        } else {
            Color.black
                .ignoresSafeArea()
                .onAppear {
                    Log.notice(.app, "全屏内容没有播放会话，关闭全屏")
                    isPlayerFullscreen = false
                }
        }
    }

    private var compactShell: some View {
        NavigationStack {
            LibraryContentPage(
                store: store,
                showsBackButton: true,
                showDiagnostics: $showDiagnostics,
                onDisconnect: disconnectAction
            )
            .id(store.currentPath)
        }
    }

    private var splitShell: some View {
        GeometryReader { proxy in
            let sidebarWidth = min(340, max(260, proxy.size.width * 0.28))
            HStack(spacing: 0) {
                LibrarySidebar()
                    .frame(width: sidebarWidth)
                    .background(Color(uiColor: .secondarySystemBackground))

                Divider()

                VStack(spacing: 0) {
                    if let playback, !isPlayerFullscreen {
                        inlinePlayerBar(playback)
                        PlayerScreen(
                            engine: playback.engine,
                            renderer: playback.renderer,
                            label: playback.label,
                            subtitle: playback.timeline,
                            isFullscreen: false,
                            onToggleFullscreen: nil,
                            onClose: nil,
                            subtitleTracks: playback.tracks,
                            selectedSubtitle: playback.selectedTrack,
                            subtitleScript: playback.subtitleScript,
                            subtitleFonts: playback.subtitleFonts,
                            subtitleLoading: playback.subtitleLoading,
                            subtitleError: playback.subtitleError,
                            subtitleFontSize: playback.fontSize,
                            subtitleBottomPadding: playback.bottomPadding,
                            subtitleOffset: playback.subtitleOffset,
                            onSelectSubtitle: { playback.select($0) },
                            onAdjustFontSize: { playback.adjustFontSize($0) },
                            onAdjustBottomPadding: { playback.adjustBottomPadding($0) },
                            onAdjustOffset: { playback.adjustSubtitleOffset($0) },
                            resumeNotice: resumeNotice,
                            onRestartFromBeginning: { restartPlayback() }
                        )
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .background(Color.black)
                        .clipped()
                        .id("\(playback.id)-\(inlineGeneration)")
                    }

                    NavigationStack {
                        LibraryContentPage(
                            store: store,
                            showsBackButton: false,
                            showDiagnostics: $showDiagnostics,
                            onDisconnect: disconnectAction
                        )
                        .id(store.currentPath)
                    }
                }
            }
        }
    }

    private func inlinePlayerBar(_ playback: LibraryPlaybackSession) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "play.rectangle.fill")
                .foregroundStyle(Color.accentColor)
            Text(playback.label)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.head)
            Text("\(playback.engine.videoCodecName) / \(playback.engine.audioCodecName)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button {
                Log.info(.app, "内联请求全屏")
                isPlayerFullscreen = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 34, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("全屏")
            .accessibilityIdentifier("inline.fullscreen")

            Button {
                closePlayback()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭播放")
            .accessibilityIdentifier("inline.close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var disconnectAction: (() -> Void)? {
        guard let onDisconnect else { return nil }
        return {
            closePlayback()
            onDisconnect()
        }
    }

    /// 仅用于截图与自检：不改变按宽度分叉的产品逻辑。
    private var forcedShell: LibraryShell? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-libraryShell"),
              arguments.indices.contains(index + 1) else { return nil }
        return LibraryShell(rawValue: arguments[index + 1])
    }

    private func openPlayback(_ entry: MediaEntry, fullscreen: Bool = true) {
        // 从搜索框直接点视频时键盘仍在退场，iPhone 上全屏覆盖层可能被系统丢弃，
        // 表现为只有声音、没有播放器界面；先把第一响应者收起来。
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        saveProgress()
        playbackTask?.cancel()
        progressTask?.cancel()
        throughputTask?.cancel()
        autoAdvanceTask?.cancel()
        resumeNoticeTask?.cancel()
        resumeNotice = nil
        playbackTask = Task { @MainActor in
            guard let prepared = await store.preparePlayback(entry),
                  let renderer = prepared.engine.videoRenderer else { return }
            if let old = playback {
                old.stopSubtitles()
                NowPlayingCenter.shared.detach(engine: old.engine)
            }
            playback?.engine.stop()
            let session = LibraryPlaybackSession(
                engine: prepared.engine,
                renderer: renderer,
                label: store.playbackTitle(for: entry),
                entry: entry,
                tracks: prepared.tracks,
                selectedTrack: prepared.selectedTrack,
                timeline: prepared.timeline,
                loader: prepared.loader
            )
            playback = session
            isPlayerFullscreen = fullscreen
            if fullscreen {
                AppOrientation.request(.landscape, delay: .milliseconds(350))
            }
            Log.debug(
                .app,
                "播放会话已建立 请求全屏=\(fullscreen) 当前全屏状态=\(isPlayerFullscreen) "
                    + "会话=\(playback != nil)"
            )
            NowPlayingCenter.shared.attach(engine: prepared.engine, title: session.label)
            let progress = PlaybackProgressStore(context: modelContext)
            let resume = progress.resumePosition(for: session.progressKey)
            // 先挂字幕采集/分片读取，再起播：大文件 ASS 才能接住第一个 Cluster 的字幕包。
            session.startSubtitles(at: resume ?? 0)
            prepared.engine.play()
            if let resume {
                prepared.engine.seek(to: resume)
                showResumeNotice(position: resume)
            }
            startProgressTimer()
            startThroughputReportIfRequested()
            applyLaunchSeekIfNeeded()
            startAutoAdvanceMonitor()
            scheduleLaunchCloseIfNeeded()
            applyLaunchPlaybackRateIfNeeded()

            Log.info(
                .app,
                "\(fullscreen ? "全屏" : "内联")播放开始 \(Log.shortPath(entry.path)) "
                    + "音频=\(prepared.engine.audioCodecName) "
                    + "视频=\(prepared.engine.videoCodecName) 字幕=\(prepared.selectedTrack?.title ?? "无")"
            )
        }
    }

    /// 播放自然结束后自动播放同目录的下一个视频；没有下一个则退回媒体库。
    private func startAutoAdvanceMonitor() {
        autoAdvanceTask?.cancel()
        Log.info(.app, "自动连播监视开始")
        autoAdvanceTask = Task { @MainActor in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let playback else {
                    Log.notice(.app, "自动连播监视退出：播放会话已释放")
                    return
                }
                tick += 1
                if tick % 20 == 0 {
                    let stats = playback.engine.statistics
                    Log.debug(
                        .app,
                        "自动连播监视 位置=\(String(format: "%.1f", playback.engine.clock.currentTime))s "
                            + "drained=\(stats.drained) 失败=\(stats.failure ?? "无")"
                    )
                }
                guard playback.engine.statistics.drained else { continue }
                let finished = playback.entry
                let entries = store.entriesByPath[finished.directoryPath]
                    ?? store.currentEntries
                Log.notice(
                    .app,
                    "检测到播放结束，查找下一集 目录=\(finished.directoryPath) "
                        + "候选=\(entries.count) 当前=\(Log.shortPath(finished.path))"
                )
                guard let next = PlaybackQueue.next(after: finished, in: entries) else {
                    Log.info(.app, "播放结束，没有下一个视频，返回媒体库")
                    closePlayback()
                    return
                }
                Log.notice(
                    .app,
                    "播放结束，自动播放下一集 \(Log.shortPath(next.path))"
                )
                openPlayback(next, fullscreen: isPlayerFullscreen)
                return
            }
        }
    }

    private func startProgressTimer() {
        progressTask?.cancel()
        progressTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                saveProgress()
            }
        }
    }

    private func saveProgress() {
        guard let playback else { return }
        let position = playback.engine.clock.currentTime
        PlaybackProgressStore(context: modelContext).record(
            key: playback.progressKey,
            path: playback.entry.path,
            position: position,
            duration: playback.engine.duration
        )
    }

    private func showResumeNotice(position: Double) {
        resumeNotice = "已续播至 \(formatTime(position))"
        resumeNoticeTask?.cancel()
        resumeNoticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            resumeNotice = nil
        }
        Log.info(
            .app,
            "续播 \(Log.shortPath(playback?.entry.path ?? "")) 位置=\(String(format: "%.1f", position))s"
        )
    }

    private func restartPlayback() {
        guard let playback else { return }
        PlaybackProgressStore(context: modelContext).clear(key: playback.progressKey)
        playback.engine.seek(to: 0)
        resumeNotice = nil
        resumeNoticeTask?.cancel()
        Log.info(.app, "续播提示：从头播放 \(Log.shortPath(playback.entry.path))")
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    /// 真机吞吐验收：`-throughputReport <秒>` 在播放若干秒后写一份 JSON 到 Documents。
    private func startThroughputReportIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-throughputReport"),
              arguments.indices.contains(index + 1),
              let seconds = Double(arguments[index + 1]),
              seconds > 0 else { return }
        throughputTask?.cancel()
        throughputTask = Task { @MainActor in
            let began = Date()
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let playback else { return }
            let elapsed = max(0.001, Date().timeIntervalSince(began))
            let stats = playback.engine.statistics
            let size = playback.entry.size
            let duration = playback.engine.duration
            let readMBps = Double(stats.bytesRead) / elapsed / 1_000_000
            let bitrate = size > 0 && duration > 0
                ? Double(size) * 8 / duration / 1_000_000
                : 0
            let report: [String: Any] = [
                "path": playback.entry.path,
                "fileSizeBytes": size,
                "durationSeconds": duration,
                "sampleSeconds": elapsed,
                "positionSeconds": playback.engine.clock.currentTime,
                "bytesRead": stats.bytesRead,
                "readMBps": readMBps,
                "averageBitrateMbps": bitrate,
                "underruns": stats.underruns,
                "bufferStalls": stats.bufferStalls,
                "bufferSeconds": stats.bufferSeconds,
                "maxBufferStallsPerMinute": stats.maxBufferStallsPerMinute,
                "droppedSeeks": stats.droppedSeeks,
                "seekCount": stats.seekCount,
                "lastSeekLatencyMilliseconds": stats.lastSeekLatencyMilliseconds,
                "lastSeekPrerollFrames": stats.lastSeekPrerollFrames,
                "lastSeekDrift": stats.lastSeekDrift,
                "maxDrift": stats.maxDrift,
                "maxVideoOffset": stats.maxVideoOffset,
                "failure": stats.failure ?? "",
                "videoCodec": playback.engine.videoCodecName,
                "audioCodec": playback.engine.audioCodecName,
                "subtitleTrack": playback.selectedTrack?.title ?? "",
                "subtitleTracks": playback.tracks.map { "\($0.language.displayName):\($0.title)" },
                "subtitleCues": playback.timeline?.cues.count ?? 0,
                "subtitleRender": playback.subtitleScript == nil ? "text" : "libass",
                "subtitleError": playback.subtitleError ?? "",
                "capturedAt": ISO8601DateFormatter().string(from: Date()),
            ]
            do {
                let url = FileManager.default.urls(
                    for: .documentDirectory,
                    in: .userDomainMask
                )[0].appendingPathComponent("ice-throughput.json")
                let data = try JSONSerialization.data(
                    withJSONObject: report,
                    options: [.prettyPrinted, .sortedKeys]
                )
                try data.write(to: url, options: .atomic)
                Log.info(
                    .app,
                    "吞吐报告已写入 Documents/ice-throughput.json "
                        + "读取=\(String(format: "%.2f", readMBps))MB/s "
                        + "平均码率=\(String(format: "%.2f", bitrate))Mbps "
                        + "欠载=\(stats.underruns) 失败=\(stats.failure ?? "无")"
                )
            } catch {
                Log.error(.app, "吞吐报告写入失败：\(error.localizedDescription)")
            }
        }
    }

    /// 真机跳转验收：`-librarySeekTo <秒>` 在起播 3 秒后执行一次 seek。
    private func applyLaunchSeekIfNeeded() {
        guard !appliedLaunchSeek else { return }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-librarySeekTo"),
              arguments.indices.contains(index + 1),
              let target = Double(arguments[index + 1]) else { return }
        appliedLaunchSeek = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard let playback else { return }
            let began = ProcessInfo.processInfo.systemUptime
            playback.engine.seek(to: target, requestedAt: began)
            try? await Task.sleep(for: .seconds(2))
            let stats = playback.engine.statistics
            Log.info(
                .app,
                "真机 seek 目标=\(String(format: "%.1f", target))s "
                    + "落点=\(String(format: "%.1f", playback.engine.clock.currentTime))s "
                    + "首包=\(stats.lastSeekLatencyMilliseconds)ms "
                    + "预滚帧=\(stats.lastSeekPrerollFrames) "
                    + "偏差=\(String(format: "%.2f", stats.lastSeekDrift))s"
            )

            if let backIndex = arguments.firstIndex(of: "-librarySeekBackTo"),
               arguments.indices.contains(backIndex + 1),
               let back = Double(arguments[backIndex + 1]) {
                try? await Task.sleep(for: .seconds(3))
                let id = playback.engine.seek(to: back)
                try? await Task.sleep(for: .seconds(3))
                let after = playback.engine.statistics
                Log.info(
                    .app,
                    "回跳 id=\(id) 目标=\(String(format: "%.1f", back))s "
                        + "落点=\(String(format: "%.1f", playback.engine.clock.currentTime))s "
                        + "音频偏差=\(String(format: "%.3f", after.maxDrift))s "
                        + "显示偏差=\(String(format: "%.3f", after.maxVideoOffset))s "
                        + "欠载=\(after.underruns) 丢弃=\(after.droppedSeeks)"
                )
            }
        }
    }

    /// 验收脚本：`-playbackRate <倍速>` 用于加速长片回归。
    private func applyLaunchPlaybackRateIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-playbackRate"),
              arguments.indices.contains(index + 1),
              let rate = Float(arguments[index + 1]) else { return }
        playback?.engine.setRate(rate)
    }

    /// 验收脚本：`-libraryCloseAfter <秒>` 在起播后若干秒关闭播放，用于验证续播。
    private func scheduleLaunchCloseIfNeeded() {
        guard !appliedLaunchClose else { return }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-libraryCloseAfter"),
              arguments.indices.contains(index + 1),
              let seconds = Double(arguments[index + 1]) else { return }
        appliedLaunchClose = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            Log.notice(.app, "验收脚本：关闭播放以保存续播位置")
            closePlayback()
        }
    }

    private func closePlayback() {
        playbackTask?.cancel()
        progressTask?.cancel()
        throughputTask?.cancel()
        autoAdvanceTask?.cancel()
        resumeNoticeTask?.cancel()
        saveProgress()
        if let playback {
            playback.stopSubtitles()
            NowPlayingCenter.shared.detach(engine: playback.engine)
        }
        playback?.engine.stop()
        playback = nil
        isPlayerFullscreen = false
        resumeNotice = nil
        AppOrientation.request(.portrait, delay: .milliseconds(900))
        Log.info(.app, "播放已关闭，返回媒体库")
    }

    private func applyLaunchSearchIfNeeded() {
        guard !appliedLaunchSearch else { return }
        appliedLaunchSearch = true
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-librarySearch"),
              arguments.indices.contains(index + 1) else { return }
        store.applySearch(arguments[index + 1])
    }

    /// 自动化验收：等待当前目录加载后，按名称直接打开一个视频，
    /// 走与点击条目完全一致的播放路径（内联/全屏、字幕、续播、吞吐报告）。
    private func openLaunchPlaybackIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        guard !appliedLaunchPlayback, arguments.contains("-libraryOpenFirst") else { return }
        appliedLaunchPlayback = true
        let preferred = arguments.firstIndex(of: "-libraryOpenName").flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        }
        Task { @MainActor in
            for _ in 0..<40 where store.currentEntries.allSatisfy(\.isDirectory) {
                try? await Task.sleep(for: .milliseconds(500))
            }
            let entry = store.currentEntries.first {
                guard !$0.isDirectory else { return false }
                guard let preferred, !preferred.isEmpty else { return true }
                return $0.name.localizedCaseInsensitiveContains(preferred)
            } ?? store.currentEntries.first { !$0.isDirectory }
            guard let entry else {
                Log.notice(.app, "自动打开跳过：当前目录没有视频")
                return
            }
            Log.notice(.app, "自动打开 \(Log.shortPath(entry.path))")
            openPlayback(entry)
        }
    }
}

struct LibraryContentPage: View {
    @Bindable var store: LibraryStore
    let showsBackButton: Bool
    @Binding var showDiagnostics: Bool
    var onDisconnect: (() -> Void)?

    private var isSearching: Bool {
        !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if isSearching {
                LibrarySearchResultsView()
            } else {
                LibraryGridView()
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(store.currentTitle)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: Binding(
                get: { store.searchText },
                set: { store.applySearch($0) }
            ),
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "搜索标题或目录"
        )
        .toolbar {
            if showsBackButton, store.canGoBack {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        store.goBack()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("返回上一级")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }

                    Button {
                        store.move(to: "")
                    } label: {
                        Label("回到共享根", systemImage: "house")
                    }
                    .disabled(store.currentPath.isEmpty)

                    if store.availableShares.count > 1 {
                        Section("切换共享") {
                            ForEach(store.availableShares, id: \.self) { share in
                                Button {
                                    Task { await store.switchShare(share) }
                                } label: {
                                    Label(
                                        share,
                                        systemImage: share == store.source.shareName
                                            ? "checkmark.circle.fill"
                                            : "externaldrive"
                                    )
                                }
                                .disabled(store.isSwitchingShare)
                            }
                        }
                    }

                    Divider()

                    Button {
                        showDiagnostics = true
                    } label: {
                        Label("诊断日志", systemImage: "stethoscope")
                    }

                    Button {
                        Task { await store.clearCaches() }
                    } label: {
                        Label("清空缓存", systemImage: "trash")
                    }

                    if let onDisconnect {
                        Divider()
                        Button(role: .destructive) {
                            onDisconnect()
                        } label: {
                            Label("断开并返回连接页", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("更多")
            }
        }
        .task(id: store.currentPath) {
            await store.loadCurrent()
        }
        .task {
            if store.availableShares.isEmpty {
                await store.refreshShares()
            }
        }
        .refreshable {
            await store.refresh()
        }
    }
}
