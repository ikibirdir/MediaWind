import AppKit
import AVKit
import PhotoViewerCore

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

    /// A clear message plus a way out: Show in Finder, or open in another app (never PhotoViewer).
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

    func showAccessBanner(_ folder: URL) {
        let settings = NSButton(title: "Open Privacy Settings…", target: self, action: #selector(openPrivacySettings(_:)))
        settings.controlSize = .small
        let dismiss = NSButton(title: "Dismiss", target: self, action: #selector(dismissBanner(_:)))
        dismiss.controlSize = .small
        banner.configure(
            text: "PhotoViewer isn't allowed to read the folder “\(folder.lastPathComponent)”, so only this file is shown. "
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

    @objc func changeSortOrder(_ sender: NSMenuItem) {
        let orders: [MediaSortOrder] = [.name, .dateModifiedNewestFirst, .dateModifiedOldestFirst]
        guard orders.indices.contains(sender.tag) else { return }
        let order = orders[sender.tag]
        guard order != navigator.sortOrder else { return }
        sortOrder = order
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
            let orders: [MediaSortOrder] = [.name, .dateModifiedNewestFirst, .dateModifiedOldestFirst]
            menuItem.state = orders.indices.contains(menuItem.tag) && orders[menuItem.tag] == sortOrder ? .on : .off
            return true
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
