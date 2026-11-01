import Foundation
import ImageIO

nonisolated struct IndexedPhotoMetadata: Codable, Equatable, Sendable {
    let captureDate: Date?
    let text: String
}

actor PhotoMetadataIndex {
    static let shared = PhotoMetadataIndex()
    private struct Entry { let fingerprint: PhotoFingerprint; let metadata: IndexedPhotoMetadata }
    private var memory: [String: Entry] = [:]
    private let disk: PhotoDiskCache
    private(set) var diskHits = 0
    private(set) var sourceReads = 0

    init(disk: PhotoDiskCache = .shared) { self.disk = disk }
    func clearMemory() { memory.removeAll() }
    func invalidate(_ urls: Set<URL>) {
        for url in urls { memory.removeValue(forKey: PhotoDiskCache.key(for: url)) }
    }

    func entry(for photo: PhotoFile, root: URL) -> IndexedPhotoMetadata? {
        guard !Task.isCancelled else { return nil }
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        guard let fingerprint = PhotoFingerprint.read(photo.url) else { return nil }
        let key = PhotoDiskCache.key(for: photo.url)
        if let entry = memory[key], entry.fingerprint == fingerprint { return entry.metadata }
        if let data = disk.read(.metadata, key: key, fingerprint: fingerprint),
           let metadata = try? JSONDecoder().decode(IndexedPhotoMetadata.self, from: data) {
            diskHits += 1
            remember(metadata, key: key, fingerprint: fingerprint)
            return metadata
        }
        sourceReads += 1
        let metadata: IndexedPhotoMetadata? = autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(photo.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return nil }
            let exif = properties["{Exif}"] as? [String: Any] ?? [:]
            let tiff = properties["{TIFF}"] as? [String: Any] ?? [:]
            let pairs = [(exif["DateTimeOriginal"], exif["OffsetTimeOriginal"]),
                         (exif["DateTimeDigitized"], exif["OffsetTimeDigitized"]), (tiff["DateTime"], nil)]
            let date = pairs.lazy.compactMap { CaptureDateIndex.parse($0.0 as? String, offset: $0.1 as? String) }.first
            var parts: [String] = []
            for group in ["{TIFF}", "{Exif}", "{ExifAux}", "{IPTC}"] {
                if let values = properties[group] { parts += Self.values(values) }
            }
            if let tags = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
                CGImageMetadataEnumerateTagsUsingBlock(tags, nil, [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { _, tag in
                    if let value = CGImageMetadataTagCopyValue(tag) { parts += Self.values(value) }
                    return true
                }
            }
            return IndexedPhotoMetadata(captureDate: date, text: parts.joined(separator: "\n"))
        }
        guard let metadata, !Task.isCancelled,
              PhotoFingerprint.read(photo.url) == fingerprint else { return nil }
        remember(metadata, key: key, fingerprint: fingerprint)
        if let data = try? JSONEncoder().encode(metadata) {
            disk.write(data, kind: .metadata, key: key, fingerprint: fingerprint)
        }
        return metadata
    }

    private func remember(_ metadata: IndexedPhotoMetadata, key: String, fingerprint: PhotoFingerprint) {
        if memory.count >= 20_000 { memory.removeAll(keepingCapacity: true) }
        memory[key] = Entry(fingerprint: fingerprint, metadata: metadata)
    }
    nonisolated private static func values(_ value: Any) -> [String] {
        if value is Data { return [] }
        if let dictionary = value as? [String: Any] { return dictionary.values.flatMap { values($0) } }
        if let array = value as? [Any] { return array.flatMap { values($0) } }
        return [String(describing: value)]
    }
}
