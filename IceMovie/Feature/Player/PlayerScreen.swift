import IceCore
import MediaLibraryKit
import RenderKit
import SubtitleKit
import SwiftUI
import UIKit

/// 播放页。全屏只隐藏系统覆盖层并加宽画面，不重建解码管线；
/// 因此播放位置、字幕时间轴与渲染器在进出全屏时原样保留。
struct PlayerScreen: View {
    let engine: PlaybackEngine
    let renderer: VideoRenderer
    let label: String
    let subtitle: SubtitleTimeline?
    let isFullscreen: Bool
    let onToggleFullscreen: (() -> Void)?
    let onClose: (() -> Void)?
    let subtitleTracks: [SubtitleTrack]
    let selectedSubtitle: SubtitleTrack?
    let subtitleScript: String?
    let subtitleFonts: [SubtitleFont]
    let subtitleLoading: Bool
    let subtitleError: String?
    let subtitleFontSize: Double
    let subtitleBottomPadding: Double
    let subtitleOffset: Double
    let onSelectSubtitle: ((SubtitleTrack?) -> Void)?
    let onAdjustFontSize: ((Double) -> Void)?
    let onAdjustBottomPadding: ((Double) -> Void)?
    let onAdjustOffset: ((Double) -> Void)?
    let resumeNotice: String?
    let onRestartFromBeginning: (() -> Void)?
    let onNextEpisode: (() -> Void)?
    let onPreviousEpisode: (() -> Void)?

    @State private var pip: PictureInPictureCoordinator
    @State private var commandToken: UUID?
    @AppStorage(PlaybackPreferences.pictureInPictureEnabledKey) private var pipEnabled = false

    init(
        engine: PlaybackEngine,
        renderer: VideoRenderer,
        label: String,
        subtitle: SubtitleTimeline?,
        isFullscreen: Bool = true,
        onToggleFullscreen: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil,
        subtitleTracks: [SubtitleTrack] = [],
        selectedSubtitle: SubtitleTrack? = nil,
        subtitleScript: String? = nil,
        subtitleFonts: [SubtitleFont] = [],
        subtitleLoading: Bool = false,
        subtitleError: String? = nil,
        subtitleFontSize: Double = 24,
        subtitleBottomPadding: Double = 130,
        subtitleOffset: Double = 0,
        onSelectSubtitle: ((SubtitleTrack?) -> Void)? = nil,
        onAdjustFontSize: ((Double) -> Void)? = nil,
        onAdjustBottomPadding: ((Double) -> Void)? = nil,
        onAdjustOffset: ((Double) -> Void)? = nil,
        resumeNotice: String? = nil,
        onRestartFromBeginning: (() -> Void)? = nil,
        onNextEpisode: (() -> Void)? = nil,
        onPreviousEpisode: (() -> Void)? = nil
    ) {
        self.engine = engine
        self.renderer = renderer
        self.label = label
        self.subtitle = subtitle
        self.isFullscreen = isFullscreen
        self.onToggleFullscreen = onToggleFullscreen
        self.onClose = onClose
        self.subtitleTracks = subtitleTracks
        self.selectedSubtitle = selectedSubtitle
        self.subtitleScript = subtitleScript
        self.subtitleFonts = subtitleFonts
        self.subtitleLoading = subtitleLoading
        self.subtitleError = subtitleError
        self.subtitleFontSize = subtitleFontSize
        self.subtitleBottomPadding = subtitleBottomPadding
        self.subtitleOffset = subtitleOffset
        self.onSelectSubtitle = onSelectSubtitle
        self.onAdjustFontSize = onAdjustFontSize
        self.onAdjustBottomPadding = onAdjustBottomPadding
        self.onAdjustOffset = onAdjustOffset
        self.resumeNotice = resumeNotice
        self.onRestartFromBeginning = onRestartFromBeginning
        self.onNextEpisode = onNextEpisode
        self.onPreviousEpisode = onPreviousEpisode
        _pip = State(initialValue: PictureInPictureCoordinator(engine: engine))
    }

