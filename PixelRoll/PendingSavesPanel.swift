import SwiftUI

struct PendingSavesPanel: View {
    @ObservedObject var library: LibraryModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let rows = library.pendingSaveRows
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text(rows.isEmpty ? "Changes Saved" : "Unsaved Changes")
                    .font(.title2.weight(.semibold))
                Text(library.root?.path ?? "No library open")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .truncationMode(.middle).textSelection(.enabled)
            }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.bottom, 24)
            if rows.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44, weight: .light)).foregroundStyle(.green)
                        .accessibilityHidden(true)
                    Text("All Changes Saved").font(.headline)
                    Text("Ratings, keywords, captions and adjustments are saved beside your photos.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 360)
                }.frame(maxWidth: .infinity).padding(.vertical, 16)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .frame(minWidth: 88).padding(.top, 28)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(rows.count) \(rows.count == 1 ? "photo has" : "photos have") changes waiting to be saved.")
                        .font(.callout)
                    if library.libraryUnavailable {
                        Text("Reconnect the library to resume saving. These pending changes are kept on this Mac.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    List(rows) { row in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(row.id.lastPathComponent).font(.headline)
                            Text(row.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Text(row.status).font(.callout)
                            HStack {
                                Button("Show Photo") { library.showPendingPhoto(row.id); dismiss() }.disabled(!row.canShow)
                                Button("Discard Pending Edits") { library.discardPendingEdits(for: row.id) }
                                    .disabled(library.libraryUnavailable || library.savingNoteIDs.contains(row.id))
                                    .help("Keep the saved notes. Command-Z can restore the pending edits.")
                            }.buttonStyle(.borderless)
                        }.padding(.vertical, 8)
                    }.frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 8))
                    Text("Original photos stay unchanged.").font(.caption).foregroundStyle(.secondary)
                    Divider().padding(.vertical, 4)
                    HStack {
                        Button("Retry All", action: library.retryAllPendingSaves)
                            .disabled(library.libraryUnavailable || library.isScanning || !rows.contains(where: { $0.canShow }))
                        Spacer()
                        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    }
                }
            }
        }.padding(28).frame(width: rows.isEmpty ? 480 : 620)
            .background { Button("") { dismiss() }.keyboardShortcut(.cancelAction).hidden() }
    }
}
