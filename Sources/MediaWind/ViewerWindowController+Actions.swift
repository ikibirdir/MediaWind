import AppKit
import AVKit
import MediaWindCore

// MARK: - Video

extension ViewerWindowController {
    func showVideo(_ item: MediaItem) {
        if isFlying {
            // No player while flying past; just say what it is.
            if shownItem != item {
                stopVideo()
                showMessage(symbol: "film", title: item.name, detail: nil, item: item, quality: .preview)
            }
            return
        }
        if shownItem == item && shownQuality >= .fit { return }
        stopVideo()
        imageView.isHidden = true
        messageView.isHidden = true
        shownItem = item
        shownQuality = .fit

        let playerItem = AVPlayerItem(url: item.url)
        let player = AVPlayer(playerItem: playerItem)
        player.isMuted = isMuted
        player.actionAtItemEnd = .pause
        self.player = player
        playerView.player = player
        playerView.isHidden = true   // until it's ready, so unplayable files never flash a player
        startSpinnerTimer()

        statusObservation = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
            DispatchQueue.main.async { self?.playerItemStatusChanged(observed, item) }
        }
        muteObservation = player.observe(\.isMuted, options: [.new]) { [weak self] observed, _ in
            DispatchQueue.main.async {
                guard let self, self.player === observed else { return }
                self.isMuted = observed.isMuted
            }
        }
        player.play()
    }

    private func playerItemStatusChanged(_ playerItem: AVPlayerItem, _ item: MediaItem) {
        guard player?.currentItem === playerItem, shownItem == item else { return }
        switch playerItem.status {
        case .readyToPlay:
            hideSpinner()
            playerView.isHidden = false
            if awaitingFirstFrame {
                awaitingFirstFrame = false
                Perf.log.notice("video ready: \(Perf.ms(since: self.openTime), privacy: .public) ms after open")
            }
            // Keep keyboard focus away from the player.
            window?.makeFirstResponder(rootView)
        case .failed:
            let reason = playerItem.error?.localizedDescription
            stopVideo()
            showCantOpen(item, title: "Can't play “\(item.name)”",
                         detail: "macOS can't play this kind of video (\(item.url.pathExtension.uppercased())). "
                             + "Try another app, such as VLC or IINA." + (reason.map { "\n\($0)" } ?? ""))
        default:
            break
        }
    }

    func stopVideo() {
        endVideoHold(restoringSpeed: false)
        statusObservation = nil
        muteObservation = nil
        if let player {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        player = nil
        playerView.player = nil
        playerView.isHidden = true
    }

    @objc func togglePlayPause(_ sender: Any?) {
        guard let player, let item = player.currentItem else { return }
        if player.rate == 0 {
            if item.duration.isNumeric && item.currentTime() >= item.duration { player.seek(to: .zero) }
            player.play()
        } else {
            player.pause()
        }
    }

    @objc func toggleMute(_ sender: Any?) {
        isMuted.toggle()
        player?.isMuted = isMuted
    }

    /// A video player is on screen (not just a "film" placeholder while flying past).
    var isShowingVideo: Bool {
        player != nil && !isFlying && shownItem?.kind == .video && shownItem == navigator.current
    }

    /// Holding ← or → on a video: plays it at 3× in that direction until the key is released.
    func startVideoScan(forward: Bool) {
        videoHoldTimer = nil
        guard videoScan == nil, let player, let item = player.currentItem else { return }
        let native = forward ? item.canPlayFastForward : item.canPlayFastReverse
        let scan = VideoScan(forward: forward, wasPlaying: player.rate != 0, startTime: item.currentTime().seconds,
                             startedAt: CFAbsoluteTimeGetCurrent())
        videoScan = scan
        Perf.log.notice("video scan \(forward ? "forward" : "back", privacy: .public) at \(VideoScan.speed, privacy: .public)× from \(scan.startTime, privacy: .public) s (\(native ? "rate" : "seeking", privacy: .public), \(scan.wasPlaying ? "playing" : "paused", privacy: .public))")
        if native {
            player.rate = forward ? VideoScan.speed : -VideoScan.speed
        } else {
            player.pause()
            scanBySeeking(scan)
        }
        speedBadge.setText("\(Int(VideoScan.speed))×", symbol: forward ? "forward.fill" : "backward.fill",
                           symbolFirst: !forward)
        setVisible(titleOverlay, false)
        setVisible(speedBadge, true)
    }

    /// For videos AVFoundation can't play that fast (in that direction): seek to where 3×
    /// playback would be by now, then again as soon as that frame is on screen.
    private func scanBySeeking(_ scan: VideoScan) {
        guard let player, let item = player.currentItem, videoScan?.startedAt == scan.startedAt else { return }
        let end = item.duration.isNumeric ? item.duration.seconds : .infinity
        let distance = (CFAbsoluteTimeGetCurrent() - scan.startedAt) * Double(VideoScan.speed)
        let target = min(max(scan.startTime + (scan.forward ? distance : -distance), 0), end)
        let reachedEdge = target == 0 || target == end
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished, !reachedEdge else { return }
            DispatchQueue.main.async { self?.scanBySeeking(scan) }
        }
    }

    /// Ends a hold on ← or →: back to normal speed, or paused if the video was paused.
    func endVideoHold(restoringSpeed: Bool = true) {
        videoArrowKey = nil
        videoHoldTimer?.invalidate()
        videoHoldTimer = nil
        guard let scan = videoScan else { return }
        videoScan = nil
        speedBadge.isHidden = true
        speedBadge.alphaValue = 0
        guard restoringSpeed, let player, let item = player.currentItem else { return }
        // A seek still on its way would land after release and override resuming.
        item.cancelPendingSeeks()
        let atEnd = item.duration.isNumeric && item.currentTime() >= item.duration
        if scan.wasPlaying && !atEnd {
            player.play()
        } else {
            player.pause()
        }
        Perf.log.notice("video scan ended at \(item.currentTime().seconds, privacy: .public) s")    }
}

