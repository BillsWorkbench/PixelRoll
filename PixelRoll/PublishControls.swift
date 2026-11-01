import SwiftUI

struct PublishControls: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var export: ExportController
    @EnvironmentObject private var develop: DevelopSettings
    private var selectedCount: Int { library.photos.filter { library.selection.ids.contains($0.id) }.count }
    private var sizeChoice: Binding<Int> {
        Binding(get: { [0,2048,4096].contains(export.options.longestEdge) ? export.options.longestEdge : -1 }, set: { value in
            export.options.longestEdge = value == -1 ? 3000 : value
        })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Export your finished photos.").font(.callout).foregroundStyle(.secondary)
                Text("\(selectedCount) selected").font(.caption)
                Divider()
                Text("Export").font(.subheadline.bold())
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Format", selection: $export.options.format) {
                        ForEach(ExportOptions.Format.allCases) { Text($0.rawValue).tag($0).disabled(!$0.available) }
                    }
                    Picker("Size", selection: sizeChoice) {
                        Text("Full Size").tag(0); Text("2,048 px Long Edge").tag(2048)
                        Text("4,096 px Long Edge").tag(4096); Text("Custom Long Edge").tag(-1)
                    }
                    if sizeChoice.wrappedValue == -1 {
                        HStack {
                            Text("Long Edge").font(.caption)
                            TextField("Pixels", value: $export.options.longestEdge, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                                .accessibilityLabel("Export Long Edge")
                            Text("px").font(.caption)
                        }
                    }
                    Text("Smaller photos keep their original size.").font(.caption).foregroundStyle(.secondary)
                    Picker("Color Profile", selection: $export.options.profile) {
                        ForEach(ExportOptions.Profile.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Text("sRGB is suitable for most sharing. TIFF uses lossless, 8-bit color.").font(.caption).foregroundStyle(.secondary)
                    VStack(spacing: 4) {
                        HStack {
                            Text("Quality").font(.caption); Spacer()
                            Text("\(Int(export.options.quality*100))%").font(.caption.monospacedDigit())
                        }
                        Slider(value: $export.options.quality, in: 0.1...1, step: 0.01).accessibilityLabel("Export Quality")
                    }.disabled(export.options.format == .tiff)
                    Picker("Existing Files", selection: $export.options.duplicates) {
                        ForEach(ExportOptions.Duplicates.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Include Photo Metadata", isOn: $export.options.metadata)
                        .help("Camera information, captions and keywords, where supported by the output format.")
                    Toggle("Include Location", isOn: $export.options.location).disabled(!export.options.metadata)
                    Text("Exports include current adjustments and crops. Existing files and original photos are kept.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !export.options.valid {
                        Text("Enter a long edge from 64 to 30,000 pixels.").font(.caption).foregroundStyle(.red)
                    }
                    if develop.cropDraft != nil {
                        Text("Apply or cancel your crop preview in Develop before exporting.").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Export Selected Photos…", systemImage: "square.and.arrow.up") { export.chooseDestination(library: library) }
                        .buttonStyle(.borderedProminent)
                        .disabled(develop.cropDraft != nil || selectedCount == 0 || !export.options.valid || !export.options.format.available || library.libraryUnavailable)
                }.disabled(export.busy)
                if export.busy {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: Double(export.completed), total: Double(max(1, export.total)))
                            .accessibilityLabel("Export Progress")
                        Text("\(export.completed) of \(export.total) processed").font(.caption.monospacedDigit())
                        Text(export.stopping ? "Stopping after the current operation…" : export.currentName)
                            .font(.caption).lineLimit(2)
                        Button(export.stopping ? "Stopping…" : "Cancel Export", action: export.cancel).disabled(export.stopping)
                    }
                }
                if let message = export.message {
                    Text(message).font(.callout)
                    Button("Show Export Folder", systemImage: "folder", action: export.revealDestination)
                }
                if !export.failures.isEmpty {
                    DisclosureGroup("\(export.failures.count) Export Errors") {
                        ForEach(Array(export.failures.enumerated()), id: \.offset) { _, failure in
                            Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        }
                    }
                }
                Divider()
                Text("Print").font(.subheadline.bold())
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Layout", selection: .constant("Single Photo")) {
                        Text("Single Photo").tag("Single Photo"); Text("Contact Sheet").tag("Contact Sheet")
                    }
                    Button("Page Setup…", systemImage: "doc") {}
                    Button("Print Selected Photos…", systemImage: "printer") {}
                }.disabled(true).foregroundStyle(.tertiary)
                Text("Printing is planned for the next release.").font(.caption).foregroundStyle(.secondary)
            }.padding(14)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
