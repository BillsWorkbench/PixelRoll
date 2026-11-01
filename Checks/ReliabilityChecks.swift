import Foundation
import Combine

@MainActor enum ReliabilityChecks {
    static func run(base: URL, imageData: Data) async throws {
        let fm = FileManager.default
        let outsideToken = "OutsideScope-" + UUID().uuidString
        let root = base.appendingPathComponent(outsideToken).appendingPathComponent("Library")
        let group = root.appendingPathComponent("Travel")
        try fm.createDirectory(at: group, withIntermediateDirectories: true)
        for number in 0..<130 {
            try imageData.write(to: group.appendingPathComponent(String(format: "Photo-%03d.jpg", number)))
        }
        let suite = "PixelRoll.reliability.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LibraryModel(defaults: defaults)
        func eventually(_ message: String, _ condition: () -> Bool) async throws {
            for _ in 0..<800 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            preconditionFailure(message)
        }
        model.open(root)
        try await eventually("Initial scan did not finish") { !model.isScanning }
        model.searchQuery = outsideToken
        try await eventually("Search did not finish") { !model.isSearching }
        precondition(model.photos.isEmpty, "A directory outside the library must not make every photo match")
        model.searchQuery = "Travel Photo-010"
        try await eventually("Relative path search did not finish") { !model.isSearching }
        precondition(model.photos.count == 1 && model.photos[0].url.lastPathComponent == "Photo-010.jpg")
        print("PASS: library search excludes ancestor-directory names and still matches paths inside the library")

        model.searchQuery = "Canon"
        try await eventually("Metadata search did not finish") { !model.isSearching }
        precondition(model.photos.count == 130)
        let previous = model.photos[0].id
        model.selection.id = previous
        let current = try NotesStore.read(previous)
        _ = try await NotesStore.shared.save(PhotoNotes(rating: 4), photo: previous, access: root, expected: current.revision)
        var didNavigate = false
        var expected: URL?
        let observation = model.$searchedCount.sink { count in
            // The second result batch arrives after the first 64 photos are already visible.
            guard count == 128, !didNavigate, let target = model.photos.first(where: { $0.url.lastPathComponent == "Photo-010.jpg" }) else { return }
            didNavigate = true
            expected = target.id
            model.beginUserNavigation()
            model.selection.id = target.id
        }
        model.refresh()
        try await eventually("Refresh search did not finish") { !model.isScanning && !model.isSearching }
        observation.cancel()
        precondition(didNavigate && model.selection.id == expected, "Later search batches must not replace a newer user selection")
        print("PASS: progressive search preserves a user selection made after refresh began")
    }
}
