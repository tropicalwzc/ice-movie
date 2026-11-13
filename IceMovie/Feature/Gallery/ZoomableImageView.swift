import SwiftUI
import UIKit

/// 用 UIScrollView 承载缩放与拖动，避免 SwiftUI 手势与分页手势互相抢占。
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let resetToken: String
    @Binding var isZoomed: Bool
    var onZoomScaleChanged: ((CGFloat) -> Void)?
    var onLongPressBegan: (() -> Void)?
    var onLongPressEnded: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> ZoomingScrollView {
        let view = ZoomingScrollView()
        view.delegate = context.coordinator
        view.minimumZoomScale = 1
        view.maximumZoomScale = 4
        view.bouncesZoom = true
        view.showsHorizontalScrollIndicator = false
        view.showsVerticalScrollIndicator = false
        view.backgroundColor = .clear
        view.imageView.contentMode = .scaleAspectFit
        view.imageView.clipsToBounds = true
        view.imageView.isUserInteractionEnabled = true
        view.panGestureRecognizer.isEnabled = false

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.28
        longPress.allowableMovement = 12
        view.addGestureRecognizer(longPress)
        return view
    }

    func updateUIView(_ view: ZoomingScrollView, context: Context) {
        context.coordinator.parent = self

        if context.coordinator.lastToken != resetToken {
            context.coordinator.lastToken = resetToken
            view.setZoomScale(1, animated: false)
            view.contentOffset = .zero
            view.panGestureRecognizer.isEnabled = false
        }

        if context.coordinator.lastImage !== image {
            context.coordinator.lastImage = image
            view.imageView.image = image
            view.setNeedsLayout()
            view.layoutIfNeeded()
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableImageView
        var lastToken: String?
        var lastImage: UIImage?

        init(_ parent: ZoomableImageView) {
            self.parent = parent
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? ZoomingScrollView)?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let zoomed = scrollView.zoomScale > 1.01
            scrollView.panGestureRecognizer.isEnabled = zoomed
            parent.onZoomScaleChanged?(scrollView.zoomScale)
            guard parent.isZoomed != zoomed else { return }
            DispatchQueue.main.async { [weak self] in
                self?.parent.isZoomed = zoomed
            }
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let scrollView = gesture.view as? ZoomingScrollView else { return }
            switch gesture.state {
            case .began:
                guard scrollView.zoomScale <= 1.01 else { return }
                parent.onLongPressBegan?()
            case .ended, .cancelled, .failed:
                parent.onLongPressEnded?()
            default:
                break
            }
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? ZoomingScrollView else { return }
            if scrollView.zoomScale > 1.01 {
                scrollView.setZoomScale(1, animated: true)
                return
            }
            let point = gesture.location(in: scrollView.imageView)
            let size = CGSize(
                width: scrollView.bounds.width / 2.4,
                height: scrollView.bounds.height / 2.4
            )
            let rect = CGRect(
                x: point.x - size.width / 2,
                y: point.y - size.height / 2,
                width: size.width,
                height: size.height
            )
            scrollView.zoom(to: rect, animated: true)
        }
    }
}

final class ZoomingScrollView: UIScrollView {
    let imageView = UIImageView()

    private var lastLayoutSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(imageView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        guard bounds.size != lastLayoutSize else {
            if zoomScale <= 1.01 {
                imageView.frame = bounds
                contentSize = bounds.size
            }
            return
        }

        let isFirstLayout = lastLayoutSize == .zero
        lastLayoutSize = bounds.size
        // 放大状态下旋转设备时，旧 imageView 尺寸与新 bounds 不匹配，
        // 继续保留缩放会看到偏移/裁切；直接回到适应屏幕的初始状态。
        if !isFirstLayout, zoomScale > 1.01 {
            setZoomScale(1, animated: false)
            contentOffset = .zero
        }
        imageView.frame = bounds
        contentSize = bounds.size
    }
}
