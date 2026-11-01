import Foundation

struct LibraryWorkspace: Codable, Sendable {
    var selectedPhotos: [String] = []
    var scrollAnchor: String?
    var expandedFolders: [String] = []
    var filters = NotesFilter()
    var sidebarVisible = true
    var showingInformation = true
    var showingFilters = true
    var showingSearch = false
    var showingPreview = false
}

nonisolated struct PendingSaveRow: Identifiable {
    let id: URL
    let path: String
    let status: String
    let canShow: Bool
}
