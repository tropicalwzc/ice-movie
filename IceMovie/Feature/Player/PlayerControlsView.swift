import IceCore
import RenderKit
import SubtitleKit
import SwiftUI

/// 底部播放控件：进度条、播放/暂停、±10 秒、全屏。
///
/// 只负责底部这一条；点按、双击与音量/亮度手势由 `PlayerGestureLayer` 处理，
/// 这样按钮与滑块的触摸不会被全屏手势层抢走。
struct PlayerControlsView: View {
    let engine: PlaybackEngine
    @Binding var visible: Bool
    var onInteraction: () -> Void
    var onToggleFullscreen: (() -> Void)?
    var isFullscreen: Bool = false
    var onTogglePiP: (() -> Void)?
    var isPiPActive: Bool = false
    var isPiPSupported: Bool = false
    var selectedSubtitle: SubtitleTrack?
    var onToggleSubtitlePanel: (() -> Void)?

    @State private var isScrubbing = false
    @State private var scrubTarget: Double = 0
    @State private var lastPreviewAt: Double = 0
    @State private var dragStartedAt: Double?
    /// 拖动过程中的手指位置，用 GestureState 保证圆圈逐帧跟手，不等 TimelineView 刷新。
    @GestureState private var scrubX: CGFloat?

    private var timeColumnWidth: CGFloat {
        CGFloat(format(engine.duration).count) * 8 + 4
    }

    private var time: Double {
        isScrubbing ? scrubTarget : engine.clock.currentTime
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            VStack(spacing: 14) {
                HStack(spacing: 16) {
                    button("gobackward.10", label: "快退 10 秒") {
                        onInteraction()
                        engine.seek(to: time - 10)
                    }
                    button(
                        engine.isPlaying ? "pause.fill" : "play.fill",
                        label: engine.isPlaying ? "暂停" : "播放"
                    ) {
                        onInteraction()
                        engine.isPlaying ? engine.pause() : engine.play()
                    }
                    .font(.system(size: 34))
                    button("goforward.10", label: "快进 10 秒") {
                        onInteraction()
                        engine.seek(to: time + 10)
                    }
                    if let onToggleFullscreen {
                        button(
                            isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                            label: isFullscreen ? "退出全屏" : "全屏"
                        ) {
                            onInteraction()
                            onToggleFullscreen()
                        }
                        .font(.system(size: 20))
                    }
                    if let onTogglePiP, isPiPSupported {
                        button(
                            isPiPActive ? "pip.exit" : "pip.enter",
                            label: isPiPActive ? "退出画中画" : "画中画"
                        ) {
                            onInteraction()
                            onTogglePiP()
                        }
                        .font(.system(size: 20))
                    }
                    if let onToggleSubtitlePanel {
                        button(
                            selectedSubtitle == nil ? "captions.bubble" : "captions.bubble.fill",
                            label: "字幕"
                        ) {
                            onInteraction()
                            onToggleSubtitlePanel()
                        }
                        .font(.system(size: 20))
                        .accessibilityValue(selectedSubtitle?.language.displayName ?? "关闭")
                    }
                }
                HStack(spacing: 10) {
                    Text(format(time))
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                        .frame(width: timeColumnWidth, alignment: .leading)
                        .accessibilityIdentifier("player.time")
                    GeometryReader { proxy in
                        progress(width: proxy.size.width)
                    }
                    .frame(height: 28)
                    Text(format(engine.duration))
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                        .frame(width: timeColumnWidth, alignment: .trailing)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.bottom, 26)
            .padding(.top, 36)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.72)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea(edges: .bottom)
            )
            .frame(maxWidth: .infinity)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .animation(.easeInOut(duration: 0.2), value: visible)
        }
    }

    private func button(
        _ systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 24))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func progress(width: CGFloat) -> some View {
        let inset: CGFloat = 10
        let trackWidth = max(1, width - inset * 2)
        let fraction = engine.duration > 0 ? min(max(time / engine.duration, 0), 1) : 0
        let knobX = scrubX.map {
            min(max($0, inset), width - inset)
        } ?? (inset + trackWidth * fraction)
        let bufferedEnd = min(engine.duration, time + engine.bufferedAheadSeconds)
        let bufferedX = inset + trackWidth
            * (engine.duration > 0 ? min(max(bufferedEnd / engine.duration, 0), 1) : 0)
        return Canvas { context, size in
            let midY = size.height / 2
            let track = CGRect(x: inset, y: midY - 2, width: trackWidth, height: 4)
            context.fill(
                Path(roundedRect: track, cornerRadius: 2),
                with: .color(.white.opacity(0.25))
            )
            // 已缓冲区间：浅绿色从当前播放点延伸到预读窗口末端。
            if bufferedX > knobX + 0.5 {
                let buffer = CGRect(
                    x: knobX,
                    y: midY - 2,
                    width: min(bufferedX, width - inset) - knobX,
                    height: 4
                )
                context.fill(
                    Path(roundedRect: buffer, cornerRadius: 2),
                    with: .color(
                        Color(red: 0.55, green: 0.92, blue: 0.65).opacity(0.65)
                    )
                )
            }
            if knobX > inset {
                let fill = CGRect(
                    x: inset,
                    y: midY - 2,
                    width: min(knobX - inset, trackWidth),
                    height: 4
                )
                context.fill(
                    Path(roundedRect: fill, cornerRadius: 2),
                    with: .color(.white)
                )
            }
            // 圆心与填充终点共用同一个 knobX；两侧留出半径，0% 时圆圈也不会被裁掉。
            let radius: CGFloat = isScrubbing ? 8.125 : 6.5
            let knob = CGRect(
                x: knobX - radius,
                y: midY - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.fill(Path(ellipseIn: knob), with: .color(.white))
        }
        .frame(width: width, height: 22)
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        .accessibilityElement()
        .accessibilityIdentifier("player.progress")
        .accessibilityLabel("播放进度")
        .accessibilityValue(
            "\(format(time))，已缓冲 \(Int(max(0, engine.bufferedAheadSeconds))) 秒"
        )
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .updating($scrubX) { value, state, _ in
                    state = min(max(value.location.x, inset), width - inset)
                }
                .onChanged { value in
                    if !isScrubbing {
                        dragStartedAt = ProcessInfo.processInfo.systemUptime
                        Log.info(
                            .render,
                            "拖动开始 位置=\(String(format: "%.2f", time))s"
                        )
                    }
                    isScrubbing = true
                    onInteraction()
                    let ratio = min(max((value.location.x - inset) / trackWidth, 0), 1)
                    scrubTarget = ratio * engine.duration
                    previewIfNeeded()
                }
                .onEnded { value in
                    isScrubbing = false
                    onInteraction()
                    let ratio = min(max((value.location.x - inset) / trackWidth, 0), 1)
                    scrubTarget = ratio * engine.duration
                    let releaseAt = ProcessInfo.processInfo.systemUptime
                    let id = engine.seek(to: scrubTarget, requestedAt: dragStartedAt ?? releaseAt)
                    let latency = Int((releaseAt - (dragStartedAt ?? releaseAt)) * 1000)
                    Log.info(
                        .render,
                        "拖动结束 id=\(id) 目标=\(String(format: "%.2f", scrubTarget))s 拖动时长=\(max(0, latency))ms"
                    )
                    dragStartedAt = nil
                }
        )
    }

    /// 拖动过程中的预览跳转，节流到 250 ms，避免把拉流线程打满。
    private func previewIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPreviewAt > 0.25 else { return }
        lastPreviewAt = now
        engine.seek(to: scrubTarget)
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
