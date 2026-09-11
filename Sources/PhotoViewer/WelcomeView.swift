import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shown only when PhotoViewer is launched without a file.
struct WelcomeView: View {
    let open: () -> Void
    let makeDefaultForPhotos: () -> Void
    let makeDefaultForVideos: () -> Void
    let restoreDefaults: () -> Void

    @State private var photoApp = WelcomeView.currentPhotoApp()
    @State private var videoApp = WelcomeView.currentVideoApp()

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("PhotoViewer")
                .font(.title.bold())
            Text("Double-click a photo in Finder, or choose File ▸ Open With ▸ PhotoViewer.\nThen use ← → to browse everything in that folder.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open…", action: open)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)

            Divider().padding(.vertical, 4)

            VStack(spacing: 10) {
                Text("Photos open in **\(photoApp)**, videos in **\(videoApp)**.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Use for Photos…", action: makeDefaultForPhotos)
                    Button("Use for Videos…", action: makeDefaultForVideos)
                    Button("Restore Preview & QuickTime…", action: restoreDefaults)
                }
                .controlSize(.small)
            }
        }
        .padding(28)
        .frame(width: 500)
        .onReceive(NotificationCenter.default.publisher(for: DefaultApps.didChange)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        photoApp = Self.currentPhotoApp()
        videoApp = Self.currentVideoApp()
    }

    private static func currentPhotoApp() -> String { DefaultApps.defaultAppName(for: .jpeg) ?? "no app" }
    private static func currentVideoApp() -> String { DefaultApps.defaultAppName(for: .mpeg4Movie) ?? "no app" }
}
