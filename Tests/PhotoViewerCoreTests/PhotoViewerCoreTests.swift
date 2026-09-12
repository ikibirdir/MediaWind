import Foundation
import Testing
@testable import PhotoViewerCore

// MARK: - Helpers

private func item(_ name: String, _ kind: MediaKind = .image, modified: TimeInterval = 0,
                  created: TimeInterval? = nil, added: TimeInterval? = nil, opened: TimeInterval? = nil,
                  size: Int64 = 0, type: String = "JPEG image") -> MediaItem {
    MediaItem(url: URL(fileURLWithPath: "/tmp/folder/\(name)"), kind: kind,
              modificationDate: Date(timeIntervalSince1970: modified),
              creationDate: created.map { Date(timeIntervalSince1970: $0) },
              addedDate: added.map { Date(timeIntervalSince1970: $0) },
              lastOpenedDate: opened.map { Date(timeIntervalSince1970: $0) },
              size: size, typeDescription: type)
}

private func names(_ items: [MediaItem]) -> [String] { items.map(\.name) }

private func makeTempFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("PhotoViewerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func touch(_ folder: URL, _ name: String, date: Date? = nil) throws {
    let url = folder.appendingPathComponent(name)
    try Data([0xFF, 0xD8, 0xFF]).write(to: url)
    if let date {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}

/// One .DS_Store record: UTF-16 name (length first), 4-char property id, 4-char type, value.
private func dsRecord(name: String, id: String, type: String, payload: Data) -> Data {
    var data = Data()
    withUnsafeBytes(of: UInt32(name.utf16.count).bigEndian) { data.append(contentsOf: $0) }
    for unit in Array(name.utf16) {
        data.append(UInt8(unit >> 8))
        data.append(UInt8(unit & 0xFF))
    }
    data.append(contentsOf: Array(id.utf8))
    data.append(contentsOf: Array(type.utf8))
    if type == "blob" {
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { data.append(contentsOf: $0) }
    }
    data.append(payload)
    return data
}

private func viewSettings(_ dictionary: [String: Any]) -> Data {
    try! PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
}

// MARK: - Classification

@Suite struct ClassifierTests {
    @Test(arguments: ["jpg", "JPG", "jpeg", "heic", "HEIC", "png", "gif", "tiff", "webp", "bmp", "dng", "avif"])
    func imagesAreImages(ext: String) {
        #expect(MediaClassifier.kind(forExtension: ext) == .image)
    }

    @Test(arguments: ["mov", "MOV", "mp4", "m4v"])
    func moviesAreVideos(ext: String) {
        #expect(MediaClassifier.kind(forExtension: ext) == .video)
    }

    @Test(arguments: ["mkv", "webm", "avi", "wmv"])
    func fallbackVideoFormatsAreVideos(ext: String) {
        #expect(MediaClassifier.kind(forExtension: ext) == .video)
    }

    @Test(arguments: ["pdf", "PDF", "txt", "mp3", "m4a", "zip", "", "swift", "docx"])
    func otherFilesAreIgnored(ext: String) {
        #expect(MediaClassifier.kind(forExtension: ext) == nil)
    }

    @Test func kindDescriptionsLookLikeFinder() {
        #expect(MediaClassifier.typeDescription(of: URL(fileURLWithPath: "/tmp/a.jpg")).isEmpty == false)
        #expect(MediaClassifier.typeDescription(of: URL(fileURLWithPath: "/tmp/a.jpg"))
                == MediaClassifier.typeDescription(of: URL(fileURLWithPath: "/tmp/b.JPG")))
    }
}

// MARK: - Scanning

@Suite struct ScannerTests {
    @Test func skipsJunkHiddenAndNonMediaFiles() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["a.jpg", "._a.jpg", ".hidden.png", "notes.txt", "doc.pdf", "b.MOV", "c.mkv", "d.heic"] {
            try touch(folder, name)
        }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub.jpg"), withIntermediateDirectories: true)
        try touch(folder.appendingPathComponent("sub.jpg"), "inner.jpg")

