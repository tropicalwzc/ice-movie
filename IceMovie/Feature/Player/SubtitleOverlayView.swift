import IceCore
import RenderKit
import SubtitleKit
import SwiftUI

/// 字幕层：ASS 走 libass 保真渲染，SRT 等仍用系统文字。
struct SubtitleOverlayView: View {
    let engine: PlaybackEngine
    let timeline: SubtitleTimeline
    let script: String?
    let fonts: [SubtitleFont]
    var fontSize: Double = 22
    var bottomPadding: Double = 130
    var offset: Double = 0

    var body: some View {
        Group {
            if let script, !script.isEmpty {
                LibassSubtitleView(
                    engine: engine,
                    timeline: timeline,
                    script: script,
                    fonts: fonts,
                    fontSize: fontSize,
                    bottomPadding: bottomPadding,
                    offset: offset
                )
            } else {
                textOverlay
            }
        }
        .allowsHitTesting(false)
    }

    private var textOverlay: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let cues = timeline.active(at: engine.clock.currentTime - offset)
            VStack {
                Spacer()
                VStack(spacing: 6) {
                    ForEach(Array(cues.enumerated()), id: \.offset) { _, cue in
                        Text(cue.text)
                            .font(.system(size: fontSize, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.9), radius: 1, x: 0, y: 1)
                            .shadow(color: .black.opacity(0.6), radius: 3)
                            .accessibilityIdentifier("subtitle.text")
                    }
                }
                .padding(.horizontal, 24)
                // 留出控件区域
                .padding(.bottom, bottomPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// libass 渲染层。位图按视频比例缩放，时间跟随主时钟并应用用户偏移。
private struct LibassSubtitleView: View {
    let engine: PlaybackEngine
    let timeline: SubtitleTimeline
    let script: String
    let fonts: [SubtitleFont]
    let fontSize: Double
    let bottomPadding: Double
    let offset: Double

    @State private var renderer: LibassSubtitleRenderer?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let time = engine.clock.currentTime - offset
            if let image = renderer?.image(at: time) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
                    .overlay(alignment: .topLeading) {
                        // 位图本身不含可访问文本；保留当前台词，便于自动化与旁白。
                        Text(timeline.active(at: time).map(\.text).joined(separator: "\n"))
                            .font(.system(size: 1))
                            .foregroundStyle(.clear)
                            .accessibilityIdentifier("subtitle.currentText")
                    }
            } else {
                Color.clear
            }
        }
        .onAppear {
            rebuild()
        }
        .onChange(of: script) { _, _ in rebuild() }
        .onChange(of: fontSize) { _, value in
            renderer?.setFontScale(value / 22)
        }
        .onChange(of: bottomPadding) { _, value in
            renderer?.setBottomMargin(margin(for: value))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subtitle.libass")
    }

    private func margin(for padding: Double) -> Int {
        Int(padding * Double(LibassSubtitleRenderer.frameHeight) / 900)
    }

    private func rebuild() {
        renderer = LibassSubtitleRenderer(
            script: script,
            fonts: fonts,
            fontScale: fontSize / 22,
            bottomMargin: margin(for: bottomPadding)
        )
        if renderer == nil {
            Log.error(.subtitle, "libass 初始化失败，回退系统文字渲染")
        }
    }
}
