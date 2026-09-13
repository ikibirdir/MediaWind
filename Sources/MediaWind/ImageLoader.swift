import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A decoded still image, already rotated upright (EXIF orientation applied).
struct DecodedImage {
    let cgImage: CGImage
    /// Full-resolution size of the original, upright, in pixels.
    let originalSize: CGSize

    var isFullResolution: Bool {
        CGFloat(cgImage.width) >= originalSize.width - 1 && CGFloat(cgImage.height) >= originalSize.height - 1
    }
    var byteCost: Int { cgImage.bytesPerRow * cgImage.height }
}

enum LoadedImage {
    case still(DecodedImage)
    /// Animated GIF/PNG/WebP, shown by NSImageView which animates it.
    case animated(NSImage, originalSize: CGSize)

    var originalSize: CGSize {
        switch self {
        case .still(let image): return image.originalSize
        case .animated(_, let size): return size
        }
    }
    var byteCost: Int {
        switch self {
        case .still(let image): return image.byteCost
        case .animated(_, let size): return Int(size.width * size.height * 4)
        }
    }
}

enum ImageLoadError: Error {
    case missing
    case unreadable
}

enum ImageRequest: Hashable {
    /// Fast, low quality: the embedded thumbnail if the file has one. Used while an arrow key is held.
    case preview
    /// Scaled so the longest side is at most this many pixels (the window's pixel size).
    case fit(Int)
    /// Every pixel. Only when zoomed in past the fit image's resolution.
    case full
}

/// Decodes images off the main thread and keeps a few of them. All methods must be called on
/// the main thread; completions run on the main thread.
final class ImageLoader {
    typealias Completion = (Result<LoadedImage, ImageLoadError>) -> Void

    private struct PendingKey: Hashable {
        let path: String
        let request: ImageRequest
    }

    private struct Pending {
        let operation: Operation
        var completions: [Completion]
    }

    private let decodeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MediaWind.decode"
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// One at a time and latest-wins, so holding an arrow key never builds a backlog.
    private let previewQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MediaWind.preview"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        return queue
    }()

    private var fitCache = CostLRU<(image: LoadedImage, maxPixel: Int)>(capacity: 5, byteBudget: 400 << 20)
    private var previewCache = CostLRU<DecodedImage>(capacity: 24, byteBudget: 64 << 20)
    private var fullCache = CostLRU<DecodedImage>(capacity: 1, byteBudget: .max)
    private var failures: [String: ImageLoadError] = [:]
    private var pending: [PendingKey: Pending] = [:]
    private var memoryPressure: DispatchSourceMemoryPressure?

    init() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in self?.purge() }
        source.resume()
        memoryPressure = source
    }

    // MARK: - Cache lookups

    /// A fit image good enough for `maxPixel`: decoded at least that large, or already full resolution.
    func cachedFit(_ url: URL, maxPixel: Int) -> LoadedImage? {
        guard let entry = fitCache.get(url.path) else { return nil }
        if case .still(let image) = entry.image, entry.maxPixel < maxPixel, !image.isFullResolution { return nil }
        return entry.image
    }

    func cachedPreview(_ url: URL) -> DecodedImage? { previewCache.get(url.path) }
    func cachedFull(_ url: URL) -> DecodedImage? { fullCache.get(url.path) }
    func failure(for url: URL) -> ImageLoadError? { failures[url.path] }

    /// Forget everything about a file (deleted, renamed or changed on disk).
    func forget(_ url: URL) {
        fitCache.remove(url.path)
        previewCache.remove(url.path)
        fullCache.remove(url.path)
        failures[url.path] = nil
    }

    /// Drops all decoded images except the one on screen.
    func purge(keeping url: URL? = nil) {
        let keepFit = url.flatMap { fitCache.get($0.path) }
        fitCache.removeAll()
        previewCache.removeAll()
        fullCache.removeAll()
        if let url, let keepFit { fitCache.set(url.path, keepFit, cost: keepFit.image.byteCost) }
    }

    // MARK: - Loading

    /// Decodes in the background. Requests for the same file and quality are merged.
    /// Pass a nil completion for preloading.
    func load(_ url: URL, _ request: ImageRequest, priority: Operation.QueuePriority = .normal,
              completion: Completion? = nil) {
        let key = PendingKey(path: url.path, request: request)

        if var existing = pending[key] {
            if let completion { existing.completions.append(completion) }
            if priority.rawValue > existing.operation.queuePriority.rawValue, !existing.operation.isExecuting {
                existing.operation.queuePriority = priority
            }
            pending[key] = existing
            return
        }

        if request == .preview {
            // Latest wins: anything still waiting is for an item already flipped past.
            for (otherKey, other) in pending where otherKey.request == .preview && !other.operation.isExecuting {
                other.operation.cancel()
                pending[otherKey] = nil
            }
        }

        let operation = BlockOperation()
        operation.addExecutionBlock { [weak operation] in
            guard let operation, !operation.isCancelled else { return }
            let result = ImageDecoder.decode(url, request)
            DispatchQueue.main.async { [weak self] in
                self?.finish(key, result)
            }
        }
        operation.queuePriority = priority
        pending[key] = Pending(operation: operation, completions: completion.map { [$0] } ?? [])
        (request == .preview ? previewQueue : decodeQueue).addOperation(operation)
    }

    /// Cancels queued preloads (requests nobody is waiting for) except for the given files.
    func cancelPreloads(except paths: Set<String>) {
        for (key, entry) in pending where entry.completions.isEmpty && !paths.contains(key.path) && !entry.operation.isExecuting {
            entry.operation.cancel()
            pending[key] = nil
        }
    }

    private func finish(_ key: PendingKey, _ result: Result<LoadedImage, ImageLoadError>) {
        let completions = pending.removeValue(forKey: key)?.completions ?? []
        switch result {
        case .success(let image):
            failures[key.path] = nil
            switch key.request {
            case .preview:
                if case .still(let still) = image { previewCache.set(key.path, still, cost: still.byteCost) }
            case .fit(let maxPixel):
                fitCache.set(key.path, (image, maxPixel), cost: image.byteCost)
            case .full:
                if case .still(let still) = image { fullCache.set(key.path, still, cost: still.byteCost) }
            }
        case .failure(let error):
            failures[key.path] = error
        }
        for completion in completions { completion(result) }
    }
}