        let items = try FolderScanner.scan(folder: folder)
        #expect(Set(names(items)) == ["a.jpg", "b.MOV", "c.mkv", "d.heic"])
        #expect(items.first { $0.name == "b.MOV" }?.kind == .video)
    }

    @Test func missingFolderIsNotFound() {
        #expect(throws: FolderScanError.notFound) {
            try FolderScanner.scan(folder: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        }
    }

    @Test func hiddenFileCanBeOpenedExplicitly() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try touch(folder, ".secret.jpg")
        let url = folder.appendingPathComponent(".secret.jpg")
        #expect(FolderScanner.makeItem(for: url) == nil)
        #expect(FolderScanner.makeItem(for: url, allowHidden: true) != nil)
    }

    @Test func deletedFileYieldsNoItem() {
        #expect(FolderScanner.makeItem(for: URL(fileURLWithPath: "/tmp/gone-\(UUID().uuidString).jpg")) == nil)
    }

    @Test func readsTheMetadataFinderSortsBy() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try touch(folder, "x.jpg", date: date)
        let item = try #require(try FolderScanner.scan(folder: folder).first)
        #expect(item.modificationDate == date)
        #expect(item.size == 3)
        #expect(item.creationDate > Date(timeIntervalSince1970: 1))
        #expect(item.addedDate > Date(timeIntervalSince1970: 1))
        #expect(item.typeDescription.isEmpty == false)
    }

    @Test func scansFiveThousandFilesQuickly() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for i in 1...5000 { try touch(folder, "IMG_\(i).jpg") }
        let start = Date()
        let items = try FolderScanner.scan(folder: folder)
        let sorted = MediaSorter.sorted(items, by: .byName)
        let elapsed = Date().timeIntervalSince(start)
        #expect(sorted.count == 5000)
        #expect(sorted[1].name == "IMG_2.jpg")
        #expect(elapsed < 3.0, "scan + sort took \(elapsed)s")
    }
}

// MARK: - Sorting

@Suite struct SortTests {
    @Test func nameOrderIsNaturalLikeFinder() {
        let items = ["IMG_10.jpg", "img_2.jpg", "IMG_1.jpg", "IMG_100.jpg", "IMG_20.jpg", "a.png", "B.png"].map { item($0) }
        #expect(names(MediaSorter.sorted(items, by: .byName)) ==
                ["a.png", "B.png", "IMG_1.jpg", "img_2.jpg", "IMG_10.jpg", "IMG_20.jpg", "IMG_100.jpg"])
    }

    @Test func reversedNameOrder() {
        let items = ["a.jpg", "b.jpg", "c.jpg"].map { item($0) }
        #expect(names(MediaSorter.sorted(items, by: MediaSortOrder(.name, ascending: false))) == ["c.jpg", "b.jpg", "a.jpg"])
    }

    @Test func datesDefaultToNewestFirstAndTieBreakByName() {
        let items = [item("c.jpg", created: 200), item("b.jpg", created: 100),
                     item("a.jpg", created: 200), item("d.jpg", created: 300)]
        #expect(names(MediaSorter.sorted(items, by: MediaSortOrder(.dateCreated))) == ["d.jpg", "a.jpg", "c.jpg", "b.jpg"])
        #expect(names(MediaSorter.sorted(items, by: MediaSortOrder(.dateCreated, ascending: true))) ==
                ["b.jpg", "a.jpg", "c.jpg", "d.jpg"])
    }

    @Test func everyDateKeySortsByItsOwnField() {
        let older = item("older.jpg", modified: 10, created: 300, added: 10, opened: 50)
        let newer = item("newer.jpg", modified: 300, created: 10, added: 300, opened: 5)
        #expect(names(MediaSorter.sorted([older, newer], by: MediaSortOrder(.dateModified))) == ["newer.jpg", "older.jpg"])
        #expect(names(MediaSorter.sorted([older, newer], by: MediaSortOrder(.dateCreated))) == ["older.jpg", "newer.jpg"])
        #expect(names(MediaSorter.sorted([older, newer], by: MediaSortOrder(.dateAdded))) == ["newer.jpg", "older.jpg"])
        #expect(names(MediaSorter.sorted([older, newer], by: MediaSortOrder(.dateLastOpened))) == ["older.jpg", "newer.jpg"])
    }

    @Test func sizeAndKind() {
        let items = [item("small.jpg", size: 10, type: "JPEG image"),
                     item("big.jpg", size: 900, type: "JPEG image"),
                     item("clip.mp4", .video, size: 50, type: "MPEG-4 movie")]
        #expect(names(MediaSorter.sorted(items, by: MediaSortOrder(.size))) == ["big.jpg", "clip.mp4", "small.jpg"])
        #expect(names(MediaSorter.sorted(items, by: MediaSortOrder(.kind))) == ["big.jpg", "small.jpg", "clip.mp4"])
    }

    @Test func ordersSurviveUserDefaultsRoundTrip() {
        for key in MediaSortKey.allCases {
            for ascending in [true, false] {
                let order = MediaSortOrder(key, ascending: ascending)
                #expect(MediaSortOrder(rawValue: order.rawValue) == order)
            }
        }
        #expect(MediaSortOrder(rawValue: "nonsense") == nil)
        #expect(MediaSortOrder(.dateCreated).ascending == false)
        #expect(MediaSortOrder(.name).ascending)
    }
}

