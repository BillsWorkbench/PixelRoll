import SwiftUI

struct CropControls: View {
    @ObservedObject var library: LibraryModel
    let photo: PhotoFile?
    let rendered: DevelopImage?
    @EnvironmentObject private var settings: DevelopSettings
    private var editing: Bool { settings.cropDraft != nil }
    private var values: PhotoCrop { settings.cropDraft ?? photo.map { library.draft(for: $0.id).adjustments.crop } ?? PhotoCrop() }
    private var sourceAspect: Double { rendered?.sourceAspect ?? 1 }
    private func change(_ update: (inout PhotoCrop) -> Void, fit: Bool = false) {
        guard var crop = settings.cropDraft else { return }
        update(&crop)
        if fit { crop = crop.fitted(sourceAspect: sourceAspect) }
        if crop.valid { settings.cropDraft = crop }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !editing {
                HStack {
                    Button(values.hasGeometry ? "Edit Crop" : "Crop Photo", systemImage: "crop") {
                        settings.before = false; settings.pickingGray = false; settings.cropDraft = values
                    }
                    Spacer()
                    Button("Reset Crop") {
                        guard let photo else { return }
                        var adjustments = library.draft(for: photo.id).adjustments; adjustments.crop = PhotoCrop()
                        library.setAdjustments(adjustments, for: [photo.id], action: "Reset Crop")
                    }.disabled(values == PhotoCrop())
                }.controlSize(.small)
            }
            HStack(spacing: 8) {
                Picker("Aspect", selection: Binding(get: { values.aspect }, set: { aspect in change({ $0.aspect = aspect }, fit: true) })) {
                    ForEach(PhotoCrop.Aspect.allCases) { Text($0.rawValue).tag($0) }
                }.disabled(!editing)
                Button("Switch Orientation", systemImage: "arrow.triangle.2.circlepath") {
                    change({ $0.flipped.toggle() }, fit: true)
                }.labelStyle(.iconOnly).help("Switch crop orientation")
                    .disabled(!editing || values.aspect == .free || values.aspect == .square)
            }
            VStack(spacing: 3) {
                HStack {
                    Text("Straighten").font(.caption); Spacer()
                    TextField("Straighten", value: Binding(get: { values.angle }, set: { angle in
                        guard angle.isFinite else { return }; change { $0.angle = min(45, max(-45, angle)) }
                    }), format: .number.precision(.fractionLength(1)))
                        .font(.caption.monospacedDigit()).multilineTextAlignment(.trailing).textFieldStyle(.plain).frame(width: 50)
                        .accessibilityLabel("Straighten Value")
                    Text("°").font(.caption).foregroundStyle(.secondary)
                }
                DottedSlider(value: Binding(get: { values.angle }, set: { angle in change { $0.angle = angle } }), range: -45...45, step: 0.1,
                             editingChanged: { settings.interacting = $0 }).accessibilityLabel("Straighten")
            }.disabled(!editing)
                .simultaneousGesture(TapGesture(count: 2).onEnded { change { $0.angle = 0 } })
                .help("Double-click to reset straightening")
            if editing {
                Text("Drag inside the frame to move it. Drag a corner to resize. Escape cancels.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Reset Crop") { settings.cropDraft = PhotoCrop() }
                    Spacer()
                    Button("Cancel") { settings.cropDraft = nil; settings.interacting = false }.keyboardShortcut(.cancelAction)
                    Button("Apply") {
                        guard let photo, let crop = settings.cropDraft else { return }
                        var adjustments = library.draft(for: photo.id).adjustments; adjustments.crop = crop
                        library.setAdjustments(adjustments, for: [photo.id], action: "Crop & Straighten")
                        settings.cropDraft = nil; settings.interacting = false
                    }.buttonStyle(.borderedProminent)
                }.controlSize(.small)
            }
        }.disabled(photo == nil || library.libraryUnavailable || rendered == nil || photo.map { library.noteErrors[$0.id] != nil } == true)
    }
}
