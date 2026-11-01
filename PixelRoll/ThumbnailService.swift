import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

actor ThumbnailService {
    static let shared = ThumbnailService()
    private let cache = NSCache<NSURL, ThumbnailBox>()
    private let disk: PhotoDiskCache
    private(set) var diskHits = 0
    private(set) var sourceDecodes = 0

    init(disk: PhotoDiskCache = .shared) {
        self.disk = disk
        cache.countLimit = 160
        cache.totalCostLimit = 64 * 1024 * 1024
    }
    func clearCache() { cache.removeAllObjects() }
    func invalidate(_ urls: Set<URL>) {
        for url in urls { cache.removeObject(forKey: url as NSURL) }
    }

    // Serial decoding prioritizes requests from visible cells; nothing pre-generates the entire library.
    func thumbnail(for url: URL, root: URL, modifiedDate: Date? = nil) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        guard let fingerprint = PhotoFingerprint.read(url) else { return nil }
        if let cached = cache.object(forKey: url as NSURL), cached.fingerprint == fingerprint { return cached.image }
        let key = PhotoDiskCache.key(for: url)
        if let data = disk.read(.thumbnail, key: key, fingerprint: fingerprint),
           let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceThumbnailMaxPixelSize: 360,
               kCGImageSourceShouldCacheImmediately: true
           ] as CFDictionary) {
            diskHits += 1
            remember(image, url: url, fingerprint: fingerprint)
            return image
        }
        sourceDecodes += 1
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 360,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary), !Task.isCancelled,
              PhotoFingerprint.read(url) == fingerprint else { return nil }
        remember(image, url: url, fingerprint: fingerprint)
        let data = NSMutableData()
        let alpha = [.first, .last, .premultipliedFirst, .premultipliedLast].contains(image.alphaInfo)
        if let destination = CGImageDestinationCreateWithData(data, (alpha ? UTType.png.identifier : UTType.jpeg.identifier) as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            if CGImageDestinationFinalize(destination) {
                disk.write(data as Data, kind: .thumbnail, key: key, fingerprint: fingerprint)
            }
        }
        return image
    }

    private func remember(_ image: CGImage, url: URL, fingerprint: PhotoFingerprint) {
        cache.setObject(ThumbnailBox(image, fingerprint: fingerprint), forKey: url as NSURL, cost: image.bytesPerRow * image.height)
    }
}

private final class ThumbnailBox: @unchecked Sendable {
    let image: CGImage
    let fingerprint: PhotoFingerprint
    nonisolated init(_ image: CGImage, fingerprint: PhotoFingerprint) { self.image = image; self.fingerprint = fingerprint }
}
