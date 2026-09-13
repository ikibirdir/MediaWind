import AppKit
import AVKit
import MediaWindCore

/// The one viewer window: shows the current photo or video and flips through the list.
final class ViewerWindowController: NSWindowController, NSWindowDelegate {
    enum ShownQuality: Int, Comparable {
        case none, preview, fit, full
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    enum ScanState {
        case scanning, done, denied(URL), failed
    }

    // MARK: Views
    let rootView = ViewerRootView()
    let imageView = ImageScrollView()
    let playerView = AVPlayerView()
    let messageView = MessageView()
    let leftArrow = ArrowButton(direction: .left)
    let rightArrow = ArrowButton(direction: .right)
    let titleOverlay = PillLabel()
    let speedBadge = PillLabel()
    let banner = BannerView()
    let spinner = NSProgressIndicator()

    // MARK: State
    var navigator = MediaNavigator(items: [], sortOrder: .byName)
    /// The folder being browsed, if any (not set when several files were opened at once).
    var currentFolder: URL?
    /// Where the current order came from, e.g. "parent's .DS_Store (icon view)".
    var sortSource = "name"
    let loader = ImageLoader()
    var scanState = ScanState.done
    /// Bumped on every open; stale background scans and sorts are discarded.
    var generation = 0
    /// Bumped whenever the list itself is replaced.
    var listVersion = 0
    var shownItem: MediaItem?
    var shownQuality = ShownQuality.none
    /// +1 when moving forward, -1 when moving back; biases preloading.
    var direction = 1
    /// True while an arrow key is held down (auto-repeat): show quick previews.
    var isFlying = false
    var flyTimer: Timer?
    var keyMonitor: Any?
    var spinnerTimer: Timer?
    var idleTimer: Timer?
    /// Fires if listing the folder takes suspiciously long, which usually means macOS is
    /// waiting for the user to allow access to it.
    var scanHintTimer: Timer?
    var mouseLocation: NSPoint?
    var isFullScreen = false
    var openTime: CFAbsoluteTime = 0
    var awaitingFirstFrame = false

    // Video
    var player: AVPlayer?
    var statusObservation: NSKeyValueObservation?
    var muteObservation: NSKeyValueObservation?
    /// Videos start muted each launch; unmuting carries over to the next video until quit.
    var isMuted = true
    /// ← or → pressed while a video is showing: a tap moves on when released, holding it
    /// scans through the video instead.
    var videoArrowKey: UInt16?
    var videoHoldTimer: Timer?
    var videoScan: VideoScan?

    /// Browse in the order Finder shows the folder in (the default), rather than a fixed order.
    var followsFinderOrder: Bool {
        get { UserDefaults.standard.object(forKey: "FollowFinderOrder") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "FollowFinderOrder") }
    }

