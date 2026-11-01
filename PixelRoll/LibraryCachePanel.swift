import SwiftUI
import AppKit

struct LibraryCachePanel: View {
    @ObservedObject var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var usage: PhotoDiskCache.Usage?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Library Cache").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Thumbnails and extracted metadata are disposable. Your photos, ratings, keywords and captions stay with the photo folder and its sidecars.")
                .font(.callout).foregroundStyle(.secondary)
            if let usage {
                if usage.available {
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(usage.bytes), countStyle: .file)) used · automatic limit about 1 GB")
                        .font(.headline)
                    Text("\(usage.thumbnails) thumbnails · \(usage.metadata) indexed photos")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Disk cache unavailable. PixelRoll can still read the original photos.").font(.callout)
                }
            } else { ProgressView().controlSize(.small) }
            Button("Show Cache Folder") { NSWorkspace.shared.open(PhotoDiskCache.shared.directory) }
            Divider()
            HStack {
                Button("Clear Cache", action: library.clearPhotoCache)
                Button("Rebuild This Library’s Index", action: library.rebuildLibraryIndex)
                    .disabled(library.root == nil || library.libraryUnavailable || library.isScanning)
            }.disabled(library.isMaintainingCache)
            Text("Clear Cache affects cached data for all libraries on this Mac. Rebuild refreshes metadata for the currently open library.")
                .font(.caption).foregroundStyle(.secondary)
            if library.isMaintainingCache {
                if library.cacheTotal > 0 {
                    ProgressView(value: Double(library.cacheProgress), total: Double(library.cacheTotal))
                    Text("\(library.cacheProgress) of \(library.cacheTotal) photos").font(.caption)
                } else { ProgressView().controlSize(.small) }
            }
            if let notice = library.cacheNotice { Text(notice).font(.callout).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }.padding(20).frame(width: 580, height: 410)
        .task { await refreshUsage() }
        .onChange(of: library.isMaintainingCache) { _, _ in Task { await refreshUsage() } }
    }
    private func refreshUsage() async {
        usage = await Task.detached(priority: .utility) { PhotoDiskCache.shared.usage() }.value
    }
}
