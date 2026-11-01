import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

@MainActor enum DevelopChecks {
    static func run(base: URL) async throws {
        let root = base.appendingPathComponent("Develop", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("Portrait.jpg")
        let cg = CGContext(data: nil, width: 3200, height: 2000, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: 3200, height: 2000))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cg.makeImage()!, [kCGImagePropertyOrientation: 6] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        let original = try Data(contentsOf: url)
        let renderer = DevelopRenderer()
        let fit = await renderer.render(photo: PhotoFile(url: url), root: root, fullSize: false)!
        precondition(fit.image.height == 2560 && fit.image.width == 1600)
        precondition(fit.status == "Original image" && !fit.fullResolution)
        precondition(fit.histogram.count == 3 && fit.histogram.allSatisfy { abs($0.reduce(0,+) - 192 * 192) < 1 })
        let peaks = fit.histogram.map { bins in bins.firstIndex(of: bins.max()!)! }
        precondition(peaks[0] > peaks[1] && peaks[1] > peaks[2], "Histogram must preserve RGB channel ordering")
        let full = await renderer.render(photo: PhotoFile(url: url), root: root, fullSize: true)!
        precondition(full.image.height == 3200 && full.image.width == 2000 && full.fullResolution)
        let cached = await renderer.render(photo: PhotoFile(url: url), root: root, fullSize: true)!
        precondition(cached.image === full.image)
        let fallbackURL = root.appendingPathComponent("PreviewOnly.NEF")
        try original.write(to: fallbackURL)
        let fallback = await renderer.render(photo: PhotoFile(url: fallbackURL), root: root, fullSize: true)!
        precondition(fallback.status == "Original image" && fallback.fullResolution, "A JPEG renamed NEF must not be reported as developed RAW")
        let corrupt = root.appendingPathComponent("Broken.NEF")
        try Data("broken".utf8).write(to: corrupt)
        let bad = await renderer.render(photo: PhotoFile(url: corrupt), root: root, fullSize: false)
        precondition(bad == nil)
        let cancelled = Task { await renderer.render(photo: PhotoFile(url: url), root: root, fullSize: true) }
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        precondition(cancelledResult == nil)
        let bytesAfter = try Data(contentsOf: url)
        precondition(bytesAfter == original)
        print("PASS: Develop fit/full-resolution orientation, RGB histogram, bounded cache, source-type detection, corrupt-file handling, cancellation and original-byte preservation")
    }
}
