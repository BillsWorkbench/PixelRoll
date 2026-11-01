import SwiftUI

struct PhotoInfoPanel: View {
    @ObservedObject var library: LibraryModel
    let photo: PhotoFile?
    let root: URL?
    @State private var metadata: PhotoMetadata?
    @State private var loading = false
    @State private var search = ""
    @State private var allExpanded = false

    private var matches: [MetadataField] {
        guard let metadata else { return [] }
        if search.isEmpty { return metadata.allFields }
        return metadata.allFields.filter {
            $0.label.localizedCaseInsensitiveContains(search) || $0.value.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Photo Information").font(.headline).padding()
            Divider()
            if library.selection.ids.count > 1 {
                BatchNotesEditor(library: library)
            } else if let photo {
                Text(photo.url.lastPathComponent)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2).textSelection(.enabled).padding()
                TextField("Search metadata", text: $search)
                    .textFieldStyle(.roundedBorder).padding(.horizontal).padding(.bottom, 12)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        PhotoNotesEditor(library: library, photo: photo).id(photo.id)
                        if loading {
                            ProgressView("Reading metadata…")
                        } else if let metadata {
                            if let notice = metadata.notice {
                                Text(notice).font(.callout).foregroundStyle(.secondary)
                            }
                            if search.isEmpty {
                                ForEach(metadata.sections) { section in
                                    MetadataSectionView(section: section)
                                }
                            }
                            DisclosureGroup(isExpanded: Binding(
                                get: { !search.isEmpty || allExpanded },
                                set: { allExpanded = $0 }
                            )) {
                                if matches.isEmpty {
                                    Text("No matching metadata.").foregroundStyle(.secondary).padding(.top, 8)
                                } else {
                                    LazyVStack(alignment: .leading, spacing: 12) {
                                        ForEach(matches) { field in MetadataFieldView(field: field) }
                                    }
                                    .padding(.top, 8)
                                }
                            } label: {
                                Text(search.isEmpty ? "All Metadata (\(matches.count))" : "Search Results (\(matches.count))")
                                    .font(.subheadline.weight(.semibold))
                            }
                            Divider()
                            Text("Original metadata · Read-only")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("No Photo Selected", systemImage: "info.circle",
                                       description: Text("Select a photo to see its information."))
            }
        }
        .task(id: photo) {
            metadata = nil
            guard let photo, let root else { loading = false; return }
            loading = true
            let result = await MetadataService.shared.read(photo.url, root: root)
            guard !Task.isCancelled else { return }
            metadata = result
            loading = false
        }
    }
}

private struct MetadataSectionView: View {
    let section: MetadataSection
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if section.fields.isEmpty {
                Text("Unavailable").font(.callout).foregroundStyle(.secondary).padding(.top, 8)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(section.fields) { field in MetadataFieldView(field: field) }
                }
                .padding(.top, 8)
            }
        } label: {
            Text(section.title).font(.subheadline.weight(.semibold))
        }
    }
}

private struct MetadataFieldView: View {
    let field: MetadataField

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(field.label).font(.caption).foregroundStyle(.secondary)
            Text(field.value).font(.callout).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
