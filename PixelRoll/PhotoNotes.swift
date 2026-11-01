import Foundation

nonisolated enum PhotoFlag: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, pick, reject
    nonisolated var id: String { rawValue }
    nonisolated var title: String { switch self { case .none: "Unflagged"; case .pick: "Pick"; case .reject: "Reject" } }
}

nonisolated struct PhotoNotes: Codable, Equatable, Sendable {
    var rating = 0
    var flag: PhotoFlag = .none
    var keywords: [String] = []
    var caption = ""
    var adjustments = PhotoAdjustments()
    var isRejected: Bool { flag == .reject }
    var isPick: Bool { rating > 0 && !isRejected }
    enum CodingKeys: String, CodingKey { case rating, flag, keywords, caption, adjustments }
    init(rating: Int = 0, flag: PhotoFlag = .none, keywords: [String] = [], caption: String = "", adjustments: PhotoAdjustments = PhotoAdjustments()) {
        self.rating = rating; self.flag = flag; self.keywords = keywords; self.caption = caption; self.adjustments = adjustments
    }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        rating = try fields.decode(Int.self, forKey: .rating)
        flag = try fields.decode(PhotoFlag.self, forKey: .flag)
        keywords = try fields.decode([String].self, forKey: .keywords)
        caption = try fields.decode(String.self, forKey: .caption)
        adjustments = try fields.decodeIfPresent(PhotoAdjustments.self, forKey: .adjustments) ?? PhotoAdjustments()
        guard adjustments.valid else { throw NotesError.invalid }
    }

}

struct NotesSnapshot: Sendable, Equatable {
    let notes: PhotoNotes
    let revision: Data?
}

nonisolated enum NotesError: LocalizedError {
    case invalid, newerVersion, conflict, unsafeLink
    var errorDescription: String? {
        switch self {
        case .invalid: "This sidecar has invalid data. It was left unchanged."
        case .newerVersion: "This sidecar uses a newer format. It was left unchanged."
        case .conflict: "The sidecar changed outside PixelRoll. Your draft is kept. Refresh, review the saved notes, then discard and reapply your draft before saving."
        case .unsafeLink: "The sidecar is a symbolic link. PixelRoll won’t write through it."
        }
    }
}

actor NotesStore {
    static let shared = NotesStore()

    nonisolated static func sidecar(for photo: URL) -> URL { photo.appendingPathExtension("pixelroll") }

    nonisolated static func read(_ photo: URL) throws -> NotesSnapshot {
        let url = sidecar(for: photo)
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else { throw NotesError.unsafeLink }
        guard FileManager.default.fileExists(atPath: url.path) else { return NotesSnapshot(notes: PhotoNotes(), revision: nil) }
        let data = try Data(contentsOf: url)
        let object = try validate(data, photo: photo)
        let fields = try JSONSerialization.data(withJSONObject: object)
        let notes = try JSONDecoder().decode(PhotoNotes.self, from: fields)
        guard (0...5).contains(notes.rating) else { throw NotesError.invalid }
        return NotesSnapshot(notes: notes, revision: data)
    }

    nonisolated private static func validate(_ data: Data, photo: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? Int else { throw NotesError.invalid }
        guard version == 1 else { throw NotesError.newerVersion }
        guard object["photo"] as? String == photo.lastPathComponent,
              object["rating"] is Int, object["flag"] is String,
              object["keywords"] is [String], object["caption"] is String else { throw NotesError.invalid }
        return object
    }

    func save(_ notes: PhotoNotes, photo: URL, access: URL, expected: Data?) throws -> NotesSnapshot {
        let scoped = access.startAccessingSecurityScopedResource()
        defer { if scoped { access.stopAccessingSecurityScopedResource() } }
        guard notes.adjustments.valid, (0...5).contains(notes.rating), SessionPaths.relative(photo, to: access) != nil,
              (try? photo.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: photo.path)) == nil else { throw NotesError.invalid }
        let current = try Self.read(photo)
        if current.revision != nil && current.notes == notes { return current }
        guard current.revision == expected else { throw NotesError.conflict }
        // Preserve fields added by other compatible versions of PixelRoll.
        var object = try current.revision.map { try Self.validate($0, photo: photo) } ?? [:]
        object["version"] = 1
        object["photo"] = photo.lastPathComponent
        object["rating"] = notes.rating
        object["flag"] = notes.flag.rawValue
        object["keywords"] = notes.keywords
        object["caption"] = notes.caption
        var adjustmentFields = object["adjustments"] as? [String: Any] ?? [:]
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(notes.adjustments)) as! [String: Any]
        for (key, value) in encoded { adjustmentFields[key] = value }
        if notes.adjustments.presetID == nil { adjustmentFields.removeValue(forKey: "presetID") }
        object["adjustments"] = adjustmentFields
        object["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Self.sidecar(for: photo), options: .atomic)
        return NotesSnapshot(notes: notes, revision: data)
    }
}

