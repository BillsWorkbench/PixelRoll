import SwiftUI

struct PhotoNotesEditor: View {
    @ObservedObject var library: LibraryModel
    let photo: PhotoFile
    @State private var keywords: String
    @State private var caption: String

    init(library: LibraryModel, photo: PhotoFile) {
        self.library = library
        self.photo = photo
        let notes = library.draft(for: photo.id)
        _keywords = State(initialValue: notes.keywords.joined(separator: ", "))
        _caption = State(initialValue: notes.caption)
    }

    private var draft: PhotoNotes { library.draft(for: photo.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PixelRoll Notes").font(.headline)
            if let error = library.noteErrors[photo.id] {
                Text(error).font(.caption).foregroundStyle(.red)
                Button("Refresh Sidecar", action: library.refresh)
            } else {
                StarRatingControl(
                    rating: Binding(get: { draft.rating }, set: { value in update { $0.rating = value; if value > 0 { $0.flag = .none } } }),
                    rejected: Binding(get: { draft.isRejected }, set: { value in update { $0.flag = value ? .reject : .none; if value { $0.rating = 0 } } })
                )
                TextField("Keywords, separated by commas", text: $keywords)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: keywords) { _, text in
                        var seen = Set<String>()
                        let words = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
                        update { $0.keywords = words }
                    }
                Text("Caption").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $caption).font(.callout).frame(minHeight: 65, maxHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                    .accessibilityLabel("PixelRoll Caption")
                    .onChange(of: caption) { _, text in update { $0.caption = text } }
                if let error = library.noteSaveErrors[photo.id] {
                    Text(error).font(.caption).foregroundStyle(.red)
                    Button("Retry Saving") { library.retryAutomaticSave(for: photo.id) }
                }
                Text(library.noteSaveErrors[photo.id] != nil ? "Not saved · your changes are kept for retry" : library.noteDrafts[photo.id] == nil ? "Saved automatically beside the photo · original unchanged" : "Saving your changes…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: draft) { _, notes in
            // Undo can return to the saved notes before a sidecar write occurs.
            // Keep editable fields synchronized without disturbing partially typed separators.
            let displayed = KeywordEditing.normalized(keywords.split(separator: ",").map(String.init))
            if displayed != notes.keywords { keywords = notes.keywords.joined(separator: ", ") }
            if caption != notes.caption { caption = notes.caption }
        }
        .padding()
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func update(_ change: (inout PhotoNotes) -> Void) {
        var notes = draft
        change(&notes)
        library.editNotes(notes, for: photo.id)
    }
}
