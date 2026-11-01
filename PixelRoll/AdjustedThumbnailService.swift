import Foundation
import ImageIO
import UniformTypeIdentifiers

actor AdjustedThumbnailService {
    static let shared = AdjustedThumbnailService()
    private let disk: PhotoDiskCache
    private let memory = NSCache<NSURL, EditedThumbnail>()
    private let renderer = DevelopRenderer(cachesIntermediates: false)
    private(set) var diskHits = 0
    private(set) var renders = 0
    private struct Record: Codable { var version = 2; var adjustments: PhotoAdjustments; var image: Data }
    init(disk: PhotoDiskCache = .shared) {
        self.disk = disk; memory.countLimit = 160; memory.totalCostLimit = 32 * 1024 * 1024
    }
    func clearMemory() { memory.removeAllObjects() }
    func thumbnail(photo: PhotoFile, root: URL, adjustments: PhotoAdjustments) async -> CGImage? {
        guard adjustments.valid, !Task.isCancelled else { return nil }
        guard adjustments.hasEdits else { return await ThumbnailService.shared.thumbnail(for: photo.url, root: root) }
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        guard let fingerprint = PhotoFingerprint.read(photo.url) else { return nil }
        let values = adjustments.visual
        if let cached = memory.object(forKey: photo.url as NSURL), cached.fingerprint == fingerprint, cached.adjustments == values { return cached.image }
        let key = PhotoDiskCache.key(for: photo.url)
        if let data = disk.read(.adjustedThumbnail, key: key, fingerprint: fingerprint),
           let record = try? JSONDecoder().decode(Record.self, from: data), record.version == 2, record.adjustments == values,
           let source = CGImageSourceCreateWithData(record.image as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            diskHits += 1; remember(image, photo: photo, fingerprint: fingerprint, values: values); return image
        }
        guard let result = await renderer.render(photo: photo, root: root, fullSize: false, adjustments: values, maximumDimension: 360, includeHistogram: false),
              !Task.isCancelled, PhotoFingerprint.read(photo.url) == fingerprint else { return nil }
        renders += 1
        let image = result.image
        remember(image, photo: photo, fingerprint: fingerprint, values: values)
        let data = NSMutableData()
        if let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            if CGImageDestinationFinalize(destination), let encoded = try? JSONEncoder().encode(Record(adjustments: values, image: data as Data)) {
                // One edited record per photo; newer settings replace the previous cached image.
                disk.write(encoded, kind: .adjustedThumbnail, key: key, fingerprint: fingerprint)
            }
        }
        return image
    }
    private func remember(_ image: CGImage, photo: PhotoFile, fingerprint: PhotoFingerprint, values: PhotoAdjustments) {
        memory.setObject(EditedThumbnail(image: image, fingerprint: fingerprint, adjustments: values), forKey: photo.url as NSURL, cost: image.bytesPerRow * image.height)
    }
}
private final class EditedThumbnail: @unchecked Sendable {
    let image: CGImage
    let fingerprint: PhotoFingerprint
    let adjustments: PhotoAdjustments
    nonisolated init(image: CGImage, fingerprint: PhotoFingerprint, adjustments: PhotoAdjustments) {
        self.image = image; self.fingerprint = fingerprint; self.adjustments = adjustments
    }
}
