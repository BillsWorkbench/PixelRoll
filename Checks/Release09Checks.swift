import Foundation

@MainActor enum Release09Checks {
    static func run(base: URL, imageData: Data) async throws {
        let fm = FileManager.default
        func eventually(_ message: String, _ condition: () -> Bool) async throws {
            for _ in 0..<800 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            preconditionFailure(message)
        }
        func ready(_ model: LibraryModel) async throws {
            try await eventually("Workspace did not finish loading") { !model.isScanning && !model.isSearching && !model.isRestoringWorkspace }
        }
        let key = "PixelRoll.librarySession.v1"
        let root = base.appendingPathComponent("WorkspaceLibrary")
        let group = root.appendingPathComponent("Group")
        try fm.createDirectory(at: group, withIntermediateDirectories: true)
        for n in 1...3 {
            let url = group.appendingPathComponent("Photo-\(n).jpg")
            try imageData.write(to: url)
            _ = try await NotesStore.shared.save(PhotoNotes(rating: 3, keywords: ["Review"]), photo: url, access: root, expected: nil)
        }
        let suite = "PixelRoll.workspace-check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LibraryModel(defaults: defaults)
        model.open(root)
        try await ready(model)
        model.selectFolder(model.folderTree!.children![0].url)
        model.notesFilter.minimumRating = 2
        model.notesFilter.keyword = "Review"
        model.notesFilter.format = .jpeg
        model.searchQuery = "Canon"
        try await ready(model)
        precondition(model.photos.count == 3)
        let files = model.photos
        model.selection.select(files[0].id, in: files)
        model.selection.select(files[2].id, in: files, toggling: true)
        model.workspace.showingInformation = false
        model.workspace.showingFilters = false
        model.workspace.showingSearch = true
        model.workspace.sidebarVisible = false
        model.scrollAnchor = files[1].id
        let savedData = defaults.data(forKey: key)!
        let saved = try JSONDecoder().decode(LibrarySession.self, from: savedData)
        precondition(saved.workspace?.selectedPhotos.count == 2 && saved.workspace?.scrollAnchor == "Group/Photo-2.jpg")
        let restored = LibraryModel(defaults: defaults)
        restored.restoreSession()
        try await ready(restored)
        precondition(restored.selection.ids.count == 2 && restored.selection.id?.lastPathComponent == "Photo-3.jpg")
        precondition(restored.scrollAnchor?.lastPathComponent == "Photo-2.jpg")
        precondition(!restored.workspace.showingInformation && !restored.workspace.showingFilters && !restored.workspace.sidebarVisible)
        precondition(restored.workspace.showingSearch && restored.notesFilter.minimumRating == 2 && restored.notesFilter.keyword == "Review")
        // Old session data still opens without workspace fields.
        var legacy = saved
        legacy.workspace = nil
        let legacySuite = "PixelRoll.legacy-check.\(UUID().uuidString)"
        let legacyDefaults = UserDefaults(suiteName: legacySuite)!
        defer { legacyDefaults.removePersistentDomain(forName: legacySuite) }
        legacyDefaults.set(try JSONEncoder().encode(legacy), forKey: key)
        let legacyModel = LibraryModel(defaults: legacyDefaults)
        legacyModel.restoreSession()
        try await ready(legacyModel)
        precondition(legacyModel.workspace.showingInformation && !legacyModel.notesFilter.active)
        // A stale scroll target and a removed selected photo fall back safely.
        let staleSuite = "PixelRoll.stale-workspace.\(UUID().uuidString)"
        let staleDefaults = UserDefaults(suiteName: staleSuite)!
        defer { staleDefaults.removePersistentDomain(forName: staleSuite) }
        staleDefaults.set(savedData, forKey: key)
        try fm.removeItem(at: files[1].url)
        try fm.removeItem(at: files[2].url)
        let stale = LibraryModel(defaults: staleDefaults)
        stale.restoreSession()
        try await ready(stale)
        precondition(stale.selection.ids.count == 1 && stale.scrollAnchor == stale.selection.id)
        print("PASS: workspace restores multi-selection, independent scroll anchor, filters, search, panels and sidebar; legacy and missing targets are safe")

        let recoveryRoot = base.appendingPathComponent("PendingRecovery")
        try fm.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        let missing = recoveryRoot.appendingPathComponent("Missing.jpg")
        let existing = recoveryRoot.appendingPathComponent("Existing.jpg")
        try imageData.write(to: missing)
        try imageData.write(to: existing)
        let recoverySuite = "PixelRoll.missing-pending.\(UUID().uuidString)"
        let recoveryDefaults = UserDefaults(suiteName: recoverySuite)!
        defer { recoveryDefaults.removePersistentDomain(forName: recoverySuite) }
        let original = LibraryModel(defaults: recoveryDefaults)
        original.open(recoveryRoot)
        try await ready(original)
        let originalMissingID = original.photos.first { $0.url.lastPathComponent == "Missing.jpg" }!.id
        original.editNotes(PhotoNotes(rating: 5), for: originalMissingID)
        try fm.removeItem(at: missing)
        let recovered = LibraryModel(defaults: recoveryDefaults)
        recovered.restoreSession()
        try await ready(recovered)
        precondition(recovered.currentPendingIDs.count == 1 && recovered.pendingSaveRows[0].status.contains("missing"))
        let draftUndo = UndoManager()
        draftUndo.groupsByEvent = false
        recovered.undoManager = draftUndo
        let missingDraftID = recovered.currentPendingIDs.first!
        draftUndo.beginUndoGrouping()
        recovered.discardPendingEdits(for: missingDraftID)
        draftUndo.endUndoGrouping()
        precondition(recovered.currentPendingIDs.isEmpty)
        draftUndo.undo()
        precondition(recovered.currentPendingIDs.count == 1 && recovered.draft(for: missingDraftID).rating == 5)
        recovered.undoManager = nil
        let existingID = recovered.photos.first { $0.url.lastPathComponent == "Existing.jpg" }!.id
        recovered.editNotes(PhotoNotes(rating: 2), for: existingID)
        try await eventually("Existing pending photo didn't save") { recovered.noteDrafts[existingID] == nil && recovered.notes(for: existingID).rating == 2 }
        let journals = recoveryDefaults.dictionary(forKey: "PixelRoll.pendingNotes.v1") as! [String: Data]
        let journalKey = recoveryRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let retained = try JSONDecoder().decode([PendingNote].self, from: journals[journalKey]!)
        precondition(retained.contains { $0.photo == "Missing.jpg" && $0.notes.rating == 5 })
        try imageData.write(to: missing)
        try await eventually("Restored photo didn't recover its pending rating") {
            recovered.currentPendingIDs.isEmpty && recovered.photos.contains { $0.url.lastPathComponent == "Missing.jpg" && recovered.notes(for: $0.id).rating == 5 }
        }
        // Pending edits wait while the library is disconnected, then resume automatically.
        recovered.editNotes(PhotoNotes(rating: 4), for: existingID)
        let parked = base.appendingPathComponent("ParkedPendingLibrary")
        try fm.moveItem(at: recoveryRoot, to: parked)
        recovered.checkAvailability()
        precondition(recovered.libraryUnavailable && !recovered.pendingSaveRows.isEmpty)
        precondition(recovered.pendingSaveRows.allSatisfy { $0.status.contains("library") })
        try fm.moveItem(at: parked, to: recoveryRoot)
        recovered.checkAvailability()
        try await eventually("Reconnect didn't resume pending notes") { !recovered.libraryUnavailable && recovered.currentPendingIDs.isEmpty && recovered.notes(for: existingID).rating == 4 }
        print("PASS: missing-photo drafts remain in the journal while other photos save, reappearing photos recover edits, disconnected libraries resume saves")

        // A bookmark resolution failure keeps enough location information for an offline status window.
        var offlineSession = saved
        offlineSession.libraryPath = base.appendingPathComponent("OfflineLibrary").path
        offlineSession.workspace = LibraryWorkspace()
        let offlineSuite = "PixelRoll.offline-bookmark.\(UUID().uuidString)"
        let offlineDefaults = UserDefaults(suiteName: offlineSuite)!
        defer { offlineDefaults.removePersistentDomain(forName: offlineSuite) }
        var offlineObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(offlineSession)) as! [String: Any]
        offlineObject["bookmark"] = Data("invalid bookmark".utf8).base64EncodedString()
        offlineDefaults.set(try JSONSerialization.data(withJSONObject: offlineObject), forKey: key)
        let offline = LibraryModel(defaults: offlineDefaults)
        offline.restoreSession()
        precondition(offline.root?.lastPathComponent == "OfflineLibrary" && offline.libraryUnavailable)