    var body: some View {
        PlayerSurface(
            engine: engine,
            renderer: renderer,
            label: label,
            subtitle: subtitle,
            isFullscreen: isFullscreen,
            pip: pip,
            pipEnabled: pipEnabled,
            onToggleFullscreen: onToggleFullscreen,
            onClose: onClose,
            subtitleTracks: subtitleTracks,
            selectedSubtitle: selectedSubtitle,
            subtitleScript: subtitleScript,
            subtitleFonts: subtitleFonts,
            subtitleLoading: subtitleLoading,
            subtitleError: subtitleError,
            subtitleFontSize: subtitleFontSize,
            subtitleBottomPadding: subtitleBottomPadding,
            subtitleOffset: subtitleOffset,
            onSelectSubtitle: onSelectSubtitle,
            onAdjustFontSize: onAdjustFontSize,
            onAdjustBottomPadding: onAdjustBottomPadding,
            onAdjustOffset: onAdjustOffset,
            resumeNotice: resumeNotice,
            onRestartFromBeginning: onRestartFromBeginning,
            onNextEpisode: onNextEpisode,
            onPreviousEpisode: onPreviousEpisode
        )
        .statusBarHidden(isFullscreen)
        .persistentSystemOverlays(isFullscreen ? .hidden : .automatic)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.surface")
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            pip.setEnabled(pipEnabled)
            Log.info(.app, "播放页出现")
            commandToken = PlayerCommands.shared.attach(
                engine: engine,
                toggleFullscreen: onToggleFullscreen
            )
        }
        .onChange(of: pipEnabled) { _, enabled in
            pip.setEnabled(enabled)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            Log.info(.app, "播放页消失")
            // 拆掉画中画控制器与显示层引用：协调器挂在 @State 上可能活得更久，
            // 而 ContentSource 会强持有显示层（连带 VideoToolbox 解码会话），
            // 不拆的话每切一个文件就多压一个解码会话在进程里。
            pip.teardown()
            if let commandToken {
                PlayerCommands.shared.detach(token: commandToken)
            }
            commandToken = nil
        }
    }
}

private struct PlayerSurface: View {
    let engine: PlaybackEngine
    let renderer: VideoRenderer
    let label: String
    let subtitle: SubtitleTimeline?
    let isFullscreen: Bool
    let pip: PictureInPictureCoordinator
    let pipEnabled: Bool
    let onToggleFullscreen: (() -> Void)?
    let onClose: (() -> Void)?
    let subtitleTracks: [SubtitleTrack]
    let selectedSubtitle: SubtitleTrack?
    let subtitleScript: String?
    let subtitleFonts: [SubtitleFont]
    let subtitleLoading: Bool
    let subtitleError: String?
    let subtitleFontSize: Double
    let subtitleBottomPadding: Double
    let subtitleOffset: Double
    let onSelectSubtitle: ((SubtitleTrack?) -> Void)?
    let onAdjustFontSize: ((Double) -> Void)?
    let onAdjustBottomPadding: ((Double) -> Void)?
    let onAdjustOffset: ((Double) -> Void)?
    let resumeNotice: String?
    let onRestartFromBeginning: (() -> Void)?
    let onNextEpisode: (() -> Void)?
    let onPreviousEpisode: (() -> Void)?

    @State private var controlsVisible = true
    @State private var showSubtitlePanel = false
    @State private var lastInteractionAt = ProcessInfo.processInfo.systemUptime
    @State private var autoHideTask: Task<Void, Never>?

    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    /// 压测/性能验收：右上角常驻网速、内存与 CPU，且内嵌播放时也要显示。
    private var showsStatusDetails: Bool {
        ProcessInfo.processInfo.arguments.contains("-playerStatusDetails")
    }