// MARK: - Following Finder's arrangement

@Suite struct FinderSortTests {
    @Test func readsIconViewArrangement() {
        let data = dsRecord(name: "Photos from 2025", id: "icvp", type: "blob",
                            payload: viewSettings(["arrangeBy": "dateCreated"]))
        let records = FinderSort.records(in: data, named: "Photos from 2025")
        let arrangement = FinderSort.arrangement(from: records, label: "test")
        #expect(arrangement?.order == MediaSortOrder(.dateCreated))
        #expect(arrangement?.order.ascending == false)
    }

    @Test func listViewUsesSortColumnAndDirection() {
        var data = dsRecord(name: "Docs", id: "vstl", type: "type", payload: Data("Nlsv".utf8))
        data.append(dsRecord(name: "Docs", id: "lsvp", type: "blob",
                             payload: viewSettings(["sortColumn": "dateAdded",
                                                    "columns": ["dateAdded": ["ascending": true]]])))
        let arrangement = FinderSort.arrangement(from: FinderSort.records(in: data, named: "Docs"), label: "test")
        #expect(arrangement?.order == MediaSortOrder(.dateAdded, ascending: true))
    }

    @Test func ordersFinderHasNoEquivalentForAreIgnored() {
        for value in ["none", "label", "tags", "grid"] {
            let data = dsRecord(name: "F", id: "icvp", type: "blob", payload: viewSettings(["arrangeBy": value]))
            #expect(FinderSort.arrangement(from: FinderSort.records(in: data, named: "F"), label: "test") == nil)
        }
    }

    @Test func findsAFolderSettingStoredInItsParent() throws {
        let parent = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appendingPathComponent("Holiday", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var data = Data(repeating: 0, count: 36)   // stand-in for the file header
        data.append(dsRecord(name: "Holiday", id: "icvp", type: "blob",
                             payload: viewSettings(["arrangeBy": "size"])))
        try data.write(to: parent.appendingPathComponent(".DS_Store"))

        let arrangement = FinderSort.arrangementFromDSStore(for: folder)
        #expect(arrangement?.order == MediaSortOrder(.size))
        #expect(arrangement?.source.contains("parent") == true)
    }

    @Test func otherEntriesInTheSameFileAreNotMixedUp() {
        var data = dsRecord(name: "A", id: "icvp", type: "blob", payload: viewSettings(["arrangeBy": "name"]))
        data.append(dsRecord(name: "B", id: "icvp", type: "blob", payload: viewSettings(["arrangeBy": "size"])))
        #expect(FinderSort.arrangement(from: FinderSort.records(in: data, named: "A"), label: "t")?.order == MediaSortOrder(.name))
        #expect(FinderSort.arrangement(from: FinderSort.records(in: data, named: "B"), label: "t")?.order == MediaSortOrder(.size))
        #expect(FinderSort.records(in: data, named: "C").isEmpty)
    }

    @Test func finderNamesMapToSortKeys() {
        #expect(FinderSort.sortKey(forFinderName: "dateLastOpened") == .dateLastOpened)
        #expect(FinderSort.sortKey(forFinderName: "kind") == .kind)
        #expect(FinderSort.sortKey(forFinderName: "logicalSize") == .size)
        #expect(FinderSort.sortKey(forFinderName: "somethingElse") == nil)
    }
}

// MARK: - Navigation

@Suite struct NavigatorTests {
    let items = ["IMG_1.jpg", "IMG_2.jpg", "IMG_3.mov", "IMG_10.jpg"].map { item($0) }

    @Test func startsAtOpenedItem() {
        let nav = MediaNavigator(items: items, current: item("IMG_2.jpg"), sortOrder: .byName)
        #expect(nav.current?.name == "IMG_2.jpg")
        #expect(nav.positionDescription == "2 of 4")
    }

