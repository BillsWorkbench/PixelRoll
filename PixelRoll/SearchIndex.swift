import Foundation

actor SearchIndex {
    static let shared = SearchIndex()
    private let index: PhotoMetadataIndex
    init(index: PhotoMetadataIndex = .shared) { self.index = index }
    func clear() async { await index.clearMemory() }
    func invalidate(_ urls: Set<URL>) async { await index.invalidate(urls) }

    func matching(_ photos: [PhotoFile], query: String, root: URL) async -> [URL] {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let scope = PhotoSearchPaths(root: root)
        var matches: [URL] = []
        for photo in photos {
            if Task.isCancelled { break }
            let metadata = await index.entry(for: photo, root: root)
            let path = scope.relative(photo.url)
            let text = path + "\n" + (metadata?.text ?? "")
            if words.allSatisfy({ text.localizedCaseInsensitiveContains($0) }) { matches.append(photo.id) }
        }
        return matches
    }
}
