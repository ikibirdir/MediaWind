import Foundation

/// Works out how Finder is showing a folder, so browsing follows the same order.
///
/// Finder keeps each folder's view settings in a `.DS_Store` file: usually in the parent
/// folder under the folder's name, sometimes in the folder itself under ".". When a folder
/// has no saved settings, Finder falls back to its global view preferences.
public enum FinderSort {
    public struct Arrangement: Equatable, Sendable {
        public var order: MediaSortOrder
        /// Where it came from, for logging.
        public var source: String
    }

    /// Finder's four view styles, as stored in `.DS_Store`.
    static let iconView = "icnv", listView = "Nlsv", columnView = "clmv", galleryView = "glyv"

    /// Optional logging, so the app can trace what was read. Set once at startup.
    nonisolated(unsafe) public static var diagnostics: ((String) -> Void)?

    public static func arrangement(for folder: URL) -> Arrangement? {
        if let fromFolder = arrangementFromDSStore(for: folder) { return fromFolder }
        return globalArrangement()
    }

    // MARK: - .DS_Store

    static func arrangementFromDSStore(for folder: URL) -> Arrangement? {
        let own = folder.appendingPathComponent(".DS_Store")
        let parent = folder.deletingLastPathComponent().appendingPathComponent(".DS_Store")
        let candidates: [(url: URL, entry: String, label: String)] = [
            (own, ".", "folder's .DS_Store"),
            (own, folder.lastPathComponent, "folder's .DS_Store"),
            (parent, folder.lastPathComponent, "parent's .DS_Store"),
        ]
        for candidate in candidates {
            guard let data = try? Data(contentsOf: candidate.url, options: [.mappedIfSafe]) else { continue }
            let start = Date()
            let records = records(in: data, named: candidate.entry)
            diagnostics?("\(candidate.url.path) entry “\(candidate.entry)”: \(data.count) bytes, "
                + "records \(records.keys.sorted()) in \(Int(-start.timeIntervalSinceNow * 1000)) ms")
            guard !records.isEmpty else { continue }
            if let arrangement = arrangement(from: records, label: candidate.label) { return arrangement }
        }
        return nil
    }

    static func arrangement(from records: [String: Value], label: String) -> Arrangement? {
        let style = records["vstl"]?.fourCharCode
            ?? (records["bwsp"]?.plist?["ViewStyle"] as? String)
            ?? iconView
        // Prefer the settings of the view the folder is actually showing.
        let preferred: [String]
        switch style {
        case listView: preferred = ["lsvp", "lsvP", "icvp", "glvp"]
        case galleryView: preferred = ["glvp", "icvp", "lsvp", "lsvP"]
        case columnView: preferred = ["icvp", "glvp", "lsvp", "lsvP"]
        default: preferred = ["icvp", "glvp", "lsvp", "lsvP"]
        }
        for id in preferred {
            guard let plist = records[id]?.plist else { continue }
            if let order = order(fromViewSettings: plist) {
                return Arrangement(order: order, source: "\(label) (\(viewName(style)))")
            }
        }
        return nil
    }

    static func viewName(_ style: String) -> String {
        switch style {
        case listView: return "list view"
        case galleryView: return "gallery view"
        case columnView: return "column view"
        default: return "icon view"
        }
    }

    /// Icon and gallery views store "arrangeBy"; list views store "sortColumn" plus a
    /// per-column direction.
    static func order(fromViewSettings settings: [String: Any]) -> MediaSortOrder? {
        if let arrangeBy = settings["arrangeBy"] as? String, let key = sortKey(forFinderName: arrangeBy) {
            return MediaSortOrder(key)
        }
        if let column = settings["sortColumn"] as? String, let key = sortKey(forFinderName: column) {
            var ascending: Bool?
            if let columns = settings["columns"] as? [String: Any],
               let entry = columns[column] as? [String: Any],
               let flag = entry["ascending"] as? Bool {
                ascending = flag
            } else if let columns = settings["columns"] as? [[String: Any]],
                      let entry = columns.first(where: { $0["identifier"] as? String == column }),
                      let flag = entry["ascending"] as? Bool {
                ascending = flag
            }
            return MediaSortOrder(key, ascending: ascending)
        }
        return nil
    }

    /// Finder's names for the orders. Anything else (labels, tags, manual "none") has no
    /// equivalent here, so the caller falls back.
    static func sortKey(forFinderName name: String) -> MediaSortKey? {
        switch name {
        case "name": return .name
        case "kind": return .kind
        case "dateCreated", "creationDate": return .dateCreated
        case "dateModified", "modificationDate": return .dateModified
        case "dateAdded": return .dateAdded
        case "dateLastOpened": return .dateLastOpened
        case "size", "logicalSize", "physicalSize": return .size
        default: return nil
        }
    }

    // MARK: - Finder's global preferences

