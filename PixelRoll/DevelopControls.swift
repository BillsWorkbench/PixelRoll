import SwiftUI

struct DevelopControls: View {
    @ObservedObject var library: LibraryModel
    let rendered: DevelopImage?
    @State private var metadata: PhotoMetadata?
    @EnvironmentObject private var settings: DevelopSettings
    @State private var savingPreset = false
    @State private var undoOpen = false
    @State private var curveChannel = CurveChannel.rgb
    private var values: PhotoAdjustments { photo.map { library.draft(for: $0.id).adjustments } ?? PhotoAdjustments() }
    private var editable: Bool { photo != nil && !library.libraryUnavailable && photo.map { library.noteErrors[$0.id] == nil } == true }
    private var photo: PhotoFile? { library.photos.first { $0.id == library.selection.id } }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                    Text("Histogram").font(.subheadline.bold())
                    VStack(spacing: 0) {
                        HistogramView(channels: rendered?.histogram ?? [])
                            .frame(height: 100).background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
                            .accessibilityLabel("RGB histogram of the displayed image")
                        cameraSummary
                    }
                    presetRow
            }.padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(photo.map { library.noteSaveErrors[$0.id] ?? (library.noteDrafts[$0.id] == nil ? "Adjustments saved beside the photo" : "Saving adjustments…") } ?? "Select a photo to edit")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = settings.error { Text(error).font(.caption).foregroundStyle(.red) }
                    section("White Balance") {
                        HStack(spacing: 8) {
                            Picker("White Balance", selection: Binding(get: { values.whiteBalance }, set: { mode in edit { $0.whiteBalance = mode } })) {
                                Text("As Shot").tag(PhotoAdjustments.WhiteBalance.asShot)
                                Text("Custom").tag(PhotoAdjustments.WhiteBalance.custom)
                                Text("Sampled Gray").tag(PhotoAdjustments.WhiteBalance.gray)
                            }
                            Button("Pick Gray", systemImage: settings.pickingGray ? "eyedropper.full" : "eyedropper") {
                                settings.cropDraft = nil; settings.before = false; settings.pickingGray.toggle()
                            }.labelStyle(.iconOnly).tint(settings.pickingGray ? .accentColor : .primary)
                                .help("Click a neutral gray area in the photo. Escape cancels.")
                        }.disabled(!editable)
                        liveAdjustment("Temperature", key: \.temperature, range: 2000...12000, step: 50)
                        liveAdjustment("Tint", key: \.tint)
                    }
                    section("Curves") {
                        Picker("Channel", selection: $curveChannel) {
                            ForEach(CurveChannel.allCases) { Text($0.rawValue).tag($0) }
                        }
                        CurveEditor(points: Binding(get: { values.curves[curveChannel] }, set: { points in edit { $0.curves[curveChannel] = points } }), histogram: rendered?.curveHistogram ?? [], channel: curveChannel, interaction: setInteraction)
                    }.disabled(!editable)
                    section("Tone") {
                        liveAdjustment("Exposure", key: \.exposure, range: -5...5, step: 0.05)
                        liveAdjustment("Contrast", key: \.contrast, range: -5...5)
                        liveAdjustment("Highlights", key: \.highlights)
                        liveAdjustment("Shadows", key: \.shadows)
                        liveAdjustment("Whites", key: \.whites)
                        liveAdjustment("Blacks", key: \.blacks)
                    }
                    section("Presence") {
                        liveAdjustment("Texture", key: \.texture)
                        liveAdjustment("Clarity", key: \.clarity)
                        liveAdjustment("Dehaze", key: \.dehaze)
                    }
                    section("Color") { liveAdjustment("Vibrance", key: \.vibrance); liveAdjustment("Saturation", key: \.saturation) }
                    section("Detail", expanded: false) {
                        liveAdjustment("Sharpening", key: \.sharpening, range: 0...150)
                        liveAdjustment("Luminance Noise", key: \.luminanceNoise, range: 0...100)
                        liveAdjustment("Color Noise", key: \.colorNoise, range: 0...100)
                    }
                    section("Lens Corrections", expanded: false) {
                        Picker("Lens Profile", selection: Binding(get: { values.lensProfile }, set: { profile in edit { $0.lensProfile = profile } })) {
                            ForEach(PhotoAdjustments.LensProfile.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.disabled(!editable || rendered?.lensProfileSupported != true)
                        Text(rendered?.lensProfileSupported == true ? (rendered?.lensProfileEnabled == true ? "macOS lens profile active" : "macOS lens profile off") : "No automatic lens profile available for this photo. Manual corrections are available below.")
                            .font(.caption).foregroundStyle(.secondary)
                        liveAdjustment("Distortion", key: \.distortion)
                        liveAdjustment("Vignette", key: \.vignette)
                        Text("Color Fringing").font(.caption.weight(.semibold))
                        liveAdjustment("Red / Cyan", key: \.redFringe, range: -10...10, step: 0.1)
                        liveAdjustment("Blue / Yellow", key: \.blueFringe, range: -10...10, step: 0.1)
                        Text("Adjust color fringing at 100%. Positive vignette values brighten the edges.").font(.caption).foregroundStyle(.secondary)
                    }
                    section("Crop & Straighten", expanded: false) {
                        CropControls(library: library, photo: photo, rendered: rendered)
                    }
                }.padding(14)
            }
        }.background(.background)
        .sheet(isPresented: $savingPreset) { if let photo { SavePresetSheet(library: library, photo: photo.id) } }
        .onDisappear { setInteraction(false) }
        .task(id: photo) {
            metadata = nil
            guard let photo, let root = library.root else { return }
            let result = await MetadataService.shared.read(photo.url, root: root)
            guard !Task.isCancelled else { return }
            metadata = result
        }
    }
    private var cameraSummary: some View {
        let fields = metadata?.sections.flatMap { $0.fields } ?? []
        return HStack(spacing: 6) {
            ForEach(["Camera", "ISO", "Aperture", "Shutter Speed", "Focal Length"], id: \.self) { label in
                let value = fields.first { $0.label == label }?.value ?? "—"
                Text(label == "ISO" ? "ISO \(value)" : value)
                    .frame(maxWidth: .infinity, alignment: label == "Camera" ? .leading : label == "Focal Length" ? .trailing : .center).lineLimit(1).minimumScaleFactor(0.75)
                    .help("\(label): \(value)")
            }
        }.font(.caption).monospacedDigit().padding(.vertical, 8).padding(.horizontal, 8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            .accessibilityElement(children: .combine)
    }
    private var presetRow: some View {
        HStack(spacing: 6) {
            Picker("Preset", selection: Binding(get: { values.presetID?.uuidString ?? "" }, set: { id in
                settings.cropDraft = nil
                guard let photo else { return }
                if let preset = settings.presets.first(where: { $0.id.uuidString == id }) {
                    var values = preset.adjustments; values.presetID = preset.id
                    library.setAdjustments(values, for: [photo.id], action: "Apply Preset")
                } else { var values = values; values.presetID = nil; library.setAdjustments(values, for: [photo.id], action: "Clear Preset") }
            })) {
                Text("--No Preset--").tag("")
                ForEach(settings.presets) { preset in
                    let current = { var v = values; v.presetID = nil; return v }()
                    Text(preset.name + (values.presetID == preset.id && current != preset.adjustments ? " (Modified)" : "")).tag(preset.id.uuidString)
                }
                if let id = values.presetID, !settings.presets.contains(where: { $0.id == id }) { Text("Unavailable Preset").tag(id.uuidString) }
            }.labelsHidden().disabled(!editable || settings.busy).accessibilityLabel("Saved Preset")
            Menu {
                Button("Update Preset") {
                    guard let id = values.presetID, let preset = settings.presets.first(where: { $0.id == id }) else { return }
                    let values = values
                    Task { _ = await settings.save(name: preset.name, settings: values, updating: id) }
                }.disabled(!settings.presets.contains(where: { $0.id == values.presetID }) || settings.busy)
                Button("Save New Preset…") { settings.error = nil; savingPreset = true }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Preset Actions").disabled(!editable)
            Button("Reset all settings") {
                guard let photo else { return }; settings.cropDraft = nil; settings.before = false; settings.pickingGray = false
                library.setAdjustments(PhotoAdjustments(), for: [photo.id], action: "Reset All Settings")
            }.disabled(!editable).fixedSize()
        }.controlSize(.small)
    }
    private func edit(_ change: (inout PhotoAdjustments) -> Void) {
        guard editable, let photo else { return }
        var changed = values; change(&changed)
        settings.before = false
        library.setAdjustments(changed, for: [photo.id])
    }
    private func liveAdjustment(_ label: String, key: WritableKeyPath<PhotoAdjustments, Double>, range: ClosedRange<Double> = -100...100, step: Double = 1) -> some View {
        let binding = Binding(get: { values[keyPath: key] }, set: { value in
            guard range.contains(value) else { return }
            edit { values in
                values[keyPath: key] = value
                if key == \.temperature || key == \.tint { values.whiteBalance = .custom }
            }
        })
        return VStack(spacing: 3) {
            HStack {
                Text(label).font(.caption); Spacer()
                TextField(label, value: binding, format: .number.precision(.fractionLength(key == \.exposure ? 2 : (key == \.redFringe || key == \.blueFringe) ? 1 : 0)))
                    .multilineTextAlignment(.trailing).textFieldStyle(.plain).frame(width: 62).font(.caption.monospacedDigit())
                    .accessibilityLabel(label + " Value")
            }
            DottedSlider(value: binding, range: range, step: step, editingChanged: setInteraction).accessibilityLabel(label)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            edit { values in values[keyPath: key] = PhotoAdjustments()[keyPath: key] }
        })
        .help("Double-click to reset " + label.lowercased())
        .disabled(!editable)
    }
    private func setInteraction(_ editing: Bool) {
        settings.interacting = editing
        if editing && !undoOpen { library.undoManager?.beginUndoGrouping(); undoOpen = true }
        if !editing && undoOpen { library.undoManager?.endUndoGrouping(); undoOpen = false }
    }
    private func section<Content: View>(_ title: String, expanded: Bool = true, @ViewBuilder content: () -> Content) -> some View {
        DevelopSection(title: title, initiallyExpanded: expanded, content: content)
    }
    private func adjustment(_ label: String, value: Double = 0, range: ClosedRange<Double> = -100...100, display: String = "0") -> some View {
        VStack(spacing: 3) {
            HStack { Text(label); Spacer(); Text(display).monospacedDigit() }.font(.caption).foregroundStyle(.tertiary)
            DottedSlider(value: .constant(value), range: range).disabled(true).accessibilityLabel(label)
        }
    }
}

private struct DevelopSection<Content: View>: View {
    let title: String
    @State private var expanded: Bool
    let content: Content
    init(title: String, initiallyExpanded: Bool, @ViewBuilder content: () -> Content) {
        self.title = title; _expanded = State(initialValue: initiallyExpanded); self.content = content()
    }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) { VStack(spacing: 10) { content }.padding(.top, 10) } label: {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        }
        Divider()
    }
}

private struct HistogramView: View {
    let channels: [[Double]]
    var body: some View {
        Canvas { context, size in
            let maximum = channels.flatMap { $0 }.max() ?? 0
            guard maximum > 0 else { return }
            for (channel, values) in channels.enumerated() {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for (index, value) in values.enumerated() {
                    path.addLine(to: CGPoint(x: Double(index) / Double(max(1, values.count - 1)) * size.width,
                                            y: size.height * (1 - log1p(value) / log1p(maximum))))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height)); path.closeSubpath()
                context.blendMode = .plusLighter
                context.fill(path, with: .color([Color.red, .green, .blue][channel].opacity(0.48)))
            }
        }.padding(6)
    }
}

