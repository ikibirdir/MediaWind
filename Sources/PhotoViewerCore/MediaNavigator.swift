import Foundation

public enum SortOrder: String, CaseIterable, Sendable {
    /// Natural order like Finder: IMG_2 before IMG_10, case-insensitive.
    case name
    /// Like Finder's Date Modified column: newest at the top.
    case dateModifiedNewestFirst
    case dateModifiedOldestFirst
}

public enum MediaSorter {
    public static func sorted(_ items: [MediaItem], by order: SortOrder) -> [MediaItem] {
        items.sorted { areInIncreasingOrder($0, $1, order) }
    }

    public static func areInIncreasingOrder(_ a: MediaItem, _ b: MediaItem, _ order: SortOrder) -> Bool {
        switch order {
        case .name:
            return nameOrder(a, b)
        case .dateModifiedNewestFirst:
            if a.modificationDate != b.modificationDate { return a.modificationDate > b.modificationDate }
            return nameOrder(a, b)
        case .dateModifiedOldestFirst:
            if a.modificationDate != b.modificationDate { return a.modificationDate < b.modificationDate }
            return nameOrder(a, b)
        }
    }

    private static func nameOrder(_ a: MediaItem, _ b: MediaItem) -> Bool {
        switch a.name.localizedStandardCompare(b.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a.key < b.key
        }
    }
}

public enum NavigationStep: Sendable {
    case previous, next, first, last
}

/// The ordered list being browsed and the position in it. Stops at the first/last item.
public struct MediaNavigator: Sendable {
    public private(set) var items: [MediaItem]
    public private(set) var currentIndex: Int
    public private(set) var sortOrder: SortOrder

    public init(items: [MediaItem], current: MediaItem? = nil, sortOrder: SortOrder) {
        self.sortOrder = sortOrder
        var all = items
        if let current, !all.contains(current) { all.append(current) }
        self.items = MediaSorter.sorted(Self.unique(all), by: sortOrder)
        self.currentIndex = 0
        if let current, let index = self.items.firstIndex(of: current) {
            currentIndex = index
        }
    }

    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }

    public var current: MediaItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    public var canGoPrevious: Bool { currentIndex > 0 }
    public var canGoNext: Bool { currentIndex < items.count - 1 }

    /// "12 of 348", or nil when there is nothing to show.
    public var positionDescription: String? {
        guard !items.isEmpty else { return nil }
        return "\(currentIndex + 1) of \(items.count)"
    }

    public func index(of item: MediaItem) -> Int? {
        items.firstIndex(of: item)
    }

    /// Moves and returns true if the current item changed.
    @discardableResult
    public mutating func move(_ step: NavigationStep) -> Bool {
        guard !items.isEmpty else { return false }
        let target: Int
        switch step {
        case .previous: target = max(currentIndex - 1, 0)
        case .next: target = min(currentIndex + 1, items.count - 1)
        case .first: target = 0
        case .last: target = items.count - 1
        }
        guard target != currentIndex else { return false }
        currentIndex = target
        return true
    }

    @discardableResult
    public mutating func select(_ item: MediaItem) -> Bool {
        guard let index = items.firstIndex(of: item) else { return false }
        currentIndex = index
        return true
    }

    /// Re-sorts, keeping the current item current.
    public mutating func setSortOrder(_ order: SortOrder) {
        let keep = current
        sortOrder = order
        items = MediaSorter.sorted(items, by: order)
        if let keep, let index = items.firstIndex(of: keep) { currentIndex = index }
    }

    /// Swaps in a fresh listing (e.g. after the background folder scan). The current item
    /// stays current; if the listing doesn't contain it (a hidden file the user opened
    /// explicitly), it is kept anyway.
    public mutating func replaceItems(_ newItems: [MediaItem]) {
        let keep = current
        var all = newItems
        if let keep, !all.contains(keep) { all.append(keep) }
        items = MediaSorter.sorted(Self.unique(all), by: sortOrder)
        currentIndex = 0
        if let keep, let index = items.firstIndex(of: keep) { currentIndex = index }
    }

    /// Drops a file that was deleted or renamed. If it was the current item, the item after
    /// it becomes current (or the one before, if it was the last), so repeating the same
    /// navigation step continues in the same direction.
    @discardableResult
    public mutating func remove(_ item: MediaItem) -> Bool {
        guard let index = items.firstIndex(of: item) else { return false }
        items.remove(at: index)
        if index < currentIndex {
            currentIndex -= 1
        } else if currentIndex >= items.count {
            currentIndex = max(items.count - 1, 0)
        }
        return true
    }

    /// Items worth preloading around the current one, nearest first, biased towards the
    /// direction of travel (`direction` > 0 means moving forward).
    public func neighbors(direction: Int, ahead: Int = 2, behind: Int = 1) -> [MediaItem] {
        guard !items.isEmpty else { return [] }
        let forward = direction >= 0
        var result: [MediaItem] = []
        for distance in 1...max(ahead, behind) {
            if distance <= ahead {
                let i = currentIndex + (forward ? distance : -distance)
                if items.indices.contains(i) { result.append(items[i]) }
            }
            if distance <= behind {
                let i = currentIndex + (forward ? -distance : distance)
                if items.indices.contains(i) { result.append(items[i]) }
            }
        }
        return result
    }

    private static func unique(_ items: [MediaItem]) -> [MediaItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.key).inserted }
    }
}
