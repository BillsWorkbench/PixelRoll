import AppKit
import Combine

@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var savedNotes: [URL: NotesSnapshot] = [:]
    @Published private(set) var noteErrors: [URL: String] = [:]
    @Published var noteDrafts: [URL: PhotoNotes] = [:]
    private var draftBases: [URL: NotesSnapshot] = [:]
    @Published private(set) var savingNoteIDs: Set<URL> = []
    @Published private(set) var writeAccessURL: URL?
    @Published var notesFilter = NotesFilter() { didSet { applyFilter(); saveSession() } }
    @Published var operationError: String?
    @Published private(set) var isMaintainingCache = false
    @Published private(set) var cacheProgress = 0
    @Published private(set) var cacheTotal = 0
    @Published private(set) var cacheNotice: String?
    @Published private(set) var thumbnailEpoch = 0
    private var cacheTask: Task<Void, Never>?
    @Published private(set) var noteSaveErrors: [URL: String] = [:]
    @Published private(set) var isManagingKeywords = false
    @Published private(set) var keywordNotice: String?
    @Published private(set) var canUndoKeywords = false
    private var keywordUndo: [KeywordChange] = []
    private var autoSaveTasks: [URL: Task<Void, Never>] = [:]
    private var automaticDraftIDs: Set<URL> = []
    private var writeAccessCallbacks: [(Bool) -> Void] = []
    private var requestingWriteAccess = false
    @Published private(set) var needsWriteAccessRepair = false
    private var writeAccessDeclined = false
    private var renameAccessURL: URL?
    private var renameBookmark: Data?
    private var writeBookmark: Data?
    weak var undoManager: UndoManager?
    var canOrganize: Bool { writeAccessURL != nil && !libraryUnavailable }
    func notes(for photo: URL) -> PhotoNotes { savedNotes[photo]?.notes ?? PhotoNotes() }
    func draft(for photo: URL) -> PhotoNotes { noteDrafts[photo] ?? notes(for: photo) }
    func updateDraft(_ notes: PhotoNotes, for photo: URL) {
        if notes == self.notes(for: photo) && !savingNoteIDs.contains(photo) { discardDraft(for: photo) }
        else {
            if draftBases[photo] == nil { draftBases[photo] = savedNotes[photo] ?? NotesSnapshot(notes: PhotoNotes(), revision: nil) }
            noteDrafts[photo] = notes
        }
    }

    @Published var thumbnailSize: Double { didSet { defaults.set(thumbnailSize, forKey: "PixelRoll.thumbnailSize") } }
    @Published var sortOrder: PhotoSortOrder {
        didSet {
            defaults.set(sortOrder.rawValue, forKey: "PixelRoll.sortOrder")
            resort()
            if sortOrder == .captureDate { prepareCaptureDates() }
            else { sortTask?.cancel(); isSorting = false }
        }
    }
    @Published var sortAscending: Bool { didSet { defaults.set(sortAscending, forKey: "PixelRoll.sortAscending"); resort() } }
    @Published private(set) var isSorting = false
    @Published private(set) var datedCount = 0
    @Published private(set) var dateTotal = 0
    @Published private(set) var isRefreshing = false
    @Published private(set) var libraryUnavailable = false
    private var captureDates: [URL: Date] = [:]
    private var datedPhotos: Set<URL> = []
    private var pendingChanges: Set<LibraryChange> = []
    private(set) var lastRefreshItemCount = 0
    private(set) var lastRefreshWasIncremental = false
    private var sortTask: Task<Void, Never>?
    private var watcher: LibraryWatcher?
    private var automaticRefreshTask: Task<Void, Never>?
    private var availabilityTask: Task<Void, Never>?
    private var refreshPending = false
    private var recoveryPhoto: URL?
    private var needsBookmarkReconnect = false
    private var sessionBases: [String] = []
    @Published private(set) var root: URL? {
        didSet {
            if oldValue?.path != root?.path, let root {
                sessionBases = Array(Set([root.path, root.standardizedFileURL.path, FolderRenamer.canonicalMissingPath(root).path]))
            }
        }
    }
    // Browsing scope and sidebar highlight are separate: following a photo never changes the grid.
    @Published private(set) var selectedFolder: URL?
    @Published private(set) var highlightedFolder: URL?
    @Published var expandedFolders: Set<URL> = [] { didSet { if oldValue != expandedFolders { saveSession() } } }
    @Published var workspace = LibraryWorkspace() { didSet { saveSession() } }
    @Published var scrollAnchor: URL? { didSet { saveSession() } }
    private var pendingWorkspace: LibraryWorkspace?
    private(set) var shouldFollowSelection = true
    var isRestoringWorkspace: Bool { pendingWorkspace != nil }
    private var waitingForPhotos: Set<URL> = []
    private var retryOnReconnect: Set<URL> = []
    @Published private(set) var folderTree: PhotoFolder?
    @Published var includesSubfolders = true { didSet { applyFilter(); saveSession() } }
    @Published var searchQuery = "" { didSet { applyFilter(); saveSession() } }
    @Published var selection = PhotoSelection() {
        didSet {
            if oldValue.id != selection.id || oldValue.ids != selection.ids { followSelectedPhoto(); saveSession() }
        }
    }
    @Published private(set) var photos: [PhotoFile] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isSearching = false
    @Published private(set) var searchedCount = 0
    @Published private(set) var searchTotal = 0
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var navigationRevision = 0
    @Published private(set) var unreadableItems = 0
    @Published private(set) var sessionNotice: String?
    private var allPhotos: [PhotoFile] = []
    private var scanTask: Task<ScanResult, Never>?
    private var generation = UUID()
    private var scanGeneration = UUID()
    private var knownDirectories: Set<URL> = []
    private let defaults: UserDefaults
    private var bookmark: Data?
    private var didRestore = false
    private var savingSuspended = false
    private static let sessionKey = "PixelRoll.librarySession.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        thumbnailSize = min(300, max(120, defaults.object(forKey: "PixelRoll.thumbnailSize") as? Double ?? 180))
        sortOrder = PhotoSortOrder(rawValue: defaults.string(forKey: "PixelRoll.sortOrder") ?? "") ?? .filename
        sortAscending = defaults.object(forKey: "PixelRoll.sortAscending") as? Bool ?? true
    }

    private func resort() {
        photos = PhotoOrdering.sort(photos, by: sortOrder, ascending: sortAscending, captureDates: captureDates)
    }

    private func prepareCaptureDates() {
        sortTask?.cancel()
        guard sortOrder == .captureDate, let root, !libraryUnavailable, !isScanning else { return }
        let files = PhotoScope.filter(allPhotos, folder: selectedFolder ?? root, includesSubfolders: true)
            .filter { !datedPhotos.contains($0.id) }
        guard !files.isEmpty else { isSorting = false; return }
        let request = generation
        isSorting = true
        datedCount = 0
        dateTotal = files.count
        sortTask = Task(priority: .background) { [weak self] in
            for start in stride(from: 0, to: files.count, by: 64) {
                let end = min(start + 64, files.count)
                let dates = await CaptureDateIndex.shared.dates(for: Array(files[start..<end]), root: root)
                guard let self, !Task.isCancelled, self.generation == request else { return }
                self.captureDates.merge(dates) { _, new in new }
                self.datedPhotos.formUnion(files[start..<end].map(\.id))
                if end == files.count || end % 1024 == 0 { self.datedCount = end }
            }
            guard let self, !Task.isCancelled, self.generation == request else { return }
            self.resort()
            self.isSorting = false
            self.sortTask = nil
        }
    }

    func revealInFinder(_ url: URL? = nil) {
        guard let target = url ?? selection.id, let root, !libraryUnavailable else { return }
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    private func startWatching(_ root: URL) {
        automaticRefreshTask?.cancel()
        pendingChanges.removeAll()
        watcher = LibraryWatcher(root: root) { [weak self] changes in
            Task { @MainActor [weak self] in
                guard let self, self.root?.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path else { return }
                self.queueAutomaticRefresh(changes)
            }
        }
        if watcher == nil {
            sessionNotice = "Automatic folder updates are unavailable for this folder. Use Refresh to check for changes."
        }
        availabilityTask?.cancel()
        availabilityTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard let self else { return }
                self.checkAvailability()
            }
        }
    }

    private func queueAutomaticRefresh(_ changes: [LibraryChange] = []) {
        pendingChanges.formUnion(changes)
        automaticRefreshTask?.cancel()
        automaticRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
            guard let self else { return }
            self.checkAvailability()
            guard !self.libraryUnavailable else { return }
            if self.isScanning || self.isRefreshing || self.isManagingKeywords || !self.savingNoteIDs.isEmpty {
                self.refreshPending = true
                self.queueAutomaticRefresh()
                return
            }
            guard let root = self.root, !self.pendingChanges.isEmpty else { return }
            let changes = self.pendingChanges
            self.pendingChanges.removeAll()
            self.refreshPending = false
            self.load(root, folder: self.selectedFolder ?? root, photo: self.selection.id,
                      preservingContent: true, changes: changes, background: true)
        }
    }

    func checkAvailability() {
        guard var root else { return }
        if needsBookmarkReconnect, let bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) {
                let access = resolved.startAccessingSecurityScopedResource()
                let exists = FileManager.default.fileExists(atPath: resolved.path)
                if access { resolved.stopAccessingSecurityScopedResource() }
                if exists {
                    let relativeFolder = selectedFolder.flatMap { SessionPaths.relative($0, to: root) } ?? ""
                    self.root = resolved
                    selectedFolder = SessionPaths.resolve(relativeFolder, within: resolved) ?? resolved
                    root = resolved
                    if let data = writeBookmark {
                        var staleWrite = false
                        writeAccessURL = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &staleWrite)
                    }
                    needsBookmarkReconnect = false
                }
            }
        }
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        var directory: ObjCBool = false
        let available = FileManager.default.fileExists(atPath: root.path, isDirectory: &directory) && directory.boolValue
        if !available && !libraryUnavailable {
            recoveryPhoto = selection.id
            libraryUnavailable = true
            let parts = root.pathComponents
            if parts.count > 2, parts[1] == "Volumes", !FileManager.default.fileExists(atPath: "/Volumes/" + parts[2]) {
                sessionNotice = "Reconnect the drive “\(parts[2])”. Your workspace and unsaved changes are kept on this Mac."
            } else {
                sessionNotice = "The library folder “\(root.lastPathComponent)” is missing or was moved. Restore it to its original location, or open another library. Unsaved changes are kept on this Mac."
            }
            retryOnReconnect.formUnion(currentPendingIDs.filter { noteSaveErrors[$0] == nil })
            for task in autoSaveTasks.values { task.cancel() }
            autoSaveTasks.removeAll()
            cacheTask?.cancel()
            if isMaintainingCache { cacheNotice = "Library unavailable. Rebuild the index after reconnecting."; isMaintainingCache = false }
            scanTask?.cancel(); searchTask?.cancel(); sortTask?.cancel()
            generation = UUID(); scanGeneration = UUID(); searchGeneration = UUID()
            isScanning = false; isRefreshing = false; isSearching = false; isSorting = false
        } else if available && libraryUnavailable {
            libraryUnavailable = false
            sessionNotice = nil
            watcher = nil
            startWatching(root)
            load(root, folder: selectedFolder ?? root, photo: recoveryPhoto ?? selection.id, preservingContent: true)
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Photo Folder"
        panel.message = "Choose your top photo folder once. PixelRoll will browse its subfolders and save ratings, keywords and captions beside photos. Original photos stay unchanged."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Folder"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.open(url)
        }
    }

    func open(_ url: URL) {
        cacheTask?.cancel()
        isMaintainingCache = false
        cacheNotice = nil
        savingSuspended = true
        pendingWorkspace = nil
        needsBookmarkReconnect = false
        shouldFollowSelection = true
        workspace = LibraryWorkspace()
        scrollAnchor = nil
        waitingForPhotos.removeAll()
        retryOnReconnect.removeAll()
        searchQuery = ""
        notesFilter = NotesFilter()
        writeAccessURL = nil
        writeBookmark = nil
        renameAccessURL = nil
        renameBookmark = nil
        writeAccessDeclined = false
        needsWriteAccessRepair = false
        keywordUndo = []; canUndoKeywords = false
        undoManager?.removeAllActions()
        selection = PhotoSelection()
        expandedFolders = []
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        writeBookmark = bookmark
        writeAccessURL = bookmark == nil ? nil : url
        savingSuspended = false
        sessionNotice = bookmark == nil ? "This folder is open, but access couldn’t be saved for the next launch." : nil
        libraryUnavailable = false
        startWatching(url)
        load(url, folder: url, photo: nil)
    }

    func restoreSession() {
        guard !didRestore else { return }
        didRestore = true
        guard let data = defaults.data(forKey: Self.sessionKey),
              let saved = try? JSONDecoder().decode(LibrarySession.self, from: data) else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: saved.bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            bookmark = stale ? try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) : saved.bookmark
            if let data = saved.writeBookmark {
                needsWriteAccessRepair = saved.writeAccessVersion != 2
                var writeStale = false
                if let access = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &writeStale),
                   access.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path {
                    writeAccessURL = access
                    writeBookmark = data
                }
            }
            if let data = saved.renameBookmark {
                var staleParent = false
                renameAccessURL = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &staleParent)
                renameBookmark = renameAccessURL == nil ? nil : data
            }
            savingSuspended = true
            includesSubfolders = saved.includesSubfolders
            pendingWorkspace = saved.workspace
            var legacyWorkspace = LibraryWorkspace()
            legacyWorkspace.showingFilters = defaults.object(forKey: "PixelRoll.showFilters") as? Bool ?? true
            workspace = saved.workspace ?? legacyWorkspace
            shouldFollowSelection = saved.workspace == nil
            notesFilter = saved.workspace?.filters ?? NotesFilter()
            searchQuery = saved.searchQuery
            savingSuspended = false
            root = url
            selectedFolder = SessionPaths.resolve(saved.folder, within: url) ?? url
            recoveryPhoto = saved.photo.flatMap { SessionPaths.resolve($0, within: url) }
            startWatching(url)
            checkAvailability()
            if !libraryUnavailable {
                load(url, folder: selectedFolder ?? url, photo: recoveryPhoto)
            } else { restorePendingNotes() }
        } catch {
            guard let path = saved.libraryPath, path.hasPrefix("/") else {
                sessionNotice = "PixelRoll couldn’t restore folder access. Reopen your photo folder to reconnect it."
                return
            }
            savingSuspended = true
            let fallback = URL(fileURLWithPath: path, isDirectory: true)
            bookmark = saved.bookmark
            writeBookmark = saved.writeBookmark
            needsWriteAccessRepair = saved.writeAccessVersion != 2
            root = fallback
            selectedFolder = SessionPaths.resolve(saved.folder, within: fallback) ?? fallback
            recoveryPhoto = saved.photo.flatMap { SessionPaths.resolve($0, within: fallback) }
            includesSubfolders = saved.includesSubfolders
            searchQuery = saved.searchQuery
            workspace = saved.workspace ?? LibraryWorkspace()
            notesFilter = workspace.filters
            pendingWorkspace = saved.workspace
            shouldFollowSelection = false
            needsBookmarkReconnect = true
            libraryUnavailable = true
            savingSuspended = false
            startWatching(fallback)
            sessionNotice = "The saved library is unavailable. Reconnect its drive or restore “\(fallback.lastPathComponent)” to its original location. Your workspace and pending changes are kept."
            restorePendingNotes()
        }
    }

    func refresh() {
        checkAvailability()
        if let root, !libraryUnavailable, !isScanning {
            thumbnailEpoch += 1
            load(root, folder: selectedFolder ?? root, photo: selection.id, preservingContent: true)
        }
    }

    func selectFolder(_ url: URL) {
        beginUserNavigation()
        if !libraryUnavailable { sessionNotice = nil }
        savingSuspended = true
        searchQuery = ""
        selectedFolder = url
        highlightedFolder = url
        savingSuspended = false
        applyFilter()
        workspace.showingPreview = false
        scrollAnchor = selection.id
        if sortOrder == .captureDate { prepareCaptureDates() }
        saveSession()
    }

    private func applyFilter(preferredPhoto: URL? = nil) {
        guard !savingSuspended, !isScanning, !libraryUnavailable, let root, let selectedFolder else { return }
        searchTask?.cancel()
        searchGeneration = UUID()
        isSearching = false
        let searching = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Searches always include descendants of the browsing folder, regardless of the grid toggle.
        let candidates = PhotoScope.filter(allPhotos, folder: selectedFolder,
                                           includesSubfolders: searching || includesSubfolders)
            .filter { notesFilter.matches($0, notes: notes(for: $0.id)) }
        let filenameMatches = Set(PhotoSearch.filter(candidates, query: searchQuery, root: root).map(\.id))
        let words = searchQuery.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let immediate = candidates.filter { photo in
            if filenameMatches.contains(photo.id) { return true }
            let notes = notes(for: photo.id)
            let path = relativeForWorkspace(photo.url) ?? photo.url.lastPathComponent
            let text = ([path, notes.caption] + notes.keywords).joined(separator: "\n")
            return words.allSatisfy { text.localizedCaseInsensitiveContains($0) }
        }
        photos = PhotoOrdering.sort(searching ? immediate : candidates,
                                    by: sortOrder, ascending: sortAscending, captureDates: captureDates)
        if let preferredPhoto, let actual = photos.first(where: { $0.url.path == preferredPhoto.path || $0.url.resolvingSymlinksInPath().path == preferredPhoto.resolvingSymlinksInPath().path }) {
            if selection.id?.path != actual.id.path { selection.id = actual.id }
        }
        selection.synchronize(with: photos)
        followSelectedPhoto()
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchMetadata(candidates: candidates, root: root, preferredPhoto: preferredPhoto)
        }
    }

    private func searchMetadata(candidates: [PhotoFile], root: URL, preferredPhoto: URL?) {
        let request = searchGeneration
        let navigation = navigationRevision
        let query = searchQuery
        var matches = Set(photos.map(\.id))
        isSearching = true
        searchedCount = 0
        searchTotal = candidates.count
        searchTask = Task { [weak self] in
            // A brief debounce avoids reading files for every keystroke.
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            for start in stride(from: 0, to: candidates.count, by: 64) {
                guard !Task.isCancelled else { return }
                let end = min(start + 64, candidates.count)
                let found = await SearchIndex.shared.matching(Array(candidates[start..<end]), query: query, root: root)
                guard let self, !Task.isCancelled, self.searchGeneration == request else { return }
                let oldCount = matches.count
                matches.formUnion(found)
                self.searchedCount = end
                if matches.count != oldCount {
                    self.photos = PhotoOrdering.sort(candidates.filter { matches.contains($0.id) }, by: self.sortOrder,
                                                     ascending: self.sortAscending, captureDates: self.captureDates)
                    if self.navigationRevision == navigation, let preferredPhoto, let restored = self.photos.first(where: {
                        $0.url.resolvingSymlinksInPath().path == preferredPhoto.resolvingSymlinksInPath().path
                    }) { if self.selection.id?.path != restored.id.path { self.selection.id = restored.id } }
                    self.selection.synchronize(with: self.photos)
                }
            }
            guard let self, !Task.isCancelled, self.searchGeneration == request else { return }
            self.isSearching = false
            self.searchTask = nil
            self.restoreWorkspaceIfReady()
        }
    }

    private func followSelectedPhoto() {
        guard !savingSuspended, let root else { return }
        guard let photo = photos.first(where: { $0.id == selection.id }) else {
            highlightedFolder = selectedFolder
            return
        }
        var folder = photo.url.deletingLastPathComponent()
        let rootPath = root.resolvingSymlinksInPath().path
        highlightedFolder = folder.resolvingSymlinksInPath().path == rootPath ? root : folder
        while folder.resolvingSymlinksInPath().path != rootPath {
            let parent = folder.deletingLastPathComponent()
            guard parent.path != folder.path, SessionPaths.relative(parent, to: root) != nil else { break }
            expandedFolders.insert(parent.resolvingSymlinksInPath().path == rootPath ? root : parent)
            folder = parent
        }
    }

    private func saveSession() {
        guard !savingSuspended, pendingWorkspace == nil, !isScanning, !libraryUnavailable, let bookmark, let root, let selectedFolder,
              let folder = SessionPaths.relative(selectedFolder, to: root) else { return }
        var saved = LibrarySession(bookmark: bookmark, folder: folder,
                                   photo: selection.id.flatMap { relativeForWorkspace($0) },
                                   includesSubfolders: includesSubfolders, searchQuery: searchQuery)
        var layout = workspace
        layout.selectedPhotos = selection.ids.compactMap { relativeForWorkspace($0) }.sorted()
        layout.scrollAnchor = scrollAnchor.flatMap { relativeForWorkspace($0) }
        layout.expandedFolders = expandedFolders.compactMap { relativeForWorkspace($0) }.sorted()
        layout.filters = notesFilter
        saved.libraryPath = root.path
        saved.workspace = layout
        saved.writeBookmark = writeBookmark
        saved.writeAccessVersion = needsWriteAccessRepair ? nil : 2
        saved.renameBookmark = renameBookmark
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: Self.sessionKey) }
    }

    private func load(_ url: URL, folder: URL, photo: URL?, preservingContent: Bool = false,
                      changes: Set<LibraryChange>? = nil, background: Bool = false) {
        scanTask?.cancel()
        let request = UUID()
        scanGeneration = request
        if !preservingContent {
            generation = UUID()
            sortTask?.cancel()
            isSorting = false
            searchTask?.cancel()
            searchGeneration = UUID()
            isSearching = false
        }
        isScanning = !background
        isRefreshing = preservingContent
        root = url
        selectedFolder = folder
        if !preservingContent {
            highlightedFolder = folder
            folderTree = nil
            allPhotos = []
            photos = []
        }
        if !preservingContent { unreadableItems = 0 }
        let previous = allPhotos
        let snapshot = ScanResult(photos: previous, unreadableItems: unreadableItems,
                                  directories: Array(knownDirectories), notes: savedNotes, noteErrors: noteErrors)
        let worker = Task.detached(priority: background ? .background : .userInitiated) {
            let result = changes.map { PhotoScanner.updating(snapshot, root: url, changes: $0) } ?? PhotoScanner.scan(url)
            let current = Dictionary(uniqueKeysWithValues: result.photos.map { ($0.id, $0) })
            let invalid = Set(previous.filter { current[$0.id] != $0 }.map(\.id))
            await ThumbnailService.shared.invalidate(invalid)
            await SearchIndex.shared.invalidate(invalid)
            await CaptureDateIndex.shared.invalidate(invalid)
            return result
        }
        scanTask = worker
        Task { [weak self] in
            let result = await worker.value
            guard let self, self.scanGeneration == request else { return }
            self.lastRefreshItemCount = result.inspectedItems
            self.lastRefreshWasIncremental = changes != nil && changes?.contains(.rescan) == false
            let sourcesChanged = self.allPhotos != result.photos
            // A save may complete while the background scan is reading. Keep that newer local
            // snapshot, then reconcile its sidecar again instead of rolling the displayed notes back.
            let locallySaved = Set(self.savedNotes.keys).union(snapshot.notes.keys).filter { self.savedNotes[$0] != snapshot.notes[$0] }
            var refreshedNotes = result.notes
            var refreshedErrors = result.noteErrors
            for url in locallySaved {
                refreshedNotes[url] = self.savedNotes[url]
                refreshedErrors[url] = self.noteErrors[url]
            }
            let notesChanged = self.savedNotes != refreshedNotes || self.noteErrors != refreshedErrors
            let directoriesChanged = self.knownDirectories != Set(result.directories)
            let changed = !preservingContent || sourcesChanged || notesChanged || directoriesChanged
            if sourcesChanged || !preservingContent {
                self.generation = UUID()
                self.sortTask?.cancel()
                self.isSorting = false
                let current = Set(result.photos)
                let unchanged = Set(previous.filter { current.contains($0) }.map(\.id))
                self.captureDates = self.captureDates.filter { unchanged.contains($0.key) }
                self.datedPhotos.formIntersection(unchanged)
                self.allPhotos = result.photos
            }
            if notesChanged || !preservingContent {
                self.savedNotes = refreshedNotes
                self.noteErrors = refreshedErrors
            }
            if directoriesChanged || !preservingContent {
                self.knownDirectories = Set(result.directories)
                self.folderTree = PhotoFolder.tree(root: url, directories: result.directories)
            }
            if let selected = self.selectedFolder,
               selected.resolvingSymlinksInPath().path != url.resolvingSymlinksInPath().path {
                if let found = result.directories.first(where: { $0.resolvingSymlinksInPath().path == selected.resolvingSymlinksInPath().path }) {
                    self.selectedFolder = found
                } else {
                    self.selectedFolder = url
                    self.sessionNotice = "The folder “\(selected.lastPathComponent)” is missing or was moved. Showing the top library folder. Pending changes are kept."
                }
            }
            self.unreadableItems = result.unreadableItems
            self.isScanning = false
            self.isRefreshing = false
            if changed { self.applyFilter(preferredPhoto: preservingContent ? self.selection.id : photo) }
            if !preservingContent { self.restorePendingNotes() }
            self.restoreWorkspaceIfReady()
            self.resumeWaitingSaves()
            self.saveSession()
            self.scanTask = nil
            if self.sortOrder == .captureDate && (sourcesChanged || !preservingContent) { self.prepareCaptureDates() }
            if !locallySaved.isEmpty {
                self.queueAutomaticRefresh(locallySaved.map { .file(NotesStore.sidecar(for: $0)) })
            } else if self.refreshPending {
                self.refreshPending = false
                self.queueAutomaticRefresh()
            }
        }
    }
}

