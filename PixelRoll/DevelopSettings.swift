import SwiftUI
import Combine

@MainActor final class DevelopSettings: ObservableObject {
    @Published var presets: [DevelopPreset] = []
    @Published var interacting = false
    @Published var pickingGray = false
    @Published var before = false
    @Published var cropDraft: PhotoCrop?
    @Published var presetPhoto: URL?
    @Published var busy = false
    @Published var error: String?
    private var root: URL?
    private var revision: Data?
    private var readable = false

    func load(root: URL?) async {
        self.root = root; presets = []; revision = nil; readable = false
        guard let root else { return }
        do {
            let snapshot = try await PresetStore.shared.read(root: root)
            guard self.root == root else { return }
            presets = snapshot.presets; revision = snapshot.revision; readable = true
        } catch { self.error = "Presets couldn’t be loaded: \(error.localizedDescription)" }
    }
    func save(name: String, settings: PhotoAdjustments, updating id: UUID? = nil) async -> UUID? {
        guard !busy, readable, let root else { error = "Reopen the library to reload presets before saving."; return nil }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { error = "Enter a preset name."; return nil }
        guard !presets.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { error = "A preset with this name already exists."; return nil }
        busy = true; defer { busy = false }
        var presets = self.presets
        var values = settings; values.presetID = nil
        let preset = DevelopPreset(id: id ?? UUID(), name: name, adjustments: values)
        if let index = presets.firstIndex(where: { $0.id == preset.id }) { presets[index] = preset } else { presets.append(preset) }
        do {
            let snapshot = try await PresetStore.shared.save(presets, root: root, expected: revision)
            guard self.root == root else { return nil }
            self.presets = snapshot.presets; revision = snapshot.revision
            return preset.id
        } catch { self.error = "Preset wasn’t saved: \(error.localizedDescription)"; return nil }
    }
}

struct SavePresetSheet: View {
    @ObservedObject var library: LibraryModel
    let photo: URL
    @EnvironmentObject private var settings: DevelopSettings
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save New Preset").font(.headline)
            TextField("Preset name", text: $name).textFieldStyle(.roundedBorder)
            Text("Saved in this photo library. Ratings, keywords and captions are excluded.").font(.caption).foregroundStyle(.secondary)
            if let error = settings.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer(); Button("Cancel") { dismiss() }
                Button("Save") {
                    let original = library.draft(for: photo).adjustments
                    Task {
                        if let id = await settings.save(name: name, settings: original) {
                            if library.draft(for: photo).adjustments == original {
                                var edited = original; edited.presetID = id
                                library.setAdjustments(edited, for: [photo], action: "Save Preset")
                            }
                            dismiss()
                        }
                    }
                }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || settings.busy)
            }
        }.padding(24).frame(width: 360)
    }
}

@MainActor final class AdjustmentClipboard: ObservableObject {
    static let shared = AdjustmentClipboard()
    @Published var values: PhotoAdjustments?
}
