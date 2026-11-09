import DemuxKit
import IceCore
import MediaLibraryKit
import Observation
import PersistenceKit
import RenderKit
import SubtitleKit
import SwiftData
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
    @State private var stressTask: Task<Void, Never>?

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
                    startStressTestIfRequested()
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
        if let playback {
            writeAcceptanceReport(playback, reason: "replaced")
        }
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
            scheduleLaunchRewindIfNeeded(session)
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

    /// 随机抽样压力测试：从共享根目录递归抽取视频，每条约 1 分钟起播，
    /// 起播 4 秒后立刻 seek 到 50%，记录黑屏/解码恢复/缓冲/字幕指标。
    /// 发现严重问题或达到时间上限自动停止。
    private func startStressTestIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        stressLog("进入 startStressTestIfRequested args=\(arguments.joined(separator: " "))")
        guard arguments.contains("-stressRandom") else { return }
        stressLog("已确认 -stressRandom")
        stressTask?.cancel()
        stressTask = Task { @MainActor in
            let root = argumentValue("-stressRootPath") ?? ""
            let count = Int(argumentValue("-stressCount") ?? "16") ?? 16
            let playSeconds = Double(argumentValue("-stressPlaySeconds") ?? "60") ?? 60
            let seekAfter = Double(argumentValue("-stressSeekAfter") ?? "4") ?? 4
            let seekFraction = Double(argumentValue("-stressSeekFraction") ?? "0.5") ?? 0.5
            let seekBackFraction = Double(argumentValue("-stressSeekBackFraction") ?? "") ?? -1
            let seekBackSeconds = Double(argumentValue("-stressSeekBackSeconds") ?? "") ?? 0
            let seekBackRepeats = max(1, Int(argumentValue("-stressSeekBackRepeats") ?? "1") ?? 1)
            let seekForwardSeconds = Double(argumentValue("-stressSeekForwardSeconds") ?? "") ?? 0
            let timeLimit = Double(argumentValue("-stressTimeLimit") ?? "1800") ?? 1800
            let hdFirst = arguments.contains("-stressHDFirst")
            let tolerateBuffer = arguments.contains("-stressTolerateBufferStalls")
            let began = ProcessInfo.processInfo.systemUptime

            var waited = 0.0
            while store.isLoading && waited < 20 {
                try? await Task.sleep(for: .milliseconds(500))
                waited += 0.5
            }
            stressLog("开始抽样")
            let all = await collectStressVideos(root: root)
            let picks = selectStressVideos(all, count: count, hdFirst: hdFirst)
            stressLog("抽样完成 候选=\(all.count) 选中=\(picks.count)")
            for pick in picks.prefix(20) {
                stressLog("样本 \(pick.path) size=\(pick.size)")
            }
            Log.notice(
                .app,
                "压力测试开始 共享文件=\(all.count) 选中=\(picks.count) "
                    + "每条=\(Int(playSeconds))s 中间点=\(Int(seekFraction * 100))%"
            )
            guard !picks.isEmpty else {
                Log.error(.app, "压力测试没有找到视频")
                writeStressPlan(all: all, picks: picks)
                writeStressSummary(completed: 0, serious: false, reason: "no-videos")
                return
            }
            writeStressPlan(all: all, picks: picks)

            var completed = 0
            var foundSerious = false
            var stopReason = "completed"
            var bufferExceptions = 0
            for (index, entry) in picks.enumerated() {
                if Task.isCancelled { return }
                let elapsed = ProcessInfo.processInfo.systemUptime - began
                if elapsed >= timeLimit {
                    Log.notice(.app, "压力测试达到时间上限 \(Int(timeLimit))s，停止")
                    stopReason = "time-limit"
                    break
                }

                let key = PlaybackProgressPolicy.key(
                    path: entry.path,
                    size: entry.size,
                    modified: entry.modified
                )
                PlaybackProgressStore(context: modelContext).clear(key: key)
                openPlayback(entry, fullscreen: true)

                stressLog("打开 \(entry.path)")
                let readyDeadline = Date().addingTimeInterval(90)
                while playback?.entry.id != entry.id, Date() < readyDeadline {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                guard let session = playback, session.entry.id == entry.id else {
                    stressLog("打开失败 \(entry.path)")
                    Log.error(.app, "压力测试打开失败 \(Log.shortPath(entry.path))")
                    try? appendAcceptanceReport([
                        "reason": "stress-open-failed",
                        "stressIndex": index + 1,
                        "path": entry.path,
                        "fileSizeBytes": entry.size,
                        "capturedAt": ISO8601DateFormatter().string(from: Date()),
                    ])
                    closePlayback(report: false)
                    continue
                }

                stressLog("会话就绪 \(entry.path)")
                Log.notice(
                    .app,
                    "压力测试 [\(index + 1)/\(picks.count)] \(Log.shortPath(entry.path)) "
                        + "大小=\(entry.size / 1024 / 1024)MB"
                )
                try? await Task.sleep(for: .seconds(seekAfter))
                let target = session.engine.duration * seekFraction
                session.engine.seek(to: target)
                Log.notice(
                    .app,
                    "压力测试 seek 目标=\(String(format: "%.1f", target))s"
                )
                let remain = max(1, playSeconds - seekAfter)
                let until = Date().addingTimeInterval(remain)
                var tick = 0
                while Date() < until, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    tick += 1
                    let backStep = tick - 4
                    if backStep >= 0, backStep % 2 == 0, backStep / 2 < seekBackRepeats,
                       seekBackFraction >= 0 || seekBackSeconds > 0 {
                        let backTarget = seekBackSeconds > 0
                            ? max(0, session.engine.clock.currentTime - seekBackSeconds)
                            : session.engine.duration * seekBackFraction
                        session.engine.seek(to: backTarget)
                        stressLog("连续 seek 回退 第\(backStep / 2 + 1)次 目标=\(String(format: "%.1f", backTarget))s")
                    }
                    if tick == 8, seekForwardSeconds > 0 {
                        let forwardTarget = session.engine.clock.currentTime + seekForwardSeconds
                        session.engine.seek(to: forwardTarget)
                        stressLog("二次 seek 前进 \(Int(seekForwardSeconds))s 目标=\(String(format: "%.1f", forwardTarget))s")
                    }
                    let s = session.engine.statistics
                    stressLog(
                        "采样 t=\(tick * 5)s 位置=\(String(format: "%.1f", session.engine.clock.currentTime))s "
                            + "下载=\(String(format: "%.1f", session.engine.downloadBytesPerSecond / 1_048_576))MB/s "
                            + "预读=\(String(format: "%.1f", session.engine.bufferedAheadSeconds))s "
                            + "音频领先=\(String(format: "%.1f", session.engine.bufferedAhead))s "
                            + "视频领先=\(String(format: "%.1f", session.renderer.bufferedAhead))s "
                            + "待消费=\(session.renderer.metrics.pendingDispatch) "
                            + "队列=\(s.videoQueueDepth)/丢\(s.videoQueueDropped)/\(s.videoQueueBytes / 1024 / 1024)MB "
                            + "包=\(s.packetsRead)/\(s.packetsDecoded) 视频包=\(s.videoPackets) 解码=\(String(format: "%.1f", s.decodedSeconds))s "
                            + "音频排入=\(session.engine.audioOutputMetrics?.scheduledBuffers ?? 0)/\(session.engine.audioOutputMetrics?.playedBuffers ?? 0) "
                            + "断层=\(session.engine.audioOutputMetrics?.contentGaps ?? 0) 滞后=\(session.engine.audioOutputMetrics?.lateSchedules ?? 0) "
                            + "字节头=\(session.engine.sourcePlayheadByteOffset)/\(session.engine.sourceReadHeadByteOffset)/\(session.engine.sourcePrefetchHeadByteOffset) "
                            + "缓冲=\(s.bufferStalls)次/\(String(format: "%.1f", s.bufferSeconds))s "
                            + "帧=\(session.renderer.metrics.enqueued) "
                            + "reset=\(session.engine.ringResetCount) "
                            + "命中=\(session.engine.lastSeekCacheHit) "
                            + "seek=\(s.lastSeekLatencyMilliseconds)ms"
                    )
                }

                let stats = session.engine.statistics
                let video = session.renderer.metrics
                stressLog(
                    "结果 首帧=\(stats.firstVideoMilliseconds)ms 视频=\(video.enqueued) "
                        + "恢复=\(video.recoveries) 缓冲=\(stats.bufferStalls)/\(stats.maxBufferStallsPerMinute) "
                        + "状态=\(session.renderer.statusDescription)"
                )
                let noVideo = stats.firstVideoMilliseconds == 0 || video.enqueued == 0
                let decodeFault = video.recoveries > 0
                let buffering = stats.maxBufferStallsPerMinute >= 6
                    || stats.bufferStalls >= 6
                let failed = stats.failure != nil
                let statusFailed = session.renderer.statusDescription.contains("failed")
                // 过热/服务器掉速只记录，不当作代码严重问题中断整轮验收。
                let bufferException = buffering && tolerateBuffer
                let serious = noVideo || decodeFault || failed || statusFailed
                    || (buffering && !tolerateBuffer)
                if bufferException { bufferExceptions += 1 }

                var reasons: [String] = []
                if noVideo { reasons.append("无视频帧") }
                if decodeFault { reasons.append("显示层恢复\(video.recoveries)次") }
                if buffering {
                    reasons.append(
                        bufferException
                            ? "缓冲\(stats.bufferStalls)次/峰值\(stats.maxBufferStallsPerMinute)（环境掉速，已记录）"
                            : "缓冲\(stats.bufferStalls)次/峰值\(stats.maxBufferStallsPerMinute)"
                    )
                }
                if failed { reasons.append("失败:\(stats.failure ?? "")") }
                if statusFailed { reasons.append("层状态:\(session.renderer.statusDescription)") }
                let reason = reasons.isEmpty ? "正常" : reasons.joined(separator: "；")

                Log.notice(
                    .app,
                    "压力测试结果 严重=\(serious) 原因=\(reason) "
                        + "首帧=\(stats.firstVideoMilliseconds)ms "
                        + "视频帧=\(video.enqueued) 缓冲=\(stats.bufferStalls)次 "
                        + "seek=\(stats.lastSeekLatencyMilliseconds)ms/\(String(format: "%.2f", stats.lastSeekDrift))s"
                )

                writeAcceptanceReport(
                    session,
                    reason: "stress",
                    extraReportFields: [
                        "stressIndex": index + 1,
                        "stressTotal": picks.count,
                        "stressSeriousBug": serious,
                        "stressBufferException": bufferException,
                        "stressReason": reason,
                        "stressSeekTarget": target,
                    ]
                )
                closePlayback(report: false)
                completed += 1
                if serious {
                    foundSerious = true
                    stopReason = "serious-bug"
                    Log.error(.app, "压力测试发现严重问题，自动停止：\(reason)")
                    break
                }
                try? await Task.sleep(for: .seconds(1))
            }
            writeStressSummary(
                completed: completed,
                serious: foundSerious,
                reason: stopReason,
                bufferExceptions: bufferExceptions
            )
            Log.notice(.app, "压力测试结束 完成=\(completed) 条")
        }
    }

    /// 压力测试文件日志：真机没有可用的系统日志通道，写到 Documents 便于回传。
    private func stressLog(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ice-stress.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url, options: .atomic)
        }
    }

    private func writeStressPlan(all: [MediaEntry], picks: [MediaEntry]) {
        guard ProcessInfo.processInfo.arguments.contains("-acceptanceReport") else { return }
        try? appendAcceptanceReport([
            "reason": "stress-plan",
            "stressAllCount": all.count,
            "stressPickCount": picks.count,
            "stressPicks": picks.map { ["path": $0.path, "size": $0.size] },
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
        ])
    }

    private func collectStressVideos(root: String) async -> [MediaEntry] {
        _ = root
        var result: [MediaEntry] = []
        var seen = Set<String>()
        func add(_ entry: MediaEntry) {
            // 过滤网站广告占位文件（几百 KB，伪装成 MP4/MKV）和花絮小片段。
            guard entry.isPlayableMedia, entry.size >= 100_000_000,
                  seen.insert(entry.id).inserted else { return }
            result.append(entry)
        }
        for entry in stressEntriesFromHistory() { add(entry) }
        let historyCount = result.count
        for entry in store.currentEntries { add(entry) }
        let currentCount = result.count - historyCount

        // 共享接近 10TB，绝不递归；只列指定起始目录、根目录关键词命中和启动参数目录。
        let deadline = Date().addingTimeInterval(20)
        let startRoot = root.trimmingCharacters(in: .whitespacesAndNewlines)
        if !startRoot.isEmpty {
            let startEntries = (try? await store.source.listAllEntries(path: startRoot)) ?? []
            for entry in startEntries { add(entry) }
            var listedStartDirs = 0
            for directory in startEntries.filter(\.isDirectory).prefix(8) {
                if Task.isCancelled || Date() > deadline { break }
                let entries = (try? await store.source.listAllEntries(path: directory.path)) ?? []
                if !entries.isEmpty { listedStartDirs += 1 }
                for entry in entries { add(entry) }
            }
            stressLog("起始目录 \(startRoot) 条目=\(startEntries.count) 子目录=\(listedStartDirs)")
        }
        var listed = 0
        var paths = (argumentValue("-stressPaths") ?? "")
            .split(separator: "|")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let keywords = ["Solo Leveling", "Transformers", "变形金刚", "American", "无职转生", "K-ON", "KON"]
        var rootEntries = store.currentEntries
        if !rootEntries.contains(where: \.isDirectory) {
            rootEntries = (try? await store.source.listAllEntries(path: "")) ?? []
        }
        stressLog("根目录 \(rootEntries.count) 条：" + rootEntries.prefix(40).map(\.name).joined(separator: " / "))
        for entry in rootEntries where entry.isDirectory {
            if keywords.contains(where: { entry.name.localizedCaseInsensitiveContains($0) }) {
                paths.append(entry.path)
            }
        }
        // 根目录里已经带 4K/UHD 标记的电影目录，最多再列 4 个，避免扫全盘。
        let hdMarkers = ["2160p", "4k", "uhd", "hdr"]
        let hdDirectories = rootEntries.filter { entry in
            entry.isDirectory && hdMarkers.contains { marker in
                entry.name.lowercased().contains(marker)
            }
        }.shuffled().prefix(4)
        for directory in hdDirectories {
            paths.append(directory.path)
        }
        var seenPaths = Set<String>()
        paths = paths.filter { seenPaths.insert($0).inserted }
        for path in paths.prefix(12) {
            if Task.isCancelled || Date() > deadline { break }
            let entries = (try? await store.source.listAllEntries(path: path)) ?? []
            if !entries.isEmpty { listed += 1 }
            for entry in entries { add(entry) }
        }
        if let filter = argumentValue("-stressFilter"), !filter.isEmpty {
            result = result.filter { $0.path.localizedCaseInsensitiveContains(filter) }
        }
        Log.notice(
            .app,
            "压力测试抽样 历史=\(historyCount) 当前目录=\(currentCount) "
                + "指定目录=\(listed)/\(paths.count) 合计=\(result.count)"
        )
        stressLog("抽样明细 历史=\(historyCount) 当前=\(currentCount) 指定=\(listed)/\(paths.count) 合计=\(result.count)")
        return result
    }

    /// 从 SwiftData 续播历史构造样本：共享近 10TB，绝不能靠枚举，
    /// 历史里已有播放过的 1080p / 4K / 长片，直接复用路径和大小。
    private func stressEntriesFromHistory() -> [MediaEntry] {
        var descriptor = FetchDescriptor<PlaybackProgressRecord>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 40
        let records = (try? modelContext.fetch(descriptor)) ?? []
        return records.compactMap { record in
            let parts = record.key.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { return nil }
            let size = Int64(parts[parts.count - 2]) ?? 0
            guard size > 0 else { return nil }
            let stamp = Int64(parts[parts.count - 1]) ?? 0
            let modified = stamp > 0 ? Date(timeIntervalSince1970: TimeInterval(stamp)) : nil
            let name = (record.path as NSString).lastPathComponent
            guard !name.isEmpty else { return nil }
            return MediaEntry(
                path: record.path,
                name: name,
                isDirectory: false,
                size: size,
                modified: modified
            )
        }
    }

    private func selectStressVideos(
        _ videos: [MediaEntry],
        count: Int,
        hdFirst: Bool
    ) -> [MediaEntry] {
        var picks: [MediaEntry] = []
        var used = Set<String>()
        var perDirectory: [String: Int] = [:]
        let maxPerDirectory = 3
        func add(_ entry: MediaEntry?) {
            guard picks.count < count, let entry, used.insert(entry.id).inserted else { return }
            let directory = entry.directoryPath
            guard (perDirectory[directory] ?? 0) < maxPerDirectory else { return }
            perDirectory[directory, default: 0] += 1
            picks.append(entry)
        }
        let lower: (MediaEntry) -> String = { $0.path.lowercased() }
        let is4K: (MediaEntry) -> Bool = {
            $0.fileExtension == "mkv"
                && (lower($0).contains("2160p") || lower($0).contains("4k"))
        }
        // 第一条小 MP4 让画面尽快出来；随后保证 1080p、4K、长片都有覆盖。
        add(videos.filter { $0.fileExtension == "mp4" && $0.size < 1_500_000_000 }.randomElement())
        if hdFirst {
            // 验收用：最大 4K HDR 优先，避免服务器连续读大文件后冷读掉速影响判定。
            for entry in videos.filter(is4K).sorted(by: { $0.size > $1.size }).prefix(3) {
                add(entry)
            }
        } else {
            add(videos.filter {
                $0.fileExtension == "mkv"
                    && !lower($0).contains("2160p")
                    && !lower($0).contains("4k")
            }.randomElement())
            add(videos.filter(is4K).randomElement())
            add(videos.filter(is4K).randomElement())
            add(videos.filter(is4K).randomElement())
        }
        add(videos.filter { $0.size > 5_000_000_000 }.randomElement())
        add(videos.filter { $0.size > 2_000_000_000 }.randomElement())
        add(videos.filter { $0.fileExtension == "mp4" }.randomElement())
        for entry in videos.shuffled() where picks.count < count {
            add(entry)
        }
        return picks
    }

    private func argumentValue(_ flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// 验收脚本：每集播到 `-libraryRewindAt` 后回退到 `-libraryRewindTo`，用于长片压力验收。
    private func scheduleLaunchRewindIfNeeded(_ session: LibraryPlaybackSession) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let atIndex = arguments.firstIndex(of: "-libraryRewindAt"),
              arguments.indices.contains(atIndex + 1),
              let at = Double(arguments[atIndex + 1]),
              let toIndex = arguments.firstIndex(of: "-libraryRewindTo"),
              arguments.indices.contains(toIndex + 1),
              let target = Double(arguments[toIndex + 1]),
              at > target, target >= 0 else { return }
        Task { @MainActor [weak session] in
            guard let session else { return }
            while !Task.isCancelled {
                guard playback === session else { return }
                if session.engine.clock.currentTime >= at {
                    session.engine.seek(to: target)
                    Log.notice(
                        .app,
                        "验收脚本：回退 \(String(format: "%.0f", at))s → "
                            + "\(String(format: "%.0f", target))s"
                    )
                    return
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    /// 验收脚本：`-acceptanceReport` 时把每集结束时的缓冲/字幕指标追加到 Documents/ice-acceptance.json。
    private func writeAcceptanceReport(
        _ session: LibraryPlaybackSession,
        reason: String,
        extraReportFields: [String: Any]? = nil
    ) {
        guard ProcessInfo.processInfo.arguments.contains("-acceptanceReport") else { return }
        let stats = session.engine.statistics
        let size = session.entry.size
        let duration = session.engine.duration
        let bitrate = size > 0 && duration > 0
            ? Double(size) * 8 / duration / 1_000_000
            : 0
        let video = session.renderer.metrics
        var report: [String: Any] = [
            "path": session.entry.path,
            "reason": reason,
            "fileSizeBytes": size,
            "durationSeconds": duration,
            "audioCodec": session.engine.audioCodecName,
            "videoCodec": session.engine.videoCodecName,
            "averageBitrateMbps": bitrate,
            "positionSeconds": session.engine.clock.currentTime,
            "startupMilliseconds": stats.startupMilliseconds,
            "firstVideoMilliseconds": stats.firstVideoMilliseconds,
            "videoEnqueued": video.enqueued,
            "videoRecoveries": video.recoveries,
            "videoLastRecovery": video.lastRecoveryReason ?? "",
            "videoDroppedWhileUnbound": video.droppedWhileUnbound,
            "videoBufferedAhead": session.renderer.bufferedAhead,
            "videoStatus": session.renderer.statusDescription,
            "videoQueueDepth": stats.videoQueueDepth,
            "videoQueueDropped": stats.videoQueueDropped,
            "videoQueueBytes": stats.videoQueueBytes,
            "downloadBytesPerSecond": session.engine.downloadBytesPerSecond,
            "bufferedAheadSeconds": session.engine.bufferedAheadSeconds,
            "seekCacheHit": session.engine.lastSeekCacheHit,
            "seekCacheHits": session.engine.seekCacheHits,
            "seekCacheMisses": session.engine.seekCacheMisses,
            "ringResetCount": session.engine.ringResetCount,
            "bytesRead": stats.bytesRead,
            "packetsRead": stats.packetsRead,
            "bufferStalls": stats.bufferStalls,
            "bufferSeconds": stats.bufferSeconds,
            "maxBufferStallsPerMinute": stats.maxBufferStallsPerMinute,
            "underruns": stats.underruns,
            "maxDrift": stats.maxDrift,
            "maxDriftPosition": stats.maxDriftPosition,
            "maxDriftAudioTime": stats.maxDriftAudioTime,
            "maxDriftClockTime": stats.maxDriftClockTime,
            "clockJumpCount": stats.clockJumpCount,
            "maxVideoOffset": stats.maxVideoOffset,
            "seekCount": stats.seekCount,
            "lastSeekLatencyMilliseconds": stats.lastSeekLatencyMilliseconds,
            "lastSeekDrift": stats.lastSeekDrift,
            "lastSeekPrerollFrames": stats.lastSeekPrerollFrames,
            "subtitleTrack": session.selectedTrack?.title ?? "",
            "subtitleCues": session.timeline?.cues.count ?? 0,
            "subtitleError": session.subtitleError ?? "",
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let extra = extraReportFields {
            report.merge(extra) { _, new in new }
        }
        do {
            try appendAcceptanceReport(report)
            Log.notice(
                .app,
                "验收报告已追加 \(Log.shortPath(session.entry.path)) "
                    + "缓冲=\(stats.bufferStalls)次/\(String(format: "%.1f", stats.bufferSeconds))s "
                    + "峰值=\(stats.maxBufferStallsPerMinute)/min "
                    + "字幕=\(session.timeline?.cues.count ?? 0)条"
            )
        } catch {
            Log.error(.app, "验收报告写入失败：\(error.localizedDescription)")
        }
    }

    private func appendAcceptanceReport(_ report: [String: Any]) throws {
        let url = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("ice-acceptance.json")
        var items: [[String: Any]] = []
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            items = existing
        }
        items.append(report)
        let data = try JSONSerialization.data(
            withJSONObject: items,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }

    private func writeStressSummary(
        completed: Int,
        serious: Bool,
        reason: String,
        bufferExceptions: Int = 0
    ) {
        guard ProcessInfo.processInfo.arguments.contains("-acceptanceReport") else { return }
        let summary: [String: Any] = [
            "reason": "stress-summary",
            "stressDone": true,
            "stressCompleted": completed,
            "stressSeriousFound": serious,
            "stressBufferExceptions": bufferExceptions,
            "stressStopReason": reason,
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        do {
            try appendAcceptanceReport(summary)
            Log.notice(
                .app,
                "压力测试总结已写入 完成=\(completed) 严重=\(serious) 原因=\(reason)"
            )
        } catch {
            Log.error(.app, "压力测试总结写入失败：\(error.localizedDescription)")
        }
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

    private func closePlayback(report: Bool = true) {
        if report, let playback {
            writeAcceptanceReport(playback, reason: "closed")
        }
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