extension LibraryModel {
    func discardDraft(for photo: URL) {
        noteDrafts.removeValue(forKey: photo)
        draftBases.removeValue(forKey: photo)
        automaticDraftIDs.remove(photo)
        waitingForPhotos.remove(photo)
        retryOnReconnect.remove(photo)
        noteSaveErrors.removeValue(forKey: photo)
        persistPendingNotes()
    }

    func authorizeOrganizing(_ url: URL) throws {
        guard let root, url.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path else { throw NotesError.invalid }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        writeBookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        writeAccessURL = url
        needsWriteAccessRepair = false
        saveSession()
    }

    func ensureWriteAccess(_ completion: @escaping (Bool) -> Void) {
        if canOrganize && !needsWriteAccessRepair { completion(true); return }
        guard let root, !libraryUnavailable else { completion(false); return }
        writeAccessCallbacks.append(completion)
        guard !requestingWriteAccess else { return }
        requestingWriteAccess = true
        let panel = NSOpenPanel()
        panel.title = "Choose Your Photo Folder"
        panel.message = "macOS needs access to save your ratings, keywords and captions beside your photos. Select “\(root.lastPathComponent)” once. Original photo files won’t be rewritten."
        panel.directoryURL = root
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use Folder"
        panel.begin { [weak self] response in
            guard let self else { return }
            var allowed = false
            if response == .OK, let url = panel.url, self.root?.path == root.path {
                do { try self.authorizeOrganizing(url); allowed = true }
                catch { self.operationError = error.localizedDescription }
            }
            self.requestingWriteAccess = false
            self.writeAccessDeclined = !allowed
            let callbacks = self.writeAccessCallbacks
            self.writeAccessCallbacks = []
            for callback in callbacks { callback(allowed) }
        }
    }

