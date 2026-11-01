import SwiftUI
import AppKit
import Combine

@MainActor final class ExportController: ObservableObject {
    @Published var options = ExportOptions()
    @Published var busy = false
    @Published var stopping = false
    @Published var completed = 0
    @Published var total = 0
    @Published var saved = 0
    @Published var skipped = 0
    @Published var currentName = ""
    @Published var message: String?
    @Published var failures: [String] = []
    @Published var destination: URL?
    private var task: Task<Void, Never>?

    func chooseDestination(library: LibraryModel) {
        guard !busy, options.valid, let root = library.root, !library.libraryUnavailable else { return }
        let selected = library.photos.filter { library.selection.ids.contains($0.id) }
        guard !selected.contains(where: { library.noteErrors[$0.id] != nil }) else {
            message = "Resolve the selected photos’ sidecar errors in Library before exporting."; return
        }
        let items = selected.map { ExportPhoto(photo: $0, notes: library.draft(for: $0.id)) }
        guard !items.isEmpty else { return }
        let chosenOptions = options
        let panel = NSOpenPanel()
        panel.title = "Choose Export Folder"; panel.prompt = "Export Here"
        panel.message = "Choose where to save \(items.count) exported \(items.count == 1 ? "photo" : "photos"). Existing files are kept."
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false; panel.directoryURL = destination
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.start(items: items, root: root, destination: url, options: chosenOptions)
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }
    func start(items: [ExportPhoto], root: URL, destination: URL, options: ExportOptions) {
        guard !busy, !items.isEmpty else { return }
        self.destination = destination; busy = true; stopping = false; completed = 0; total = items.count
        saved = 0; skipped = 0; failures = []; message = nil
        task = Task {
            let exporter = PhotoExporter()
            for item in items {
                if Task.isCancelled { break }
                currentName = item.photo.url.lastPathComponent
                do {
                    let result = try await exporter.export(item, root: root, destination: destination, options: options)
                    switch result { case .saved: saved += 1; case .skipped: skipped += 1 }
                    completed += 1
                } catch is CancellationError { break }
                catch { failures.append("\(item.photo.url.lastPathComponent): \(error.localizedDescription)"); completed += 1 }
            }
            message = "\(Task.isCancelled ? "Export cancelled" : "Export finished"): \(saved) saved, \(skipped) skipped, \(failures.count) failed."
            currentName = ""; busy = false; stopping = false; task = nil
        }
    }
    func cancel() { guard busy else { return }; stopping = true; task?.cancel() }
    func revealDestination() { if let destination { NSWorkspace.shared.open(destination) } }
}
