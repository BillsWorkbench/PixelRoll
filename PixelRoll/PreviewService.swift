import Foundation
import ImageIO
import CoreGraphics

// A separate decoder keeps large previews from holding up the thumbnail queue.
actor PreviewService {
    static let shared = PreviewService()

    func image(for url: URL, root: URL) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2560,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}
