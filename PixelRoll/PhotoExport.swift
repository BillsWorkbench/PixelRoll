import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

nonisolated struct ExportOptions: Equatable, Sendable {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case jpeg = "JPEG", tiff = "TIFF", heif = "HEIF"
        var id: String { rawValue }
        var type: UTType { switch self { case .jpeg: .jpeg; case .tiff: .tiff; case .heif: .heic } }
        var suffix: String { switch self { case .jpeg: "jpg"; case .tiff: "tif"; case .heif: "heic" } }
        var available: Bool { (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(type.identifier) }
    }
    enum Profile: String, CaseIterable, Identifiable, Sendable {
        case sRGB, displayP3 = "Display P3", adobeRGB = "Adobe RGB (1998)"
        var id: String { rawValue }
        var space: CGColorSpace { CGColorSpace(name: self == .sRGB ? CGColorSpace.sRGB : self == .displayP3 ? CGColorSpace.displayP3 : CGColorSpace.adobeRGB1998)! }
    }
    enum Duplicates: String, CaseIterable, Identifiable, Sendable {
        case keepBoth = "Keep Both (number new files)", skip = "Skip Existing"
        var id: String { rawValue }
    }
    var format = Format.jpeg
    var profile = Profile.sRGB
    // Zero means full size; otherwise the maximum output edge. Never enlarge the photo.
    var longestEdge = 0
    var quality = 0.9
    var duplicates = Duplicates.keepBoth
    var metadata = true
    var location = false
    var valid: Bool { (longestEdge == 0 || (64...30000).contains(longestEdge)) && quality.isFinite && (0.1...1).contains(quality) }
}

nonisolated struct ExportPhoto: Sendable {
    var photo: PhotoFile
    var notes: PhotoNotes
    var fingerprint: PhotoFingerprint?
    init(photo: PhotoFile, notes: PhotoNotes) {
        self.photo = photo; self.notes = notes; fingerprint = PhotoFingerprint.read(photo.url)
    }
}
nonisolated enum ExportOutcome: Sendable { case saved(URL), skipped }
nonisolated enum ExportError: LocalizedError {
    case invalid, unavailable, changed, decode, encode, names
    var errorDescription: String? {
        switch self {
        case .invalid: "Choose a valid export size and quality."
        case .unavailable: "This export format isn’t available on this Mac."
        case .changed: "The original photo changed or is unavailable. Refresh the library and try again."
        case .decode: "The full-resolution photo couldn’t be developed."
        case .encode: "The exported image couldn’t be encoded."
        case .names: "Too many files have the same name in this destination."
        }
    }
}

