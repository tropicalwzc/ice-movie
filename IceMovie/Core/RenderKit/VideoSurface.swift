import AVFoundation
import IceCore
import SwiftUI
import UIKit

/// SwiftUI 里的视频画面。`AVSampleBufferDisplayLayer` 由视图直接持有，
/// 渲染器只保存弱引用，因此视图重建（内联 ↔ 全屏）时显示层会跟着重建，
/// 播放管线不受影响——这一点在 6.7 会进一步收紧。
public struct VideoSurface: UIViewRepresentable {
    private let renderer: VideoRenderer
    private let onLayerReady: ((AVSampleBufferDisplayLayer) -> Void)?

    public init(
        renderer: VideoRenderer,
        onLayerReady: ((AVSampleBufferDisplayLayer) -> Void)? = nil
    ) {
        self.renderer = renderer
        self.onLayerReady = onLayerReady
    }

    public func makeUIView(context: Context) -> VideoLayerView {
        let view = VideoLayerView()
        renderer.bind(view.displayLayer)
        onLayerReady?(view.displayLayer)
        return view
    }

    public func updateUIView(_ uiView: VideoLayerView, context: Context) {}
}

public final class VideoLayerView: UIView {
    public override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    public var displayLayer: AVSampleBufferDisplayLayer {
        // layerClass 已指定为 AVSampleBufferDisplayLayer。
        layer as! AVSampleBufferDisplayLayer
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
    }
}
