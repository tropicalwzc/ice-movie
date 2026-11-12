import Foundation
import IceCore
import QuartzCore
import UIKit

/// 滚动期间用 CADisplayLink 统计真实交付帧率。
/// 只在带 `-fpsMonitor` 启动时工作，避免正常使用产生额外开销。
@MainActor
final class ScrollFPSMonitor: NSObject {
    static let shared = ScrollFPSMonitor()

    private let enabled = ProcessInfo.processInfo.arguments.contains("-fpsMonitor")
    private var displayLink: CADisplayLink?
    private var startedAt: CFTimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    private var lastReport: CFTimeInterval = 0
    private var frames = 0
    private var droppedFrames = 0
    private var active = false

    func begin(reason: String) {
        guard enabled, !active else { return }
        active = true
        startedAt = CACurrentMediaTime()
        lastTick = startedAt
        lastReport = startedAt
        frames = 0
        droppedFrames = 0
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        Log.info(.app, "FPS 监测开始 \(reason)")
    }

    func end() {
        guard active, let displayLink else { return }
        displayLink.invalidate()
        self.displayLink = nil
        active = false
        let elapsed = max(0.001, CACurrentMediaTime() - startedAt)
        let fps = Double(frames) / elapsed
        Log.info(
            .app,
            String(
                format: "FPS 汇总 fps=%.1f frames=%d dropped≈%d duration=%.2fs",
                fps,
                frames,
                droppedFrames,
                elapsed
            )
        )
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let delta = now - lastTick
        lastTick = now
        frames += 1
        if delta > 1.0 / 50.0 {
            droppedFrames += max(1, Int((delta * 60).rounded()) - 1)
        }
        if now - lastReport >= 1 {
            let elapsed = max(0.001, now - startedAt)
            let fps = Double(frames) / elapsed
            Log.info(
                .app,
                String(
                    format: "FPS 滚动 fps=%.1f frames=%d dropped≈%d",
                    fps,
                    frames,
                    droppedFrames
                )
            )
            lastReport = now
        }
    }
}