    static func globalArrangement(defaults: UserDefaults? = UserDefaults(suiteName: "com.apple.finder")) -> Arrangement? {
        guard let defaults else { return nil }
        let style = defaults.string(forKey: "FXPreferredViewStyle") ?? iconView
        let settings = defaults.dictionary(forKey: "StandardViewSettings") ?? [:]
        func view(_ name: String) -> [String: Any]? { settings[name] as? [String: Any] }

        let candidates: [[String: Any]?]
        switch style {
        case listView: candidates = [view("ExtendedListViewSettingsV2"), view("ListViewSettings"), view("IconViewSettings")]
        case galleryView: candidates = [view("GalleryViewSettings"), view("IconViewSettings")]
        default: candidates = [view("IconViewSettings"), view("GalleryViewSettings")]
        }
        for settings in candidates.compactMap({ $0 }) {
            if let order = order(fromViewSettings: settings) {
                return Arrangement(order: order, source: "Finder settings (\(viewName(style)))")
            }
        }
        return nil
    }

    // MARK: - Minimal .DS_Store reader

    enum Value: Equatable {
        case blob(Data)
        case fourChar(String)
        case number(Int64)
        case boolean(Bool)
        case text(String)

        var fourCharCode: String? { if case .fourChar(let code) = self { return code } else { return nil } }

        var plist: [String: Any]? {
            guard case .blob(let data) = self else { return nil }
            return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        }

        static func == (lhs: Value, rhs: Value) -> Bool {
            switch (lhs, rhs) {
            case (.blob(let a), .blob(let b)): return a == b
            case (.fourChar(let a), .fourChar(let b)): return a == b
            case (.number(let a), .number(let b)): return a == b
            case (.boolean(let a), .boolean(let b)): return a == b
            case (.text(let a), .text(let b)): return a == b
            default: return false
            }
        }
    }

    /// Pulls the records for one entry out of a .DS_Store.
    ///
    /// The file is a B-tree in Apple's "buddy allocator" container, but every record has the
    /// same shape wherever it sits: a big-endian UTF-16 name (length first), a four-character
    /// property id, a four-character type, then the value. Finding the name is enough to read
    /// the record that follows it.
    static func records(in data: Data, named entry: String) -> [String: Value] {
        let bytes = [UInt8](data)
        var nameBytes: [UInt8] = []
        for unit in Array(entry.utf16) {
            nameBytes.append(UInt8(unit >> 8))
            nameBytes.append(UInt8(unit & 0xFF))
        }
        // .DS_Store files are tens of kilobytes; anything else isn't one, and scanning a huge
        // file byte by byte would stall the folder listing.
        guard !nameBytes.isEmpty, bytes.count > nameBytes.count + 12, bytes.count <= 8 << 20 else { return [:] }

        func readUInt32(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            return Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        }
        func ascii(_ offset: Int, _ length: Int) -> String? {
            guard offset >= 0, offset + length <= bytes.count else { return nil }
            let slice = bytes[offset..<offset + length]
            guard slice.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
            return String(bytes: slice, encoding: .ascii)
        }

        var result: [String: Value] = [:]
        var searchStart = 0
        var inspected = 0
        while inspected < 100_000, let match = firstIndex(of: nameBytes, in: bytes, from: searchStart) {
            inspected += 1
            searchStart = match + nameBytes.count
            // The name is preceded by its length in UTF-16 units.
            guard readUInt32(match - 4) == entry.utf16.count else { continue }
            var cursor = match + nameBytes.count
            guard let id = ascii(cursor, 4), let type = ascii(cursor + 4, 4) else { continue }
            cursor += 8
            switch type {
            case "blob":
                guard let length = readUInt32(cursor), cursor + 4 + length <= bytes.count else { continue }
                result[id] = .blob(Data(bytes[(cursor + 4)..<(cursor + 4 + length)]))
            case "type":
                guard let code = ascii(cursor, 4) else { continue }
                result[id] = .fourChar(code)
            case "long", "shor":
                guard let value = readUInt32(cursor) else { continue }
                result[id] = .number(Int64(value))
            case "bool":
                guard cursor < bytes.count else { continue }
                result[id] = .boolean(bytes[cursor] != 0)
            case "ustr":
                guard let length = readUInt32(cursor), cursor + 4 + length * 2 <= bytes.count else { continue }
                let text = Data(bytes[(cursor + 4)..<(cursor + 4 + length * 2)])
                result[id] = .text(String(data: text, encoding: .utf16BigEndian) ?? "")
            default:
                continue
            }
        }
        return result
    }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let last = haystack.count - needle.count
        guard start <= last else { return nil }
        for index in start...last where haystack[index] == needle[0] {
            var matched = true
            for offset in 1..<needle.count where haystack[index + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { return index }
        }
        return nil
    }
}
