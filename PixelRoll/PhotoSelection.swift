import Foundation

struct PhotoSelection: Sendable {
    var id: URL? {
        didSet { ids = Set(id.map { [$0] } ?? []); anchor = id }
    }
    private(set) var ids: Set<URL> = []
    private var anchor: URL?

    nonisolated mutating func select(_ target: URL, in photos: [PhotoFile], extending: Bool = false, toggling: Bool = false) {
        guard photos.contains(where: { $0.id == target }) else { return }
        let oldAnchor = anchor ?? id ?? target
        let oldIDs = ids
        if extending, let start = photos.firstIndex(where: { $0.id == oldAnchor }),
           let end = photos.firstIndex(where: { $0.id == target }) {
            id = target
            ids = Set(photos[min(start, end)...max(start, end)].map(\.id))
            if toggling { ids.formUnion(oldIDs) }
            anchor = oldAnchor
        } else if toggling {
            var next = oldIDs
            if !next.insert(target).inserted { next.remove(target) }
            id = next.contains(target) ? target : photos.first(where: { next.contains($0.id) })?.id
            ids = next
            anchor = id
        } else { id = target }
    }

    nonisolated mutating func selectAll(in photos: [PhotoFile]) {
        let primary = id ?? photos.first?.id
        id = primary
        ids = Set(photos.map(\.id))
        anchor = primary
    }

    nonisolated mutating func restore(_ restored: Set<URL>, primary: URL?, in photos: [PhotoFile]) {
        let available = restored.intersection(photos.map(\.id))
        let chosen = primary.flatMap { available.contains($0) ? $0 : nil } ?? photos.first(where: { available.contains($0.id) })?.id
        id = chosen
        ids = available
        anchor = chosen
    }

    nonisolated mutating func synchronize(with photos: [PhotoFile]) {
        let retained = ids.intersection(photos.map(\.id))
        let oldAnchor = anchor
        let primary = photos.contains(where: { $0.id == id }) ? id : photos.first(where: { retained.contains($0.id) })?.id ?? photos.first?.id
        id = primary
        ids = retained.isEmpty ? Set(primary.map { [$0] } ?? []) : retained
        anchor = oldAnchor.flatMap { value in photos.contains(where: { $0.id == value }) ? value : nil } ?? primary
    }

    nonisolated mutating func move(by offset: Int, in photos: [PhotoFile], extending: Bool = false) {
        guard !photos.isEmpty else { id = nil; return }
        let index = photos.firstIndex(where: { $0.id == id }) ?? 0
        select(photos[min(max(index + offset, 0), photos.count - 1)].id, in: photos, extending: extending)
    }
}
