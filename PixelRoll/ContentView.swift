import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var library = LibraryModel()
    @StateObject private var exportController = ExportController()
    @StateObject private var developSettings = DevelopSettings()
    @Environment(\.undoManager) private var undoManager
    @State private var workspace: WorkspaceTab = .library
    @State private var developedImage: DevelopImage?
    @State private var showingKeywords = false
    @State private var showingPendingSaves = false
    @State private var showingCache = false
    @State private var editingKeyword = false
    @FocusState private var searchFocused: Bool
    @FocusState private var browserFocused: Bool
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: library.thumbnailSize, maximum: library.thumbnailSize + 60), spacing: 20)]
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                Picker("Workspace", selection: $workspace) {
                    ForEach(WorkspaceTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
                }.pickerStyle(.segmented).labelsHidden().padding(10)
                Divider()
                switch workspace {
                case .library: FolderSidebar(library: library)
                case .develop: DevelopControls(library: library, rendered: developedImage)
                case .publish: PublishControls(library: library, export: exportController)
                }
            }
            .frame(minWidth: 290, idealWidth: 320, maxWidth: 380)
            if workspace == .library {
                browser
            } else {
                DevelopView(library: library, rendered: $developedImage, publishing: workspace == .publish)
            }
        }
        .environmentObject(developSettings)
        .task(id: library.root) { await developSettings.load(root: library.root) }
        .task {
            library.undoManager = undoManager
            library.restoreSession()
            if !library.searchQuery.isEmpty { library.workspace.showingSearch = true }
        }
        .alert("PixelRoll", isPresented: Binding(get: { library.operationError != nil }, set: { if !$0 { library.operationError = nil } })) {
            Button("OK") { library.operationError = nil }
        } message: { Text(library.operationError ?? "") }
        .sheet(isPresented: Binding(get: { developSettings.presetPhoto != nil }, set: { if !$0 { developSettings.presetPhoto = nil } })) {
            if let photo = developSettings.presetPhoto { SavePresetSheet(library: library, photo: photo) }
        }
        .sheet(isPresented: $showingKeywords) { KeywordManager(library: library) }
        .sheet(isPresented: $showingPendingSaves) { PendingSavesPanel(library: library) }
        .sheet(isPresented: $showingCache) { LibraryCachePanel(library: library) }
        .inspector(isPresented: Binding(get: { workspace == .library && library.workspace.showingInformation }, set: { if workspace == .library { library.workspace.showingInformation = $0 } })) {
            PhotoInfoPanel(library: library, photo: selectedPhoto, root: library.root)
                .inspectorColumnWidth(min: 280, ideal: 320, max: 460)
        }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            if let notice = library.sessionNotice {
                Text(notice).font(.callout).foregroundStyle(.secondary).padding()
                Divider()
            }
            if library.workspace.showingSearch {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search files, cameras, lenses, keywords…", text: Binding(get: { library.searchQuery }, set: { library.beginUserNavigation(); library.searchQuery = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .focused($searchFocused)
                        .onKeyPress(.escape) { closeSearch(); return .handled }
                    Button("Done") { searchFocused = false; browserFocused = true }
                    Button { closeSearch() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).help("Clear and close file search")
                }
                .padding()
                Divider()
            }
            if let folder = library.selectedFolder {
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        Label(folder.lastPathComponent, systemImage: "folder")
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                            .help(folder.path)
                        Toggle("Subfolders", isOn: $library.includesSubfolders)
                            .toggleStyle(.checkbox).fixedSize()
                            .disabled(library.isScanning || !library.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .help("Include photos in subfolders")
                        Picker("Sort", selection: $library.sortOrder) {
                            ForEach(PhotoSortOrder.allCases) { order in Text(order.title).tag(order) }
                        }.labelsHidden().frame(width: 125).accessibilityLabel("Sort")
                        Button { library.sortAscending.toggle() } label: {
                            Image(systemName: library.sortAscending ? "arrow.up" : "arrow.down")
                        }.help(library.sortAscending ? "Ascending — click for descending" : "Descending — click for ascending")
                        Image(systemName: "square.grid.2x2").foregroundStyle(.secondary)
                        Slider(value: $library.thumbnailSize, in: 120...300, step: 20)
                            .frame(width: 85).accessibilityLabel("Thumbnail Size")
                        ProgressView().controlSize(.mini).frame(width: 12)
                            .opacity(library.isScanning || library.isSearching || library.isSorting || library.isMaintainingCache ? 1 : 0)
                            .help(library.isSearching ? "Searching metadata: \(library.searchedCount) of \(library.searchTotal)" : library.isSorting ? "Reading dates: \(library.datedCount) of \(library.dateTotal)" : "Updating library")
                        Text(library.isMaintainingCache ? (library.cacheTotal > 0 ? "Indexing \(library.cacheProgress)/\(library.cacheTotal)" : "Clearing cache…") : library.isSorting ? "Indexing \(library.datedCount)/\(library.dateTotal)" : library.isSearching ? "Searching \(library.searchedCount)/\(library.searchTotal)" : library.isRefreshing ? "Updating…" : "\(library.photos.count) photos")
                            .monospacedDigit().foregroundStyle(.secondary)
                            .font(.caption).frame(width: 144, alignment: .trailing).lineLimit(1)
                            .help("\(library.photos.count) photos in this view")
                    }
                    .frame(height: 30)
                    if library.workspace.showingFilters { LibraryFilterBar(library: library, editingKeyword: $editingKeyword) }
                }
                .font(.callout).padding(.horizontal, 12).padding(.vertical, 8)
                .disabled(library.libraryUnavailable)
                Divider()
            }

            if library.libraryUnavailable {
                ContentUnavailableView {
                    Label("Library Unavailable", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text("Reconnect the original drive or restore the library folder to its original location. Pending changes stay on this Mac and resume saving when the photos return.")
                } actions: {
                    Button("Check Again", action: library.checkAvailability)
                    Button("Open Another Library…", action: library.chooseFolder)
                }
            } else if library.isScanning && !library.isRefreshing {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Finding photos in this folder and its subfolders…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let root = library.root {
                if library.photos.isEmpty && library.notesFilter.active {
                    ContentUnavailableView("No Photos Match These Filters", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("Clear the filters to see the other photos in this folder."))
                } else if library.photos.isEmpty {
                    ContentUnavailableView(
                        !library.searchQuery.isEmpty ? (library.isSearching ? "Searching Photos…" : "No Matching Photos") : (library.unreadableItems > 0 ? "Folder Couldn’t Be Fully Read" : "No Photos Found"),
                        systemImage: "photo.on.rectangle.angled",
                        description: Text(library.isSearching ? "Camera and other metadata matches will appear as photos are checked." : !library.searchQuery.isEmpty ? "Try a filename, folder, camera, lens, keyword, or caption. Search includes this folder and its subfolders." : library.unreadableItems > 0
                                          ? "Check folder access permissions and try Refresh."
                                          : "Choose another folder or enable Include Subfolders.")
                    )
                } else {
                    GeometryReader { geometry in
                        ZStack {
                            if library.workspace.showingPreview, let photo = selectedPhoto {
                                PhotoPreview(photo: photo, root: root, adjustments: library.draft(for: photo.id).adjustments)
                                    .contextMenu {
                                Button("Select All") { library.selection.selectAll(in: library.photos) }
                                Button("Reveal in Finder") { library.revealInFinder(photo.url) }
                            }
                            .id(photo.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) {
                                        library.workspace.showingPreview = false
                                        browserFocused = true
                                    }
                                    .accessibilityAction(named: Text("Return to Grid")) {
                                        library.workspace.showingPreview = false
                                        browserFocused = true
                                    }
                            } else {
                                photoGrid(root: root)
                            }
                        }
                        .focusable()
                        .focusEffectDisabled()
                        .focused($browserFocused)
                        .onKeyPress(.leftArrow, phases: .down) { key in move(-1, extending: key.modifiers.contains(.shift)); return .handled }
                        .onKeyPress(.rightArrow, phases: .down) { key in move(1, extending: key.modifiers.contains(.shift)); return .handled }
                        .onKeyPress(.upArrow, phases: .down) { key in move(library.workspace.showingPreview ? -1 : -columnCount(geometry.size.width), extending: key.modifiers.contains(.shift)); return .handled }
                        .onKeyPress(.downArrow, phases: .down) { key in move(library.workspace.showingPreview ? 1 : columnCount(geometry.size.width), extending: key.modifiers.contains(.shift)); return .handled }
                        .onKeyPress(characters: CharacterSet(charactersIn: "012345xXaA")) { key in
                            if key.modifiers.contains(.command), key.characters.lowercased() == "a" {
                                library.selection.selectAll(in: library.photos)
                                return .handled
                            }
                            guard key.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
                            if let rating = Int(key.characters) { library.rateSelection(rating); return .handled }
                            if key.characters.lowercased() == "x" {
                                library.rejectSelection(!library.selectedPhotos.allSatisfy { library.draft(for: $0.id).isRejected })
                                return .handled
                            }
                            return .ignored
                        }
                        .onKeyPress(.space) { library.workspace.showingPreview.toggle(); return .handled }
                        .onKeyPress(.return) { library.workspace.showingPreview = true; return .handled }
                        .onKeyPress(.escape) {
                            guard library.workspace.showingPreview else { return .ignored }
                            library.workspace.showingPreview = false
                            return .handled
                        }
                    }
                    Divider()
                    HStack {
                        if let photo = selectedPhoto {
                            Text(photo.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(library.selection.ids.count > 1 ? "\(library.selection.ids.count) selected · \(library.photos.count) photos" : "\(selectedIndex + 1) of \(library.photos.count)")
                        }
                        if !library.currentPendingIDs.isEmpty {
                            Button("\(library.currentPendingIDs.count) unsaved") { showingPendingSaves = true }
                                .buttonStyle(.link).help("Review unsaved changes across this library")
                        }
                        Text(library.workspace.showingPreview ? "Double-click, Space or Esc: grid · ← →: browse" : "0–5: rate · X: reject · Space: preview")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(12)
                }
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Your photos. Your folders.").font(.title)
                    Text("Open a folder to browse its photos and subfolders.\nYour originals stay exactly where they are.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Open Photo Folder…", action: library.chooseFolder)
                        .buttonStyle(.borderedProminent)
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if library.unreadableItems > 0 && !library.isScanning {
                Divider()
                Text("\(library.unreadableItems) items couldn’t be read. Check folder permissions and try Refresh.")
                    .font(.caption).foregroundStyle(.secondary).padding(10)
            }
        }
        .frame(minWidth: 700, minHeight: 460)
        .onChange(of: library.photos) { old, photos in
            if photos.isEmpty { library.workspace.showingPreview = false }
            else if old.isEmpty && !searchFocused && !editingKeyword { browserFocused = true }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    if library.workspace.showingSearch { closeSearch() }
                    else { library.workspace.showingSearch = true; searchFocused = true }
                } label: {
                    Label("Search Files", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(library.root == nil || library.isScanning)
                .help("Search files and metadata in the selected folder and its subfolders (Command-F)")
                if !library.photos.isEmpty && !library.isScanning {
                    Button {
                        library.workspace.showingPreview.toggle()
                        browserFocused = true
                    } label: {
                        Label(library.workspace.showingPreview ? "Show Grid" : "Show Preview", systemImage: library.workspace.showingPreview ? "square.grid.2x2" : "photo")
                    }
                    .help(library.workspace.showingPreview ? "Return to grid (Space or Escape)" : "Show selected photo (Space)")
                    Button { move(-1); browserFocused = true } label: {
                        Label("Previous Photo", systemImage: "chevron.left")
                    }
                    .disabled(selectedIndex <= 0)
                    Button { move(1); browserFocused = true } label: {
                        Label("Next Photo", systemImage: "chevron.right")
                    }
                    .disabled(selectedIndex >= library.photos.count - 1)
                }
                Button { library.workspace.showingFilters.toggle(); editingKeyword = false; browserFocused = true } label: {
                    Label(library.workspace.showingFilters ? "Hide Filters" : "Show Filters", systemImage: library.notesFilter.active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .help(library.notesFilter.active ? "Filters are active. Show or hide the filter bar." : "Show or hide the filter bar")
                Button { showingPendingSaves = true } label: {
                    Label("Unsaved Changes (\(library.currentPendingIDs.count))", systemImage: library.currentPendingIDs.isEmpty ? "checkmark.circle" : "exclamationmark.circle.fill")
                }.help(library.currentPendingIDs.isEmpty ? "All changes saved — view save status" : "Review and retry unsaved changes across the library")
                .disabled(library.root == nil)
                Button { showingCache = true } label: { Label("Library Cache", systemImage: "internaldrive") }
                    .help("View cache size, clear cached data, or rebuild the library index")
                Button { showingKeywords = true } label: {
                    Label("Manage Keywords", systemImage: "tag")
                }
                .disabled(library.root == nil || library.libraryUnavailable)
                .help("Rename, merge, or delete saved PixelRoll keywords across this library")
                Button {
                    library.workspace.showingInformation.toggle()
                } label: {
                    Label(library.workspace.showingInformation ? "Hide Photo Information" : "Show Photo Information", systemImage: "info.circle")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help("Show or hide photo information (Option-Command-I)")
                Button { library.revealInFinder() } label: {
                    Label("Reveal in Finder", systemImage: "folder.badge.questionmark")
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(selectedPhoto == nil || library.libraryUnavailable)
                .help("Reveal selected original in Finder (Shift-Command-R)")
                Button(action: library.chooseFolder) { Label("Open Folder", systemImage: "folder.badge.plus") }
                    .keyboardShortcut("o", modifiers: .command)
                    .help("Open a photo folder")
                Button(action: library.refresh) { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(library.root == nil || library.isScanning)
                    .help("Scan this folder again")
            }
        }
    }

    private func closeSearch() {
        library.beginUserNavigation()
        library.searchQuery = ""
        library.workspace.showingSearch = false
        searchFocused = false
        browserFocused = true
    }

    private var selectedIndex: Int {
        library.photos.firstIndex(where: { $0.id == library.selection.id }) ?? 0
    }

    private var selectedPhoto: PhotoFile? {
        library.photos.first(where: { $0.id == library.selection.id })
    }

    private func move(_ offset: Int, extending: Bool = false) {
        library.beginUserNavigation()
        library.selection.move(by: offset, in: library.photos, extending: extending)
    }

    private func selectPhoto(_ photo: PhotoFile, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        library.beginUserNavigation()
        library.selection.select(photo.id, in: library.photos,
                                 extending: modifiers.contains(.shift), toggling: modifiers.contains(.command))
        browserFocused = true
    }

    private func columnCount(_ width: CGFloat) -> Int {
        max(1, Int((width - 48 + 20) / (library.thumbnailSize + 20)))
    }

    private func photoGrid(root: URL) -> some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(library.photos) { photo in
                        PhotoGridItem(library: library, photo: photo, root: root, selected: library.selection.ids.contains(photo.id),
                                      height: library.thumbnailSize * 0.8, notes: library.draft(for: photo.id), cacheEpoch: library.thumbnailEpoch,
                                      select: { selectPhoto(photo, modifiers: $0) },
                                      open: {
                                          library.beginUserNavigation()
                                          library.selection.id = photo.id
                                          library.workspace.showingPreview = true
                                          browserFocused = true
                                      },
                                      selectAll: { library.selection.selectAll(in: library.photos) },
                                      reveal: { library.revealInFinder(photo.url) })
                            .equatable()
                            .id(photo.id)
                    }
                }
                .scrollTargetLayout()
                .padding(24)
            }
            .scrollPosition(id: Binding(get: { library.scrollAnchor }, set: { if library.scrollAnchor != $0 { library.scrollAnchor = $0 } }), anchor: .top)
            .onChange(of: library.selection.id) { _, id in
                if library.shouldFollowSelection, let id { scroll.scrollTo(id) }
            }
            .onAppear {
                if let id = library.scrollAnchor ?? library.selection.id { scroll.scrollTo(id) }
            }
        }
    }
}

// Keep the lazy grid's item construction small; metadata progress should not rebuild every menu and thumbnail.
private struct PhotoGridItem: View, Equatable {
    let library: LibraryModel
    let photo: PhotoFile
    let root: URL
    let selected: Bool
    let height: Double
    let notes: PhotoNotes
    let cacheEpoch: Int
    let select: (NSEvent.ModifierFlags) -> Void
    let open: () -> Void
    let selectAll: () -> Void
    let reveal: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.photo == rhs.photo && lhs.root == rhs.root && lhs.selected == rhs.selected &&
        lhs.height == rhs.height && lhs.notes == rhs.notes && lhs.cacheEpoch == rhs.cacheEpoch
    }

    var body: some View {
        PhotoCell(photo: photo, root: root, selected: selected, height: height, notes: notes, cacheEpoch: cacheEpoch)
            .contentShape(Rectangle())
            .overlay {
                PhotoClickTarget { modifiers, count in
                    if count == 2 { open() } else { select(modifiers) }
                }.accessibilityHidden(true)
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { select(NSEvent.modifierFlags) }
            .accessibilityAction(named: Text("Open Preview"), open)
            .contextMenu {
                Button("Select All", action: selectAll)
                Button("Reveal in Finder", action: reveal)
                Divider()
                AdjustmentContextMenu(library: library, photo: photo.id)
            }
    }
}

struct PhotoCell: View {
    @EnvironmentObject private var developSettings: DevelopSettings
    let photo: PhotoFile
    let root: URL
    let selected: Bool
    let height: Double
    let notes: PhotoNotes
    let cacheEpoch: Int
    @State private var renderedEpoch = -1
    private struct ThumbnailRequest: Equatable { let photo: PhotoFile?; let epoch: Int; let adjustments: PhotoAdjustments; let interacting: Bool }
    @State private var renderedAdjustments = PhotoAdjustments()
    @State private var thumbnail: CGImage?
    @State private var finished = false
    @State private var visible = false
    @State private var renderedPhoto: PhotoFile?

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                if let thumbnail {
                    GeometryReader { geometry in
                        Image(decorative: thumbnail, scale: 1)
                            .resizable().scaledToFit()
                            .frame(width: max(0, geometry.size.width - 24), height: max(0, geometry.size.height - 24), alignment: .center)
                            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    }
                } else if finished {
                    Image(systemName: "photo.badge.exclamationmark")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: height)
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 3) {
                    if notes.rating > 0 {
                        ForEach(0..<notes.rating, id: \.self) { _ in
                            Image(systemName: "star.fill").foregroundStyle(.yellow)
                        }
                    }
                    if notes.isRejected { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
                }
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 5).frame(height: 20)
                .background(Color(white: 0.16).opacity(0.96), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.65), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                .opacity(notes.rating > 0 || notes.isRejected ? 1 : 0)
                .padding(6)
                .allowsHitTesting(false)
            }
            Text(photo.url.lastPathComponent)
                .font(.caption).lineLimit(1).truncationMode(.middle)
        }
        .padding(6)
        .background(selected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2)
        }
        .help(photo.url.path)
        .accessibilityElement(children: .combine)
        .accessibilityValue((selected ? "Selected. " : "") + "\(notes.rating) stars. \(notes.isRejected ? "Rejected" : "")")
        .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
        .task(id: ThumbnailRequest(photo: visible ? photo : nil, epoch: cacheEpoch, adjustments: notes.adjustments.visual, interacting: developSettings.interacting)) {
            let values = notes.adjustments.visual
            guard visible, !developSettings.interacting,
                  renderedPhoto != photo || renderedEpoch != cacheEpoch || renderedAdjustments != values else { return }
            if renderedPhoto == photo && values.hasEdits {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            let decoded = await AdjustedThumbnailService.shared.thumbnail(photo: photo, root: root, adjustments: values)
            guard !Task.isCancelled else { return }
            thumbnail = decoded
            renderedPhoto = photo
            renderedAdjustments = values
            renderedEpoch = cacheEpoch
            finished = true
        }
    }

}