    /// iPhone 横屏标题：放不下时按词缩短，末尾保留「第 X 集」；iPad 仍用两行。
    @ViewBuilder
    private var playerTitle: some View {
        if isPad {
            titleLabel(label, lineLimit: 2)
                .frame(maxWidth: 640, alignment: .leading)
        } else {
            ViewThatFits(in: .horizontal) {
                ForEach(
                    Array(PlaybackTitleFitter.candidates(for: label).enumerated()),
                    id: \.offset
                ) { candidate in
                    titleLabel(candidate.element, lineLimit: 1)
                }
            }
        }
    }

    private func titleLabel(_ text: String, lineLimit: Int) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(lineLimit)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55))
            .clipShape(Capsule())
            .accessibilityIdentifier("player.title")
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            VideoSurface(renderer: renderer, onLayerReady: { layer in
                pip.setEnabled(pipEnabled)
                pip.bind(layer: layer)
            })
            .ignoresSafeArea()

            PlayerGestureLayer(
                engine: engine,
                onInteraction: noteInteraction,
                onToggleControls: toggleControls
            )

            BufferingOverlay(engine: engine)
            PlaybackFailureOverlay(engine: engine, onClose: onClose)

            // 顶部栏：返回 + 标题在左，网速/电量与关闭在右；同一行布局避免标题压住状态条。
            if isFullscreen || onClose != nil || showsStatusDetails {
                VStack {
                    HStack(spacing: 12) {
                        if isFullscreen {
                            Button {
                                onClose?()
                            } label: {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 15, weight: .bold))
                                    .frame(width: 34, height: 34)
                                    .background(.black.opacity(0.55))
                                    .clipShape(Circle())
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                            .opacity(controlsVisible ? 1 : 0)
                            .allowsHitTesting(controlsVisible)
                            .accessibilityLabel("返回")
                            .accessibilityIdentifier("player.back")

                            playerTitle
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .opacity(controlsVisible ? 1 : 0)
                                .allowsHitTesting(false)
                        } else {
                            Spacer(minLength: 0)
                        }

                        PlayerStatusBadge(engine: engine)
                            .opacity(showsStatusDetails || controlsVisible ? 1 : 0)
                            .allowsHitTesting(false)

                        if let onClose {
                            Button {
                                onClose()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .frame(width: 34, height: 34)
                                    .background(.black.opacity(0.55))
                                    .clipShape(Circle())
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                            .opacity(controlsVisible ? 1 : 0)
                            .allowsHitTesting(controlsVisible)
                            .accessibilityLabel("关闭播放")
                            .accessibilityIdentifier("player.close")
                        }
                    }
                    Spacer()
                }
                .padding(.top, 12)
                .padding(.horizontal, 14)
                .animation(.easeInOut(duration: 0.2), value: controlsVisible)
            }

            if let subtitle {
                SubtitleOverlayView(
                    engine: engine,
                    timeline: subtitle,
                    script: subtitleScript,
                    fonts: subtitleFonts,
                    fontSize: subtitleFontSize,
                    bottomPadding: subtitleBottomPadding,
                    offset: subtitleOffset
                )
            }

            if subtitleLoading, subtitle == nil {
                VStack {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        Text("字幕加载中…")
                            .font(.caption.weight(.medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.65))
                    .clipShape(Capsule())
                    .foregroundStyle(.white)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("subtitle.loading")
                    Spacer()
                }
                .padding(.top, isFullscreen ? 56 : 16)
                .frame(maxWidth: .infinity, alignment: .center)
                .allowsHitTesting(false)
            }

            if let subtitleError, !subtitleLoading {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text(subtitleError)
                            .font(.caption.weight(.medium))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(.white)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("subtitle.error")
                    Spacer()
                }
                .padding(.top, isFullscreen ? 56 : 16)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .center)
                .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                PlayerControlsView(
                    engine: engine,
                    visible: $controlsVisible,
                    onInteraction: noteInteraction,
                    onToggleFullscreen: onToggleFullscreen,
                    isFullscreen: isFullscreen,
                    selectedSubtitle: selectedSubtitle,
                    onToggleSubtitlePanel: {
                        showSubtitlePanel.toggle()
                    },
                    onPreviousEpisode: onPreviousEpisode,
                    onNextEpisode: onNextEpisode
                )
            }

            if !isFullscreen {
                Text("\(label)  \(engine.videoCodecName) / \(engine.audioCodecName)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(10)
                    .allowsHitTesting(false)
            }

            if let resumeNotice {
                VStack {
                    HStack(spacing: 10) {
                        Text(resumeNotice)
                            .font(.footnote.weight(.semibold))
                            .accessibilityIdentifier("resume.text")
                        Button("从头播放") {
                            onRestartFromBeginning?()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityIdentifier("resume.restart")
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.72))
                    .clipShape(Capsule())
                    .padding(.top, isFullscreen ? 56 : 14)
                    Spacer()
                }
            }
        }
        .sheet(isPresented: $showSubtitlePanel) {
            SubtitlePanel(
                tracks: subtitleTracks,
                selected: selectedSubtitle,
                fontSize: subtitleFontSize,
                bottomPadding: subtitleBottomPadding,
                offset: subtitleOffset,
                onSelect: onSelectSubtitle,
                onAdjustFontSize: onAdjustFontSize,
                onAdjustBottomPadding: onAdjustBottomPadding,
                onAdjustOffset: onAdjustOffset,
                onClose: { showSubtitlePanel = false }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onAppear {
            noteInteraction()
            startAutoHideLoop()
        }
        .onDisappear {
            autoHideTask?.cancel()
        }
    }

    private func noteInteraction() {
        controlsVisible = true
        lastInteractionAt = ProcessInfo.processInfo.systemUptime
        Log.debug(.render, "控件交互 visible=true")
    }

    private func toggleControls() {
        if controlsVisible {
            controlsVisible = false
        } else {
            noteInteraction()
        }
    }

    private func startAutoHideLoop() {
        // 验收脚本用：保持控件常显，避免长等待后测试点击到隐藏按钮的坐标。
        if ProcessInfo.processInfo.arguments.contains("-keepControlsVisible") { return }
        autoHideTask?.cancel()
        autoHideTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                guard controlsVisible, engine.isPlaying else { continue }
                let idle = ProcessInfo.processInfo.systemUptime - lastInteractionAt
                if idle > 3.5 {
                    controlsVisible = false
                    Log.debug(.render, "控件自动隐藏 idle=\(String(format: "%.1f", idle))s")
                }
            }
        }
    }
}

