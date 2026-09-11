import Foundation
import Testing
@testable import PhotoViewerCore

// MARK: - Helpers

private func item(_ name: String, _ kind: MediaKind = .image, date: TimeInterval = 0) -> MediaItem {
    MediaItem(url: URL(fileURLWithPath: "/tmp/folder/\(name)"), kind: kind,
              modificationDate: Date(timeIntervalSince1970: date))
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
        #expect(items.first { $0.name == "c.mkv" }?.kind == .video)
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

    @Test func readsModificationDates() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try touch(folder, "x.jpg", date: date)
        let items = try FolderScanner.scan(folder: folder)
        #expect(items.first?.modificationDate == date)
    }

    @Test func scansFiveThousandFilesQuickly() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for i in 1...5000 { try touch(folder, "IMG_\(i).jpg") }
        let start = Date()
        let items = try FolderScanner.scan(folder: folder)
        let sorted = MediaSorter.sorted(items, by: .name)
        let elapsed = Date().timeIntervalSince(start)
        #expect(sorted.count == 5000)
        #expect(sorted[1].name == "IMG_2.jpg")
        #expect(elapsed < 2.0, "scan + sort took \(elapsed)s")
    }
}

// MARK: - Sorting

@Suite struct SortTests {
    @Test func nameOrderIsNaturalLikeFinder() {
        let items = ["IMG_10.jpg", "img_2.jpg", "IMG_1.jpg", "IMG_100.jpg", "IMG_20.jpg", "a.png", "B.png"].map { item($0) }
        #expect(names(MediaSorter.sorted(items, by: .name)) ==
                ["a.png", "B.png", "IMG_1.jpg", "img_2.jpg", "IMG_10.jpg", "IMG_20.jpg", "IMG_100.jpg"])
    }

    @Test func dateOrdersBreakTiesByName() {
        let items = [item("c.jpg", date: 200), item("b.jpg", date: 100), item("a.jpg", date: 200), item("d.jpg", date: 300)]
        #expect(names(MediaSorter.sorted(items, by: .dateModifiedNewestFirst)) == ["d.jpg", "a.jpg", "c.jpg", "b.jpg"])
        #expect(names(MediaSorter.sorted(items, by: .dateModifiedOldestFirst)) == ["b.jpg", "a.jpg", "c.jpg", "d.jpg"])
    }
}

// MARK: - Navigation

@Suite struct NavigatorTests {
    let items = ["IMG_1.jpg", "IMG_2.jpg", "IMG_3.mov", "IMG_10.jpg"].map { item($0) }

    @Test func startsAtOpenedItem() {
        let nav = MediaNavigator(items: items, current: item("IMG_2.jpg"), sortOrder: .name)
        #expect(nav.current?.name == "IMG_2.jpg")
        #expect(nav.positionDescription == "2 of 4")
    }

    @Test func stopsAtTheEnds() {
        var nav = MediaNavigator(items: items, current: item("IMG_1.jpg"), sortOrder: .name)
        #expect(!nav.canGoPrevious)
        var moved = nav.move(.previous)
        #expect(!moved)
        #expect(nav.current?.name == "IMG_1.jpg")
        for _ in 0..<3 {
            moved = nav.move(.next)
            #expect(moved)
        }
        #expect(nav.current?.name == "IMG_10.jpg")
        #expect(!nav.canGoNext)
        moved = nav.move(.next)
        #expect(!moved)
        #expect(nav.current?.name == "IMG_10.jpg")
    }

    @Test func firstAndLast() {
        var nav = MediaNavigator(items: items, current: item("IMG_2.jpg"), sortOrder: .name)
        var moved = nav.move(.last)
        #expect(moved)
        #expect(nav.current?.name == "IMG_10.jpg")
        moved = nav.move(.last)
        #expect(!moved)
        moved = nav.move(.first)
        #expect(moved)
        #expect(nav.current?.name == "IMG_1.jpg")
    }

