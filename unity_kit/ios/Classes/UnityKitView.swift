import UIKit

/// Custom container view that hosts the Unity root view.
///
/// Responsibilities:
/// - Keeps the Unity root view sized to match this container via layout passes.
/// - Forwards touch events to the Unity view so gestures work correctly.
/// - Optionally renders transparently so Flutter widgets painted behind the
///   platform view can show through (requires the Unity scene's camera to
///   also use a clear colour with alpha 0).
final class UnityKitView: UIView {

    // MARK: - Properties

    /// The Unity root view currently attached as a subview.
    private weak var unityView: UIView?

    /// When true, this container and any attached Unity view are marked
    /// non-opaque with a clear background.
    private let transparentBackground: Bool

    // MARK: - Init

    init(frame: CGRect, transparentBackground: Bool = false) {
        self.transparentBackground = transparentBackground
        super.init(frame: frame)
        if transparentBackground {
            isOpaque = false
            backgroundColor = .clear
        }
    }

    required init?(coder: NSCoder) {
        self.transparentBackground = false
        super.init(coder: coder)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()

        guard !bounds.isEmpty else { return }

        // Size the Unity view to fill the container.
        if let unityView = unityView, unityView.superview === self {
            unityView.frame = bounds
        }
    }

    // MARK: - Attach / Detach

    /// Attach the Unity root view as a subview.
    ///
    /// Removes the view from any previous superview first, then adds it here.
    func attachUnityView(_ view: UIView) {
        // Remove from previous parent if needed.
        if let superview = view.superview, superview !== self {
            view.removeFromSuperview()
            superview.layoutIfNeeded()
        }

        guard view.superview !== self else { return }

        unityView = view
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        applyTransparencyIfNeeded(to: view)
        addSubview(view)
        layoutIfNeeded()
    }

    /// Detach the Unity root view from this container.
    ///
    /// Ensures execution on the main thread for UIKit safety (iOS-M2).
    func detachUnityView() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.detachUnityView() }
            return
        }
        // Guard: skip removal if another container already owns this view
        // (e.g. after Flutter navigation created a new PlatformView).
        if let uv = unityView, uv.superview === self {
            uv.removeFromSuperview()
        }
        unityView = nil
        layoutIfNeeded()
    }

    // MARK: - Transparency

    /// Recursively mark the attached Unity view (and its subviews) as
    /// non-opaque with a clear background. Unity's root view is a plain
    /// `UIView` hosting Metal/OpenGL layers — once all levels of the
    /// hierarchy report `isOpaque = false`, the GPU compositor honours
    /// the camera's alpha 0 clear and lets Flutter content show through.
    private func applyTransparencyIfNeeded(to view: UIView) {
        guard transparentBackground else { return }
        view.isOpaque = false
        view.backgroundColor = .clear
        for subview in view.subviews {
            applyTransparencyIfNeeded(to: subview)
        }
    }

    // MARK: - Touch Forwarding

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Let the Unity view handle touches within its bounds.
        if let unityView = unityView,
           unityView.frame.contains(point) {
            let convertedPoint = convert(point, to: unityView)
            return unityView.hitTest(convertedPoint, with: event) ?? unityView
        }
        return super.hitTest(point, with: event)
    }
}
