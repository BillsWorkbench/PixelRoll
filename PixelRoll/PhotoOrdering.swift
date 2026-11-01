import Foundation
import ImageIO

enum PhotoSortOrder: String, CaseIterable, Identifiable, Sendable {
    case filename, captureDate, modifiedDate
    nonisolated var id: String { rawValue }
    nonisolated var title: String {
        switch self {
        case .filename: "Filename"
        case .captureDate: "Capture Date"
        case .modifiedDate: "Modified Date"
        }
    }
}

enum PhotoOrdering {
    nonisolated static func sort(_ photos: [PhotoFile], by order: PhotoSortOrder, ascending: Bool,
                                 captureDates: [URL: Date] = [:]) -> [PhotoFile] {
        photos.sorted { a, b in
            if order != .filename {
                let first = order == .captureDate ? captureDates[a.id] : a.modifiedDate
                let second = order == .captureDate ? captureDates[b.id] : b.modifiedDate
                if first == nil && second != nil { return false }
                if first != nil && second == nil { return true }
                if let first, let second, first != second { return ascending ? first < second : first > second }
            }
            let name = a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent)
            let comparison = name == .orderedSame ? a.url.path.localizedStandardCompare(b.url.path) : name
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }
}

actor CaptureDateIndex {
    static let shared = CaptureDateIndex()
    private let index: PhotoMetadataIndex
    init(index: PhotoMetadataIndex = .shared) { self.index = index }
    func clear() async { await index.clearMemory() }
    func invalidate(_ urls: Set<URL>) async { await index.invalidate(urls) }

    func dates(for photos: [PhotoFile], root: URL) async -> [URL: Date] {
        var dates: [URL: Date] = [:]
        for photo in photos {
            if Task.isCancelled { break }
            if let date = await index.entry(for: photo, root: root)?.captureDate { dates[photo.id] = date }
        }
        return dates
    }

    nonisolated static func parse(_ value: String?, offset: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.isLenient = false
        // Untagged capture times retain their wall-clock order without assuming the Mac's timezone.
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        if let offset, offset.range(of: "^[+-][0-9]{2}:[0-9]{2}$", options: .regularExpression) != nil {
            let parts = offset.dropFirst().split(separator: ":").compactMap { Int($0) }
            if parts.count == 2, parts[0] <= 23, parts[1] <= 59 {
                formatter.timeZone = TimeZone(secondsFromGMT: (offset.first == "-" ? -1 : 1) * (parts[0] * 3600 + parts[1] * 60))
            }
        }
        return formatter.date(from: value)
    }
}
