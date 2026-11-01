import SwiftUI

struct BatchNotesEditor: View {
    @ObservedObject var library: LibraryModel
    @State private var keywords = ""
    private var ratings: Set<Int> { Set(library.selectedPhotos.map { library.draft(for: $0.id).rating }) }
    private var allRejected: Bool { library.selectedPhotos.allSatisfy { library.draft(for: $0.id).isRejected } }
    private var errors: [String] {
        library.selectedPhotos.compactMap { photo in
            (library.noteErrors[photo.id] ?? library.noteSaveErrors[photo.id]).map { "\(photo.url.lastPathComponent): \($0)" }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(library.selection.ids.count) photos selected").font(.headline)
                Text("Changes apply to every selected photo.").font(.callout).foregroundStyle(.secondary)
                StarRatingControl(
                    rating: Binding(get: { ratings.count == 1 ? ratings.first! : 0 }, set: { library.rateSelection($0) }),
                    rejected: Binding(get: { allRejected }, set: { library.rejectSelection($0) })
                ).disabled(!library.canEditSelection)
                if ratings.count > 1 { Text("Mixed ratings").font(.caption).foregroundStyle(.secondary) }
                Text("Keywords").font(.headline)
                TextField("Keywords, separated by commas", text: $keywords).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Add Keywords") { library.changeSelectionKeywords(keywords, removing: false); keywords = "" }
                    Button("Remove Keywords") { library.changeSelectionKeywords(keywords, removing: true); keywords = "" }
                }.disabled(!library.canEditSelection || KeywordEditing.normalized(keywords.split(separator: ",").map(String.init)).isEmpty)
                Text("Other keywords and captions stay unchanged.").font(.caption).foregroundStyle(.secondary)
                Divider()
                ForEach(errors, id: \.self) { error in Text(error).font(.caption).foregroundStyle(.red) }
                if !errors.isEmpty {
                    Button("Retry Saving") {
                        library.retryAutomaticSaves(for: library.selection.ids)
                    }
                }
                Text(!errors.isEmpty ? "Not saved · your changes are kept for retry" : library.selectedPhotos.contains { library.noteDrafts[$0.id] != nil } ? "Saving your changes…" : "Saved automatically beside each photo · originals unchanged")
                    .font(.caption).foregroundStyle(.secondary)
                Text("0–5: rating · X: reject\nCommand-Z: undo · Shift-Command-Z: redo")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