/// 缓冲提示：播放中音频与视频缓冲都低于 250 ms 时显示，数据恢复后自动消失。
private struct BufferingOverlay: View {
    let engine: PlaybackEngine

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { _ in
            if engine.isBuffering {
                VStack(spacing: 10) {
                    ProgressView()
                        .tint(.white)
                    Text("缓冲中…")
                        .font(.footnote.weight(.medium))
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .background(.black.opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(.white)
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("player.buffering")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// 播放中途失败：读取/解码管线报错时盖住画面，允许直接返回媒体库。
private struct PlaybackFailureOverlay: View {
    let engine: PlaybackEngine
    let onClose: (() -> Void)?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            if let detail = engine.statistics.failure {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.yellow)
                    Text("播放中断")
                        .font(.headline)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                    if let onClose {
                        Button("返回媒体库") {
                            onClose()
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("player.failure.close")
                    }
                }
                .padding(24)
                .background(.black.opacity(0.82))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .foregroundStyle(.white)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("player.failure")
            }
        }
    }
}

/// 全屏手势层：单击显隐控件、双击左右快退/快进、竖向拖动调亮度/音量。
private struct PlayerGestureLayer: View {
    let engine: PlaybackEngine
    let onInteraction: () -> Void
    let onToggleControls: () -> Void

    private enum VerticalSide {
        case brightness
        case volume
    }

    @State private var hintText: String?
    @State private var hintSymbol: String?
    @State private var hintValue: Double?
    @State private var hintTask: Task<Void, Never>?
    @State private var verticalSide: VerticalSide?
    @State private var verticalStartValue: Double = 0
    @State private var viewSize: CGSize = .zero

    var body: some View {
        ZStack {
            Color.clear.contentShape(Rectangle())

            if let hintText {
                VStack(spacing: 6) {
                    if let hintSymbol {
                        Image(systemName: hintSymbol)
                            .font(.system(size: 26, weight: .medium))
                    }
                    Text(hintText)
                        .font(.subheadline.weight(.semibold))
                    if let hintValue {
                        Text("\(Int(hintValue * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(.black.opacity(0.68))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(.white)
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("player.hint")
            }
        }
        .simultaneousGesture(
            ExclusiveGesture(
                SpatialTapGesture(count: 2),
                SpatialTapGesture(count: 1)
            )
            .onEnded { value in
                switch value {
                case .first(let tap):
                    handleDoubleTap(x: tap.location.x)
                case .second:
                    onToggleControls()
                }
            }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onChanged(handleVerticalDrag)
                .onEnded { _ in verticalSide = nil }
        )
        .onDisappear { hintTask?.cancel() }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            viewSize = size
        }
    }

    private func handleDoubleTap(x: CGFloat) {
        let forward = x > max(1, viewSize.width) / 2
        let target = min(
            max(0, engine.clock.currentTime + (forward ? PlaybackSeek.step : -PlaybackSeek.step)),
            max(0, engine.duration - 0.05)
        )
        onInteraction()
        let id = engine.seek(to: target)
        showHint(
            text: PlaybackSeek.label(forward: forward),
            symbol: forward ? PlaybackSeek.forwardSymbol : PlaybackSeek.backwardSymbol,
            value: nil
        )
        Log.info(.render, "双击\(forward ? "快进" : "快退") id=\(id) 目标=\(format(target))")
    }

    private func handleVerticalDrag(_ value: DragGesture.Value) {
        let dx = abs(value.translation.width)
        let dy = abs(value.translation.height)
        guard dy > dx * 1.2, dy > 12 else { return }

        if verticalSide == nil {
            onInteraction()
            if value.startLocation.x < max(1, viewSize.width) / 2 {
                verticalSide = .brightness
                verticalStartValue = Double(currentScreen?.brightness ?? 0.5)
            } else {
                verticalSide = .volume
                verticalStartValue = Double(engine.currentVolume)
            }
        }

        let delta = -Double(value.translation.height) / Double(max(1, viewSize.height))
        let newValue = min(max(verticalStartValue + delta, 0), 1)
        switch verticalSide {
        case .brightness:
            currentScreen?.brightness = CGFloat(newValue)
            showHint(text: "亮度", symbol: "sun.max.fill", value: newValue)
        case .volume:
            engine.setVolume(Float(newValue))
            showHint(
                text: "音量",
                symbol: newValue <= 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                value: newValue
            )
        case nil:
            break
        }
    }

    private func showHint(text: String, symbol: String?, value: Double?) {
        hintText = text
        hintSymbol = symbol
        hintValue = value
        hintTask?.cancel()
        hintTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            hintText = nil
            hintSymbol = nil
            hintValue = nil
        }
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    /// 多窗口下不能再用 UIScreen.main；取当前前台窗口所在屏幕。
    private var currentScreen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .screen
    }
}

/// 字幕设置面板：轨道选择 + 字号 / 底部距离 / 时间轴偏移。
private struct SubtitlePanel: View {
    let tracks: [SubtitleTrack]
    let selected: SubtitleTrack?
    let fontSize: Double
    let bottomPadding: Double
    let offset: Double
    let onSelect: ((SubtitleTrack?) -> Void)?
    let onAdjustFontSize: ((Double) -> Void)?
    let onAdjustBottomPadding: ((Double) -> Void)?
    let onAdjustOffset: ((Double) -> Void)?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("字幕")
                    .font(.headline)
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭字幕面板")
            }

            ScrollView {
                VStack(spacing: 4) {
                    trackRow(nil)
                    ForEach(tracks) { track in
                        trackRow(track)
                    }
                }
            }
            .frame(maxHeight: 250)

            Divider()
                .overlay(.white.opacity(0.2))

            settingRow(title: "字号") {
                Button("－") { onAdjustFontSize?(-2) }
                    .accessibilityLabel("字号减小")
                Text("\(Int(fontSize))")
                    .frame(minWidth: 28)
                    .accessibilityIdentifier("subtitle.fontSize")
                Button("＋") { onAdjustFontSize?(2) }
                    .accessibilityLabel("字号增大")
            }

            settingRow(title: "位置") {
                Button("上移") { onAdjustBottomPadding?(20) }
                Text("\(Int(bottomPadding))")
                    .frame(minWidth: 36)
                    .accessibilityIdentifier("subtitle.bottomPadding")
                Button("下移") { onAdjustBottomPadding?(-20) }
            }

            settingRow(title: "偏移") {
                Button("-0.5s") { onAdjustOffset?(-0.5) }
                    .accessibilityLabel("字幕提前")
                Text(String(format: "%+.1fs", offset))
                    .frame(minWidth: 52)
                    .accessibilityIdentifier("subtitle.offset")
                Button("+0.5s") { onAdjustOffset?(0.5) }
                    .accessibilityLabel("字幕延迟")
            }
        }
        .font(.subheadline)
        .padding(16)
        .background(.black.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subtitle.panel")
    }

    private func trackRow(_ track: SubtitleTrack?) -> some View {
        Button {
            onSelect?(track)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected?.id == track?.id ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected?.id == track?.id ? Color.accentColor : .white.opacity(0.4))
                VStack(alignment: .leading, spacing: 2) {
                    Text(track?.language.displayName ?? "关闭字幕")
                    if let track {
                        Text(track.title)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(track.map { "subtitle.track.\($0.id)" } ?? "subtitle.track.off")
    }

    private func settingRow<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 34, alignment: .leading)
            content()
                .buttonStyle(.bordered)
                .tint(.white)
            Spacer(minLength: 0)
        }
    }
}

