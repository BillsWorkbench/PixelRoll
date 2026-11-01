import Foundation
import UniformTypeIdentifiers

struct PhotoFile: Identifiable, Hashable, Sendable {
    let url: URL
    let modifiedDate: Date?
    let fileSize: Int?
    nonisolated init(url: URL, modifiedDate: Date? = nil, fileSize: Int? = nil) {
        self.url = url
        self.modifiedDate = modifiedDate
        self.fileSize = fileSize
    }
    nonisolated var id: URL { url }
}

struct ScanResult: Sendable {
    let photos: [PhotoFile]
    let unreadableItems: Int
    let inspectedItems: Int
    let directories: [URL]
    let notes: [URL: NotesSnapshot]
    let noteErrors: [URL: String]
    nonisolated init(photos: [PhotoFile], unreadableItems: Int, directories: [URL],
                     notes: [URL: NotesSnapshot] = [:], noteErrors: [URL: String] = [:], inspectedItems: Int = 0) {
        self.inspectedItems = inspectedItems
        self.photos = photos; self.unreadableItems = unreadableItems; self.directories = directories
        self.notes = notes; self.noteErrors = noteErrors
    }
}

enum PhotoScanner {
    nonisolated static func isPhoto(_ url: URL, type: UTType?) -> Bool {
        type?.conforms(to: .image) == true || ["nef", "nrw", "dng", "arw", "cr2", "cr3", "raf", "orf", "rw2", "pef", "srw"].contains(url.pathExtension.lowercased())
    }

    // File traversal runs outside the main actor; original files are never modified.
    nonisolated static func scan(_ root: URL) -> ScanResult {
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        var unreadable = 0
        var inspected = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .isPackageKey, .contentTypeKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in unreadable += 1; return true }
        ) else {
            return ScanResult(photos: [], unreadableItems: 1, directories: [])
        }
        var photos: [PhotoFile] = []
        var directories: [URL] = []
        var notes: [URL: NotesSnapshot] = [:]
        var noteErrors: [URL: String] = [:]
        for case let url as URL in enumerator {
            if Task.isCancelled { break }
            do {
                inspected += 1
                let values = try url.resourceValues(forKeys: Set(keys))
                guard values.isSymbolicLink != true else { enumerator.skipDescendants(); continue }
                if values.isDirectory == true {
                    if values.isPackage != true { directories.append(url) }
                    continue
                }
                guard values.isRegularFile == true else { continue }
                if isPhoto(url, type: values.contentType) {
                    photos.append(PhotoFile(url: url, modifiedDate: values.contentModificationDate, fileSize: values.fileSize))
                    let sidecar = NotesStore.sidecar(for: url)
                    if FileManager.default.fileExists(atPath: sidecar.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: sidecar.path)) != nil {
                        do { notes[url] = try NotesStore.read(url) }
                        catch { noteErrors[url] = error.localizedDescription }
                    }
                }
            } catch {
                unreadable += 1
            }
        }
        photos.sort { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        return ScanResult(photos: photos, unreadableItems: unreadable, directories: directories, notes: notes, noteErrors: noteErrors, inspectedItems: inspected)
    }
}
