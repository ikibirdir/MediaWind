import AppKit
import UniformTypeIdentifiers

enum MediaGroup {
    case photos, videos
}

/// Changing which app opens photos/videos. Only ever runs when the user picks the menu
/// command or welcome-window button, and always asks first.
enum DefaultApps {
    static let didChange = Notification.Name("MediaWindDefaultAppsDidChange")

    static let photoTypes: [UTType] = [
        "public.jpeg", "public.heic", "public.heif", "public.png", "com.compuserve.gif", "public.tiff",
        "com.microsoft.bmp", "org.webmproject.webp", "public.avif", "public.jpeg-2000", "com.microsoft.ico",
        "com.adobe.raw-image", "com.canon.cr2-raw-image", "com.canon.cr3-raw-image", "com.nikon.raw-image",
        "com.nikon.nrw-raw-image", "com.sony.arw-raw-image", "com.fuji.raw-image", "com.olympus.raw-image",
        "com.panasonic.rw2-raw-image",
    ].compactMap { UTType($0) }

    /// Only formats AVFoundation actually plays.
    static let videoTypes: [UTType] = [
        "public.mpeg-4", "com.apple.quicktime-movie", "com.apple.m4v-video", "public.3gpp",
    ].compactMap { UTType($0) }

    static let previewBundleID = "com.apple.Preview"
    static let quickTimeBundleID = "com.apple.QuickTimePlayerX"

    static func types(for group: MediaGroup) -> [UTType] {
        group == .photos ? photoTypes : videoTypes
    }

    static func defaultAppName(for type: UTType) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: type) else { return nil }
        return appName(url)
    }

    static func appName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func confirmAndSet(_ group: MediaGroup, toMediaWind: Bool) {
        let types = types(for: group)
        let what = group == .photos ? "photos" : "videos"
        let alert = NSAlert()
        alert.messageText = "Make MediaWind the default app for \(what)?"
        alert.informativeText = """
        Double-clicking these files in Finder will open MediaWind:
        \(extensionList(types))

        You can undo this with MediaWind ▸ Default Viewer ▸ Restore Preview and QuickTime Player.
        """
        alert.addButton(withTitle: "Make Default")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setDefault(Bundle.main.bundleURL, for: types, description: "MediaWind is now the default for \(what).")
    }

    static func confirmRestore() {
        let alert = NSAlert()
        alert.messageText = "Restore Preview and QuickTime Player as the default apps?"
        alert.informativeText = "Photos will open in Preview and videos in QuickTime Player again."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let workspace = NSWorkspace.shared
        guard let preview = workspace.urlForApplication(withBundleIdentifier: previewBundleID),
              let quickTime = workspace.urlForApplication(withBundleIdentifier: quickTimeBundleID) else {
            showResult("Couldn't find Preview or QuickTime Player.", failures: [])
            return
        }
        setDefault(preview, for: photoTypes, description: nil) { photoFailures in
            setDefault(quickTime, for: videoTypes, description: "Preview and QuickTime Player are the defaults again.",
                       previousFailures: photoFailures)
        }
    }

    private static func setDefault(_ app: URL, for types: [UTType], description: String?,
                                   previousFailures: [String] = [],
                                   then next: (([String]) -> Void)? = nil) {
        let group = DispatchGroup()
        let lock = NSLock()
        var failures = previousFailures
        for type in types {
            group.enter()
            NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { error in
                if let error {
                    lock.lock()
                    failures.append("\(type.preferredFilenameExtension ?? type.identifier): \(error.localizedDescription)")
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            NotificationCenter.default.post(name: didChange, object: nil)
            if let next {
                next(failures)
            } else if let description {
                showResult(description, failures: failures)
            }
        }
    }

    private static func showResult(_ message: String, failures: [String]) {
        let alert = NSAlert()
        if failures.isEmpty {
            alert.messageText = message
        } else {
            alert.messageText = "Some file types couldn't be changed."
            alert.informativeText = failures.joined(separator: "\n")
        }
        alert.runModal()
    }

    private static func extensionList(_ types: [UTType]) -> String {
        var seen = Set<String>()
        return types.compactMap { $0.preferredFilenameExtension?.uppercased() }
            .filter { seen.insert($0).inserted }
            .joined(separator: ", ")
    }
}

/// Apps that can open a file, excluding MediaWind itself so "open in another app" can
/// never loop back here.
enum OtherApps {
    struct App {
        let url: URL
        let name: String
        let icon: NSImage
    }

    static func candidates(for file: URL) -> [App] {
        let workspace = NSWorkspace.shared
        let ownID = Bundle.main.bundleIdentifier
        let defaultApp = workspace.urlForApplication(toOpen: file)
        var seen = Set<String>()
        var apps: [App] = []
        var urls = workspace.urlsForApplications(toOpen: file)
        if let defaultApp { urls.insert(defaultApp, at: 0) }
        for url in urls {
            let bundleID = Bundle(url: url)?.bundleIdentifier
            if bundleID == ownID || url.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL { continue }
            guard seen.insert(bundleID ?? url.path).inserted else { continue }
            let icon = workspace.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            apps.append(App(url: url, name: DefaultApps.appName(url), icon: icon))
        }
        return apps
    }

    static func open(_ file: URL, with app: URL) {
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                DispatchQueue.main.async { NSAlert(error: error).runModal() }
            }
        }
    }

    /// Lets the user pick any app; refuses MediaWind itself.
    static func chooseApp(for file: URL, window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open"
        panel.message = "Choose an app to open “\(file.lastPathComponent)”."
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let app = panel.url else { return }
            if Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier { NSSound.beep(); return }
            open(file, with: app)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { panel.begin(completionHandler: handler) }
    }
}