    @Test func singleOpenedFileThenScanFillsInPosition() {
        var nav = MediaNavigator(items: [item("IMG_3.mov")], current: item("IMG_3.mov"), sortOrder: .name)
        #expect(nav.positionDescription == "1 of 1")
        nav.replaceItems(items)
        #expect(nav.current?.name == "IMG_3.mov")
        #expect(nav.positionDescription == "3 of 4")
    }

    @Test func openedFileMissingFromScanIsKept() {
        var nav = MediaNavigator(items: [item(".hidden.jpg")], current: item(".hidden.jpg"), sortOrder: .name)
        nav.replaceItems(items)
        #expect(nav.current?.name == ".hidden.jpg")
        #expect(nav.count == 5)
    }

    @Test func changingSortKeepsCurrentItem() {
        let dated = [item("a.jpg", date: 3), item("b.jpg", date: 1), item("c.jpg", date: 2)]
        var nav = MediaNavigator(items: dated, current: item("b.jpg"), sortOrder: .name)
        #expect(nav.positionDescription == "2 of 3")
        nav.setSortOrder(.dateModifiedNewestFirst)
        #expect(nav.current?.name == "b.jpg")
        #expect(nav.positionDescription == "3 of 3")
        nav.setSortOrder(.dateModifiedOldestFirst)
        #expect(nav.positionDescription == "1 of 3")
    }

    @Test func removingCurrentContinuesInSameDirection() {
        // Going forward from IMG_1 to IMG_2, which turns out to be deleted: land on IMG_3.
        var nav = MediaNavigator(items: items, current: item("IMG_2.jpg"), sortOrder: .name)
        nav.remove(item("IMG_2.jpg"))
        #expect(nav.current?.name == "IMG_3.mov")

        // Going backward from IMG_10 to IMG_3, which is deleted: current becomes IMG_10 again,
        // and one more step back continues to IMG_1.
        nav.select(item("IMG_3.mov"))
        nav.remove(item("IMG_3.mov"))
        #expect(nav.current?.name == "IMG_10.jpg")
        nav.move(.previous)
        #expect(nav.current?.name == "IMG_1.jpg")
    }

    @Test func removingOtherItemsKeepsCurrent() {
        var nav = MediaNavigator(items: items, current: item("IMG_3.mov"), sortOrder: .name)
        nav.remove(item("IMG_1.jpg"))
        #expect(nav.current?.name == "IMG_3.mov")
        #expect(nav.positionDescription == "2 of 3")
        nav.remove(item("IMG_10.jpg"))
        #expect(nav.current?.name == "IMG_3.mov")
        #expect(nav.positionDescription == "2 of 2")
    }

    @Test func removingLastItemMovesBack() {
        var nav = MediaNavigator(items: items, current: item("IMG_10.jpg"), sortOrder: .name)
        nav.remove(item("IMG_10.jpg"))
        #expect(nav.current?.name == "IMG_3.mov")
        nav.remove(item("IMG_1.jpg")); nav.remove(item("IMG_2.jpg")); nav.remove(item("IMG_3.mov"))
        #expect(nav.isEmpty)
        #expect(nav.current == nil)
        #expect(nav.positionDescription == nil)
    }

    @Test func neighborsFavourDirectionOfTravel() {
        let many = (1...9).map { item("IMG_\($0).jpg") }
        let nav = MediaNavigator(items: many, current: item("IMG_5.jpg"), sortOrder: .name)
        #expect(names(nav.neighbors(direction: 1)) == ["IMG_6.jpg", "IMG_4.jpg", "IMG_7.jpg"])
        #expect(names(nav.neighbors(direction: -1)) == ["IMG_4.jpg", "IMG_6.jpg", "IMG_3.jpg"])
    }

    @Test func duplicatesAreCollapsed() {
        let nav = MediaNavigator(items: items + items, current: nil, sortOrder: .name)
        #expect(nav.count == 4)
    }
}
