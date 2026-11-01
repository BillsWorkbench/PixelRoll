import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import CoreServices
import Combine

@main
struct Check {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("PixelRoll-check-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("Photos", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("Trip/Nested"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".Hidden"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Ignore.photoslibrary"), withIntermediateDirectories: true)
        let context = CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.15, green: 0.45, blue: 0.65, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
        context.setFillColor(CGColor(red: 0.95, green: 0.65, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 400, y: 0, width: 400, height: 800))
        let image = context.makeImage()!
        func writePNG(_ relative: String) {
            let dest = CGImageDestinationCreateWithURL(root.appendingPathComponent(relative) as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, image, nil)
            precondition(CGImageDestinationFinalize(dest))
        }
        writePNG("Trip/Nested/Sample.png")
        writePNG(".Hidden/Secret.png")
        writePNG("Ignore.photoslibrary/Hidden.png")
        for name in ["Nikon.NEF", "Leica.DNG", "Broken.jpg", "Notes.txt", ".Hidden.jpg"] {
            try Data("fixture".utf8).write(to: root.appendingPathComponent(name))
        }
        let link = root.appendingPathComponent("Linked.png")
        if !fm.fileExists(atPath: link.path) {
            try fm.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("Trip/Nested/Sample.png"))
        }
        let result = PhotoScanner.scan(root)
        let names = Set(result.photos.map { $0.url.lastPathComponent })
        precondition(names == ["Sample.png", "Nikon.NEF", "Leica.DNG", "Broken.jpg"], "Unexpected scan: \(names)")
        precondition(result.unreadableItems == 0)
        print("PASS: recursive discovery, uppercase NEF/DNG, hidden/package/symlink exclusions")
        let thumbnail = await ThumbnailService.shared.thumbnail(for: root.appendingPathComponent("Trip/Nested/Sample.png"), root: root)
        precondition(thumbnail != nil && max(thumbnail!.width, thumbnail!.height) <= 360)
        print("PASS: bounded ImageIO thumbnail decoding")
        let broken = await ThumbnailService.shared.thumbnail(for: root.appendingPathComponent("Broken.jpg"), root: root)
        precondition(broken == nil)
        print("PASS: corrupt image returns unavailable preview")
        let empty = base.appendingPathComponent("Empty", isDirectory: true)
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        precondition(PhotoScanner.scan(empty).photos.isEmpty)
        print("PASS: empty folder")

        try fm.createDirectory(at: root.appendingPathComponent("EmptyFolder"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Trip-other"), withIntermediateDirectories: true)
        writePNG("Trip-other/Sibling.png")
        let folderScan = PhotoScanner.scan(root)
        let tree = PhotoFolder.tree(root: root, directories: folderScan.directories)
        precondition(Set(tree.children?.map { $0.url.lastPathComponent } ?? []) == ["EmptyFolder", "Trip", "Trip-other"], "Root: \(root.path), directories: \(folderScan.directories.map { $0.path }), children: \(tree.children?.map { $0.url.path } ?? [])")
        let trip = tree.children!.first { $0.url.lastPathComponent == "Trip" }!
        precondition(trip.children?.first?.url.lastPathComponent == "Nested")
        precondition(PhotoScope.filter(folderScan.photos, folder: trip.url, includesSubfolders: false).isEmpty)
        let nestedPhotos = PhotoScope.filter(folderScan.photos, folder: trip.url, includesSubfolders: true)
        precondition(nestedPhotos.count == 1 && nestedPhotos[0].url.lastPathComponent == "Sample.png")
        precondition(PhotoScope.filter(folderScan.photos, folder: root, includesSubfolders: false).count == 3)
        print("PASS: nested and empty folder tree, direct-only filter, recursive filter, sibling prefix exclusion")
        let collapsedRows = tree.visibleRows(expanded: [])
        precondition(collapsedRows.count == 1 && collapsedRows[0].folder.id == tree.id)
        let rootRows = tree.visibleRows(expanded: [tree.id])
        precondition(rootRows.contains { $0.folder.id == trip.id && $0.depth == 1 })
        precondition(!rootRows.contains { $0.folder.url.lastPathComponent == "Nested" })
        let expandedRows = tree.visibleRows(expanded: [tree.id, trip.id])
        precondition(expandedRows.contains { $0.folder.url.lastPathComponent == "Nested" && $0.depth == 2 })
        print("PASS: parent rows remain selectable while collapsed; expansion only adds descendant rows")

        let files = (0..<6).map { PhotoFile(url: root.appendingPathComponent("Photo\($0).jpg")) }
        var selection = PhotoSelection()
        selection.synchronize(with: files)
        precondition(selection.id == files[0].id)
        selection.move(by: -1, in: files)
        precondition(selection.id == files[0].id)
        selection.move(by: 1, in: files)
        precondition(selection.id == files[1].id)
        selection.move(by: 3, in: files)
        precondition(selection.id == files[4].id)
        selection.move(by: 100, in: files)
        precondition(selection.id == files[5].id)
        selection.synchronize(with: Array(files.prefix(2)))
        precondition(selection.id == files[0].id)
        selection.move(by: 1, in: [])
        precondition(selection.id == nil)
        print("PASS: selection, row movement, boundary clamping, removed selections, empty navigation")

        selection.select(files[1].id, in: files)
        selection.select(files[4].id, in: files, extending: true)
        precondition(selection.ids == Set(files[1...4].map(\.id)))
        selection.move(by: -1, in: files, extending: true)
        precondition(selection.ids == Set(files[1...3].map(\.id)))
        selection.select(files[5].id, in: files, toggling: true)
        precondition(selection.ids.count == 4 && selection.id == files[5].id)
        selection.select(files[2].id, in: files, toggling: true)
        precondition(!selection.ids.contains(files[2].id) && selection.ids.count == 3)
        selection.selectAll(in: files)
        selection.synchronize(with: Array(files.prefix(3)))
        precondition(selection.ids == Set(files.prefix(3).map(\.id)))
        selection.move(by: 1, in: files)
        precondition(selection.ids.count == 1)
        print("PASS: Command selection, anchored Shift ranges, Shift-arrow extension, select-all and pruning removed photos")

        let preview = await PreviewService.shared.image(for: root.appendingPathComponent("Trip/Nested/Sample.png"), root: root)
        precondition(preview?.width == 1200 && preview?.height == 800)
        let badPreview = await PreviewService.shared.image(for: root.appendingPathComponent("Broken.jpg"), root: root)
        precondition(badPreview == nil)
        let orientedURL = root.appendingPathComponent("Rotated.jpg")
        let orientedDest = CGImageDestinationCreateWithURL(orientedURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(orientedDest, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        precondition(CGImageDestinationFinalize(orientedDest))
        let oriented = await PreviewService.shared.image(for: orientedURL, root: root)
        precondition(oriented?.width == 800 && oriented?.height == 1200)
        print("PASS: large preview, unreadable preview, EXIF orientation")

        let metadataURL = root.appendingPathComponent("Metadata.jpg")
        let metadataDestination = CGImageDestinationCreateWithURL(metadataURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: ["Make": "NIKON", "Model": "Fixture Camera", "Artist": "Test Photographer"],
            kCGImagePropertyExifDictionary: ["ExposureTime": 0.008, "FNumber": 2.8, "ISOSpeedRatings": [400],
                                            "FocalLength": 50.0, "DateTimeOriginal": "2026:10:31 09:00:00", "LensModel": "Fixture Lens"],
            kCGImagePropertyIPTCDictionary: ["Keywords": ["desert", "neon"], "Caption/Abstract": "Test caption"],
            kCGImagePropertyGPSDictionary: ["Latitude": 35.0, "LatitudeRef": "N", "Longitude": 115.0, "LongitudeRef": "W"]
        ]
        CGImageDestinationAddImage(metadataDestination, image, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(metadataDestination))
        let before = try Data(contentsOf: metadataURL)
        let info = await MetadataService.shared.read(metadataURL, root: root)
        let displayed = info.sections.flatMap { $0.fields }
        precondition(info.notice == nil)
        precondition(displayed.contains { $0.label == "Camera" && $0.value == "Fixture Camera" })
        precondition(displayed.contains { $0.label == "Shutter Speed" && $0.value == "1/125 s" })
        precondition(displayed.contains { $0.label == "Aperture" && $0.value == "ƒ/2.8" })
        precondition(displayed.contains { $0.label == "ISO" && $0.value == "400" })
        precondition(displayed.contains { $0.label == "Keywords" && $0.value.contains("neon") })
        precondition(info.sections.contains { $0.title == "Location (GPS)" && !$0.fields.isEmpty })
        precondition(info.allFields.contains { $0.label.contains("Exif") && $0.label.contains("FNumber") })
        precondition(info.allFields.contains { $0.label.hasPrefix("XMP") })
        let after = try Data(contentsOf: metadataURL)
        precondition(after == before)
        let plain = await MetadataService.shared.read(root.appendingPathComponent("Trip/Nested/Sample.png"), root: root)
        precondition(plain.sections.first { $0.title == "Camera & Lens" }?.fields.isEmpty == true)
        let corrupt = await MetadataService.shared.read(root.appendingPathComponent("Broken.jpg"), root: root)
        precondition(corrupt.notice != nil && !corrupt.sections[0].fields.isEmpty)
        print("PASS: camera, exposure units, IPTC, GPS, searchable properties/XMP, missing metadata, read-only extraction")

        func cameraFixture(_ name: String, maker: String, model: String) -> PhotoFile {
            let url = root.appendingPathComponent(name)
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyTIFFDictionary: ["Make": maker, "Model": model]] as CFDictionary)
            precondition(CGImageDestinationFinalize(destination))
            return PhotoFile(url: url)
        }
        let canon = cameraFixture("Camera-A.jpg", maker: "Canon", model: "Canon EOS R5")
        let phone = cameraFixture("Camera-B.jpg", maker: "Apple", model: "iPhone 16 Pro")
        let cameraPhotos = [canon, phone, PhotoFile(url: metadataURL)]
        let canonMatches = await SearchIndex.shared.matching(cameraPhotos, query: "canon", root: root)
        precondition(canonMatches == [canon.id])
        let phoneMatches = await SearchIndex.shared.matching(cameraPhotos, query: "IPHONE", root: root)
        precondition(phoneMatches == [phone.id])
        let keywordMatches = await SearchIndex.shared.matching(cameraPhotos, query: "neon", root: root)
        precondition(keywordMatches == [metadataURL])
        let lensMatches = await SearchIndex.shared.matching(cameraPhotos, query: "fixture lens", root: root)
        precondition(lensMatches == [metadataURL])
        let mixedMatches = await SearchIndex.shared.matching(cameraPhotos, query: "Camera-B Apple", root: root)
        precondition(mixedMatches == [phone.id])
        print("PASS: Canon/iPhone camera metadata, case-insensitive matching, keywords, lens, mixed filename/metadata query")


        precondition(PhotoSearch.filter(folderScan.photos, query: "sAmPlE.PNG", root: root).count == 1)
        precondition(PhotoSearch.filter(folderScan.photos, query: "Trip Nested", root: root).count == 1)
        precondition(PhotoSearch.filter(folderScan.photos, query: "not-a-photo", root: root).isEmpty)
        precondition(PhotoSearch.filter(folderScan.photos, query: "   ", root: root).count == folderScan.photos.count)
        precondition(SessionPaths.resolve("../escape.jpg", within: root) == nil)
        precondition(SessionPaths.resolve("/outside.jpg", within: root) == nil)
        let relative = SessionPaths.relative(root.appendingPathComponent("Trip/Nested/Sample.png"), to: root)!
        precondition(relative == "Trip/Nested/Sample.png")
        precondition(SessionPaths.resolve(relative, within: root)?.lastPathComponent == "Sample.png")
        print("PASS: case-insensitive filename/path search, multiword search, empty/no matches, safe relative session paths")

        let suite = "PixelRoll.checks." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        func waitForScan(_ model: LibraryModel) async throws {
            for _ in 0..<400 {
                if !model.isScanning { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            preconditionFailure("Library scan timed out")
        }
        let model = LibraryModel(defaults: preferences)
        model.open(root)
        try await waitForScan(model)
        let originalCount = model.photos.count
        model.searchQuery = "Canon"
        model.searchQuery = "iphone"
        for _ in 0..<400 {
            if !model.isSearching { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        precondition(!model.isSearching && model.photos.map { $0.url.resolvingSymlinksInPath().path } == [phone.url.resolvingSymlinksInPath().path])
        model.searchQuery = "Canon"
        for _ in 0..<400 {
            if !model.isSearching { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        precondition(!model.isSearching && model.photos.map { $0.url.resolvingSymlinksInPath().path } == [canon.url.resolvingSymlinksInPath().path])
        model.searchQuery = ""
        precondition(!model.isSearching && model.photos.count == originalCount)
        print("PASS: progressive camera search, cancelled query cannot replace newer results, clearing restores library")
        model.selectFolder(root)
        precondition(model.photos.count == originalCount && model.selectedFolder?.path == root.path)
        model.selection.id = model.photos.first { $0.url.lastPathComponent == "Sample.png" }!.id
        precondition(model.selectedFolder?.path == root.path && model.photos.count == originalCount)
        model.selectFolder(trip.url)
        precondition(model.photos.count == 1 && model.photos[0].url.lastPathComponent == "Sample.png")
        model.selectFolder(root)
        precondition(model.photos.count == originalCount)
        print("PASS: selecting parent restores all descendants; following a photo never overrides browsing scope")

        let scopedCanon = cameraFixture("Trip/Nested/Scoped.jpg", maker: "Canon", model: "Canon EOS R6")
        model.refresh()
        try await waitForScan(model)
        func waitForSearch(_ model: LibraryModel) async throws {
            for _ in 0..<400 {
                if !model.isSearching { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            preconditionFailure("Metadata search timed out")
        }
        let nestedPhoto = model.photos.first { $0.url.lastPathComponent == "Sample.png" }!
        model.selection.id = nestedPhoto.id
        precondition(model.highlightedFolder?.lastPathComponent == "Nested")
        precondition(model.expandedFolders.contains { $0.lastPathComponent == "Trip" })
        precondition(model.photos.count == originalCount + 1 && model.selectedFolder?.path == root.path)
        model.selectFolder(trip.url)
        model.includesSubfolders = false
        precondition(model.photos.isEmpty)
        model.searchQuery = "Metadata.jpg"
        try await waitForSearch(model)
        precondition(model.photos.isEmpty, "Search leaked a filename outside the selected folder")
        model.searchQuery = "Canon"
        try await waitForSearch(model)
        precondition(model.photos.count == 1 && model.photos[0].url.lastPathComponent == scopedCanon.url.lastPathComponent,
                     "Search leaked camera matches outside scope or skipped a descendant")
        precondition(model.selectedFolder?.lastPathComponent == "Trip" && model.highlightedFolder?.lastPathComponent == "Nested")
        model.searchQuery = "Sample.png"
        precondition(model.photos.count == 1 && model.photos[0].url.lastPathComponent == "Sample.png")
        model.searchQuery = ""
        precondition(model.photos.isEmpty)
        model.includesSubfolders = true
        model.selection.id = nestedPhoto.id
        precondition(preferences.data(forKey: "PixelRoll.librarySession.v1") != nil, "Bookmark couldn't be saved")
        let restored = LibraryModel(defaults: preferences)
        restored.restoreSession()
        try await waitForScan(restored)
        precondition(restored.sessionNotice == nil)
        precondition(restored.selectedFolder?.lastPathComponent == "Trip")
        precondition(restored.selection.id?.lastPathComponent == "Sample.png")
        precondition(restored.highlightedFolder?.lastPathComponent == "Nested")
        precondition(restored.includesSubfolders)
        print("PASS: folder following preserves grid, search stays within folder and descendants, closing search restores scope, bookmarked session restores folder/photo")
        model.searchQuery = "Canon"
        try await waitForSearch(model)
        let searchRestored = LibraryModel(defaults: preferences)
        searchRestored.restoreSession()
        try await waitForScan(searchRestored)
        try await waitForSearch(searchRestored)
        precondition(searchRestored.searchQuery == "Canon" && searchRestored.photos.count == 1)
        precondition(searchRestored.photos[0].url.lastPathComponent == "Scoped.jpg")
        let savedRecord = preferences.data(forKey: "PixelRoll.librarySession.v1")
        try fm.removeItem(at: root)
        let unavailable = LibraryModel(defaults: preferences)
        unavailable.restoreSession()
        precondition(unavailable.sessionNotice != nil && unavailable.photos.isEmpty)
        precondition(preferences.data(forKey: "PixelRoll.librarySession.v1") == savedRecord)
        print("PASS: search session restoration, unavailable library recovery preserves saved session")

        let natural = [PhotoFile(url: base.appendingPathComponent("IMG_10.jpg")), PhotoFile(url: base.appendingPathComponent("IMG_2.jpg"))]
        precondition(PhotoOrdering.sort(natural, by: .filename, ascending: true).first?.url.lastPathComponent == "IMG_2.jpg")
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)
        let byDate = [PhotoFile(url: base.appendingPathComponent("A.jpg"), modifiedDate: secondDate),
                      PhotoFile(url: base.appendingPathComponent("B.jpg"), modifiedDate: firstDate),
                      PhotoFile(url: base.appendingPathComponent("C.jpg"))]
        precondition(PhotoOrdering.sort(byDate, by: .modifiedDate, ascending: true).map { $0.url.lastPathComponent } == ["B.jpg", "A.jpg", "C.jpg"])
        precondition(PhotoOrdering.sort(byDate, by: .modifiedDate, ascending: false).map { $0.url.lastPathComponent } == ["A.jpg", "B.jpg", "C.jpg"])
        precondition(PhotoOrdering.sort(byDate, by: .captureDate, ascending: false, captureDates: [byDate[1].id: firstDate]).map { $0.url.lastPathComponent } == ["B.jpg", "C.jpg", "A.jpg"])
        precondition(CaptureDateIndex.parse("2026:10:31 10:00:00", offset: "+02:00") == CaptureDateIndex.parse("2026:10:31 08:00:00", offset: "+00:00"))
        precondition(CaptureDateIndex.parse("not a date", offset: nil) == nil)
        print("PASS: natural filename sorting, ascending/descending dates, missing dates last, capture timezone offsets")

        let liveRoot = base.appendingPathComponent("Live", isDirectory: true)
        try fm.createDirectory(at: liveRoot.appendingPathComponent("Group"), withIntermediateDirectories: true)
        let liveSuite = "PixelRoll.live." + UUID().uuidString
        let liveDefaults = UserDefaults(suiteName: liveSuite)!
        defer { liveDefaults.removePersistentDomain(forName: liveSuite) }
        let live = LibraryModel(defaults: liveDefaults)
        live.open(liveRoot)
        try await waitForScan(live)
        func eventually(_ message: String, _ condition: () -> Bool) async throws {
            for _ in 0..<600 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            preconditionFailure(message)
        }
        let livePhoto = liveRoot.appendingPathComponent("Group/IMG_2.jpg")
        let liveDestination = CGImageDestinationCreateWithURL(livePhoto as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(liveDestination, image, [kCGImagePropertyExifDictionary: ["DateTimeOriginal": "2026:10:31 09:00:00"]] as CFDictionary)
        precondition(CGImageDestinationFinalize(liveDestination))
        try await eventually("FSEvents didn't detect a nested addition") { live.photos.count == 1 && !live.isScanning }
        let selected = live.selection.id
        live.thumbnailSize = 260
        live.sortAscending = false
        live.sortOrder = .captureDate
        try await eventually("Capture date sorting didn't finish") { !live.isSorting }
        precondition(live.selection.id == selected)
        let extracted = await CaptureDateIndex.shared.dates(for: live.photos, root: liveRoot)
        precondition(extracted.count == 1)
        let prefsRestored = LibraryModel(defaults: liveDefaults)
        precondition(prefsRestored.thumbnailSize == 260 && prefsRestored.sortOrder == .captureDate && !prefsRestored.sortAscending)
        let modifiedEvent = UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified)
        precondition(!LibraryWatcher.affectsLibrary(path: liveRoot.appendingPathComponent(".DS_Store").path, flags: modifiedEvent))
        precondition(!LibraryWatcher.affectsLibrary(path: liveRoot.appendingPathComponent("readme.txt").path, flags: modifiedEvent))
        precondition(!LibraryWatcher.affectsLibrary(path: livePhoto.path, flags: UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemInodeMetaMod)))
        precondition(LibraryWatcher.affectsLibrary(path: livePhoto.path, flags: modifiedEvent))
        precondition(LibraryWatcher.affectsLibrary(path: NotesStore.sidecar(for: livePhoto).path, flags: modifiedEvent))
        precondition(LibraryWatcher.affectsLibrary(path: liveRoot.path, flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs)))
        let warmThumbnail = await ThumbnailService.shared.thumbnail(for: livePhoto, root: liveRoot, modifiedDate: live.photos[0].modifiedDate)
        precondition(warmThumbnail != nil)
        var photoPublications = 0
        let observation = live.$photos.dropFirst().sink { _ in photoPublications += 1 }
        live.refresh()
        try await waitForScan(live)
        let retainedThumbnail = await ThumbnailService.shared.thumbnail(for: livePhoto, root: liveRoot, modifiedDate: live.photos[0].modifiedDate)
        precondition(warmThumbnail === retainedThumbnail)
        precondition(photoPublications == 0 && !live.isSorting)
        try Data("unrelated background change".utf8).write(to: liveRoot.appendingPathComponent(".DS_Store"))
        try Data("unrelated document".utf8).write(to: liveRoot.appendingPathComponent("readme.txt"))
        try await Task.sleep(for: .seconds(2))
        precondition(photoPublications == 0 && live.selection.id == selected)
        let sidecarBefore = try NotesStore.read(livePhoto)
        _ = try await NotesStore.shared.save(PhotoNotes(rating: 4), photo: livePhoto, access: liveRoot, expected: sidecarBefore.revision)
        try await eventually("External sidecar change wasn't detected") { live.photos.first.map { live.notes(for: $0.id).rating == 4 } == true && !live.isScanning }
        let afterNotesThumbnail = await ThumbnailService.shared.thumbnail(for: livePhoto, root: liveRoot, modifiedDate: live.photos[0].modifiedDate)
        precondition(warmThumbnail === afterNotesThumbnail && !live.isSorting)
        observation.cancel()
        print("PASS: idle filesystem noise ignored, no-op refresh doesn't republish photos, thumbnail cache survives refresh and sidecar changes, capture sorting stays stable")
        let beforeMetadataSearch = await SearchIndex.shared.matching(live.photos, query: "2026:10:31", root: liveRoot)
        precondition(beforeMetadataSearch.count == 1)
        let oldModified = live.photos.first?.modifiedDate
        try Data("changed image fixture".utf8).write(to: livePhoto)
        try await eventually("FSEvents didn't detect a modified photo") { live.photos.first?.modifiedDate != oldModified && !live.isScanning }
        let changedThumbnail = await ThumbnailService.shared.thumbnail(for: livePhoto, root: liveRoot, modifiedDate: live.photos[0].modifiedDate)
        let changedDates = await CaptureDateIndex.shared.dates(for: live.photos, root: liveRoot)
        let changedSearch = await SearchIndex.shared.matching(live.photos, query: "2026:10:31", root: liveRoot)
        precondition(changedThumbnail == nil && changedDates.isEmpty && changedSearch.isEmpty)
        print("PASS: a real source modification invalidates its thumbnail, capture date and search metadata")
        precondition(live.selection.id == selected)
        let renamed = liveRoot.appendingPathComponent("Group/IMG_10.jpg")
        try fm.moveItem(at: livePhoto, to: renamed)
        try await eventually("FSEvents didn't detect a rename") { live.photos.first?.url.lastPathComponent == "IMG_10.jpg" && !live.isScanning }
        try fm.removeItem(at: renamed)
        try await eventually("FSEvents didn't detect removal") { live.photos.isEmpty && !live.isScanning }
        print("PASS: live nested additions, modifications, renames and removals; selection retained on modification; saved browsing preferences")
        precondition(live.lastRefreshWasIncremental && live.lastRefreshItemCount == 1)
        let incrementalRoot = base.appendingPathComponent("Incremental")
        try fm.createDirectory(at: incrementalRoot.appendingPathComponent("A"), withIntermediateDirectories: true)
        try fm.createDirectory(at: incrementalRoot.appendingPathComponent("B"), withIntermediateDirectories: true)
        for group in ["A", "B"] {
            for number in 0..<30 { try Data("fixture".utf8).write(to: incrementalRoot.appendingPathComponent("\(group)/Photo\(number).jpg")) }
        }
        let initialIncremental = PhotoScanner.scan(incrementalRoot)
        let modifiedIncremental = incrementalRoot.appendingPathComponent("A/Photo0.jpg")
        try Data("updated fixture".utf8).write(to: modifiedIncremental)
        let singleUpdate = PhotoScanner.updating(initialIncremental, root: incrementalRoot, changes: [.file(modifiedIncremental)])
        precondition(singleUpdate.inspectedItems == 1 && singleUpdate.photos.count == 60)
        let unchangedB = initialIncremental.photos.filter { $0.url.deletingLastPathComponent().lastPathComponent == "B" }
        precondition(singleUpdate.photos.filter { $0.url.deletingLastPathComponent().lastPathComponent == "B" } == unchangedB)
        let dropped = incrementalRoot.appendingPathComponent("A/Photo1.jpg")
        try fm.removeItem(at: dropped)
        let singleRemoval = PhotoScanner.updating(singleUpdate, root: incrementalRoot, changes: [.file(dropped)])
        precondition(singleRemoval.inspectedItems == 1 && singleRemoval.photos.count == 59)
        let incoming = incrementalRoot.appendingPathComponent("Incoming/Nested")
        try fm.createDirectory(at: incoming, withIntermediateDirectories: true)
        try Data("new NEF".utf8).write(to: incoming.appendingPathComponent("New.NEF"))
        let folderAdded = PhotoScanner.updating(singleRemoval, root: incrementalRoot, changes: [.subtree(incoming.deletingLastPathComponent())])
        precondition(folderAdded.photos.count == 60 && folderAdded.inspectedItems == 2)
        try fm.moveItem(at: incoming.deletingLastPathComponent(), to: incrementalRoot.appendingPathComponent("Moved"))
        let folderMoved = PhotoScanner.updating(folderAdded, root: incrementalRoot,
            changes: [.subtree(incoming.deletingLastPathComponent()), .subtree(incrementalRoot.appendingPathComponent("Moved"))])
        precondition(folderMoved.photos.count == 60 && folderMoved.photos.contains { $0.url.path.contains("/Moved/Nested/New.NEF") })
        precondition(!folderMoved.photos.contains { $0.url.path.contains("/Incoming/") })
        let package = incrementalRoot.appendingPathComponent("Ignore.photoslibrary")
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("hidden package photo".utf8).write(to: package.appendingPathComponent("Ignore.jpg"))
        let packageUpdate = PhotoScanner.updating(folderMoved, root: incrementalRoot, changes: [.file(package.appendingPathComponent("Ignore.jpg")), .subtree(package)])
        precondition(packageUpdate.photos.count == folderMoved.photos.count)
        print("PASS: single-file updates/removals inspect one source, unrelated folders stay unchanged, incoming and moved subtrees reconcile, package exclusions survive incremental events")

        let recordBeforeDisconnect = liveDefaults.data(forKey: "PixelRoll.librarySession.v1")
        let parked = base.appendingPathComponent("Disconnected", isDirectory: true)
        try fm.moveItem(at: liveRoot, to: parked)
        try await eventually("Unavailable library wasn't detected") { live.libraryUnavailable }
        precondition(liveDefaults.data(forKey: "PixelRoll.librarySession.v1") == recordBeforeDisconnect)
        try fm.moveItem(at: parked, to: liveRoot)
        try await eventually("Reconnected library wasn't restored") { !live.libraryUnavailable && !live.isScanning && live.sessionNotice == nil }
        print("PASS: unavailable library preserves saved session; reconnection resumes automatically")

        let notesRoot = base.appendingPathComponent("Notes", isDirectory: true)
        let year = notesRoot.appendingPathComponent("2025", isDirectory: true)
        let tripFolder = year.appendingPathComponent("Trip", isDirectory: true)
        try fm.createDirectory(at: tripFolder, withIntermediateDirectories: true)
        let rawPhoto = tripFolder.appendingPathComponent("Frame.NEF")
        let jpegPhoto = tripFolder.appendingPathComponent("Frame.jpg")
        let originalRaw = Data("unchanged original RAW fixture".utf8)
        try originalRaw.write(to: rawPhoto)
        let jpegDestination = CGImageDestinationCreateWithURL(jpegPhoto as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(jpegDestination, image, nil)
        precondition(CGImageDestinationFinalize(jpegDestination))
        let originalJPEG = try Data(contentsOf: jpegPhoto)
        let absent = try NotesStore.read(rawPhoto)
        precondition(absent.revision == nil && !fm.fileExists(atPath: NotesStore.sidecar(for: rawPhoto).path))
        let note = PhotoNotes(rating: 5, flag: .pick, keywords: ["Sunset", "Desert"], caption: "Evening light")
        let written = try await NotesStore.shared.save(note, photo: rawPhoto, access: notesRoot, expected: nil)
        let roundTrip = try NotesStore.read(rawPhoto)
        precondition(roundTrip.notes == note)
        precondition(NotesStore.sidecar(for: rawPhoto) != NotesStore.sidecar(for: jpegPhoto))
        var extra = try JSONSerialization.jsonObject(with: written.revision!) as! [String: Any]
        extra["futureField"] = ["preserve": true]
        let extraData = try JSONSerialization.data(withJSONObject: extra)
        try extraData.write(to: NotesStore.sidecar(for: rawPhoto))
        let extraSnapshot = try NotesStore.read(rawPhoto)
        var fourStars = note; fourStars.rating = 4
        let merged = try await NotesStore.shared.save(fourStars, photo: rawPhoto, access: notesRoot, expected: extraSnapshot.revision)
        let mergedObject = try JSONSerialization.jsonObject(with: merged.revision!) as! [String: Any]
        precondition(mergedObject["futureField"] != nil)
        do {
            _ = try await NotesStore.shared.save(note, photo: rawPhoto, access: notesRoot, expected: written.revision)
            preconditionFailure("Stale save should fail")
        } catch NotesError.conflict { }
        let brokenData = Data("broken JSON".utf8)
        try brokenData.write(to: NotesStore.sidecar(for: jpegPhoto))
        do {
            _ = try await NotesStore.shared.save(note, photo: jpegPhoto, access: notesRoot, expected: brokenData)
            preconditionFailure("Malformed sidecar should never be overwritten")
        } catch { }
        let untouchedBroken = try Data(contentsOf: NotesStore.sidecar(for: jpegPhoto))
        precondition(untouchedBroken == brokenData)
        try fm.removeItem(at: NotesStore.sidecar(for: jpegPhoto))
        var future = mergedObject; future["version"] = 2; future["photo"] = jpegPhoto.lastPathComponent
        let futureData = try JSONSerialization.data(withJSONObject: future)
        try futureData.write(to: NotesStore.sidecar(for: jpegPhoto))
        do {
            _ = try NotesStore.read(jpegPhoto)
            preconditionFailure("Newer format should be refused")
        } catch NotesError.newerVersion { }
        try fm.removeItem(at: NotesStore.sidecar(for: jpegPhoto))
        let outside = base.appendingPathComponent("outside.json")
        try Data("outside".utf8).write(to: outside)
        try fm.createSymbolicLink(at: NotesStore.sidecar(for: jpegPhoto), withDestinationURL: outside)
        do {
            _ = try await NotesStore.shared.save(note, photo: jpegPhoto, access: notesRoot, expected: nil)
            preconditionFailure("Sidecar symlink should be refused")
        } catch NotesError.unsafeLink { }
        try fm.removeItem(at: NotesStore.sidecar(for: jpegPhoto))
        let outsideAfter = try Data(contentsOf: outside)
        precondition(outsideAfter == Data("outside".utf8))
        let rawAfter = try Data(contentsOf: rawPhoto)
        let jpegAfter = try Data(contentsOf: jpegPhoto)
        precondition(rawAfter == originalRaw && jpegAfter == originalJPEG)
        print("PASS: sidecar round trip, basename collisions, unknown fields, stale-save conflicts, malformed/newer formats, symlinks, original bytes unchanged")

        let notesSuite = "PixelRoll.notes." + UUID().uuidString
        let notesDefaults = UserDefaults(suiteName: notesSuite)!
        defer { notesDefaults.removePersistentDomain(forName: notesSuite) }
        let notesModel = LibraryModel(defaults: notesDefaults)
        notesModel.open(notesRoot)
        try await waitForScan(notesModel)
        try notesModel.authorizeOrganizing(notesRoot)
        let rawID = notesModel.photos.first { $0.url.pathExtension == "NEF" }!.id
        notesModel.selection.id = rawID
        notesModel.updateDraft(note, for: rawID)
        notesModel.saveNotes(for: rawID)
        try await eventually("Sidecar save didn't finish") { notesModel.savingNoteIDs.isEmpty && notesModel.notes(for: rawID) == note }
        notesModel.notesFilter = NotesFilter(minimumRating: 4, flag: .pick, format: .raw, keyword: "sun")
        precondition(notesModel.photos.count == 1 && notesModel.photos[0].id == rawID)
        notesModel.notesFilter.format = .jpeg
        precondition(notesModel.photos.isEmpty)
        notesModel.notesFilter = NotesFilter()
        notesModel.searchQuery = "Evening"
        precondition(notesModel.photos.count == 1 && notesModel.photos[0].id == rawID)
        notesModel.searchQuery = ""
        var draft = note; draft.caption = "My unsaved draft"
        notesModel.updateDraft(draft, for: rawID)
        let current = try NotesStore.read(rawID)
        var external = note; external.caption = "External change"
        let externalSnapshot = try await NotesStore.shared.save(external, photo: rawID, access: notesRoot, expected: current.revision)
        notesModel.refresh()
        try await waitForScan(notesModel)
        notesModel.saveNotes(for: rawID)
        try await eventually("Conflicting draft was not reported") { notesModel.operationError != nil && notesModel.savingNoteIDs.isEmpty }
        let afterConflict = try Data(contentsOf: NotesStore.sidecar(for: rawID))
        precondition(afterConflict == externalSnapshot.revision && notesModel.noteDrafts[rawID]?.caption == draft.caption)
        notesModel.operationError = nil
        notesModel.discardDraft(for: rawID)
        notesModel.selectFolder(tripFolder)
        notesModel.selection.id = rawID
        notesModel.updateDraft(draft, for: rawID)
        try notesModel.renameFolder(tripFolder, to: "Renamed", parentAccess: year)
        try await waitForScan(notesModel)
        let renamedID = notesModel.selection.id!
        precondition(notesModel.selectedFolder?.lastPathComponent == "Renamed")
        precondition(renamedID.deletingLastPathComponent().lastPathComponent == "Renamed")
        precondition(notesModel.noteDrafts[renamedID]?.caption == draft.caption, "Selected: \(renamedID.path), drafts: \(notesModel.noteDrafts.map { $0.key.path + "=" + $0.value.caption })")
        let renamedSidecar = try Data(contentsOf: NotesStore.sidecar(for: renamedID))
        precondition(renamedSidecar == externalSnapshot.revision)
        let collision = year.appendingPathComponent("Existing", isDirectory: true)
        try fm.createDirectory(at: collision, withIntermediateDirectories: true)
        do {
            try notesModel.renameFolder(renamedID.deletingLastPathComponent(), to: "Existing", parentAccess: year)
            preconditionFailure("Rename collision should fail")
        } catch FolderRenameError.collision { }
        do {
            _ = try FolderRenamer.rename(renamedID.deletingLastPathComponent(), to: "../escape", library: notesRoot)
            preconditionFailure("Invalid folder name should fail")
        } catch FolderRenameError.invalidName { }
        let notesRestored = LibraryModel(defaults: notesDefaults)
        notesRestored.restoreSession()
        try await waitForScan(notesRestored)
        precondition(notesRestored.canOrganize && notesRestored.selectedFolder?.lastPathComponent == "Renamed")
        precondition(notesRestored.selection.id?.lastPathComponent == "Frame.NEF")
        try notesModel.renameFolder(notesRoot, to: "NotesRenamed", parentAccess: base)
        try await waitForScan(notesModel)
        precondition(notesModel.root?.lastPathComponent == "NotesRenamed" && notesModel.canOrganize)
        let rootRenamedID = notesModel.selection.id!
        precondition(rootRenamedID.path.contains("NotesRenamed/2025/Renamed"))
        let finalRaw = try Data(contentsOf: rootRenamedID)
        precondition(finalRaw == originalRaw)
        print("PASS: saved ratings/flags/format/keyword filters, caption search, external conflict after refresh, child/root folder rename, drafts and sidecars follow, collision protection, saved-session paths")

        precondition(PhotoNotes(rating: 4, flag: .none).isPick)
        precondition(!PhotoNotes(rating: 0, flag: .pick).isPick)
        precondition(!PhotoNotes(rating: 4, flag: .reject).isPick)
        precondition(KeywordEditing.replacing(["Desert", "Sunset", "desert"], selected: ["DESERT"], with: "Landscape") == ["Landscape", "Sunset"])
        precondition(KeywordEditing.replacing(["Cats", "Dogs", "Pets"], selected: ["cats", "dogs"], with: "Pets") == ["Pets"])
        precondition(KeywordEditing.replacing(["Beach", "Desert"], selected: ["beach"], with: nil) == ["Desert"])
        var automatic = notesModel.draft(for: rootRenamedID)
        automatic.rating = 4; automatic.flag = .none; automatic.caption = "Automatically saved caption"
        notesModel.editNotes(automatic, for: rootRenamedID)
        try await eventually("Automatic note saving didn't finish") {
            notesModel.noteDrafts[rootRenamedID] == nil && notesModel.notes(for: rootRenamedID) == automatic
        }
        precondition(notesModel.notes(for: rootRenamedID).isPick)
        let canonicalRoot = notesModel.root!
        let secondPhoto = rootRenamedID.deletingLastPathComponent().appendingPathComponent("Frame.jpg")
        let secondNotes = PhotoNotes(rating: 0, flag: .none, keywords: ["Sunset", "Beach"], caption: "Second caption")
        _ = try await NotesStore.shared.save(secondNotes, photo: secondPhoto, access: canonicalRoot, expected: nil)
        notesModel.refresh()
        try await waitForScan(notesModel)
        precondition(notesModel.keywordCounts.first { $0.name.lowercased() == "sunset" }?.count == 2)
        let beforeBatch = try NotesStore.read(rootRenamedID)
        do {
            _ = try await NotesStore.shared.changeKeywords([
                KeywordChange(photo: rootRenamedID, notes: PhotoNotes(), expected: beforeBatch.revision),
                KeywordChange(photo: secondPhoto, notes: PhotoNotes(), expected: Data("stale".utf8))
            ], access: canonicalRoot)
            preconditionFailure("Batch conflict should fail before writing any photo")
        } catch NotesError.conflict { }
        let afterBatchConflict = try NotesStore.read(rootRenamedID)
        precondition(afterBatchConflict.revision == beforeBatch.revision)
        notesModel.manageKeywords(selected: ["Sunset"], replacement: "Golden Hour")
        try await eventually("Keyword rename didn't finish") { !notesModel.isManagingKeywords && notesModel.canUndoKeywords }
        precondition(notesModel.notes(for: rootRenamedID).keywords == ["Golden Hour", "Desert"])
        precondition(notesModel.notes(for: secondPhoto).keywords == ["Golden Hour", "Beach"])
        notesModel.undoKeywordChanges()
        try await eventually("Keyword undo didn't finish") { !notesModel.isManagingKeywords && !notesModel.canUndoKeywords }
        precondition(notesModel.notes(for: secondPhoto).keywords == ["Sunset", "Beach"])
        notesModel.manageKeywords(selected: ["Sunset", "Desert"], replacement: "Landscape")
        try await eventually("Keyword merge didn't finish") { !notesModel.isManagingKeywords && notesModel.canUndoKeywords }
        precondition(notesModel.notes(for: rootRenamedID).keywords == ["Landscape"])
        precondition(notesModel.notes(for: secondPhoto).keywords == ["Landscape", "Beach"])
        notesModel.manageKeywords(selected: ["Landscape"], replacement: nil)
        try await eventually("Keyword delete didn't finish") { !notesModel.isManagingKeywords && notesModel.notes(for: rootRenamedID).keywords.isEmpty }
        precondition(notesModel.notes(for: secondPhoto).keywords == ["Beach"])
        notesModel.undoKeywordChanges()
        try await eventually("Delete undo didn't finish") { !notesModel.isManagingKeywords && !notesModel.canUndoKeywords }
        precondition(notesModel.notes(for: rootRenamedID).keywords == ["Landscape"])
        let originalRawAfterKeywords = try Data(contentsOf: rootRenamedID)
        let originalJPEGAfterKeywords = try Data(contentsOf: secondPhoto)
        precondition(originalRawAfterKeywords == originalRaw && originalJPEGAfterKeywords == originalJPEG)
        precondition(notesModel.notes(for: rootRenamedID).caption == automatic.caption)
        try notesModel.renameFolder(rootRenamedID.deletingLastPathComponent(), to: "Direct Rename", parentAccess: canonicalRoot)
        try await waitForScan(notesModel)
        precondition(notesModel.selectedFolder?.lastPathComponent == "Direct Rename")
        print("PASS: stars imply picks, automatic notes saving, case-insensitive keyword rename/merge/delete/undo, batch conflict preflight, originals unchanged, rename reuses library access")
        let recoveryID = notesModel.selection.id!
        var pending = notesModel.draft(for: recoveryID)
        pending.caption = "Recovered automatic caption"
        notesModel.editNotes(pending, for: recoveryID)
        precondition(notesDefaults.dictionary(forKey: "PixelRoll.pendingNotes.v1") != nil)
        let recoveredModel = LibraryModel(defaults: notesDefaults)
        recoveredModel.restoreSession()
        try await waitForScan(recoveredModel)
        let recoveredID = recoveredModel.photos.first { $0.url.lastPathComponent == recoveryID.lastPathComponent }!.id
        precondition(recoveredModel.draft(for: recoveredID).caption == pending.caption)
        try await eventually("Recovered pending note did not save") {
            recoveredModel.noteDrafts[recoveredID] == nil && recoveredModel.notes(for: recoveredID).caption == pending.caption
        }
        let recoveredOnDisk = try NotesStore.read(recoveredID)
        precondition(recoveredOnDisk.notes.caption == pending.caption)
        print("PASS: pending automatic changes survive session reconstruction; duplicate identical saves are safe")
        try await eventually("Original recovery model still saving") { notesModel.noteDrafts[recoveryID] == nil }
        recoveredModel.notesFilter = NotesFilter()
        recoveredModel.selectFolder(recoveredModel.root!)
        let batchPhotos = recoveredModel.photos
        precondition(batchPhotos.count >= 2)
        let undo = UndoManager()
        undo.groupsByEvent = false
        recoveredModel.undoManager = undo
        recoveredModel.selection.selectAll(in: batchPhotos)
        let beforeRatings = Dictionary(uniqueKeysWithValues: batchPhotos.map { ($0.id, recoveredModel.draft(for: $0.id)) })
        undo.beginUndoGrouping()
        recoveredModel.rateSelection(2)
        undo.endUndoGrouping()
        precondition(batchPhotos.allSatisfy { recoveredModel.draft(for: $0.id).rating == 2 })
        // Undo before debounce, redo and then undo after persistence must all survive autosave.
        undo.undo()
        precondition(batchPhotos.allSatisfy { recoveredModel.draft(for: $0.id) == beforeRatings[$0.id] })
        undo.redo()
        try await eventually("Batch ratings didn't save") { batchPhotos.allSatisfy { recoveredModel.noteDrafts[$0.id] == nil && recoveredModel.notes(for: $0.id).rating == 2 } }
        undo.undo()
        try await eventually("Batch rating undo didn't save") { batchPhotos.allSatisfy { recoveredModel.noteDrafts[$0.id] == nil && recoveredModel.notes(for: $0.id) == beforeRatings[$0.id] } }
        undo.beginUndoGrouping()
        recoveredModel.changeSelectionKeywords("Batch, bAtCh, Travel", removing: false)
        undo.endUndoGrouping()
        try await eventually("Batch keyword addition didn't save") { batchPhotos.allSatisfy { recoveredModel.noteDrafts[$0.id] == nil && recoveredModel.notes(for: $0.id).keywords.suffix(2) == ["Batch", "Travel"] } }
        undo.beginUndoGrouping()
        recoveredModel.changeSelectionKeywords("BATCH", removing: true)
        undo.endUndoGrouping()
        try await eventually("Batch keyword removal didn't save") { batchPhotos.allSatisfy { recoveredModel.noteDrafts[$0.id] == nil && !recoveredModel.notes(for: $0.id).keywords.contains("Batch") } }
        undo.undo()
        try await eventually("Batch keyword undo didn't save") { batchPhotos.allSatisfy { recoveredModel.noteDrafts[$0.id] == nil && recoveredModel.notes(for: $0.id).keywords.contains("Batch") } }
        undo.beginUndoGrouping()
        recoveredModel.rejectSelection(true)
        undo.endUndoGrouping()
        try await eventually("Batch rejection didn't save") { batchPhotos.allSatisfy { recoveredModel.noteDrafts[$0.id] == nil && recoveredModel.notes(for: $0.id).isRejected && recoveredModel.notes(for: $0.id).rating == 0 } }
        undo.undo()
        try await eventually("Batch rejection undo didn't save") { batchPhotos.allSatisfy { recoveredModel.noteDrafts[$0.id] == nil && recoveredModel.notes(for: $0.id).rating == beforeRatings[$0.id]?.rating } }
        recoveredModel.refresh()
        try await waitForScan(recoveredModel)
        precondition(recoveredModel.selection.ids.count == batchPhotos.count)
        for photo in batchPhotos {
            let persisted = try NotesStore.read(photo.id)
            precondition(persisted.notes == recoveredModel.notes(for: photo.id))
        }
        print("PASS: batch ratings, rejection, additive/removal keywords, grouped undo/redo before and after autosave, selection survives refresh")


        precondition(SaveFailure.isPermission(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)))
        precondition(SaveFailure.isPermission(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 13)])))
        precondition(!SaveFailure.isPermission(NotesError.conflict))
        let failureRoot = base.appendingPathComponent("PermissionFailure")
        try fm.createDirectory(at: failureRoot, withIntermediateDirectories: true)
        let failurePhoto = failureRoot.appendingPathComponent("Sample.png")
        try originalJPEG.write(to: failurePhoto)
        let failureDefaults = UserDefaults(suiteName: "PixelRoll.permission-check.\(UUID().uuidString)")!
        let failureModel = LibraryModel(defaults: failureDefaults)
        failureModel.open(failureRoot)
        try await waitForScan(failureModel)
        let failureID = failureModel.photos[0].id
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: failureRoot.path)
        failureModel.editNotes(PhotoNotes(rating: 3), for: failureID)
        try await eventually("Permission failure was not retained") { failureModel.noteSaveErrors[failureID] != nil }
        precondition(failureModel.needsWriteAccessRepair && failureModel.draft(for: failureID).rating == 3)
        precondition(failureDefaults.dictionary(forKey: "PixelRoll.pendingNotes.v1") != nil)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: failureRoot.path)
        try failureModel.authorizeOrganizing(failureRoot)
        failureModel.retryAutomaticSaves(for: [failureID])
        try await eventually("Permission recovery did not save retained rating") {
            failureModel.noteDrafts[failureID] == nil && failureModel.notes(for: failureID).rating == 3
        }
        precondition(!failureModel.needsWriteAccessRepair)
        print("PASS: permission failures keep drafts, identify access repair, and retry successfully after one root authorization")





        let diskPhotos = base.appendingPathComponent("PersistentPhotos")
        let diskDirectory = base.appendingPathComponent("PersistentCache")
        try fm.createDirectory(at: diskPhotos, withIntermediateDirectories: true)
        let diskPhoto = diskPhotos.appendingPathComponent("Cached.jpg")
        let diskDestination = CGImageDestinationCreateWithURL(diskPhoto as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(diskDestination, image, [
            kCGImagePropertyTIFFDictionary: ["Make": "Canon", "Model": "Cache Camera"],
            kCGImagePropertyExifDictionary: ["DateTimeOriginal": "2026:10:31 09:00:00"],
            kCGImagePropertyIPTCDictionary: ["Keywords": ["Desert"]]
        ] as CFDictionary)
        precondition(CGImageDestinationFinalize(diskDestination))
        let originalDiskPhoto = try Data(contentsOf: diskPhoto)
        let diskFile = PhotoScanner.scan(diskPhotos).photos[0]
        let cacheA = PhotoDiskCache(directory: diskDirectory)
        let thumbnailsA = ThumbnailService(disk: cacheA)
        let metadataA = PhotoMetadataIndex(disk: cacheA)
        let datesA = CaptureDateIndex(index: metadataA)
        let searchA = SearchIndex(index: metadataA)
        let diskThumbnailA = await thumbnailsA.thumbnail(for: diskPhoto, root: diskPhotos)
        precondition(diskThumbnailA != nil)
        let indexedDatesA = await datesA.dates(for: [diskFile], root: diskPhotos)
        let indexedSearchA = await searchA.matching([diskFile], query: "Canon Desert", root: diskPhotos)
        precondition(indexedDatesA.count == 1 && indexedSearchA.count == 1)
        let firstMetadataReads = await metadataA.sourceReads
        precondition(firstMetadataReads == 1)
        // Fresh connections/services have no memory entries, simulating an app relaunch.
        let cacheB = PhotoDiskCache(directory: diskDirectory)
        let thumbnailsB = ThumbnailService(disk: cacheB)
        let metadataB = PhotoMetadataIndex(disk: cacheB)
        let datesB = CaptureDateIndex(index: metadataB)
        let searchB = SearchIndex(index: metadataB)
        let diskThumbnailB = await thumbnailsB.thumbnail(for: diskPhoto, root: diskPhotos)
        let indexedDatesB = await datesB.dates(for: [diskFile], root: diskPhotos)
        let indexedSearchB = await searchB.matching([diskFile], query: "Canon Desert", root: diskPhotos)
        let thumbnailDiskHits = await thumbnailsB.diskHits
        let thumbnailReads = await thumbnailsB.sourceDecodes
        let metadataDiskHits = await metadataB.diskHits
        let metadataReads = await metadataB.sourceReads
        precondition(diskThumbnailB?.width == diskThumbnailA?.width && diskThumbnailB?.height == diskThumbnailA?.height)
        precondition(indexedDatesB == indexedDatesA && indexedSearchB == indexedSearchA)
        precondition(thumbnailDiskHits == 1 && thumbnailReads == 0 && metadataDiskHits == 1 && metadataReads == 0)
        let unchangedDiskPhoto = try Data(contentsOf: diskPhoto)
        precondition(unchangedDiskPhoto == originalDiskPhoto)
        // A size change must invalidate even when an external tool preserves the modification date.
        let oldFingerprint = PhotoFingerprint.read(diskPhoto)!
        var enlarged = originalDiskPhoto
        enlarged.append(Data(repeating: 0, count: 128))
        try enlarged.write(to: diskPhoto)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: oldFingerprint.modified)], ofItemAtPath: diskPhoto.path)
        let largerFile = PhotoScanner.scan(diskPhotos).photos[0]
        precondition(largerFile.fileSize != diskFile.fileSize)
        _ = await thumbnailsB.thumbnail(for: diskPhoto, root: diskPhotos)
        _ = await metadataB.entry(for: largerFile, root: diskPhotos)
        let changedThumbnailReads = await thumbnailsB.sourceDecodes
        let changedMetadataReads = await metadataB.sourceReads
        precondition(changedThumbnailReads == 1 && changedMetadataReads == 1)
        // Damaged individual records rebuild without affecting the originals.
        let fingerprint = PhotoFingerprint.read(diskPhoto)!
        let cacheKey = PhotoDiskCache.key(for: diskPhoto)
        cacheB.write(Data("damaged image".utf8), kind: .thumbnail, key: cacheKey, fingerprint: fingerprint)
        cacheB.write(Data("damaged metadata".utf8), kind: .metadata, key: cacheKey, fingerprint: fingerprint)
        let recoveredThumbnails = ThumbnailService(disk: cacheB)
        let recoveredMetadata = PhotoMetadataIndex(disk: cacheB)
        let repairedThumbnail = await recoveredThumbnails.thumbnail(for: diskPhoto, root: diskPhotos)
        let repairedMetadata = await recoveredMetadata.entry(for: largerFile, root: diskPhotos)
        precondition(repairedThumbnail != nil && repairedMetadata?.captureDate == indexedDatesA[diskFile.id])
        let unchangedEnlargedPhoto = try Data(contentsOf: diskPhoto)
        precondition(unchangedEnlargedPhoto == enlarged)
        let brokenDirectory = base.appendingPathComponent("DamagedDatabase")
        try fm.createDirectory(at: brokenDirectory, withIntermediateDirectories: true)
        try Data("not a SQLite database".utf8).write(to: brokenDirectory.appendingPathComponent("photos.sqlite"))
        let rebuiltDisk = PhotoDiskCache(directory: brokenDirectory)
        rebuiltDisk.write(Data("rebuilt".utf8), kind: .metadata, key: "test", fingerprint: fingerprint)
        precondition(rebuiltDisk.read(.metadata, key: "test", fingerprint: fingerprint) == Data("rebuilt".utf8))
        let noCacheDirectory = base.appendingPathComponent("NotACacheDirectory")
        try Data("file".utf8).write(to: noCacheDirectory)
        let unavailableDisk = PhotoDiskCache(directory: noCacheDirectory)
        let fallbackThumbnails = ThumbnailService(disk: unavailableDisk)
        let fallbackMetadata = PhotoMetadataIndex(disk: unavailableDisk)
        let fallbackImage = await fallbackThumbnails.thumbnail(for: diskPhoto, root: diskPhotos)
        let fallbackEntry = await fallbackMetadata.entry(for: largerFile, root: diskPhotos)
        precondition(fallbackImage != nil && fallbackEntry != nil)
        try fm.removeItem(at: diskPhoto)
        let removedImage = await thumbnailsB.thumbnail(for: diskPhoto, root: diskPhotos)
        let removedMetadata = await metadataB.entry(for: largerFile, root: diskPhotos)
        precondition(removedImage == nil && removedMetadata == nil)
        let smallCache = PhotoDiskCache(directory: base.appendingPathComponent("SmallCache"), maximumBytes: 400)
        smallCache.write(Data(repeating: 1, count: 300), kind: .thumbnail, key: "old", fingerprint: fingerprint)
        smallCache.write(Data(repeating: 2, count: 300), kind: .metadata, key: "new", fingerprint: fingerprint)
        precondition(smallCache.read(.thumbnail, key: "old", fingerprint: fingerprint) == nil)
        precondition(smallCache.read(.metadata, key: "new", fingerprint: fingerprint)?.count == 300)
        precondition(smallCache.read(.metadata, key: "new", fingerprint: oldFingerprint) == nil)
        smallCache.write(Data(repeating: 2, count: 100), kind: .metadata, key: "new", fingerprint: fingerprint)
        smallCache.write(Data(repeating: 1, count: 300), kind: .thumbnail, key: "old", fingerprint: fingerprint)
        precondition(smallCache.read(.metadata, key: "new", fingerprint: fingerprint)?.count == 100)
        precondition(smallCache.read(.thumbnail, key: "old", fingerprint: fingerprint)?.count == 300)
        print("PASS: thumbnail and metadata persistence across fresh connections, shared date/search extraction, size-based invalidation, damaged-record repair, unavailable-cache fallback, missing-photo safety and bounded eviction")

        try await Release09Checks.run(base: base, imageData: originalDiskPhoto)
        try await ReliabilityChecks.run(base: base, imageData: originalDiskPhoto)
        try await DevelopChecks.run(base: base)
        try await AdjustmentChecks.run(base: base, imageData: originalDiskPhoto)
        try await Release12Checks.run(base: base)
        try await Release13Checks.run(base: base)
        try await Release14Checks.run(base: base)
        try await Release15Checks.run(base: base)
        try await Release16Checks.run(base: base)

    }
}
