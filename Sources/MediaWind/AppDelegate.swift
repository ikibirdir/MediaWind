import AppKit
import MediaWindCore
import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var viewer: ViewerWindowController?
    private var welcomeWindow: NSWindow?
    private var hasOpenedFiles = false

    // MARK: - Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Never reopen windows from a previous session; each launch shows what Finder asked for.
        // The View menu has its own full-screen items, so AppKit shouldn't add another.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false,
                                                  "NSFullScreenMenuItemEverywhere": false])
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.mainMenu = MainMenu.build()
        FinderSort.diagnostics = { message in
            Perf.log.notice("FinderSort: \(message, privacy: .public)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Perf.log.notice("did finish launching: \(Perf.ms(since: Perf.launch), privacy: .public) ms")
        DebugHook.installIfRequested { [weak self] in self?.viewer }
        // Files passed at launch arrive through application(_:open:) before this point. Give a
        // late open event one more run-loop turn so the welcome window never flashes first.
        DispatchQueue.main.async { [self] in
            if !hasOpenedFiles && viewer == nil { showWelcome() }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        hasOpenedFiles = true
        Perf.log.notice("open event: \(urls.count, privacy: .public) file(s) at \(Perf.ms(since: Perf.launch), privacy: .public) ms")
        showViewer(with: urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // ⌘Q quits without closing the window first.
        viewer?.showInFinderOnClose()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWelcome() }
        return true
    }

    // MARK: - Windows

    func showViewer(with urls: [URL]) {
        guard !urls.isEmpty else { return }
        let controller = viewer ?? ViewerWindowController()
        viewer = controller
        controller.open(urls)
        // Close the welcome window only once the viewer is up, so the app never has zero
        // windows in between (which would quit it).
        if let welcomeWindow {
            self.welcomeWindow = nil
            welcomeWindow.close()
        }
        NSApp.activate()
    }

    func showWelcome() {
        if let welcomeWindow {
            welcomeWindow.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: WelcomeView(
            open: { [weak self] in self?.openDocument(nil) },
            makeDefaultForPhotos: { [weak self] in self?.makeDefaultForPhotos(nil) },
            makeDefaultForVideos: { [weak self] in self?.makeDefaultForVideos(nil) },
            restoreDefaults: { [weak self] in self?.restoreSystemDefaults(nil) }
        ))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = "MediaWind"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.collectionBehavior = [.fullScreenNone]
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        welcomeWindow = window
    }

    // MARK: - Actions

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.image, .movie, .folder]
        panel.message = "Choose photos or videos, or a folder to browse."
        panel.prompt = "Open"
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            self?.showViewer(with: panel.urls)
        }
        if let window = viewer?.window, window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    @objc func makeDefaultForPhotos(_ sender: Any?) {
        DefaultApps.confirmAndSet(.photos, toMediaWind: true)
    }

    @objc func makeDefaultForVideos(_ sender: Any?) {
        DefaultApps.confirmAndSet(.videos, toMediaWind: true)
    }

    @objc func restoreSystemDefaults(_ sender: Any?) {
        DefaultApps.confirmRestore()
    }

    @objc func showKeyboardShortcuts(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Keyboard Shortcuts"
        alert.informativeText = """
        ← / →\tPrevious / next photo or video
        Hold ← / → on a video\tRewind / fast-forward at 3×
        fn← / fn→ (Home / End)\tFirst / last
        ⌘+ / ⌘−\tZoom in / out
        ⌘0\tZoom to fit
        ⌘1\tActual size
        Double-click\tToggle fit / actual size
        Drag\tPan when zoomed in
        F or ⌃⌘F\tToggle full screen
        Esc\tExit full screen, or close
        Space\tPlay / pause video
        M\tMute / unmute videos
        ⌘O\tOpen…
        ⇧⌘O\tOpen in Preview
        ⇧⌘R\tShow in Finder
        ⌘C\tCopy file
        ⌘W\tClose
        """
        alert.runModal()
    }
}
