import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

nonisolated struct DevelopImage: @unchecked Sendable {
    let image: CGImage
    let status: String
    let fullResolution: Bool
    let histogram: [[Double]]
    let curveHistogram: [[Double]]
    let sourceAspect: Double
    let lensProfileSupported: Bool
    let lensProfileEnabled: Bool
}

// Separate from library thumbnails: RAW work must never block scrolling the library.
actor DevelopRenderer {
    static let shared = DevelopRenderer()
    private let context: CIContext
    private var rawKey: String?
    private var rawFilter: CIRAWFilter?
    private var rawTemperature: Float = 6500
    private var rawLensEnabled = false
    private var rawTint: Float = 0
    private(set) var rawDecoderCreations = 0
    private var rasterKey: String?
    private var rasterImage: CGImage?
    init(cachesIntermediates: Bool = true) { context = CIContext(options: [.cacheIntermediates: cachesIntermediates]) }
    private var lastKey: String?
    private var lastImage: DevelopImage?

    func render(photo: PhotoFile, root: URL, fullSize: Bool, adjustments: PhotoAdjustments = PhotoAdjustments(), interactive: Bool = false, maximumDimension: Int? = nil, includeHistogram: Bool = true) -> DevelopImage? {
        guard !Task.isCancelled, adjustments.valid else { return nil }
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        guard let fingerprint = PhotoFingerprint.read(photo.url) else { return nil }
        let sourceKey = "\(photo.url.path)|\(fingerprint.token)"
        let limitSize = maximumDimension ?? (interactive && !fullSize ? 1280 : 2560)
        let key = "\(sourceKey)|\(fullSize)|\(limitSize)|\(includeHistogram)|\(adjustments.cacheToken)"
        if rawKey != sourceKey { rawFilter = nil; rawKey = nil; rasterImage = nil; rasterKey = nil; context.clearCaches() }
        if key == lastKey { return lastImage }
        // Release the previous full-size bitmap before decoding another one.
        lastImage = nil; lastKey = nil
        let source = CGImageSourceCreateWithURL(photo.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        let sourceType = source.flatMap { CGImageSourceGetType($0) }.flatMap { UTType($0 as String) }
        let isRAW = sourceType?.conforms(to: .rawImage) == true || (sourceType == nil &&
            ["nef", "nrw", "dng", "arw", "cr2", "cr3", "raf", "orf", "rw2", "pef", "srw"].contains(photo.url.pathExtension.lowercased()))
        var curveInput: CIImage?
        var beforeCurves = adjustments; beforeCurves.curves = PhotoCurves()
        var rendered: CGImage?
        var rawAdjusted = false
        var sourceAspect = 1.0
        var lensSupported = false, lensEnabled = false
        var status = "Original image"
        var native = fullSize
        if isRAW {
            if rawFilter == nil {
                rawFilter = CIRAWFilter(imageURL: photo.url); rawKey = sourceKey
                rawLensEnabled = rawFilter?.isLensCorrectionEnabled ?? false
                rawTemperature = rawFilter?.neutralTemperature ?? 6500; rawTint = rawFilter?.neutralTint ?? 0
                if rawFilter != nil { rawDecoderCreations += 1 }
            }
        } else { rawFilter = nil; rawKey = sourceKey }
        if isRAW, let filter = rawFilter {
            lensSupported = filter.isLensCorrectionSupported
            if lensSupported {
                filter.isLensCorrectionEnabled = adjustments.lensProfile == .automatic ? rawLensEnabled : adjustments.lensProfile == .enabled
                lensEnabled = filter.isLensCorrectionEnabled
            }
            let longest = max(filter.nativeSize.width, filter.nativeSize.height)
            filter.scaleFactor = fullSize ? 1 : Float(min(1, Double(limitSize) / max(1, longest)))
            filter.exposure = Float(adjustments.exposure)
            filter.neutralTemperature = adjustments.whiteBalance == .custom ? Float(adjustments.temperature) : rawTemperature
            filter.neutralTint = adjustments.whiteBalance == .custom ? Float(adjustments.tint) : rawTint
            if !Task.isCancelled, let output = filter.outputImage {
                sourceAspect = output.extent.width / output.extent.height
                if includeHistogram && !adjustments.curves.isIdentity { curveInput = Self.adjust(output, settings: beforeCurves, raw: true) }
                let adjusted = Self.adjust(output, settings: adjustments, raw: true)
                rendered = context.createCGImage(adjusted, from: adjusted.extent, format: .RGBA8,
                                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            }
            if rendered != nil { status = "Developed RAW"; rawAdjusted = true }
        }
        guard !Task.isCancelled else { return nil }
        if rendered == nil, let source {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let largest = max(properties?[kCGImagePropertyPixelWidth] as? Int ?? 2560,
                              properties?[kCGImagePropertyPixelHeight] as? Int ?? 2560)
            let limit = isRAW ? limitSize : (fullSize ? largest : limitSize)
            let decodedKey = "\(sourceKey)|\(limit)"
            if rasterKey == decodedKey { rendered = rasterImage }
            else { rendered = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: !isRAW,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: limit,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
                rasterKey = decodedKey; rasterImage = rendered
            }
            if isRAW { status = "Embedded preview · RAW development unavailable"; native = false }
        }
        guard let rendered, !Task.isCancelled, PhotoFingerprint.read(photo.url) == fingerprint else { return nil }
        if !rawAdjusted { sourceAspect = Double(rendered.width)/Double(rendered.height) }
        let final: CGImage
        if !rawAdjusted && adjustments.hasEdits {
            let input = CIImage(cgImage: rendered)
            if includeHistogram && !adjustments.curves.isIdentity { curveInput = Self.adjust(input, settings: beforeCurves, raw: false) }
            let output = Self.adjust(input, settings: adjustments, raw: false)
            guard let adjusted = context.createCGImage(output, from: output.extent,
                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
            final = adjusted
        } else { final = rendered }
        var curveHistogram: [[Double]] = []
        if includeHistogram {
            if let input = curveInput {
                let scale = min(1, 256 / max(input.extent.width, input.extent.height))
                let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                if let image = context.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) {
                    curveHistogram = Self.histogram(image, includeLuminance: true)
                }
            } else { curveHistogram = Self.histogram(final, includeLuminance: true) }
        }
        guard !Task.isCancelled else { return nil }
        let result = DevelopImage(image: final, status: status, fullResolution: native,
                                  histogram: includeHistogram ? Self.histogram(final) : [], curveHistogram: curveHistogram, sourceAspect: sourceAspect, lensProfileSupported: rawAdjusted && lensSupported, lensProfileEnabled: rawAdjusted && lensEnabled)
        lastKey = key; lastImage = result
        return result
    }

    nonisolated static func adjust(_ input: CIImage, settings s: PhotoAdjustments, raw: Bool) -> CIImage {
        var image = input
        if !raw && s.whiteBalance == .custom {
            image = image.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: s.temperature, y: s.tint), "inputTargetNeutral": CIVector(x: 6500, y: 0)])
        }
        if s.whiteBalance == .gray {
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: s.redGain, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: s.greenGain, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: s.blueGain, w: 0)])
        }
        if !raw && s.exposure != 0 { image = image.applyingFilter("CIExposureAdjust", parameters: ["inputEV": s.exposure]) }
        image = DevelopEffects.presence(image, settings: s)
        if s.contrast != 0 { image = image.applyingFilter("CIColorControls", parameters: ["inputContrast": s.contrastMultiplier]) }
        if s.highlights != 0 || s.shadows != 0 || s.whites != 0 || s.blacks != 0 {
            var parameters: [String: Any] = [:]
            for index in 0...4 {
                let x = Double(index) / 4
                let delta = s.shadows / 100 * 3 * x * pow(1-x, 3) + s.highlights / 100 * 3 * pow(x, 3) * (1-x) +
                    s.whites / 100 * 0.25 * pow(x, 4) + s.blacks / 100 * 0.15 * pow(1-x, 4)
                parameters["inputPoint\(index)"] = CIVector(x: x, y: min(1, max(0, x + delta)))
            }
            image = image.applyingFilter("CIToneCurve", parameters: parameters)
        }
        if s.vibrance != 0 { image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": s.vibrance / 100]) }
        if s.saturation != 0 { image = image.applyingFilter("CIColorControls", parameters: ["inputSaturation": 1 + s.saturation / 100]) }
        if !s.curves.isIdentity {
            image = image.applyingFilter("CIColorCurves", parameters: ["inputCurvesData": s.curves.lookupData(), "inputCurvesDomain": CIVector(x: 0, y: 1), "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!])
        }
        // Separate luminance and chroma treatments work for RAW and ordinary images alike.
        // Clamp during neighborhood filtering, then crop to avoid dark borders.
        if s.colorNoise > 0 {
            let smooth = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": s.colorNoise / 100 * 3]).cropped(to: input.extent)
            image = smooth.applyingFilter("CIColorBlendMode", parameters: [kCIInputBackgroundImageKey: image])
        }
        if s.luminanceNoise > 0 {
            let smooth = image.clampedToExtent().applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": s.luminanceNoise / 100 * 0.1, "inputSharpness": 0]).cropped(to: input.extent)
            image = smooth.applyingFilter("CILuminosityBlendMode", parameters: [kCIInputBackgroundImageKey: image])
        }
        if s.sharpening > 0 {
            image = image.clampedToExtent().applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": s.sharpening / 100]).cropped(to: input.extent)
        }
        image = DevelopEffects.lens(image, settings: s)
        if s.crop.hasGeometry { image = geometry(image, crop: s.crop) }
        return image
    }

    nonisolated static func geometry(_ input: CIImage, crop: PhotoCrop) -> CIImage {
        let extent = input.extent
        var image = input.transformed(by: CGAffineTransform(translationX: -extent.midX, y: -extent.midY))
        if crop.angle != 0 { image = image.transformed(by: CGAffineTransform(rotationAngle: -crop.angle * .pi / 180)) }
        let size = PhotoCrop.straightenedSize(extent.size, angle: crop.angle)
        let safe = CGRect(x: -size.width/2, y: -size.height/2, width: size.width, height: size.height)
        // Integral bounds stay inside the rotated photo and make raster dimensions predictable.
        let rect = CGRect(x: safe.minX + crop.x*size.width, y: safe.minY + (1-crop.y-crop.height)*size.height,
                          width: crop.width*size.width, height: crop.height*size.height)
        let inner = CGRect(x: ceil(rect.minX), y: ceil(rect.minY), width: max(1, floor(rect.maxX)-ceil(rect.minX)), height: max(1, floor(rect.maxY)-ceil(rect.minY)))
        image = image.cropped(to: inner)
        return image.transformed(by: CGAffineTransform(translationX: -inner.minX, y: -inner.minY))
    }

    nonisolated static func histogram(_ image: CGImage, includeLuminance: Bool = false) -> [[Double]] {
        let size = 192
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        let drawn = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let cg = CGContext(data: storage.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                     bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            cg.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        var bins = Array(repeating: Array(repeating: 0.0, count: 128), count: includeLuminance ? 4 : 3)
        guard drawn else { return bins }
        for pixel in stride(from: 0, to: bytes.count, by: 4) where bytes[pixel + 3] > 0 {
            for channel in 0..<3 { bins[channel][Int(bytes[pixel + channel]) / 2] += 1 }
            if includeLuminance {
                let luma = 0.2126 * Double(bytes[pixel]) + 0.7152 * Double(bytes[pixel+1]) + 0.0722 * Double(bytes[pixel+2])
                bins[3][min(127, Int(luma)/2)] += 1
            }
        }
        return bins
    }
}
