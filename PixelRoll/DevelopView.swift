import SwiftUI

struct DevelopView: View {
    @ObservedObject var library: LibraryModel
    @State private var filmstripAnchor: URL?
    @State private var actualPixels = false
    @Binding var rendered: DevelopImage?
    let publishing: Bool
    @EnvironmentObject private var settings: DevelopSettings
    @State private var renderedPhoto: PhotoFile?
    @State private var renderedAdjustments = PhotoAdjustments()
    @State private var loading = false
    @State private var failed = false
    private var photo: PhotoFile? { library.photos.first { $0.id == library.selection.id } }
    private struct Request: Equatable { let photo: PhotoFile?; let full: Bool; let epoch: Int; let adjustments: PhotoAdjustments; let interactive: Bool }

    var body: some View {
        VStack(spacing: 0) {
                viewerBar
                Divider()
                ZStack {
                    Color(white: 0.09)
                    if let rendered {
                        DevelopCanvas(image: rendered.image, actualPixels: actualPixels, photoID: photo?.id ?? URL(fileURLWithPath: "/"), crop: !loading && renderedPhoto == photo ? settings.cropDraft : nil, cropChanged: { settings.cropDraft = $0 }, sample: settings.pickingGray && !loading && renderedAdjustments == PhotoAdjustments() ? { point in sampleGray(rendered.image, point: point) } : nil)
                    }
                    if library.libraryUnavailable {
                        ContentUnavailableView("Library Unavailable", systemImage: "externaldrive.badge.exclamationmark", description: Text("Reconnect the photo drive, then return to Library to check again."))
                    } else if photo == nil {
                        ContentUnavailableView("Select a Photo", systemImage: "photo", description: Text("Choose a photo in Library to begin developing."))
                    } else if failed {
                        ContentUnavailableView("Image Unavailable", systemImage: "photo.badge.exclamationmark", description: Text("macOS couldn’t decode this photo. Select another photo to continue."))
                    }
                    if loading && rendered == nil {
                        ProgressView(actualPixels ? "Loading full resolution…" : "Developing image…")
                            .padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                filmstrip
            }
        .frame(minWidth: 460)
        .frame(minHeight: 500)
        .task(id: Request(photo: photo, full: actualPixels, epoch: library.thumbnailEpoch, adjustments: renderAdjustments, interactive: settings.interacting)) {
            if renderedPhoto != photo { rendered = nil }; failed = false
            guard let photo, let root = library.root, !library.libraryUnavailable else { loading = false; return }
            loading = true
            let adjustments = renderAdjustments
            do { try await Task.sleep(for: .milliseconds(settings.interacting ? 16 : 60)) } catch { return }
            let result = await DevelopRenderer.shared.render(photo: photo, root: root, fullSize: actualPixels, adjustments: adjustments, interactive: settings.interacting)
            guard !Task.isCancelled else { return }
            rendered = result; renderedPhoto = photo; renderedAdjustments = adjustments; failed = result == nil; loading = false
        }
        .onChange(of: photo?.id) { _, _ in settings.before = false; settings.pickingGray = false; settings.cropDraft = nil }
        .onDisappear { settings.pickingGray = false; settings.before = false; settings.cropDraft = nil; settings.interacting = false }
        .onKeyPress(.escape) { settings.pickingGray = false; settings.cropDraft = nil; settings.interacting = false; return .handled }
        .toolbar {
            ToolbarItemGroup {
                Button { library.revealInFinder() } label: { Label("Reveal in Finder", systemImage: "folder") }
                    .disabled(photo == nil || library.libraryUnavailable)
                Button(action: library.chooseFolder) { Label("Open Folder", systemImage: "folder.badge.plus") }
            }
        }
    }

    private func select(_ photo: PhotoFile, modifiers: NSEvent.ModifierFlags) {
        library.beginUserNavigation()
        library.selection.select(photo.id, in: library.photos, extending: modifiers.contains(.shift), toggling: modifiers.contains(.command))
    }

    private var renderAdjustments: PhotoAdjustments {
        if settings.before || settings.pickingGray { return PhotoAdjustments() }
        var values = photo.map { library.draft(for: $0.id).adjustments } ?? PhotoAdjustments()
        if let crop = settings.cropDraft { values.crop = crop.preview }
        return values
    }
    private func sampleGray(_ image: CGImage, point: CGPoint) {
        guard let photo else { return }
        guard let gains = GrayBalance.gains(image: image, x: point.x, y: point.y) else {
            settings.error = "Choose a midtone gray area away from clipped highlights and deep shadows."; return
        }
        var values = library.draft(for: photo.id).adjustments
        values.whiteBalance = .gray; values.redGain = gains.0; values.greenGain = gains.1; values.blueGain = gains.2
        library.setAdjustments(values, for: [photo.id], action: "Pick Gray")
        settings.pickingGray = false; settings.error = nil
    }

    private var index: Int { library.photos.firstIndex { $0.id == library.selection.id } ?? 0 }
    private func move(_ offset: Int) {
        library.beginUserNavigation()
        library.selection.move(by: offset, in: library.photos)
    }

    private var viewerBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(photo?.url.lastPathComponent ?? "Develop").font(.headline).lineLimit(1).truncationMode(.middle)
                Text(rendered.map { "\($0.status) · \($0.image.width) × \($0.image.height)" } ?? (loading ? "Loading image…" : "Original photos stay unchanged"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if loading { ProgressView().controlSize(.mini) }
            if settings.pickingGray {
                Text("Click neutral gray").font(.caption).foregroundStyle(.secondary)
                Button("Cancel") { settings.pickingGray = false }.keyboardShortcut(.cancelAction)
            }
            else if settings.cropDraft != nil { Text("Crop Preview").font(.caption.bold()) }
            else if settings.before { Text("Before").font(.caption.bold()) }
            Spacer(minLength: 6)
            Button { move(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(index <= 0).keyboardShortcut(.leftArrow, modifiers: []).help("Previous Photo")
            Button { move(1) } label: { Image(systemName: "chevron.right") }
                .disabled(index >= library.photos.count - 1).keyboardShortcut(.rightArrow, modifiers: []).help("Next Photo")
            Picker("Zoom", selection: $actualPixels) {
                Text("Fit").tag(false)
                Text("100%").tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 120)
                .disabled(photo == nil || library.libraryUnavailable)
            Button(settings.before ? "Show After" : "Show Before", systemImage: "rectangle.lefthalf.inset.filled") {
                settings.cropDraft = nil; settings.pickingGray = false; settings.before.toggle()
            }.labelStyle(.iconOnly).disabled(photo == nil)
                .tint(settings.before ? .accentColor : .primary)
                .help(settings.before ? "Show your adjustments" : "Show the original without adjustments")
        }.padding(12).frame(height: 64)
    }

    private var filmstrip: some View {
        VStack(spacing: 0) {
            HStack {
                Text(library.selectedFolder?.lastPathComponent ?? "Filmstrip").lineLimit(1)
                Spacer()
                Text("\(library.photos.count) photos · Library order & filters").foregroundStyle(.secondary)
            }.font(.caption).padding(.horizontal, 12).padding(.top, 8)
            ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(library.photos) { photo in
                            PhotoCell(photo: photo, root: library.root ?? photo.url.deletingLastPathComponent(),
                                      selected: library.selection.ids.contains(photo.id), height: 76,
                                      notes: library.draft(for: photo.id), cacheEpoch: library.thumbnailEpoch)
                                .frame(width: 112)
                                .contentShape(Rectangle())
                                .overlay {
                                    PhotoClickTarget { modifiers, _ in select(photo, modifiers: modifiers) }
                                        .accessibilityHidden(true)
                                }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { select(photo, modifiers: []) }
                                .id(photo.id)
                                .contextMenu {
                                    Button("Select All") { library.selection.selectAll(in: library.photos) }
                                    Divider()
                                    AdjustmentContextMenu(library: library, photo: photo.id)
                                }
                        }
                    }.scrollTargetLayout().padding(10)
            }
            .scrollPosition(id: $filmstripAnchor, anchor: .center)
            .onChange(of: library.selection.id) { _, id in filmstripAnchor = id }
            .onChange(of: library.photos) { _, _ in filmstripAnchor = library.selection.id }
            .onAppear { filmstripAnchor = library.selection.id }
        }.frame(height: 142).background(.bar)
    }
}

