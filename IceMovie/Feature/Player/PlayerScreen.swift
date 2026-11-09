import IceCore
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
    let subtitleFontSize: Double
    let subtitleBottomPadding: Double
    let subtitleOffset: Double
    let onSelectSubtitle: ((SubtitleTrack?) -> Void)?
    let onAdjustFontSize: ((Double) -> Void)?
    let onAdjustBottomPadding: ((Double) -> Void)?
    let onAdjustOffset: ((Double) -> Void)?
    let resumeNotice: String?
    let onRestartFromBeginning: (() -> Void)?

    @State private var pip: PictureInPictureCoordinator
    @State private var pipActive = false
    @State private var commandToken: UUID?

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
        subtitleFontSize: Double = 22,
        subtitleBottomPadding: Double = 130,
        subtitleOffset: Double = 0,
        onSelectSubtitle: ((SubtitleTrack?) -> Void)? = nil,
        onAdjustFontSize: ((Double) -> Void)? = nil,
        onAdjustBottomPadding: ((Double) -> Void)? = nil,
        onAdjustOffset: ((Double) -> Void)? = nil,
        resumeNotice: String? = nil,
        onRestartFromBeginning: (() -> Void)? = nil
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
        self.subtitleFontSize = subtitleFontSize
        self.subtitleBottomPadding = subtitleBottomPadding
        self.subtitleOffset = subtitleOffset
        self.onSelectSubtitle = onSelectSubtitle
        self.onAdjustFontSize = onAdjustFontSize
        self.onAdjustBottomPadding = onAdjustBottomPadding
        self.onAdjustOffset = onAdjustOffset
        self.resumeNotice = resumeNotice
        self.onRestartFromBeginning = onRestartFromBeginning
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
            pipActive: pipActive,
            onToggleFullscreen: onToggleFullscreen,
            onClose: onClose,
            subtitleTracks: subtitleTracks,
            selectedSubtitle: selectedSubtitle,
            subtitleScript: subtitleScript,
            subtitleFonts: subtitleFonts,
            subtitleFontSize: subtitleFontSize,
            subtitleBottomPadding: subtitleBottomPadding,
            subtitleOffset: subtitleOffset,
            onSelectSubtitle: onSelectSubtitle,
            onAdjustFontSize: onAdjustFontSize,
            onAdjustBottomPadding: onAdjustBottomPadding,
            onAdjustOffset: onAdjustOffset,
            resumeNotice: resumeNotice,
            onRestartFromBeginning: onRestartFromBeginning
        )
        .statusBarHidden(isFullscreen)
        .persistentSystemOverlays(isFullscreen ? .hidden : .automatic)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.surface")
        .onAppear {
            pip.onStateChange = { active in
                pipActive = active
            }
            pipActive = pip.isActive
            commandToken = PlayerCommands.shared.attach(
                engine: engine,
                toggleFullscreen: onToggleFullscreen,
                togglePiP: { pip.toggle() }
            )
        }
        .onDisappear {
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
    let pipActive: Bool
    let onToggleFullscreen: (() -> Void)?
    let onClose: (() -> Void)?
    let subtitleTracks: [SubtitleTrack]
    let selectedSubtitle: SubtitleTrack?
    let subtitleScript: String?
    let subtitleFonts: [SubtitleFont]
    let subtitleFontSize: Double
    let subtitleBottomPadding: Double
    let subtitleOffset: Double
    let onSelectSubtitle: ((SubtitleTrack?) -> Void)?
    let onAdjustFontSize: ((Double) -> Void)?
    let onAdjustBottomPadding: ((Double) -> Void)?
    let onAdjustOffset: ((Double) -> Void)?
    let resumeNotice: String?
    let onRestartFromBeginning: (() -> Void)?

    @State private var controlsVisible = true
    @State private var showSubtitlePanel = false
    @State private var lastInteractionAt = ProcessInfo.processInfo.systemUptime
    @State private var autoHideTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            VideoSurface(renderer: renderer, onLayerReady: { layer in
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

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                PlayerControlsView(
                    engine: engine,
                    visible: $controlsVisible,
                    onInteraction: noteInteraction,
                    onToggleFullscreen: onToggleFullscreen,
                    isFullscreen: isFullscreen,
                    onTogglePiP: { pip.toggle() },
                    isPiPActive: pipActive,
                    isPiPSupported: pip.isSupported,
                    selectedSubtitle: selectedSubtitle,
                    onToggleSubtitlePanel: {
                        showSubtitlePanel.toggle()
                    }
                )
            }

            if !isFullscreen {
                Text("\(label)  \(engine.videoCodecName) / \(engine.audioCodecName)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(10)
                    .allowsHitTesting(false)
            }

            if let onClose {
                VStack {
                    HStack {
                        Spacer()
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
                        .accessibilityLabel("关闭播放")
                    }
                    Spacer()
                }
                .padding(14)
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
                    .padding(.top, 14)
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
    }

    private func handleDoubleTap(x: CGFloat) {
        let forward = x > UIScreen.main.bounds.midX
        let target = min(
            max(0, engine.clock.currentTime + (forward ? 10 : -10)),
            max(0, engine.duration - 0.05)
        )
        onInteraction()
        let id = engine.seek(to: target)
        showHint(
            text: forward ? "快进 10 秒" : "快退 10 秒",
            symbol: forward ? "goforward.10" : "gobackward.10",
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
            if value.startLocation.x < UIScreen.main.bounds.midX {
                verticalSide = .brightness
                verticalStartValue = Double(UIScreen.main.brightness)
            } else {
                verticalSide = .volume
                verticalStartValue = Double(engine.currentVolume)
            }
        }

        let delta = -Double(value.translation.height) / Double(max(1, UIScreen.main.bounds.height))
        let newValue = min(max(verticalStartValue + delta, 0), 1)
        switch verticalSide {
        case .brightness:
            UIScreen.main.brightness = CGFloat(newValue)
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