    /// The order chosen in the View menu, used when not following Finder.
    var fixedSortOrder: MediaSortOrder {
        get { MediaSortOrder(rawValue: UserDefaults.standard.string(forKey: "SortOrder") ?? "") ?? .byName }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "SortOrder") }
    }

    /// The order to use before a folder's own arrangement is known.
    var currentOrder: MediaSortOrder { followsFinderOrder ? navigator.sortOrder : fixedSortOrder }

    var currentURL: URL? { navigator.current?.url }

    // MARK: - Setup

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 750),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.07, alpha: 1)
        window.minSize = NSSize(width: 420, height: 300)
        window.collectionBehavior = [.fullScreenPrimary]
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.title = "MediaWind"
        super.init(window: window)
        window.delegate = self

        if !window.setFrameUsingName("ViewerWindow"), let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let size = NSSize(width: (visible.width * 0.75).rounded(), height: (visible.height * 0.8).rounded())
            window.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                                   width: size.width, height: size.height), display: false)
        }
        window.setFrameAutosaveName("ViewerWindow")

        buildViews()
        installKeyMonitor()
        navigator = MediaNavigator(items: [], sortOrder: currentOrder)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildViews() {
        guard let window else { return }
        rootView.frame = window.contentLayoutRect
        window.contentView = rootView

        for view in [imageView, playerView, messageView] as [NSView] {
            view.frame = rootView.bounds
            view.autoresizingMask = [.width, .height]
            rootView.addSubview(view)
        }
        playerView.isHidden = true
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = false
        playerView.allowsPictureInPicturePlayback = false
        playerView.allowsVideoFrameAnalysis = false
        playerView.videoGravity = .resizeAspect
        messageView.isHidden = true

        imageView.onZoomChange = { [weak self] in self?.loadFullResolutionIfNeeded() }

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.appearance = NSAppearance(named: .darkAqua)
        spinner.isDisplayedWhenStopped = false

        let overlays: [NSView] = [leftArrow, rightArrow, titleOverlay, speedBadge, banner, spinner]
        for view in overlays {
            view.translatesAutoresizingMaskIntoConstraints = false
            rootView.addSubview(view)
        }
        for arrow in [leftArrow, rightArrow] {
            arrow.alphaValue = 0
            arrow.isHidden = true
        }
        leftArrow.action = { [weak self] in self?.navigate(.previous, source: "arrow button") }
        rightArrow.action = { [weak self] in self?.navigate(.next, source: "arrow button") }
        titleOverlay.alphaValue = 0
        titleOverlay.isHidden = true
        speedBadge.alphaValue = 0
        speedBadge.isHidden = true
        banner.isHidden = true

        NSLayoutConstraint.activate([
            leftArrow.widthAnchor.constraint(equalToConstant: 48),
            leftArrow.heightAnchor.constraint(equalToConstant: 48),
            leftArrow.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 18),
            leftArrow.centerYAnchor.constraint(equalTo: rootView.centerYAnchor),
            rightArrow.widthAnchor.constraint(equalToConstant: 48),
            rightArrow.heightAnchor.constraint(equalToConstant: 48),
            rightArrow.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -18),
            rightArrow.centerYAnchor.constraint(equalTo: rootView.centerYAnchor),
            titleOverlay.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 16),
            titleOverlay.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            titleOverlay.widthAnchor.constraint(lessThanOrEqualTo: rootView.widthAnchor, constant: -40),
            speedBadge.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 16),
            speedBadge.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            banner.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -20),
            banner.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            banner.widthAnchor.constraint(lessThanOrEqualTo: rootView.widthAnchor, constant: -40),
            spinner.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: rootView.centerYAnchor),
        ])

        rootView.onMouseMoved = { [weak self] point in self?.mouseMoved(to: point) }
        rootView.onMouseExited = { [weak self] in
            self?.mouseLocation = nil
            self?.updateArrows()
        }
    }

    // MARK: - Keyboard

    /// Window-level key handling, so ← → and Space always work: right after opening, and
    /// while AVPlayerView (which likes to grab the arrow keys) is showing.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  window.isKeyWindow, window.attachedSheet == nil else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        let character = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if event.type == .keyUp {
            if event.keyCode == 123 || event.keyCode == 124 {
                if event.keyCode == videoArrowKey {
                    videoArrowReleased()
                } else {
                    stopFlying()
                }
                return true
            }
            return false
        }

        if modifiers.isEmpty {
            switch event.keyCode {
            case 123, 124: arrowPressed(event); return true
            case 115: navigate(.first, source: "key"); return true
            case 119: navigate(.last, source: "key"); return true
            case 49: togglePlayPause(nil); return true
            case 53: escapeAction(nil); return true
            default: break
            }
        }
        if character == "f" && (modifiers.isEmpty || modifiers == [.control, .command]) {
            window?.toggleFullScreen(nil)
            return true
        }
        if character == "m" && modifiers.isEmpty {
            toggleMute(nil)
            return true
        }
        // ⌘= is what people type for ⌘+ on most keyboards.
        if character == "=" && modifiers == [.command] {
            zoomIn(nil)
            return true
        }
        return false
    }

    private func arrowPressed(_ event: NSEvent) {
        let step: NavigationStep = event.keyCode == 123 ? .previous : .next
        // Auto-repeats of an arrow held on a video (or the other arrow meanwhile) change nothing.
        if videoArrowKey != nil { return }
        if !event.isARepeat && isShowingVideo {
            // Wait to see whether it's a tap (move on when released) or a hold (scan the video).
            videoArrowKey = event.keyCode
            videoHoldTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
                self?.startVideoScan(forward: step == .next)
            }
            return
        }
        navigate(step, isRepeat: event.isARepeat, source: "key")
    }

    private func videoArrowReleased() {
        let step: NavigationStep = videoArrowKey == 123 ? .previous : .next
        let isTap = videoHoldTimer != nil
        endVideoHold()
        if isTap { navigate(step, source: "key") }
    }

    // MARK: - Opening

    func open(_ urls: [URL]) {
        openTime = CFAbsoluteTimeGetCurrent()
        awaitingFirstFrame = true
        generation += 1
        listVersion += 1
        isFlying = false
        flyTimer?.invalidate()
        banner.isHidden = true
        shownItem = nil
        shownQuality = .none
        stopVideo()

        var isDirectory: ObjCBool = false
        if urls.count == 1, FileManager.default.fileExists(atPath: urls[0].path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            navigator = MediaNavigator(items: [], sortOrder: currentOrder)
            scanState = .scanning
            imageView.clear()
            startSpinnerTimer()
            scanFolder(urls[0], keeping: nil)
        } else if urls.count == 1 {
            // Show the opened file right away; the folder is listed in the background.
            let item = Self.item(for: urls[0])
            navigator = MediaNavigator(items: [item], current: item, sortOrder: currentOrder)
            scanState = .scanning
            showCurrent()
            scanFolder(urls[0].deletingLastPathComponent(), keeping: item)
        } else {
            // Several files at once: browse just those.
            navigator = MediaNavigator(items: urls.map(Self.item(for:)), sortOrder: currentOrder)
            scanState = .done
            showCurrent()
        }

        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(rootView)
    }

    private static func item(for url: URL) -> MediaItem {
        FolderScanner.makeItem(for: url, allowHidden: true)
            ?? MediaItem(url: url, kind: MediaClassifier.kind(of: url) ?? .image, modificationDate: .distantPast)
    }

    private func scanFolder(_ folder: URL, keeping item: MediaItem?) {
        let generation = self.generation
        let follows = followsFinderOrder
        let fallback = fixedSortOrder
        let start = CFAbsoluteTimeGetCurrent()
        currentFolder = folder
        Perf.log.notice("scan folder: \(folder.path, privacy: .public) (follow Finder: \(follows, privacy: .public))")
        scanHintTimer?.invalidate()
        scanHintTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.showWaitingForAccessBanner(folder)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // Browse in the order the folder is shown in: read Finder's arrangement for it.
            let arrangement = follows ? FinderSort.arrangement(for: folder) : nil
            let order = arrangement?.order ?? (follows ? .byName : fallback)
            let source = arrangement?.source ?? (follows ? "name (Finder has no setting)" : "View menu")
            let result: Result<MediaNavigator, FolderScanError>
            do throws(FolderScanError) {
                let items = try FolderScanner.scan(folder: folder)
                result = .success(MediaNavigator(items: items, current: item, sortOrder: order))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation else { return }
                Perf.log.notice("scan: \(Perf.ms(since: start), privacy: .public) ms, order \(order.rawValue, privacy: .public) from \(source, privacy: .public)")
                self.sortSource = source
                self.scanFinished(result, folder: folder)
            }
        }
    }

    private func scanFinished(_ result: Result<MediaNavigator, FolderScanError>, folder: URL) {
        hideSpinner()
        scanHintTimer?.invalidate()
        scanHintTimer = nil
        if case .success = result { banner.isHidden = true }
        switch result {
        case .success(let scanned):
            navigator = scanned
            listVersion += 1
            scanState = .done
            Perf.log.notice("listed \(scanned.count, privacy: .public) items")
            if navigator.isEmpty {
                showMessage(symbol: "photo.on.rectangle.angled", title: "No photos or videos",
                            detail: "“\(folder.lastPathComponent)” doesn't contain any photos or videos.", item: nil)
                updateTitle()
            } else {
                showCurrent()
            }
        case .failure(.accessDenied):
            scanState = .denied(folder)
            showAccessBanner(folder)
            if navigator.isEmpty {
                showMessage(symbol: "lock", title: "Can't open this folder",
                            detail: "macOS didn't allow MediaWind to read “\(folder.lastPathComponent)”.", item: nil)
            }
            updateTitle()
        case .failure:
            scanState = .failed
            updateTitle()
        }
        updateArrows()
    }

    // MARK: - Navigation

    func navigate(_ step: NavigationStep, isRepeat: Bool = false, source: String = "menu") {
        guard !navigator.isEmpty else { return }
        Perf.log.notice("navigate \(String(describing: step), privacy: .public) from \(source, privacy: .public)\(isRepeat ? " (repeat)" : "", privacy: .public) at \(self.navigator.positionDescription ?? "-", privacy: .public)")
        if isRepeat {
            isFlying = true
            // Fallback in case the key-up gets lost.
            flyTimer?.invalidate()
            flyTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
                self?.stopFlying()
            }
        }
        direction = (step == .previous || step == .first) ? -1 : 1
        guard navigator.move(step) else { return }
        skipVanishedFiles(after: step)
        showCurrent()
    }

    func stopFlying() {
        flyTimer?.invalidate()
        flyTimer = nil
        guard isFlying else { return }
        isFlying = false
        showCurrent()
    }

    /// Quietly drops files deleted or renamed since the folder was listed, continuing in
    /// the direction of travel.
    private func skipVanishedFiles(after step: NavigationStep) {
        var budget = 10_000
        while let item = navigator.current, budget > 0, navigator.count > 1,
              !FileManager.default.fileExists(atPath: item.url.path) {
            budget -= 1
            loader.forget(item.url)
            navigator.remove(item)
            listVersion += 1
            if step == .previous { navigator.move(.previous) }
        }
    }

    // MARK: - Showing the current item

    func showCurrent() {
        updateTitle()
        updateArrows()
        guard let item = navigator.current else { return }
        switch item.kind {
        case .image: showImage(item)
        case .video: showVideo(item)
        }
        if !isFlying { preloadNeighbors() }
    }

    private func showImage(_ item: MediaItem) {
        if shownItem != item {
            stopVideo()
        }
        if loader.failure(for: item.url) == .unreadable {
            showUnreadableImage(item)
            return
        }
        let maxPixel = fitPixelSize
        if let image = loader.cachedFit(item.url, maxPixel: isFlying ? 0 : maxPixel) {
            display(image, item, image.isFull ? .full : .fit)
            return
        }
        if shownItem == item && shownQuality >= (isFlying ? .preview : .fit) { return }
        if let preview = loader.cachedPreview(item.url), !(shownItem == item && shownQuality >= .preview) {
            display(.still(preview), item, .preview)
        }

        let request: ImageRequest = isFlying ? .preview : .fit(maxPixel)
        let quality: ShownQuality = isFlying ? .preview : .fit
        if !isFlying { startSpinnerTimer() }
        loader.load(item.url, request, priority: .veryHigh) { [weak self] result in
            self?.imageLoaded(result, item, quality)
        }
    }

    private func imageLoaded(_ result: Result<LoadedImage, ImageLoadError>, _ item: MediaItem, _ quality: ShownQuality) {
        guard navigator.current == item else { return }
        switch result {
        case .success(let image):
            if shownItem == item && shownQuality >= quality { return }
            display(image, item, image.isFull ? .full : quality)
        case .failure(.missing):
            hideSpinner()
            loader.forget(item.url)
            if navigator.count > 1 {
                navigator.remove(item)
                listVersion += 1
                if direction < 0 { navigator.move(.previous) }
                showCurrent()
            } else {
                showMessage(symbol: "questionmark.folder", title: "“\(item.name)” is no longer there",
                            detail: "It was moved, renamed or deleted.", item: nil)
            }
        case .failure(.unreadable):
            showUnreadableImage(item)
        }
    }

    private func display(_ image: LoadedImage, _ item: MediaItem, _ quality: ShownQuality) {
        let isNewItem = shownItem != item
        hideSpinner()
        playerView.isHidden = true
        messageView.isHidden = true
        imageView.isHidden = false
        imageView.show(image, resetZoom: isNewItem)
        shownItem = item
        shownQuality = quality
        Perf.log.debug("show \(item.name, privacy: .public) \(String(describing: quality), privacy: .public) \(image.isFull ? "full" : "\(self.imageView.shownPixelWidth)px", privacy: .public)")
        if awaitingFirstFrame {
            awaitingFirstFrame = false
            Perf.log.notice("first image on screen: \(Perf.ms(since: self.openTime), privacy: .public) ms after open, \(Perf.ms(since: Perf.launch), privacy: .public) ms after launch")
        }
        if !isNewItem { loadFullResolutionIfNeeded() }
    }

    /// When zoomed in past the fit image's resolution, swap in every pixel.
    func loadFullResolutionIfNeeded() {
        guard let item = shownItem, item.kind == .image, shownQuality != .full, !imageView.isHidden,
              imageView.needsMoreResolution else { return }
        let refit = imageView.isFit
        if !refit, let full = loader.cachedFull(item.url) {
            display(.still(full), item, .full)
            return
        }
        let request: ImageRequest = refit ? .fit(fitPixelSize) : .full
        loader.load(item.url, request, priority: .veryHigh) { [weak self] result in
            guard let self, self.shownItem == item, case .success(let image) = result else { return }
            self.display(image, item, image.isFull ? .full : .fit)
        }
    }

    private func preloadNeighbors() {
        let maxPixel = fitPixelSize
        let neighbors = navigator.neighbors(direction: direction, ahead: 2, behind: 1).filter { $0.kind == .image }
        loader.cancelPreloads(except: Set(neighbors.map(\.url.path)))
        for (index, item) in neighbors.enumerated()
        where loader.cachedFit(item.url, maxPixel: maxPixel) == nil && loader.failure(for: item.url) == nil {
            loader.load(item.url, .fit(maxPixel), priority: index == 0 ? .high : .normal)
        }
    }

    /// Longest side of the visible area in pixels, rounded up so small resizes reuse the cache.
    var fitPixelSize: Int {
        let size = imageView.contentView.frame.size
        let scale = window?.backingScaleFactor ?? 2
        let pixels = Int((max(size.width, size.height) * scale).rounded(.up))
        return max(256, (pixels + 255) / 256 * 256)
    }

    // MARK: - Title, arrows, overlays

    func updateTitle() {
        guard let item = navigator.current else {
            window?.title = "MediaWind"
            window?.representedURL = nil
            titleOverlay.text = ""
            return
        }
        var title = item.name
        if case .done = scanState, let position = navigator.positionDescription {
            title += " — " + position
        }
        window?.title = title
        titleOverlay.text = title
        if !isFlying { window?.representedURL = item.url }
    }

    private func mouseMoved(to point: NSPoint) {
        mouseLocation = point
        updateArrows()
        if isFullScreen { setVisible(titleOverlay, true) }
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.mouseBecameIdle()
        }
    }

    private func mouseBecameIdle() {
        mouseLocation = nil
        updateArrows()
        setVisible(titleOverlay, false)
        if isFullScreen { NSCursor.setHiddenUntilMouseMoves(true) }
    }

    func updateArrows() {
        let width = rootView.bounds.width
        let zone = max(110, width * 0.14)
        let showLeft = navigator.canGoPrevious && (mouseLocation.map { $0.x < zone } ?? false)
        let showRight = navigator.canGoNext && (mouseLocation.map { $0.x > width - zone } ?? false)
        setVisible(leftArrow, showLeft)
        setVisible(rightArrow, showRight)
    }

    func setVisible(_ view: NSView, _ visible: Bool) {
        let target: CGFloat = visible ? 1 : 0
        if visible == !view.isHidden && view.alphaValue == target { return }
        if visible { view.isHidden = false }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.12 : 0.35
            view.animator().alphaValue = target
        } completionHandler: {
            if !visible && view.alphaValue == 0 { view.isHidden = true }
        }
    }

    func startSpinnerTimer() {
        spinnerTimer?.invalidate()
        spinnerTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.spinner.startAnimation(nil)
        }
    }

    func hideSpinner() {
        spinnerTimer?.invalidate()
        spinnerTimer = nil
        spinner.stopAnimation(nil)
    }

    // MARK: - Window delegate

    func windowDidResignKey(_ notification: Notification) {
        // The key-up of a held arrow goes to whichever window is key now.
        endVideoHold()
    }

    func windowWillClose(_ notification: Notification) {
        stopVideo()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        isFullScreen = true
        setVisible(titleOverlay, true)
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.mouseBecameIdle()
        }
        loadFullResolutionIfNeeded()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        isFullScreen = false
        setVisible(titleOverlay, false)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        window?.makeFirstResponder(rootView)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        loadFullResolutionIfNeeded()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        loadFullResolutionIfNeeded()
    }
}

extension LoadedImage {
    var isFull: Bool {
        switch self {
        case .still(let image): return image.isFullResolution
        case .animated: return true
        }
    }
}
