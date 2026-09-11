// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "PhotoViewer",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "PhotoViewer", targets: ["PhotoViewer"]),
    ],
    targets: [
        // Folder scanning, filtering, sorting and previous/next logic. No UI.
        .target(name: "PhotoViewerCore"),
        // The AppKit app.
        .executableTarget(name: "PhotoViewer", dependencies: ["PhotoViewerCore"]),
        .testTarget(name: "PhotoViewerCoreTests", dependencies: ["PhotoViewerCore"]),
    ],
    swiftLanguageModes: [.v5]
)