// MARK: - Decoding (thread-safe, no shared state)

enum ImageDecoder {
    /// Longest side of a preview while flipping fast.
    static let previewMaxPixel = 1024

    static func decode(_ url: URL, _ request: ImageRequest) -> Result<LoadedImage, ImageLoadError> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .failure(.missing) }

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, width > 0,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, height > 0
        else {
            return decodeWithAppKit(url, request)
        }

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotated = (5...8).contains(orientation)
        let original = CGSize(width: rotated ? height : width, height: rotated ? width : height)
        let longest = max(width, height)

        if request != .preview, isAnimated(source),
           let image = NSImage(contentsOf: url), image.isValid {
            return .success(.animated(image, originalSize: original))
        }

        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        switch request {
        case .preview:
            // Uses the embedded thumbnail when there is one; otherwise a quick reduced decode.
            options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
            options[kCGImageSourceThumbnailMaxPixelSize] = min(longest, previewMaxPixel)
        case .fit(let maxPixel):
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
            options[kCGImageSourceThumbnailMaxPixelSize] = min(longest, max(maxPixel, 1))
        case .full:
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
            options[kCGImageSourceThumbnailMaxPixelSize] = longest
        }

        if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return .success(.still(DecodedImage(cgImage: image, originalSize: original)))
        }
        return decodeWithAppKit(url, request)
    }

    private static func isAnimated(_ source: CGImageSource) -> Bool {
        guard CGImageSourceGetCount(source) > 1, let type = CGImageSourceGetType(source) as String? else { return false }
        return type == UTType.gif.identifier || type == UTType.png.identifier || type == UTType.webP.identifier
    }

    /// Formats ImageIO can't read but AppKit can (e.g. SVG). Rendered at 2× for Retina.
    private static func decodeWithAppKit(_ url: URL, _ request: ImageRequest) -> Result<LoadedImage, ImageLoadError> {
        guard let image = NSImage(contentsOf: url), image.isValid,
              image.size.width > 0, image.size.height > 0 else {
            return .failure(.unreadable)
        }
        let natural = image.size
        let longestNatural = max(natural.width, natural.height)
        let target: CGFloat
        switch request {
        case .preview: target = CGFloat(previewMaxPixel)
        case .fit(let maxPixel): target = CGFloat(maxPixel)
        case .full: target = longestNatural * 2
        }
        let scale = min(target / longestNatural, 2)
        let pixelWidth = max(1, Int(natural.width * scale)), pixelHeight = max(1, Int(natural.height * scale))
        guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return .failure(.unreadable)
        }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        image.draw(in: NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = context.makeImage() else { return .failure(.unreadable) }
        return .success(.still(DecodedImage(cgImage: cgImage, originalSize: natural)))
    }
}

// MARK: - Small LRU with a memory budget

struct CostLRU<Value> {
    let capacity: Int
    let byteBudget: Int
    private var values: [String: (value: Value, cost: Int)] = [:]
    private var order: [String] = []
    private var totalCost = 0

    init(capacity: Int, byteBudget: Int) {
        self.capacity = capacity
        self.byteBudget = byteBudget
    }

    mutating func get(_ key: String) -> Value? {
        guard let entry = values[key] else { return nil }
        touch(key)
        return entry.value
    }

    mutating func set(_ key: String, _ value: Value, cost: Int) {
        remove(key)
        values[key] = (value, cost)
        order.append(key)
        totalCost += cost
        while order.count > capacity || (totalCost > byteBudget && order.count > 1) {
            remove(order[0])
        }
    }

    mutating func remove(_ key: String) {
        guard let entry = values.removeValue(forKey: key) else { return }
        totalCost -= entry.cost
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
    }

    mutating func removeAll() {
        values.removeAll()
        order.removeAll()
        totalCost = 0
    }

    private mutating func touch(_ key: String) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }
}