    @Test func stopsAtTheEnds() {
        var nav = MediaNavigator(items: items, current: item("IMG_1.jpg"), sortOrder: .byName)
        #expect(!nav.canGoPrevious)
        var moved = nav.move(.previous)
        #expect(!moved)
        for _ in 0..<3 {
            moved = nav.move(.next)
            #expect(moved)
        }
        #expect(nav.current?.name == "IMG_10.jpg")
        moved = nav.move(.next)
        #expect(!moved)
    }

    @Test func firstAndLast() {
        var nav = MediaNavigator(items: items, current: item("IMG_2.jpg"), sortOrder: .byName)
        var moved = nav.move(.last)
        #expect(moved)
        #expect(nav.current?.name == "IMG_10.jpg")
        moved = nav.move(.first)
        #expect(moved)
        #expect(nav.current?.name == "IMG_1.jpg")
    }

    @Test func singleOpenedFileThenScanFillsInPosition() {
        var nav = MediaNavigator(items: [item("IMG_3.mov")], current: item("IMG_3.mov"), sortOrder: .byName)
        #expect(nav.positionDescription == "1 of 1")
        nav.replaceItems(items)
        #expect(nav.current?.name == "IMG_3.mov")
        #expect(nav.positionDescription == "3 of 4")
    }

    @Test func openedFileMissingFromScanIsKept() {
        var nav = MediaNavigator(items: [item(".hidden.jpg")], current: item(".hidden.jpg"), sortOrder: .byName)
        nav.replaceItems(items)
        #expect(nav.current?.name == ".hidden.jpg")
        #expect(nav.count == 5)
    }

    @Test func changingSortKeepsCurrentItem() {
        let dated = [item("a.jpg", created: 3), item("b.jpg", created: 1), item("c.jpg", created: 2)]
        var nav = MediaNavigator(items: dated, current: item("b.jpg"), sortOrder: .byName)
        #expect(nav.positionDescription == "2 of 3")
        nav.setSortOrder(MediaSortOrder(.dateCreated))
        #expect(nav.current?.name == "b.jpg")
        #expect(nav.positionDescription == "3 of 3")
        nav.setSortOrder(MediaSortOrder(.dateCreated, ascending: true))
        #expect(nav.positionDescription == "1 of 3")
    }

    @Test func removingCurrentContinuesInSameDirection() {
        var nav = MediaNavigator(items: items, current: item("IMG_2.jpg"), sortOrder: .byName)
        nav.remove(item("IMG_2.jpg"))
        #expect(nav.current?.name == "IMG_3.mov")

        nav.select(item("IMG_3.mov"))
        nav.remove(item("IMG_3.mov"))
        #expect(nav.current?.name == "IMG_10.jpg")
        nav.move(.previous)
        #expect(nav.current?.name == "IMG_1.jpg")
    }

    @Test func removingOtherItemsKeepsCurrent() {
        var nav = MediaNavigator(items: items, current: item("IMG_3.mov"), sortOrder: .byName)
        nav.remove(item("IMG_1.jpg"))
        #expect(nav.current?.name == "IMG_3.mov")
        #expect(nav.positionDescription == "2 of 3")
    }

    @Test func removingLastItemMovesBack() {
        var nav = MediaNavigator(items: items, current: item("IMG_10.jpg"), sortOrder: .byName)
        nav.remove(item("IMG_10.jpg"))
        #expect(nav.current?.name == "IMG_3.mov")
        nav.remove(item("IMG_1.jpg")); nav.remove(item("IMG_2.jpg")); nav.remove(item("IMG_3.mov"))
        #expect(nav.isEmpty)
        #expect(nav.positionDescription == nil)
    }

    @Test func neighborsFavourDirectionOfTravel() {
        let many = (1...9).map { item("IMG_\($0).jpg") }
        let nav = MediaNavigator(items: many, current: item("IMG_5.jpg"), sortOrder: .byName)
        #expect(names(nav.neighbors(direction: 1)) == ["IMG_6.jpg", "IMG_4.jpg", "IMG_7.jpg"])
        #expect(names(nav.neighbors(direction: -1)) == ["IMG_4.jpg", "IMG_6.jpg", "IMG_3.jpg"])
    }

    @Test func duplicatesAreCollapsed() {
        let nav = MediaNavigator(items: items + items, current: nil, sortOrder: .byName)
        #expect(nav.count == 4)
    }
}