actor PhotoExporter {
    private let renderer = DevelopRenderer(cachesIntermediates: false)
    private let context = CIContext(options: [.cacheIntermediates: false])

    func export(_ item: ExportPhoto, root: URL, destination: URL, options: ExportOptions) async throws -> ExportOutcome {
        guard options.valid, item.notes.adjustments.valid else { throw ExportError.invalid }
        guard options.format.available else { throw ExportError.unavailable }
        try Task.checkCancellation()
        let sourceScope = root.startAccessingSecurityScopedResource()
        let outputScope = destination.startAccessingSecurityScopedResource()
        defer {
            if sourceScope { root.stopAccessingSecurityScopedResource() }
            if outputScope { destination.stopAccessingSecurityScopedResource() }
            context.clearCaches()
        }
        guard let fingerprint = item.fingerprint, PhotoFingerprint.read(item.photo.url) == fingerprint else { throw ExportError.changed }
        let folder = destination.resolvingSymlinksInPath()
        let stem = item.photo.url.deletingPathExtension().lastPathComponent
        let first = folder.appendingPathComponent(stem).appendingPathExtension(options.format.suffix)
        if options.duplicates == .skip && exists(first) { return .skipped }
        guard let rendered = await renderer.render(photo: item.photo, root: root, fullSize: true, adjustments: item.notes.adjustments, includeHistogram: false), rendered.fullResolution else { throw ExportError.decode }
        try Task.checkCancellation()
        var image = CIImage(cgImage: rendered.image)
        if options.longestEdge > 0 {
            let scale = min(1, Double(options.longestEdge)/max(image.extent.width, image.extent.height))
            if scale < 1 {
                image = image.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": scale, "inputAspectRatio": 1])
                let width = rendered.image.width >= rendered.image.height ? options.longestEdge : max(1, Int((Double(rendered.image.width)*scale).rounded()))
                let height = rendered.image.height >= rendered.image.width ? options.longestEdge : max(1, Int((Double(rendered.image.height)*scale).rounded()))
                image = image.clampedToExtent().cropped(to: CGRect(x: 0,y: 0,width: width,height: height))
            }
        }
        guard let output = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: options.profile.space) else { throw ExportError.encode }
        let encoded = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(encoded, options.format.type.identifier as CFString, 1, nil) else { throw ExportError.encode }
        var properties = Self.properties(item: item, width: output.width, height: output.height, options: options)
        if options.format != .tiff { properties[kCGImageDestinationLossyCompressionQuality] = options.quality }
        else {
            var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCompression] = 5 // Lossless LZW; exported channels are 8-bit.
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        CGImageDestinationAddImage(writer, output, properties as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw ExportError.encode }
        try Task.checkCancellation()
        guard PhotoFingerprint.read(item.photo.url) == fingerprint else { throw ExportError.changed }
        // Exclusive creation protects originals, sidecars, existing exports and racing jobs.
        // Do not combine this with .atomic, whose replacement behavior is inappropriate here.
        for index in 1...10000 {
            let name = index == 1 ? stem : "\(stem)-\(index)"
            let target = folder.appendingPathComponent(name).appendingPathExtension(options.format.suffix)
            if exists(target) {
                if options.duplicates == .skip { return .skipped }
                continue
            }
            do {
                try (encoded as Data).write(to: target, options: .withoutOverwriting)
                return .saved(target)
            } catch {
                if exists(target), (error as NSError).code == NSFileWriteFileExistsError {
                    if options.duplicates == .skip { return .skipped }
                    continue
                }
                throw error
            }
        }
        throw ExportError.names
    }
    private func exists(_ url: URL) -> Bool { (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil }

    private static func properties(item: ExportPhoto, width: Int, height: Int, options: ExportOptions) -> [CFString: Any] {
        var result: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        guard options.metadata else { return result }
        let source = CGImageSourceCreateWithURL(item.photo.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        let original = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0,0,nil) } as? [CFString: Any] ?? [:]
        var exif = original[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        exif.removeValue(forKey: kCGImagePropertyExifMakerNote)
        exif[kCGImagePropertyExifPixelXDimension] = width; exif[kCGImagePropertyExifPixelYDimension] = height
        result[kCGImagePropertyExifDictionary] = exif
        var tiff = original[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation] = 1
        tiff[kCGImagePropertyTIFFSoftware] = "PixelRoll"
        var iptc = original[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        if !item.notes.caption.isEmpty {
            tiff[kCGImagePropertyTIFFImageDescription] = item.notes.caption
            iptc[kCGImagePropertyIPTCCaptionAbstract] = item.notes.caption
        }
        let keywords = Array(Set((iptc[kCGImagePropertyIPTCKeywords] as? [String] ?? []) + item.notes.keywords)).sorted()
        if !keywords.isEmpty { iptc[kCGImagePropertyIPTCKeywords] = keywords }
        result[kCGImagePropertyTIFFDictionary] = tiff
        result[kCGImagePropertyIPTCDictionary] = iptc
        if options.location, let gps = original[kCGImagePropertyGPSDictionary] { result[kCGImagePropertyGPSDictionary] = gps }
        return result
    }
}
