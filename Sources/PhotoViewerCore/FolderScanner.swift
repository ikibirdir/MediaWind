import Foundation

public struct MediaItem: Hashable, Sendable {
    public let url: URL
    public let kind: MediaKind
    public let modificationDate: Date

    public init(url: URL, kind: MediaKind, modificationDate: Date) {
        self.url = url
        self.kind = kind
        self.modificationDate = modificationDate
    }

    public var name: String { url.lastPathComponent }

    /// Identity used to match the same file coming from different sources
    /// (Finder's open event vs. a directory listing).
    public var key: String { url.standardizedFileURL.path }

    public static func == (lhs: MediaItem, rhs: MediaItem) -> Bool { lhs.key == rhs.key }
    public func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

public enum FolderScanError: Error, Equatable {
    /// macOS privacy protection (or plain permissions) refused to list the folder.
    case accessDenied
    case notFound
    case other(String)
}

public enum FolderScanner {
    private static let resourceKeys: [URLResourceKey] = [
        .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey, .contentModificationDateKey,
    ]

    /// Hidden files, including the AppleDouble `._name` files macOS leaves on exFAT/FAT drives.
    public static func isIgnoredName(_ name: String) -> Bool {
        name.hasPrefix("._") || name.hasPrefix(".")
    }

    /// Lists the photos and videos directly inside `folder` (not recursive), unsorted.
    public static func scan(folder: URL) throws(FolderScanError) -> [MediaItem] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants]
            )
        } catch {
            throw classify(error)
        }
        var items: [MediaItem] = []
        items.reserveCapacity(urls.count)
        for url in urls {
            if let item = makeItem(for: url) { items.append(item) }
        }
        return items
    }

    /// Builds an item for a single file, or nil if it isn't a photo/video, is hidden,
    /// or no longer exists. `allowHidden` is for files the user opened explicitly.
    public static func makeItem(for url: URL, allowHidden: Bool = false) -> MediaItem? {
        if !allowHidden && isIgnoredName(url.lastPathComponent) { return nil }
        guard let kind = MediaClassifier.kind(of: url) else { return nil }
        guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)) else { return nil }
        if !allowHidden && values.isHidden == true { return nil }

        var isFile = values.isRegularFile == true
        if !isFile && values.isSymbolicLink == true {
            let target = url.resolvingSymlinksInPath()
            isFile = (try? target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        guard isFile else { return nil }

        return MediaItem(url: url, kind: kind, modificationDate: values.contentModificationDate ?? .distantPast)
    }

    static func classify(_ error: Error) -> FolderScanError {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileReadNoPermissionError: return .accessDenied
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError: return .notFound
            default: break
            }
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain,
           underlying.code == Int(EPERM) || underlying.code == Int(EACCES) {
            return .accessDenied
        }
        return .other(nsError.localizedDescription)
    }
}