/// 播放器右上角状态：实时下载速度 + 电量，iPhone 与 iPad 使用同一套紧凑样式。
///
/// 内存/CPU 是排查泄漏用的额外指标，默认不展示；需要时用
/// `-playerStatusDetails` 启动参数打开，布局会加宽并补上这两格。
private struct PlayerStatusBadge: View {
    let engine: PlaybackEngine

    /// 进入播放页时的内存基线，用来区分“本次会话自身增长”与进程历史占用。
    @State private var baselineMB: Double?

    private var showsDetails: Bool {
        ProcessInfo.processInfo.arguments.contains("-playerStatusDetails")
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let speed = engine.downloadBytesPerSecond
            // 隐藏状态（控件淡出且未开压测详情）时不要每秒采样 CPU/内存；
            // CPUUsage 会读取 mach 线程信息，在 4K 播放时属于额外开销。
            let memory = showsDetails ? MemoryFootprint.currentMB : -1
            let cpu = showsDetails ? CPUUsage.currentPercent() : -1
            let battery = BatteryStatus.current
            let memoryTint = tint(for: memory)
            let cpuTint = tint(forCPU: cpu)
            HStack(spacing: showsDetails ? 9 : 7) {
                Image(systemName: "wifi")
                    .font(.caption2)
                Text(speedLabel(speed))
                    .monospacedDigit()
                if showsDetails {
                    Rectangle()
                        .fill(.white.opacity(0.25))
                        .frame(width: 1, height: 12)
                    Image(systemName: "memorychip")
                        .font(.caption2)
                    Text(MemoryFootprint.label(memory))
                        .monospacedDigit()
                        .foregroundStyle(memoryTint)
                    Rectangle()
                        .fill(.white.opacity(0.25))
                        .frame(width: 1, height: 12)
                    Image(systemName: "cpu")
                        .font(.caption2)
                    Text(CPUUsage.label(cpu))
                        .monospacedDigit()
                        .foregroundStyle(cpuTint)
                }
                Rectangle()
                    .fill(.white.opacity(0.25))
                    .frame(width: 1, height: 12)
                batteryIcon(battery)
                Text(battery.label)
                    .monospacedDigit()
                    .foregroundStyle(battery.low ? .red : .white)
            }
            .font(showsDetails ? .caption.weight(.medium) : .caption2.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, showsDetails ? 12 : 10)
            .padding(.vertical, showsDetails ? 7 : 6)
            .background(.black.opacity(0.55))
            .clipShape(Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("player.status")
            .accessibilityLabel(
                "\(speedLabel(speed))，"
                    + (showsDetails
                        ? "内存 \(MemoryFootprint.label(memory))，CPU \(CPUUsage.label(cpu))，"
                        : "")
                    + "电量 \(battery.label)\(battery.isCharging ? "，充电中" : "")"
            )
        }
        .onAppear {
            // 只记一次：TimelineView 每次刷新都会重算 body，不能在 body 里写状态。
            if baselineMB == nil {
                baselineMB = MemoryFootprint.currentMB
            }
            // 电池监控只需开启一次，避免每秒重复写全局状态。
            UIDevice.current.isBatteryMonitoringEnabled = true
        }
    }