struct VideoScan {
    static let speed: Float = 3
    let forward: Bool
    let wasPlaying: Bool
    /// Where the video was when the hold began, in seconds.
    let startTime: Double
    let startedAt: CFAbsoluteTime
}

// MARK: - Messages

extension ViewerWindowController {
    func showMessage(symbol: String, title: String, detail: String?, item: MediaItem?,
                     buttons: [NSView] = [], quality: ShownQuality = .fit) {
        hideSpinner()
        imageView.isHidden = true
        imageView.clear()
        playerView.isHidden = true
        messageView.configure(symbol: symbol, title: title, detail: detail, buttons: buttons)
        messageView.isHidden = false
        shownItem = item
        shownQuality = quality
        awaitingFirstFrame = false
    }

    func showUnreadableImage(_ item: MediaItem) {
        stopVideo()
        showCantOpen(item, title: "Can't display “\(item.name)”",
                     detail: "The file may be damaged, or it's in a format macOS can't read.")
    }

    /// A clear message plus a way out: Show in Finder, or open in another app (never MediaWind).
    func showCantOpen(_ item: MediaItem, title: String, detail: String) {
        let finder = NSButton(title: "Show in Finder", target: self, action: #selector(showInFinder(_:)))
        let openWith = NSPopUpButton(frame: .zero, pullsDown: true)
        openWith.addItem(withTitle: "Open With")
        for app in OtherApps.candidates(for: item.url) {
            openWith.addItem(withTitle: app.name)
            openWith.lastItem?.image = app.icon
            openWith.lastItem?.representedObject = app.url
            openWith.lastItem?.target = self
            openWith.lastItem?.action = #selector(openWithApp(_:))
        }
        openWith.menu?.addItem(.separator())
        openWith.addItem(withTitle: "Other…")
        openWith.lastItem?.target = self
        openWith.lastItem?.action = #selector(openWithOtherApp(_:))
        showMessage(symbol: "exclamationmark.triangle", title: title, detail: detail, item: item,
                    buttons: [finder, openWith])
    }

    /// Shown while a folder listing is stuck, which on macOS means a pending privacy prompt.
    func showWaitingForAccessBanner(_ folder: URL) {
        let settings = NSButton(title: "Open Privacy Settings…", target: self, action: #selector(openPrivacySettings(_:)))
        settings.controlSize = .small
        let dismiss = NSButton(title: "Dismiss", target: self, action: #selector(dismissBanner(_:)))
        dismiss.controlSize = .small
        banner.configure(
            text: "Waiting for permission to read “\(folder.lastPathComponent)”. If macOS asked whether "
                + "MediaWind may access this folder, click Allow; until then only this file is shown.",
            buttons: [settings, dismiss])
        banner.isHidden = false
    }

    func showAccessBanner(_ folder: URL) {
        let settings = NSButton(title: "Open Privacy Settings…", target: self, action: #selector(openPrivacySettings(_:)))
        settings.controlSize = .small
        let dismiss = NSButton(title: "Dismiss", target: self, action: #selector(dismissBanner(_:)))
        dismiss.controlSize = .small
        banner.configure(
            text: "MediaWind isn't allowed to read the folder “\(folder.lastPathComponent)”, so only this file is shown. "
                + "To browse it with ← →, turn on access in Privacy & Security ▸ Files and Folders, then open the file again.",
            buttons: [settings, dismiss])
        banner.isHidden = false
    }

    @objc func openPrivacySettings(_ sender: Any?) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func dismissBanner(_ sender: Any?) {
        banner.isHidden = true
    }
}

// MARK: - Menu commands

extension ViewerWindowController: NSMenuItemValidation {
    @objc func showPrevious(_ sender: Any?) { navigate(.previous) }
    @objc func showNext(_ sender: Any?) { navigate(.next) }
    @objc func showFirst(_ sender: Any?) { navigate(.first) }
    @objc func showLast(_ sender: Any?) { navigate(.last) }

    @objc func zoomIn(_ sender: Any?) { imageView.zoom(by: 1.5) }
    @objc func zoomOut(_ sender: Any?) { imageView.zoom(by: 1 / 1.5) }
    @objc func zoomToFit(_ sender: Any?) {
        imageView.zoomToFit()
        loadFullResolutionIfNeeded()
    }
    @objc func zoomToActualSize(_ sender: Any?) { imageView.zoomToActualSize() }

    @objc func toggleViewerFullScreen(_ sender: Any?) {
        window?.toggleFullScreen(nil)
    }

    @objc func escapeAction(_ sender: Any?) {
        if isFullScreen {
            window?.toggleFullScreen(nil)
        } else {
            window?.performClose(nil)
        }
    }

    static let sortKeysByTag: [Int: MediaSortKey] = [
        1: .name, 2: .kind, 3: .dateCreated, 4: .dateModified, 5: .dateAdded, 6: .dateLastOpened, 7: .size,
    ]

    @objc func changeSortOrder(_ sender: NSMenuItem) {
        if sender.tag == 0 {
            followsFinderOrder = true
            reapplyFinderOrder()
            return
        }
        guard let key = Self.sortKeysByTag[sender.tag] else { return }
        followsFinderOrder = false
        // Keep the direction if the same key is picked again, else use Finder's default for it.
        let ascending = key == fixedSortOrder.key ? fixedSortOrder.ascending : key.defaultAscending
        apply(MediaSortOrder(key, ascending: ascending), source: "View menu")
    }

    @objc func toggleSortDirection(_ sender: Any?) {
        followsFinderOrder = false
        var order = navigator.sortOrder
        order.ascending.toggle()
        apply(order, source: "View menu")
    }

    /// Re-reads how Finder is showing the current folder and follows it.
    func reapplyFinderOrder() {
        guard let folder = currentFolder else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let arrangement = FinderSort.arrangement(for: folder)
            DispatchQueue.main.async { [weak self] in
                self?.apply(arrangement?.order ?? .byName,
                            source: arrangement?.source ?? "name (Finder has no setting)")
            }
        }
    }

    func apply(_ order: MediaSortOrder, source: String) {
        if !followsFinderOrder { fixedSortOrder = order }
        sortSource = source
        guard order != navigator.sortOrder else { return }
        // Sorting thousands of names with Finder's comparison takes a moment: do it off the main thread.
        var snapshot = navigator
        let version = listVersion
        DispatchQueue.global(qos: .userInitiated).async {
            snapshot.setSortOrder(order)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let current = self.navigator.current
                if self.listVersion == version {
                    self.navigator = snapshot
                    if let current { self.navigator.select(current) }
                } else {
                    self.navigator.setSortOrder(order)
                }
                Perf.log.notice("sort: \(order.rawValue, privacy: .public) from \(source, privacy: .public)")
                self.updateTitle()
                self.updateArrows()
                self.showCurrent()
            }
        }
    }

    @objc func openInPreview(_ sender: Any?) {
        guard let url = currentURL,
              let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: DefaultApps.previewBundleID)
        else { return }
        OtherApps.open(url, with: preview)
    }

    @objc func showInFinder(_ sender: Any?) {
        guard let url = currentURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func copy(_ sender: Any?) {
        guard let url = currentURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    @objc func openWithApp(_ sender: NSMenuItem) {
        guard let url = currentURL, let app = sender.representedObject as? URL else { return }
        OtherApps.open(url, with: app)
    }

    @objc func openWithOtherApp(_ sender: Any?) {
        guard let url = currentURL else { return }
        OtherApps.chooseApp(for: url, window: window)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let isImage = navigator.current?.kind == .image && !imageView.isHidden && imageView.hasImage
        switch menuItem.action {
        case #selector(showPrevious(_:)), #selector(showFirst(_:)):
            return navigator.canGoPrevious
        case #selector(showNext(_:)), #selector(showLast(_:)):
            return navigator.canGoNext
        case #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(zoomToFit(_:)), #selector(zoomToActualSize(_:)):
            return isImage
        case #selector(changeSortOrder(_:)):
            if menuItem.tag == 0 {
                menuItem.state = followsFinderOrder ? .on : .off
            } else {
                let key = Self.sortKeysByTag[menuItem.tag]
                menuItem.state = !followsFinderOrder && key == navigator.sortOrder.key ? .on : .off
            }
            return true
        case #selector(toggleSortDirection(_:)):
            let order = navigator.sortOrder
            menuItem.state = order.ascending != order.key.defaultAscending ? .on : .off
            return !followsFinderOrder
        case #selector(toggleViewerFullScreen(_:)):
            menuItem.title = isFullScreen ? "Exit Full Screen" : "Enter Full Screen"
            return true
        case #selector(togglePlayPause(_:)):
            return player != nil
        case #selector(toggleMute(_:)):
            menuItem.state = isMuted ? .on : .off
            return true
        case #selector(openInPreview(_:)), #selector(showInFinder(_:)), #selector(copy(_:)),
             #selector(openWithApp(_:)), #selector(openWithOtherApp(_:)):
            return currentURL != nil
        default:
            return true
        }
    }
}
