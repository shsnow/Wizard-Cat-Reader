import SwiftUI
import UIKit

/// A page image that zooms with a pinch or a double tap (up to 4×), backed by UIScrollView.
///
/// The scale mode decides how the page rests at 1×: fitted to the screen, to its width or
/// height, or at its original pixel size. When the resting page overflows the screen the
/// scroll view pans over it; when it doesn't, swipes still reach the paging TabView around it.
/// Single taps report where they landed (0 = left edge, 1 = right edge) so the reader can
/// turn pages from the screen edges.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    var scaleMode: PageScaleMode = .fit
    var onTap: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap)
    }

    func makeUIView(context: Context) -> ZoomingScrollView {
        let scrollView = ZoomingScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.imageView.image = image
        scrollView.scaleMode = scaleMode

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:))
        )
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateUIView(_ scrollView: ZoomingScrollView, context: Context) {
        context.coordinator.onTap = onTap
        var changed = false
        if scrollView.imageView.image !== image {
            scrollView.imageView.image = image
            changed = true
        }
        if scrollView.scaleMode != scaleMode {
            scrollView.scaleMode = scaleMode
            changed = true
        }
        if changed {
            scrollView.setZoomScale(1, animated: false)
            scrollView.contentOffset = .zero
            scrollView.setNeedsLayout()
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var onTap: (CGFloat) -> Void
        weak var scrollView: ZoomingScrollView?

        init(onTap: @escaping (CGFloat) -> Void) {
            self.onTap = onTap
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? ZoomingScrollView)?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? ZoomingScrollView)?.centerImage()
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let point = recognizer.location(in: scrollView.imageView)
                let scale: CGFloat = 2.5
                let size = CGSize(
                    width: scrollView.bounds.width / scale,
                    height: scrollView.bounds.height / scale
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

        @objc func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView, scrollView.bounds.width > 0 else { return }
            let x = recognizer.location(in: scrollView).x - scrollView.contentOffset.x
            onTap(min(max(x / scrollView.bounds.width, 0), 1))
        }
    }
}

final class ZoomingScrollView: UIScrollView {
    let imageView: UIImageView = {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        return view
    }()

    var scaleMode: PageScaleMode = .fit {
        didSet { if scaleMode != oldValue { setNeedsLayout() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(imageView)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addSubview(imageView)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // At rest the image takes its base size for the scale mode; while zoomed —
        // or mid-pinch, when the bounce dips below 1× — UIScrollView owns the frame.
        if !isZooming && !isZoomBouncing && zoomScale <= minimumZoomScale + 0.001 {
            let size = baseSize()
            imageView.frame = CGRect(origin: .zero, size: size)
            contentSize = size
        }
        centerImage()
    }

    /// The page's resting size for the current scale mode.
    private func baseSize() -> CGSize {
        guard let image = imageView.image,
              image.size.width > 0, image.size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return bounds.size }
        let size = image.size
        switch scaleMode {
            case .fit:
                let ratio = min(bounds.width / size.width, bounds.height / size.height)
                return CGSize(width: size.width * ratio, height: size.height * ratio)
            case .fitWidth:
                let ratio = bounds.width / size.width
                return CGSize(width: bounds.width, height: size.height * ratio)
            case .fitHeight:
                let ratio = bounds.height / size.height
                return CGSize(width: size.width * ratio, height: bounds.height)
            case .original:
                // One image pixel per screen pixel.
                let screen = max(traitCollection.displayScale, 1)
                let ratio = image.scale / screen
                return CGSize(width: size.width * ratio, height: size.height * ratio)
        }
    }

    /// Keeps the image centered on the axes where it is smaller than the screen.
    func centerImage() {
        var frame = imageView.frame
        frame.origin.x = max((bounds.width - frame.width) / 2, 0)
        frame.origin.y = max((bounds.height - frame.height) / 2, 0)
        imageView.frame = frame
    }
}
