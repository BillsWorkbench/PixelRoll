import Foundation

nonisolated struct PendingNote: Codable {
    let photo: String
    let notes: PhotoNotes
    let originalNotes: PhotoNotes
    let originalRevision: Data?
}