    /// 充电时电池图标染绿，并在图标上叠一个小闪电；低电量且未充电时保持红色。
    private func batteryIcon(_ battery: BatteryStatus) -> some View {
        ZStack {
            Image(systemName: battery.symbol)
                .font(.caption)
                .foregroundStyle(battery.isCharging ? .green : (battery.low ? .red : .white))
            if battery.isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: -0.5)
            }
        }
        .accessibilityHidden(true)
    }

    /// 当前占用高、或相对进入时涨得多，都判为异常并变色。
    private func tint(for memory: Double) -> Color {
        guard memory >= 0 else { return .white.opacity(0.5) }
        switch MemoryFootprint.level(currentMB: memory, baselineMB: baselineMB) {
        case .critical: return .red
        case .warning: return .orange
        case .normal: return .white
        }
    }

    /// CPU 是单核百分比：100% 约等于一个核心跑满；多核解码可能超过 100%。
    private func tint(forCPU percent: Double) -> Color {
        guard percent >= 0 else { return .white.opacity(0.5) }
        if percent >= 200 { return .red }
        if percent >= 100 { return .orange }
        return .white
    }

    private func speedLabel(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_048_576 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_048_576)
        }
        if bytesPerSecond >= 1024 {
            return String(format: "%.0f KB/s", bytesPerSecond / 1024)
        }
        return "0 KB/s"
    }
}

private struct BatteryStatus {
    let label: String
    let symbol: String
    let low: Bool
    let isCharging: Bool

    @MainActor
    static var current: BatteryStatus {
        let level = UIDevice.current.batteryLevel
        let state = UIDevice.current.batteryState
        guard level >= 0 else {
            return BatteryStatus(
                label: "--%",
                symbol: "battery.0",
                low: false,
                isCharging: false
            )
        }
        let percent = Int((level * 100).rounded())
        let symbol: String
        switch percent {
        case 76...: symbol = "battery.100"
        case 51...: symbol = "battery.75"
        case 26...: symbol = "battery.50"
        default: symbol = "battery.25"
        }
        let charging = state == .charging || state == .full
        return BatteryStatus(
            label: "\(percent)%",
            symbol: symbol,
            low: percent <= 20 && !charging,
            isCharging: charging
        )
    }
}
