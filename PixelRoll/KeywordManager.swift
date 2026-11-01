import SwiftUI

struct KeywordManager: View {
    @ObservedObject var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<String>()
    @State private var query = ""
    @State private var destination = ""

    private var keywords: [(name: String, count: Int)] {
        library.keywordCounts.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Keyword Manager").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.disabled(library.isManagingKeywords)
            }
            Text("Changes apply to saved PixelRoll keywords across the opened library. Embedded photo keywords stay unchanged.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Find a keyword", text: $query).textFieldStyle(.roundedBorder)
            List(selection: $selection) {
                ForEach(keywords, id: \.name) { keyword in
                    HStack {
                        Text(keyword.name)
                        Spacer()
                        Text("\(keyword.count) photos").foregroundStyle(.secondary)
                    }
                    .tag(keyword.name.lowercased())
                }
            }
            .overlay {
                if keywords.isEmpty { Text("No saved PixelRoll keywords found.").foregroundStyle(.secondary) }
            }
            Text("\(selection.count) selected · Command-click to select multiple keywords for merging.").font(.caption).foregroundStyle(.secondary)
            TextField("New name or merged keyword", text: $destination).textFieldStyle(.roundedBorder)
            HStack {
                Button("Rename") { library.manageKeywords(selected: selection, replacement: destination); selection = [] }
                    .disabled(selection.count != 1 || destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Merge") { library.manageKeywords(selected: selection, replacement: destination); selection = [] }
                    .disabled(selection.count < 2 || destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Delete", role: .destructive) { library.manageKeywords(selected: selection, replacement: nil); selection = [] }
                    .disabled(selection.isEmpty)
                Spacer()
                Button("Undo Last Change", action: library.undoKeywordChanges).disabled(!library.canUndoKeywords)
            }
            .disabled(library.isManagingKeywords || library.isScanning)
            if library.isManagingKeywords { ProgressView().controlSize(.small) }
            if let notice = library.keywordNotice { Text(notice).font(.callout).foregroundStyle(.secondary) }
        }
        .padding(24).frame(width: 600, height: 540)
        .interactiveDismissDisabled(library.isManagingKeywords)
    }
}