    func editNotes(_ notes: PhotoNotes, for photo: URL) {
        applyNoteEdits([photo: notes], action: "Photo Notes")
    }

    private func queueNoteEdit(_ notes: PhotoNotes, for photo: URL) {
        updateDraft(notes, for: photo)
        if noteDrafts[photo] != nil { automaticDraftIDs.insert(photo) }
        persistPendingNotes()
        scheduleAutomaticSave(for: photo)
    }

    func retryAutomaticSave(for photo: URL) {
        retryAutomaticSaves(for: [photo])
    }

    func retryAutomaticSaves(for photos: Set<URL>) {
        guard let root, !libraryUnavailable else { return }
        let operationRoot = root.path
        writeAccessDeclined = false
        let retry: (Bool) -> Void = { [weak self] allowed in
            guard allowed, let self, self.root?.path == operationRoot else { return }
            // Repair is library-wide: retry retained failed drafts in any subfolder.
            let targets = photos.union(self.noteSaveErrors.keys)
            for url in targets where SessionPaths.relative(url, to: root) != nil {
                self.noteSaveErrors.removeValue(forKey: url)
                self.scheduleAutomaticSave(for: url)
            }
        }
        if needsWriteAccessRepair || !canOrganize { ensureWriteAccess(retry) }
        else { retry(true) }
    }

