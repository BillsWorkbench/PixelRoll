import Foundation
import UniformTypeIdentifiers

nonisolated enum LibraryChange: Hashable, Sendable {
    case file(URL)
    case subtree(URL)
    case rescan
}

extension PhotoScanner {
    // Reconcile only paths supplied by FSEvents. Unchanged files retain their IDs and snapshots.
    nonisolated static func updating(_ snapshot: ScanResult, root: URL, changes: Set<LibraryChange>) -> ScanResult {
        if changes.contains(.rescan) { return scan(root) }
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        let canonicalRoot = FolderRenamer.canonicalMissingPath(root)
        let bases = [root.standardizedFileURL.path, canonicalRoot.path]
        func relative(_ url: URL) -> String? {
            let path = url.path
            for base in bases {
                if path == base { return "" }
                if path.hasPrefix(base + "/") { return String(path.dropFirst(base.count + 1)) }
            }
            let canonical = FolderRenamer.canonicalMissingPath(url).path
            if canonical == canonicalRoot.path { return "" }
            return canonical.hasPrefix(canonicalRoot.path + "/") ? String(canonical.dropFirst(canonicalRoot.path.count + 1)) : nil
        }
        func inside(_ path: String, _ folder: String) -> Bool {
            folder.isEmpty || path == folder || path.hasPrefix(folder + "/")
        }
        func excluded(_ path: String) -> Bool {
            let parts = path.split(separator: "/").map(String.init)
            if parts.contains(where: { $0.hasPrefix(".") }) { return true }
            var ancestor = canonicalRoot
            for part in parts.dropLast() {
                ancestor.appendPathComponent(part)
                if let values = try? ancestor.resourceValues(forKeys: [.isSymbolicLinkKey, .isPackageKey, .isHiddenKey]),
                   values.isSymbolicLink == true || values.isPackage == true || values.isHidden == true { return true }
            }
            return false
        }
        var photos = Dictionary(uniqueKeysWithValues: snapshot.photos.compactMap { photo in relative(photo.url).map { ($0, photo) } })
        var directories = Dictionary(uniqueKeysWithValues: snapshot.directories.compactMap { url in relative(url).map { ($0, url) } })
        var notes = snapshot.notes
        var errors = snapshot.noteErrors
        var inspected = 0
        var subtrees = Set<String>()
        var files = Set<String>()
        for change in changes {
            switch change {
            case .rescan: return scan(root)
            case .subtree(let url):
                guard let path = relative(url) else { continue }
                if path.isEmpty { return scan(root) }
                if !excluded(path) { subtrees.insert(path) }
            case .file(let url):
                guard let path = relative(url) else { continue }
                if excluded(path) { continue }
                files.insert(path.lowercased().hasSuffix(".pixelroll") ? String(path.dropLast(10)) : path)
            }
        }
        let scopes = subtrees.filter { candidate in !subtrees.contains { $0 != candidate && inside(candidate, $0) } }
        func remove(_ path: String) {
            if let photo = photos.removeValue(forKey: path) {
                notes.removeValue(forKey: photo.id); errors.removeValue(forKey: photo.id)
            }
        }
        for scope in scopes.sorted() {
            if Task.isCancelled { return snapshot }
            let url = canonicalRoot.appendingPathComponent(scope)
            let values: URLResourceValues
            do { values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey]) }
            catch {
                let error = error as NSError
                if error.domain != NSCocoaErrorDomain || ![NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return scan(root) }
                for path in Array(photos.keys) where inside(path, scope) { remove(path) }
                directories = directories.filter { !inside($0.key, scope) }
                continue
            }
            for path in Array(photos.keys) where inside(path, scope) { remove(path) }
            directories = directories.filter { !inside($0.key, scope) }
            guard values.isDirectory == true, values.isSymbolicLink != true, values.isPackage != true, values.isHidden != true else { continue }
            let found = scan(url)
            // A partial subtree cannot prove deletions; a full recovery scan reports access problems.
            if found.unreadableItems > 0 { return scan(root) }
            inspected += found.inspectedItems
            directories[scope] = url
            for directory in found.directories { if let path = relative(directory) { directories[path] = directory } }
            for photo in found.photos { if let path = relative(photo.url) { photos[path] = photo } }
            notes.merge(found.notes) { _, new in new }
            errors.merge(found.noteErrors) { _, new in new }
        }
        for path in files.sorted() where !scopes.contains(where: { inside(path, $0) }) {
            if Task.isCancelled { return snapshot }
            let url = photos[path]?.url ?? canonicalRoot.appendingPathComponent(path)
            inspected += 1
            let values: URLResourceValues
            do { values = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey, .contentTypeKey, .contentModificationDateKey, .fileSizeKey]) }
            catch {
                let error = error as NSError
                if error.domain != NSCocoaErrorDomain || ![NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return scan(root) }
                remove(path)
                continue
            }
            guard values.isRegularFile == true, values.isSymbolicLink != true, values.isHidden != true,
                  isPhoto(url, type: values.contentType) else { remove(path); continue }
            let photo = PhotoFile(url: url, modifiedDate: values.contentModificationDate, fileSize: values.fileSize)
            photos[path] = photo
            notes.removeValue(forKey: photo.id); errors.removeValue(forKey: photo.id)
            do {
                let saved = try NotesStore.read(url)
                if saved.revision != nil { notes[photo.id] = saved }
            } catch { errors[photo.id] = error.localizedDescription }
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty && parent != "." {
                directories[parent] = directories[parent] ?? canonicalRoot.appendingPathComponent(parent)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        return ScanResult(photos: photos.values.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending },
                          unreadableItems: snapshot.unreadableItems,
                          directories: directories.values.sorted { $0.path < $1.path }, notes: notes, noteErrors: errors,
                          inspectedItems: inspected)
    }
}
