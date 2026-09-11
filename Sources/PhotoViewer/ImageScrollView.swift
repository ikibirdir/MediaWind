import AppKit

/// Keeps a document smaller than the visible area centered instead of pinned to the corner.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let doc = documentView.frame
        if rect.width > doc.width { rect.origin.x = doc.midX - rect.width / 2 }
        if rect.height > doc.height { rect.origin.y = doc.midY - rect.height / 2 }
        return rect
    }
}

/// Shows a CGImage as layer contents: no backing store, scaled by the GPU, so even a huge
/// document size at any magnification costs no extra memory.
final class ImageLayerView: NSView {
    var image: CGImage? {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override var isOpaque: Bool { false }

    override func updateLayer() {
        guard let layer else { return }
        layer.contents = image
        layer.contentsGravity = .resize
        layer.minificationFilter = .trilinear
        layer.magnificationFilter = .linear
    }
}

/// Pinch zoom, ⌘+/⌘−, fit / actual size, double-click toggle and drag-to-pan around one image.
/// The document is sized at 1 image pixel = 1 point (like Preview), so "actual size" is
/// magnification 1 and small images are never scaled up past that.
final class ImageScrollView: NSScrollView {
    private let layerView = ImageLayerView()
    private let animatedView: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleAxesIndependently
        view.animates = true
        view.imageFrameStyle = .none
        view.isEditable = false
        return view
    }()

    /// Size of the current image in points (= its full-resolution pixel size).
    private(set) var imageSize: CGSize = .zero
    private(set) var isFit = true
    /// Called after any zoom change settles.
    var onZoomChange: (() -> Void)?
    private var isRetiling = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentView = CenteringClipView()
        drawsBackground = false
        contentView.drawsBackground = false
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        scrollerKnobStyle = .light
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        allowsMagnification = true
        documentView = layerView
        NotificationCenter.default.addObserver(self, selector: #selector(liveMagnifyDidEnd),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The pixel resolution currently shown (for deciding whether to load full resolution).
    private(set) var shownPixelWidth: Int = 0

    var hasImage: Bool { imageSize != .zero }

    // MARK: - Content

    func show(_ image: LoadedImage, resetZoom: Bool) {
        switch image {
        case .still(let decoded):
            if documentView !== layerView {
                animatedView.image = nil
                documentView = layerView
            }
            layerView.image = decoded.cgImage
            shownPixelWidth = decoded.cgImage.width
        case .animated(let nsImage, _):
            if documentView !== animatedView {
                layerView.image = nil
                documentView = animatedView
            }
            animatedView.image = nsImage
            shownPixelWidth = Int(image.originalSize.width)
        }
        let size = image.originalSize
        if size != imageSize || resetZoom {
            imageSize = size
            documentView?.frame = CGRect(origin: .zero, size: size)
        }
        if resetZoom {
            zoomToFit()
        } else {
            updateLimits()
        }
    }

    func clear() {
        layerView.image = nil
        animatedView.image = nil
        imageSize = .zero
        shownPixelWidth = 0
        documentView?.frame = .zero
        isFit = true
        magnification = 1
        documentCursor = nil
    }

    // MARK: - Zoom

    var fitMagnification: CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        let available = contentView.frame.size
        return min(available.width / imageSize.width, available.height / imageSize.height, 1)
    }

    /// Screen pixels per image pixel needed right now, versus what the shown bitmap has.
    var needsMoreResolution: Bool {
        guard hasImage, shownPixelWidth > 0 else { return false }
        let scale = window?.backingScaleFactor ?? 2
        let needed = imageSize.width * magnification * scale
        return CGFloat(shownPixelWidth) < min(needed, imageSize.width) * 0.95
    }

    func zoomToFit() {
        isFit = true
        updateLimits()
        magnification = fitMagnification
        updateCursor()
    }

    func zoomToActualSize(centeredAt point: NSPoint? = nil) {
        guard hasImage else { return }
        updateLimits()
        if fitMagnification >= 1 {
            zoomToFit()
        } else {
            isFit = false
            setMagnification(1, centeredAt: point ?? visibleCenter)
        }
        updateCursor()
        onZoomChange?()
    }

    func zoom(by factor: CGFloat) {
        guard hasImage else { return }
        updateLimits()
        let target = min(max(magnification * factor, minMagnification), maxMagnification)
        if target <= fitMagnification * 1.001 {
            zoomToFit()
        } else {
            isFit = false
            setMagnification(target, centeredAt: visibleCenter)
        }
        updateCursor()
        onZoomChange?()
    }

    func toggleFitActualSize(at point: NSPoint?) {
        if isFit {
            zoomToActualSize(centeredAt: point)
        } else {
            zoomToFit()
            onZoomChange?()
        }
    }

    private var visibleCenter: NSPoint {
        let bounds = contentView.bounds
        return NSPoint(x: bounds.midX, y: bounds.midY)
    }

    private func updateLimits() {
        let fit = fitMagnification
        minMagnification = fit
        maxMagnification = max(16, fit * 4)
    }

    private var isPannable: Bool {
        guard hasImage else { return false }
        let shown = CGSize(width: imageSize.width * magnification, height: imageSize.height * magnification)
        let visible = contentView.frame.size
        return shown.width > visible.width + 0.5 || shown.height > visible.height + 0.5
    }

    private func updateCursor() {
        documentCursor = isPannable ? .openHand : nil
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        isFit = magnification <= fitMagnification * 1.001
    }

    override func smartMagnify(with event: NSEvent) {
        toggleFitActualSize(at: contentView.convert(event.locationInWindow, from: nil))
    }

    @objc private func liveMagnifyDidEnd(_ notification: Notification) {
        if magnification <= fitMagnification * 1.01 { zoomToFit() } else { isFit = false }
        updateCursor()
        onZoomChange?()
    }

    /// Keeps the image fitted while the window is resized or goes full screen.
    override func tile() {
        super.tile()
        guard !isRetiling, hasImage else { return }
        isRetiling = true
        updateLimits()
        if isFit || magnification < minMagnification { zoomToFit() }
        updateCursor()
        isRetiling = false
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            toggleFitActualSize(at: contentView.convert(event.locationInWindow, from: nil))
            return
        }
        guard isPannable, let window else { return }
        NSCursor.closedHand.push()
        var last = event.locationInWindow
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration,
                           mode: .eventTracking) { [self] event, stop in
            guard let event else { return }
            if event.type == .leftMouseUp {
                stop.pointee = true
                return
            }
            let location = event.locationInWindow
            var origin = contentView.bounds.origin
            origin.x -= (location.x - last.x) / magnification
            origin.y -= (location.y - last.y) / magnification
            last = location
            let constrained = contentView.constrainBoundsRect(NSRect(origin: origin, size: contentView.bounds.size))
            contentView.scroll(to: constrained.origin)
            reflectScrolledClipView(contentView)
        }
        NSCursor.pop()
    }
}