    private func scheduleAutomaticSave(for photo: URL) {
        autoSaveTasks[photo]?.cancel()
        guard noteSaveErrors[photo] == nil, noteDrafts[photo] != nil, !libraryUnavailable else { return }
        guard allPhotos.contains(where: { $0.id == photo }) else { waitingForPhotos.insert(photo); return }
        let editRoot = root?.path
        autoSaveTasks[photo] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            guard let self, self.root?.path == editRoot else { return }
            while self.savingNoteIDs.contains(photo) {
                do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
            }
            guard !Task.isCancelled, self.root?.path == editRoot, self.noteDrafts[photo] != nil,
                  self.noteSaveErrors[photo] == nil else { return }
            if self.needsWriteAccessRepair {
                self.noteSaveErrors[photo] = "Not saved. Reconnect access to the top photo folder once; your changes are kept."
            } else if self.canOrganize { self.saveNotes(for: photo, automatically: true) }
            else if !self.writeAccessDeclined {
                self.ensureWriteAccess { [weak self] allowed in
                    guard let self, self.root?.path == editRoot else { return }
                    if allowed { self.saveNotes(for: photo, automatically: true) }
                    else { self.noteSaveErrors[photo] = "Changes aren’t saved yet. Retry Saving and choose the photo folder when macOS asks." }
                }
            } else { self.noteSaveErrors[photo] = "Changes aren’t saved yet. Retry Saving to choose the photo folder." }
            self.autoSaveTasks[photo] = nil
        }
    }

    func saveNotes(for photo: URL, automatically: Bool = false) {
        guard let access = writeAccessURL, !libraryUnavailable, let root, !savingNoteIDs.contains(photo),
              let draft = noteDrafts[photo], noteErrors[photo] == nil else { return }
        let revision = draftBases[photo]?.revision
        savingNoteIDs.insert(photo)
        Task { [weak self] in
            do {
                let snapshot = try await NotesStore.shared.save(draft, photo: photo, access: access, expected: revision)
                guard let self else { return }
                self.savingNoteIDs.remove(photo)
                guard self.root?.path == root.path else { return }
                self.savedNotes[photo] = snapshot
                if self.noteDrafts[photo] == draft { self.discardDraft(for: photo) }
                else { self.draftBases[photo] = snapshot }
                self.noteSaveErrors.removeValue(forKey: photo)
                self.applyFilter()
                if automatically && self.noteDrafts[photo] != nil { self.scheduleAutomaticSave(for: photo) }
            } catch {
                self?.savingNoteIDs.remove(photo)
                guard let self, self.root?.path == root.path else { return }
                if self.libraryUnavailable {
                    self.retryOnReconnect.insert(photo)
                    self.noteSaveErrors[photo] = "Waiting for the library to return. Your changes are kept."
                } else if SaveFailure.isMissing(error) || (!SaveFailure.isPermission(error) && !FileManager.default.fileExists(atPath: photo.path)) {
                    self.waitingForPhotos.insert(photo)
                    self.noteSaveErrors[photo] = "The photo is missing. Restore it to its original folder; your changes are kept."
                } else {
                    if SaveFailure.isPermission(error) { self.needsWriteAccessRepair = true }
                    self.noteSaveErrors[photo] = SaveFailure.isPermission(error)
                        ? "Not saved. PixelRoll needs renewed access to the top photo folder; your changes are kept."
                        : error.localizedDescription
                }
                if !automatically { self.operationError = error.localizedDescription }
            }
        }
    }

    func requestRename(_ folder: URL) {
        guard !libraryUnavailable, !isScanning, !isManagingKeywords, savingNoteIDs.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Folder"
        let field = NSTextField(string: folder.lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue
        guard name != folder.lastPathComponent else { return }
        let parent = folder.deletingLastPathComponent()
        if let access = writeAccessURL, SessionPaths.relative(parent, to: access) != nil {
            do { try renameFolder(folder, to: name, parentAccess: access) }
            catch { operationError = error.localizedDescription }
        } else if let access = renameAccessURL, SessionPaths.relative(parent, to: access) != nil {
            do { try renameFolder(folder, to: name, parentAccess: access) }
            catch { operationError = error.localizedDescription }
        } else if let root, SessionPaths.relative(parent, to: root) != nil {
            ensureWriteAccess { [weak self] allowed in
                guard allowed, let self, let access = self.writeAccessURL else { return }
                do { try self.renameFolder(folder, to: name, parentAccess: access) }
                catch { self.operationError = error.localizedDescription }
            }
        } else {
            let panel = NSOpenPanel()
            panel.title = "Choose the Containing Folder"
            panel.message = "macOS needs access to the containing folder to rename this library. Choose “\(parent.lastPathComponent)” once."
            panel.directoryURL = parent
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = "Use Folder"
            panel.begin { [weak self] response in
                guard response == .OK, let access = panel.url, let self else { return }
                do {
                    guard access.resolvingSymlinksInPath().path == parent.resolvingSymlinksInPath().path else { throw FolderRenameError.invalidFolder }
                    let scoped = access.startAccessingSecurityScopedResource()
                    defer { if scoped { access.stopAccessingSecurityScopedResource() } }
                    self.renameBookmark = try access.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                    self.renameAccessURL = access
                    try self.renameFolder(folder, to: name, parentAccess: access)
                } catch { self.operationError = error.localizedDescription }
            }
        }
    }

    func renameFolder(_ folder: URL, to name: String, parentAccess: URL) throws {
        guard let oldRoot = root, savingNoteIDs.isEmpty, !isManagingKeywords,
              SessionPaths.relative(folder.deletingLastPathComponent(), to: parentAccess) != nil else {
            throw FolderRenameError.invalidFolder
        }
        let scoped = parentAccess.startAccessingSecurityScopedResource()
        defer { if scoped { parentAccess.stopAccessingSecurityScopedResource() } }
        let oldJournalKey = oldRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let oldFolder = selectedFolder ?? oldRoot
        let oldSelection = selection
        let oldPhoto = selection.id
        let newFolder = try FolderRenamer.rename(folder, to: name, library: oldRoot)
        if newFolder.path == folder.path { return }
        watcher = nil
        automaticRefreshTask?.cancel()
        for task in autoSaveTasks.values { task.cancel() }
        autoSaveTasks.removeAll()
        keywordUndo = []; canUndoKeywords = false
        undoManager?.removeAllActions()
        savingSuspended = true
        let newRoot = FolderRenamer.rebase(oldRoot, from: folder, to: newFolder)
        let browsing = FolderRenamer.rebase(oldFolder, from: folder, to: newFolder)
        let selected = oldPhoto.map { FolderRenamer.rebase($0, from: folder, to: newFolder) }
        expandedFolders = Set(expandedFolders.map { FolderRenamer.rebase($0, from: folder, to: newFolder) })
        automaticDraftIDs = Set(automaticDraftIDs.map { FolderRenamer.rebase($0, from: folder, to: newFolder) })
        noteDrafts = Dictionary(uniqueKeysWithValues: noteDrafts.map {
            (FolderRenamer.rebase($0.key, from: folder, to: newFolder), $0.value)
        })
        draftBases = Dictionary(uniqueKeysWithValues: draftBases.map {
            (FolderRenamer.rebase($0.key, from: folder, to: newFolder), $0.value)
        })
        if newRoot.path != oldRoot.path {
            bookmark = try? newRoot.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            writeBookmark = try? newRoot.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            writeAccessURL = writeBookmark == nil ? nil : newRoot
        }
        selection.id = selected
        // All selected photos follow their folder, including a selection spanning siblings.
        let rebased = oldSelection.ids.map { FolderRenamer.rebase($0, from: folder, to: newFolder) }
        for id in rebased where id != selected {
            selection.select(id, in: rebased.map { PhotoFile(url: $0) }, toggling: true)
        }
        savingSuspended = false
        if newRoot.path != oldRoot.path {
            var journals = defaults.dictionary(forKey: "PixelRoll.pendingNotes.v1") as? [String: Data] ?? [:]
            journals.removeValue(forKey: oldJournalKey)
            defaults.set(journals, forKey: "PixelRoll.pendingNotes.v1")
        }
        persistPendingNotes(in: newRoot)
        startWatching(newRoot)
        load(newRoot, folder: browsing, photo: selected)
    }
}

