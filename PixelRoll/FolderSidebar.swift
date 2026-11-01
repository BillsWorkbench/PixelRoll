import SwiftUI

struct FolderSidebar: View {
    @ObservedObject var library: LibraryModel

    var body: some View {
        ScrollViewReader { scroll in
            List {
                Section("Folders") {
                    if let tree = library.folderTree {
                        ForEach(tree.visibleRows(expanded: library.expandedFolders)) { row in
                            folderRow(row)
                        }
                    } else if library.isScanning {
                        ProgressView("Finding folders…")
                    } else {
                        Text("Open a photo folder to get started.").foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.sidebar)
            .disabled(library.isScanning)
            .onChange(of: library.highlightedFolder) { _, folder in
                if let folder { scroll.scrollTo(folder) }
            }
            .onChange(of: library.expandedFolders) { _, _ in
                if let folder = library.highlightedFolder { scroll.scrollTo(folder) }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 250, max: 380)
    }

    private func folderRow(_ row: VisibleFolder) -> some View {
        let folder = row.folder
        let browsing = library.selectedFolder?.path == folder.url.path
        let containsPhoto = library.highlightedFolder?.path == folder.url.path
        return HStack(spacing: 6) {
            if folder.children != nil {
                Button {
                    if library.expandedFolders.contains(folder.id) {
                        library.expandedFolders.remove(folder.id)
                    } else {
                        library.expandedFolders.insert(folder.id)
                    }
                } label: {
                    Image(systemName: library.expandedFolders.contains(folder.id) ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).frame(width: 14, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel((library.expandedFolders.contains(folder.id) ? "Collapse " : "Expand ") + folder.url.lastPathComponent)
            } else {
                Color.clear.frame(width: 14, height: 24)
            }
            Button {
                library.selectFolder(folder.url)
            } label: {
                HStack(spacing: 6) {
                    Label(folder.url.lastPathComponent.isEmpty ? folder.url.path : folder.url.lastPathComponent, systemImage: "folder")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if containsPhoto {
                        Image(systemName: "photo").font(.caption)
                            .help("Contains the selected photo")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Browse " + folder.url.lastPathComponent)
            .accessibilityValue(browsing ? "Selected browsing folder" : (containsPhoto ? "Contains selected photo" : ""))
            .help("Browse and search " + folder.url.path + " and its subfolders")
        }
        .padding(.leading, CGFloat(row.depth) * 14)
        .listRowBackground(browsing ? Color.accentColor.opacity(0.2) : (containsPhoto ? Color.accentColor.opacity(0.08) : Color.clear))
        .contextMenu {
            Button("Rename Folder…") { library.requestRename(folder.url) }
                .disabled(library.libraryUnavailable || library.isScanning || !library.savingNoteIDs.isEmpty)
            Button("Reveal in Finder") { library.revealInFinder(folder.url) }
        }
        .id(folder.id)
    }
}
