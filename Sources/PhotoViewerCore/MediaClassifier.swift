import Foundation
import UniformTypeIdentifiers

public enum MediaKind: String, Sendable {
    case image
    case video
}

/// Decides whether a file is a photo, a video, or something PhotoViewer ignores.
public enum MediaClassifier {
    /// Video containers that macOS may not declare as movies, but that people keep next to
    /// their photos. They are listed so browsing shows them (with a "can't play" message if
    /// AVFoundation can't handle them) instead of silently skipping them.
    public static let fallbackVideoExtensions: Set<String> = [
        "mkv", "webm", "avi", "wmv", "flv", "f4v", "ogv", "ogm", "mpg", "mpeg", "m2v",
        "m2ts", "mts", "vob", "3gp", "3g2", "divx", "asf", "rm", "rmvb", "m4v", "mp4", "mov",
    ]

    /// Formats that technically conform to an image type but belong to Preview.
    public static let excludedExtensions: Set<String> = ["pdf", "ai", "eps", "ps"]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: MediaKind?] = [:]

    public static func kind(of url: URL) -> MediaKind? {
        kind(forExtension: url.pathExtension)
    }

    public static func kind(forExtension rawExtension: String) -> MediaKind? {
        let ext = rawExtension.lowercased()
        guard !ext.isEmpty else { return nil }

        lock.lock()
        if let cached = cache[ext] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let result = classify(ext)
        lock.lock()
        cache[ext] = result
        lock.unlock()
        return result
    }

    private static func classify(_ ext: String) -> MediaKind? {
        if excludedExtensions.contains(ext) { return nil }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .movie) { return .video }
        }
        if fallbackVideoExtensions.contains(ext) { return .video }
        return nil
    }
}
