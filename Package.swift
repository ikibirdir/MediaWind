// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "MediaWind",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "MediaWind", targets: ["MediaWind"]),
    ],
    targets: [
        // Folder scanning, filtering, sorting and previous/next logic. No UI.
        .target(name: "MediaWindCore"),
        // The AppKit app.
        .executableTarget(name: "MediaWind", dependencies: ["MediaWindCore"]),
        .testTarget(name: "MediaWindCoreTests", dependencies: ["MediaWindCore"]),
    ],
    swiftLanguageModes: [.v5]
)