        let maintenance = PhotoDiskCache(directory: base.appendingPathComponent("MaintenanceCache"))
        let fingerprint = PhotoFingerprint.read(existing)!
        let firstKey = PhotoDiskCache.key(for: existing)
        let secondKey = PhotoDiskCache.key(for: missing)
        maintenance.write(Data("thumb".utf8), kind: .thumbnail, key: firstKey, fingerprint: fingerprint)
        maintenance.write(Data("metadata".utf8), kind: .metadata, key: firstKey, fingerprint: fingerprint)
        maintenance.write(Data("other metadata".utf8), kind: .metadata, key: secondKey, fingerprint: fingerprint)
        let before = maintenance.usage()
        precondition(before.available && before.thumbnails == 1 && before.metadata == 2 && before.bytes > 0)
        precondition(maintenance.removeMetadata(for: [existing]))
        precondition(maintenance.usage().thumbnails == 1 && maintenance.usage().metadata == 1)
        precondition(maintenance.clear() && maintenance.usage().thumbnails == 0 && maintenance.usage().metadata == 0)
        recovered.rebuildLibraryIndex()
        try await eventually("Index rebuild didn't finish") { !recovered.isMaintainingCache }
        precondition(recovered.cacheProgress == recovered.photos.count)
        let currentEpoch = recovered.thumbnailEpoch
        recovered.clearPhotoCache()
        try await eventually("Cache clear didn't finish") { !recovered.isMaintainingCache }
        precondition(recovered.thumbnailEpoch == currentEpoch + 1)
        let originalAfterMaintenance = try Data(contentsOf: existing)
        precondition(originalAfterMaintenance == imageData)
        print("PASS: offline location fallback, cache usage, scoped index removal, cache clear/rebuild and original-byte preservation")
    }
}