enum PhotoFormatFilter: String, Codable, CaseIterable, Identifiable, Sendable {
    case all, raw, jpeg, heic, tiff, png, other
    nonisolated var id: String { rawValue }
    nonisolated var title: String { rawValue == "all" ? "All Formats" : rawValue.uppercased() }
    nonisolated func matches(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let raw = ["nef", "nrw", "dng", "arw", "cr2", "cr3", "raf", "orf", "rw2", "pef", "srw"]
        switch self {
        case .all: return true
        case .raw: return raw.contains(ext)
        case .jpeg: return ["jpg", "jpeg"].contains(ext)
        case .heic: return ["heic", "heif", "hif"].contains(ext)
        case .tiff: return ["tif", "tiff"].contains(ext)
        case .png: return ext == "png"
        case .other: return !raw.contains(ext) && !["jpg", "jpeg", "heic", "heif", "hif", "tif", "tiff", "png"].contains(ext)
        }
    }
}

struct NotesFilter: Codable, Sendable {
    var minimumRating = 0
    var flag: PhotoFlag?
    var format: PhotoFormatFilter = .all
    var keyword = ""
    var rejectedOnly = false
    nonisolated var active: Bool { minimumRating > 0 || rejectedOnly || flag != nil || format != .all || !keyword.isEmpty }
    nonisolated func matches(_ photo: PhotoFile, notes: PhotoNotes) -> Bool {
        notes.rating >= minimumRating && (!rejectedOnly || notes.isRejected) &&
        (flag == nil || (flag == .pick ? notes.isPick : flag == .reject ? notes.isRejected : notes.rating == 0 && !notes.isRejected)) && format.matches(photo.url) &&
        (keyword.isEmpty || notes.keywords.contains { $0.localizedCaseInsensitiveContains(keyword) })
    }
}


extension NotesStore {
    func changeKeywords(_ changes: [KeywordChange], access: URL) throws -> [URL: NotesSnapshot] {
        let scoped = access.startAccessingSecurityScopedResource()
        defer { if scoped { access.stopAccessingSecurityScopedResource() } }
        for change in changes {
            guard try Self.read(change.photo).revision == change.expected else { throw NotesError.conflict }
        }
        var written: [URL: NotesSnapshot] = [:]
        do {
            for change in changes {
                written[change.photo] = try save(change.notes, photo: change.photo, access: access, expected: change.expected)
            }
            return written
        } catch {
            var notRestored = 0
            for change in changes where written[change.photo] != nil {
                do {
                    guard try Self.read(change.photo).revision == written[change.photo]?.revision else {
                        notRestored += 1; continue
                    }
                    if let original = change.expected { try original.write(to: Self.sidecar(for: change.photo), options: .atomic) }
                    else { try FileManager.default.removeItem(at: Self.sidecar(for: change.photo)) }
                } catch { notRestored += 1 }
            }
            if notRestored > 0 {
                throw NSError(domain: "PixelRoll", code: 2, userInfo: [NSLocalizedDescriptionKey:
                    "Keyword changes could not finish. \(notRestored) photos changed again and need review. Refresh the library before retrying."])
            }
            throw error
        }
    }
}
