import SwiftUI

struct LibraryFilterBar: View {
    @ObservedObject var library: LibraryModel
    @Binding var editingKeyword: Bool
    @FocusState private var keywordFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("Minimum").font(.caption).foregroundStyle(.secondary).fixedSize()
            StarRatingControl(rating: $library.notesFilter.minimumRating,
                              rejected: $library.notesFilter.rejectedOnly, compact: true).fixedSize()
            Picker("Format", selection: $library.notesFilter.format) {
                ForEach(PhotoFormatFilter.allCases) { format in Text(format.title).tag(format) }
            }.labelsHidden().frame(width: 120).accessibilityLabel("Format")
            TextField("Filter keywords", text: $library.notesFilter.keyword)
                .textFieldStyle(.roundedBorder).frame(minWidth: 90, maxWidth: .infinity)
                .focused($keywordFocused)
                .onChange(of: keywordFocused) { _, focused in editingKeyword = focused }
            Button("Clear Filters") { library.notesFilter = NotesFilter() }
                .disabled(!library.notesFilter.active).fixedSize()
        }
        .font(.callout).frame(height: 30)
        .disabled(library.libraryUnavailable || library.isScanning)
    }
}
