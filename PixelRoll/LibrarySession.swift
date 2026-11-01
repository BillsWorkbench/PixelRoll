import Foundation

struct LibrarySession: Codable, Sendable {
    let bookmark: Data
    let folder: String
    let photo: String?
    let includesSubfolders: Bool
    let searchQuery: String
    var libraryPath: String? = nil
    var workspace: LibraryWorkspace? = nil
    var writeAccessVersion: Int? = nil
    var writeBookmark: Data? = nil
    var renameBookmark: Data? = nil
}

enum SessionPaths {
    nonisolated static func relative(_ url: URL, to root: URL) -> String? {
        let base = FolderRenamer.canonicalMissingPath(root).pathComponents
        let parts = FolderRenamer.canonicalMissingPath(url).pathComponents
        guard parts.starts(with: base) else { return nil }
        return parts.dropFirst(base.count).joined(separator: "/")
    }

    nonisolated static func resolve(_ relative: String, within root: URL) -> URL? {
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { return nil }
        let candidate = relative.isEmpty ? root : root.appendingPathComponent(relative)
        guard self.relative(candidate, to: root) != nil else { return nil }
        return candidate
    }
}

// Construct once per search; raw paths avoid /var versus /private/var component-count errors.
nonisolated struct PhotoSearchPaths: Sendable {
    private let bases: [String]
    init(root: URL) {
        bases = Array(Set([root.path, root.standardizedFileURL.path, FolderRenamer.canonicalMissingPath(root).path]))
    }
    func relative(_ url: URL) -> String {
        let path = url.path
        for base in bases {
            if path == base { return "" }
            let prefix = base.hasSuffix("/") ? base : base + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        }
        return url.lastPathComponent
    }
}

enum PhotoSearch {
    nonisolated static func filter(_ photos: [PhotoFile], query: String, root: URL) -> [PhotoFile] {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return photos }
        let scope = PhotoSearchPaths(root: root)
        return photos.filter { photo in
            // Search relative paths so a library name doesn't match every photo.
            let path = scope.relative(photo.url)
            return words.allSatisfy { path.localizedCaseInsensitiveContains($0) }
        }
    }
}