extension LibraryModel {
    var keywordCounts: [(name: String, count: Int)] {
        var names: [String: String] = [:]
        var counts: [String: Int] = [:]
        for snapshot in savedNotes.values {
            var counted = Set<String>()
            for word in snapshot.notes.keywords {
                let key = word.lowercased()
                names[key] = names[key] ?? word
                if counted.insert(key).inserted { counts[key, default: 0] += 1 }
            }
        }
        return counts.map { (name: names[$0.key]!, count: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func manageKeywords(selected: Set<String>, replacement: String?) {
        guard !isManagingKeywords, !isScanning, !libraryUnavailable, !selected.isEmpty else { return }
        guard !noteDrafts.keys.contains(where: { photo in root.flatMap { SessionPaths.relative(photo, to: $0) } != nil }) && savingNoteIDs.isEmpty else {
            keywordNotice = "Wait for photo notes to finish saving, or resolve the unsaved changes first."
            return
        }
        let destination = replacement?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let destination, destination.isEmpty || destination.contains(",") || destination.rangeOfCharacter(from: .newlines) != nil {
            keywordNotice = "Enter one keyword without commas or line breaks."
            return
        }
        let keys = Set(selected.map { $0.lowercased() })
        let changes = savedNotes.compactMap { url, snapshot -> KeywordChange? in
            guard snapshot.notes.keywords.contains(where: { keys.contains($0.lowercased()) }) else { return nil }
            var notes = snapshot.notes
            notes.keywords = KeywordEditing.replacing(notes.keywords, selected: keys, with: destination)
            return KeywordChange(photo: url, notes: notes, expected: snapshot.revision)
        }
        performKeywordChanges(changes, undo: false)
    }

    func undoKeywordChanges() { performKeywordChanges(keywordUndo, undo: true) }

    private func performKeywordChanges(_ changes: [KeywordChange], undo: Bool) {
        guard !changes.isEmpty, !isManagingKeywords, !libraryUnavailable else { return }
        let original = Dictionary(uniqueKeysWithValues: changes.compactMap { change in
            savedNotes[change.photo].map { (change.photo, $0.notes) }
        })
        isManagingKeywords = true
        keywordNotice = "Saving keyword changes…"
        automaticRefreshTask?.cancel()
        let operationRoot = root?.path
        ensureWriteAccess { [weak self] allowed in
            guard let self else { return }
            guard allowed, let access = self.writeAccessURL, self.root?.path == operationRoot else {
                self.isManagingKeywords = false
                self.keywordNotice = "No keywords were changed."
                return
            }
            Task { [weak self] in
                do {
                    let saved = try await NotesStore.shared.changeKeywords(changes, access: access)
                    guard let self else { return }
                    self.savedNotes.merge(saved) { _, new in new }
                    self.keywordUndo = undo ? [] : saved.compactMap { url, snapshot in
                        original[url].map { KeywordChange(photo: url, notes: $0, expected: snapshot.revision) }
                    }
                    self.canUndoKeywords = !self.keywordUndo.isEmpty
                    self.keywordNotice = "Updated keywords on \(saved.count) photos."
                    self.isManagingKeywords = false
                    self.applyFilter()
                    if self.refreshPending { self.refreshPending = false; self.queueAutomaticRefresh() }
                } catch {
                    self?.isManagingKeywords = false
                    self?.keywordNotice = error.localizedDescription
                    self?.refresh()
                }
            }
        }
    }
}

extension LibraryModel {
    private func persistPendingNotes(in library: URL? = nil) {
        guard let root = library ?? root else { return }
        let records = automaticDraftIDs.compactMap { url -> PendingNote? in
            guard let relative = SessionPaths.relative(url, to: root), let notes = noteDrafts[url], let base = draftBases[url] else { return nil }
            return PendingNote(photo: relative, notes: notes, originalNotes: base.notes, originalRevision: base.revision)
        }
        var journals = defaults.dictionary(forKey: "PixelRoll.pendingNotes.v1") as? [String: Data] ?? [:]
        let key = root.resolvingSymlinksInPath().standardizedFileURL.path
        if records.isEmpty { journals.removeValue(forKey: key) }
        else if let data = try? JSONEncoder().encode(records) { journals[key] = data }
        defaults.set(journals, forKey: "PixelRoll.pendingNotes.v1")
    }

    private func restorePendingNotes() {
        guard let root,
              let journals = defaults.dictionary(forKey: "PixelRoll.pendingNotes.v1") as? [String: Data],
              let data = journals[root.resolvingSymlinksInPath().standardizedFileURL.path],
              let records = try? JSONDecoder().decode([PendingNote].self, from: data) else { return }
        let byPath = Dictionary(uniqueKeysWithValues: allPhotos.compactMap { photo in
            SessionPaths.relative(photo.url, to: root).map { ($0, photo.id) }
        })
        for record in records {
            guard let resolved = SessionPaths.resolve(record.photo, within: root) else { continue }
            let url = byPath[record.photo] ?? FolderRenamer.canonicalMissingPath(resolved)
            if noteDrafts[url] == nil {
                noteDrafts[url] = record.notes
                draftBases[url] = NotesSnapshot(notes: record.originalNotes, revision: record.originalRevision)
            }
            automaticDraftIDs.insert(url)
            if byPath[record.photo] == nil { waitingForPhotos.insert(url) }
            else { scheduleAutomaticSave(for: url) }
        }
    }
}


extension LibraryModel {
    var selectedPhotos: [PhotoFile] { photos.filter { selection.ids.contains($0.id) } }
    var canEditSelection: Bool {
        !selection.ids.isEmpty && !libraryUnavailable && !isScanning && !isManagingKeywords &&
        selection.ids.allSatisfy { noteErrors[$0] == nil }
    }

    private func applyNoteEdits(_ edits: [URL: PhotoNotes], action: String) {
        guard !isManagingKeywords, !libraryUnavailable, let root else { return }
        let changes = edits.filter { url, notes in
            SessionPaths.relative(url, to: root) != nil && noteErrors[url] == nil && draft(for: url) != notes
        }
        guard !changes.isEmpty else { return }
        beginUserNavigation()
        let previous = Dictionary(uniqueKeysWithValues: changes.keys.map { ($0, draft(for: $0)) })
        undoManager?.registerUndo(withTarget: self) { model in
            model.applyNoteEdits(previous, action: action)
        }
        undoManager?.setActionName(action)
        for (url, notes) in changes { queueNoteEdit(notes, for: url) }
    }

    func setAdjustments(_ adjustments: PhotoAdjustments, for urls: [URL], action: String = "Adjust Photo") {
        guard adjustments.valid, urls.allSatisfy({ noteErrors[$0] == nil }) else { return }
        let edits = Dictionary(uniqueKeysWithValues: Set(urls).map { url in
            var notes = draft(for: url); notes.adjustments = adjustments
            return (url, notes)
        })
        applyNoteEdits(edits, action: action)
    }

    func rateSelection(_ rating: Int) {
        guard canEditSelection, (0...5).contains(rating) else { return }
        var edits: [URL: PhotoNotes] = [:]
        for photo in selectedPhotos {
            var notes = draft(for: photo.id)
            notes.rating = rating
            if rating > 0 { notes.flag = .none }
            edits[photo.id] = notes
        }
        applyNoteEdits(edits, action: "Rating")
    }

    func rejectSelection(_ rejected: Bool) {
        guard canEditSelection else { return }
        var edits: [URL: PhotoNotes] = [:]
        for photo in selectedPhotos {
            var notes = draft(for: photo.id)
            notes.flag = rejected ? .reject : .none
            if rejected { notes.rating = 0 }
            edits[photo.id] = notes
        }
        applyNoteEdits(edits, action: "Rejection")
    }

    func changeSelectionKeywords(_ words: String, removing: Bool) {
        guard canEditSelection else { return }
        let keywords = KeywordEditing.normalized(words.split(separator: ",").map(String.init))
        guard !keywords.isEmpty else { return }
        let keys = Set(keywords.map { $0.lowercased() })
        var edits: [URL: PhotoNotes] = [:]
        for photo in selectedPhotos {
            var notes = draft(for: photo.id)
            notes.keywords = removing ? notes.keywords.filter { !keys.contains($0.lowercased()) } : KeywordEditing.normalized(notes.keywords + keywords)
            edits[photo.id] = notes
        }
        applyNoteEdits(edits, action: removing ? "Remove Keywords" : "Add Keywords")
    }
}


extension LibraryModel {
    private func relativeForWorkspace(_ url: URL) -> String? {
        let path = url.path
        for base in sessionBases {
            if path == base { return "" }
            if path.hasPrefix(base + "/") { return String(path.dropFirst(base.count + 1)) }
        }
        return nil
    }

    var currentPendingIDs: Set<URL> {
        guard root != nil else { return [] }
        return Set(noteDrafts.keys.filter { relativeForWorkspace($0) != nil })
    }

    var pendingSaveRows: [PendingSaveRow] {
        guard root != nil else { return [] }
        let available = Set(allPhotos.map(\.id))
        return currentPendingIDs.map { url in
            let path = relativeForWorkspace(url) ?? url.lastPathComponent
            let status: String
            if libraryUnavailable { status = "Waiting for the library to return" }
            else if !available.contains(url) { status = "Photo missing · restore it to its original folder" }
            else if savingNoteIDs.contains(url) { status = "Saving…" }
            else if let error = noteErrors[url] ?? noteSaveErrors[url] { status = error }
            else { status = "Waiting to save…" }
            return PendingSaveRow(id: url, path: path, status: status, canShow: !libraryUnavailable && available.contains(url))
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func retryAllPendingSaves() { retryAutomaticSaves(for: currentPendingIDs) }

    func showPendingPhoto(_ url: URL) {
        guard allPhotos.contains(where: { $0.id == url }), !libraryUnavailable else { return }
        notesFilter = NotesFilter()
        selectFolder(url.deletingLastPathComponent())
        selection.id = url
        workspace.showingInformation = true
    }

    func beginUserNavigation() {
        navigationRevision &+= 1
        pendingWorkspace = nil
        shouldFollowSelection = true
    }

    private func restoreWorkspaceIfReady() {
        guard !isScanning, !isSearching, let saved = pendingWorkspace, let root else { return }
        let byPath = Dictionary(uniqueKeysWithValues: photos.compactMap { photo in SessionPaths.relative(photo.id, to: root).map { ($0, photo.id) } })
        let restored = Set(saved.selectedPhotos.compactMap { byPath[$0] })
        let primary = selection.id
        pendingWorkspace = nil
        savingSuspended = true
        if saved.selectedPhotos.isEmpty || !restored.isEmpty { selection.restore(restored, primary: primary, in: photos) }
        scrollAnchor = saved.scrollAnchor.flatMap { byPath[$0] } ?? selection.id
        expandedFolders.formUnion(saved.expandedFolders.compactMap { SessionPaths.resolve($0, within: root) })
        savingSuspended = false
        saveSession()
    }

    private func resumeWaitingSaves() {
        guard !libraryUnavailable else { return }
        let available = Set(allPhotos.map(\.id))
        waitingForPhotos.formUnion(currentPendingIDs.subtracting(available))
        let ready = waitingForPhotos.union(retryOnReconnect).intersection(available).intersection(currentPendingIDs)
        for url in ready {
            waitingForPhotos.remove(url)
            retryOnReconnect.remove(url)
            noteSaveErrors.removeValue(forKey: url)
            scheduleAutomaticSave(for: url)
        }
    }
}


extension LibraryModel {
    func clearPhotoCache() {
        guard !isMaintainingCache else { return }
        isMaintainingCache = true
        cacheProgress = 0
        cacheTotal = 0
        cacheNotice = "Clearing cached thumbnails and metadata…"
        cacheTask = Task { [weak self] in
            let cleared = await Task.detached(priority: .utility) { PhotoDiskCache.shared.clear() }.value
            await ThumbnailService.shared.clearCache()
            await AdjustedThumbnailService.shared.clearMemory()
            await PhotoMetadataIndex.shared.clearMemory()
            guard let self else { return }
            guard !Task.isCancelled else { return }
            self.captureDates.removeAll()
            self.datedPhotos.removeAll()
            self.thumbnailEpoch += 1
            self.isMaintainingCache = false
            self.cacheNotice = cleared ? "Cache cleared. Thumbnails and metadata rebuild as you browse." : "The cache could not be cleared. Your photos and saved notes are unchanged."
            if self.sortOrder == .captureDate { self.prepareCaptureDates() }
        }
    }

    func rebuildLibraryIndex() {
        guard !isMaintainingCache, !libraryUnavailable, !isScanning, let root else { return }
        let files = allPhotos
        let operationRoot = root.path
        sortTask?.cancel()
        isSorting = false
        isMaintainingCache = true
        cacheProgress = 0
        cacheTotal = files.count
        cacheNotice = "Rebuilding this library’s metadata index…"
        cacheTask = Task(priority: .background) { [weak self] in
            let removed = await Task.detached(priority: .background) {
                PhotoDiskCache.shared.removeMetadata(for: files.map(\.id))
            }.value
            guard let self, !Task.isCancelled, self.root?.path == operationRoot else { return }
            guard removed else {
                self.isMaintainingCache = false
                self.cacheNotice = "The metadata cache could not be cleared. Try again later; your photos and notes are unchanged."
                return
            }
            await PhotoMetadataIndex.shared.invalidate(Set(files.map(\.id)))
            self.captureDates.removeAll()
            self.datedPhotos.removeAll()
            for start in stride(from: 0, to: files.count, by: 64) {
                let end = min(start + 64, files.count)
                let dates = await CaptureDateIndex.shared.dates(for: Array(files[start..<end]), root: root)
                guard !Task.isCancelled, self.root?.path == operationRoot else { return }
                self.captureDates.merge(dates) { _, new in new }
                self.datedPhotos.formUnion(files[start..<end].map(\.id))
                self.cacheProgress = end
            }
            if self.sortOrder == .captureDate { self.resort() }
            self.isMaintainingCache = false
            self.cacheNotice = removed ? "Rebuilt metadata for \(files.count) photos." : "Metadata was refreshed, but old disk entries could not all be removed."
        }
    }

    func discardPendingEdits(for url: URL) {
        guard currentPendingIDs.contains(url), !savingNoteIDs.contains(url), let draft = noteDrafts[url], let base = draftBases[url] else { return }
        let automatic = automaticDraftIDs.contains(url)
        let error = noteSaveErrors[url]
        undoManager?.registerUndo(withTarget: self) { model in
            model.undoManager?.registerUndo(withTarget: model) { $0.discardPendingEdits(for: url) }
            model.noteDrafts[url] = draft
            model.draftBases[url] = base
            model.noteSaveErrors[url] = error
            if automatic { model.automaticDraftIDs.insert(url) }
            model.persistPendingNotes()
            if automatic { model.scheduleAutomaticSave(for: url) }
            model.undoManager?.setActionName("Discard Pending Edits")
        }
        undoManager?.setActionName("Discard Pending Edits")
        autoSaveTasks[url]?.cancel()
        discardDraft(for: url)
    }
}