private struct PhotoPreview: View {
    let photo: PhotoFile
    let root: URL
    let adjustments: PhotoAdjustments
    private struct Request: Equatable { let photo: PhotoFile; let adjustments: PhotoAdjustments }
    @State private var image: CGImage?
    @State private var finished = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.94)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding(20)
                    .accessibilityLabel(photo.url.lastPathComponent)
            } else if finished {
                ContentUnavailableView("Preview Unavailable", systemImage: "photo.badge.exclamationmark",
                                       description: Text("macOS couldn’t decode this photo. You can continue to the next image."))
                    .foregroundStyle(.white)
            } else {
                ProgressView("Loading preview…").tint(.white).foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: Request(photo: photo, adjustments: adjustments.visual)) {
            let decoded: CGImage?
            if adjustments.hasEdits {
                decoded = await DevelopRenderer.shared.render(photo: photo, root: root, fullSize: false, adjustments: adjustments).map(\.image)
            } else { decoded = await PreviewService.shared.image(for: photo.url, root: root) }
            guard !Task.isCancelled else { return }
            image = decoded
            finished = true
        }
    }
}

#Preview {
    ContentView()
}

enum WorkspaceTab: String, CaseIterable, Identifiable {
    case library = "Library", develop = "Develop", publish = "Publish"
    var id: String { rawValue }
}

struct AdjustmentContextMenu: View {
    @ObservedObject var library: LibraryModel
    let photo: URL
    @ObservedObject private var clipboard = AdjustmentClipboard.shared
    @EnvironmentObject private var settings: DevelopSettings
    var body: some View {
        Button("Copy Adjustments") { clipboard.values = library.draft(for: photo).adjustments }
            .disabled(library.noteErrors[photo] != nil)
        Button("Paste Adjustments to Selected Photos") {
            guard let values = clipboard.values else { return }
            let targets = library.selection.ids.contains(photo) ? Array(library.selection.ids) : [photo]
            library.setAdjustments(values, for: targets, action: "Paste Adjustments")
        }.disabled(clipboard.values == nil || !library.canEditSelection)
        Button("Save Adjustments as Preset…") { settings.error = nil; settings.presetPhoto = photo }
            .disabled(library.noteErrors[photo] != nil || library.libraryUnavailable)
    }
}
