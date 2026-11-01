import Foundation

struct PhotoFolder: Identifiable, Sendable {
    let url: URL
    let children: [PhotoFolder]?
    nonisolated var id: URL { url }

    nonisolated static func tree(root: URL, directories: [URL]) -> PhotoFolder {
        let grouped = Dictionary(grouping: directories, by: { $0.deletingLastPathComponent().resolvingSymlinksInPath().path })
        func node(_ url: URL) -> PhotoFolder {
            let children = (grouped[url.resolvingSymlinksInPath().path] ?? [])
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .map { node($0) }
            return PhotoFolder(url: url, children: children.isEmpty ? nil : children)
        }
        return node(root)
    }
}

enum PhotoScope {
    nonisolated static func filter(_ photos: [PhotoFile], folder: URL, includesSubfolders: Bool) -> [PhotoFile] {
        let components = folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        // Resolve each distinct folder once, rather than once per photograph.
        var parents: [String: [String]] = [:]
        return photos.filter { photo in
            let parentURL = photo.url.deletingLastPathComponent()
            let parent: [String]
            if let cached = parents[parentURL.path] {
                parent = cached
            } else {
                parent = parentURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
                parents[parentURL.path] = parent
            }
            return includesSubfolders ? parent.starts(with: components) : parent == components
        }
    }
}

struct VisibleFolder: Identifiable, Sendable {
    let folder: PhotoFolder
    let depth: Int
    nonisolated var id: URL { folder.id }
}

extension PhotoFolder {
    nonisolated func visibleRows(expanded: Set<URL>, depth: Int = 0) -> [VisibleFolder] {
        var rows = [VisibleFolder(folder: self, depth: depth)]
        if expanded.contains(id) {
            for child in children ?? [] {
                rows += child.visibleRows(expanded: expanded, depth: depth + 1)
            }
        }
        return rows
    }
}
