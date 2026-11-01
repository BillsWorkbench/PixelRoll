import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@MainActor enum Release12Checks {
    static func run(base: URL) async throws {
        var settings = PhotoAdjustments()
        settings.vibrance = 45; settings.saturation = -20
        settings.curves.rgb = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.65), CurvePoint(x: 1, y: 1)]
        settings.curves.red = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.4, y: 0.6), CurvePoint(x: 1, y: 1)]
        precondition(settings.valid && !settings.curves.isIdentity)
        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(PhotoAdjustments.self, from: encoded)
        precondition(decoded == settings)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        for field in ["curves", "vibrance", "saturation"] { legacy.removeValue(forKey: field) }
        let older = try JSONDecoder().decode(PhotoAdjustments.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(older.curves.isIdentity && older.vibrance == 0 && older.saturation == 0)
        precondition(!PhotoCurves.valid([CurvePoint(x: 0, y: 0), CurvePoint(x: 0, y: 0.5), CurvePoint(x: 1, y: 1)]))
        let samples = settings.curves.lookupData().withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        precondition(samples.count == 512 * 3 && samples.allSatisfy { $0.isFinite && (0...1).contains($0) })
        print("PASS: curves and color round trip, 0.11 sidecars/presets remain compatible, invalid points rejected and RGB lookup bounded")

        let smoothPoints = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.12), CurvePoint(x: 0.65, y: 0.85), CurvePoint(x: 1, y: 1)]
        let smooth = CurveSpline(points: smoothPoints)
        for point in smoothPoints { precondition(abs(smooth.value(point.x) - point.y) < 0.000001) }
        let middle = smooth.value(0.45)
        let straightMiddle = 0.12 + (0.85-0.12)*0.5
        precondition(abs(middle-straightMiddle) > 0.001, "Curve must bend between points")
        let epsilon = 0.00001
        let leftSlope = (smooth.value(0.25)-smooth.value(0.25-epsilon))/epsilon
        let rightSlope = (smooth.value(0.25+epsilon)-smooth.value(0.25))/epsilon
        precondition(abs(leftSlope-rightSlope) < 0.002, "Tangents must join smoothly")
        var previous = smooth.value(0)
        for index in 1...1000 {
            let value = smooth.value(Double(index)/1000)
            precondition(value >= previous-0.0000001 && (0...1).contains(value)); previous = value
        }
        let turningPoints = [CurvePoint(x: 0, y: 0.2), CurvePoint(x: 0.3, y: 0.8), CurvePoint(x: 0.6, y: 0.1), CurvePoint(x: 1, y: 0.9)]
        let turning = CurveSpline(points: turningPoints)
        for (a,b) in zip(turningPoints, turningPoints.dropFirst()) {
            for index in 0...100 {
                let y = turning.value(a.x+(b.x-a.x)*Double(index)/100)
                precondition(y >= min(a.y,b.y)-0.0000001 && y <= max(a.y,b.y)+0.0000001, "Curve must not overshoot control points")
            }
        }
        var contrast = PhotoAdjustments(); contrast.contrast = 20
        precondition(abs(contrast.contrastMultiplier-1.2) < 0.0000001)
        contrast.contrast = -20; precondition(abs(contrast.contrastMultiplier-0.8) < 0.0000001)
        contrast.contrast = 0; precondition(contrast.contrastMultiplier == 1)
        print("PASS: smooth curves pass through every point with continuous tangents and no overshoot; contrast ±20% maps to 1.20×/0.80×")

        let root = base.appendingPathComponent("Release12")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let photo = root.appendingPathComponent("Color.png")
        let context = CGContext(data: nil, width: 3200, height: 1800, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func paint(_ color: CGColor) {
            context.setFillColor(color); context.fill(CGRect(x: 0, y: 0, width: 3200, height: 1800))
            let destination = CGImageDestinationCreateWithURL(photo as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil); precondition(CGImageDestinationFinalize(destination))
        }
        paint(CGColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 1))
        let bytes = try Data(contentsOf: photo)
        let file = PhotoFile(url: photo)
        let renderer = DevelopRenderer()
        let baseline = await renderer.render(photo: file, root: root, fullSize: false)!
        var red = PhotoAdjustments(); red.curves.red = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.85), CurvePoint(x: 1, y: 1)]
        let changed = await renderer.render(photo: file, root: root, fullSize: false, adjustments: red)!
        func mean(_ bins: [Double]) -> Double { bins.enumerated().reduce(0) { $0 + Double($1.offset)*$1.element } / bins.reduce(0,+) }
        precondition(mean(changed.histogram[0]) > mean(baseline.histogram[0]) + 5)
        precondition(abs(mean(changed.histogram[1]) - mean(baseline.histogram[1])) < 2 && abs(mean(changed.histogram[2]) - mean(baseline.histogram[2])) < 2)
        var gray = PhotoAdjustments(); gray.saturation = -100
        let grayImage = await renderer.render(photo: file, root: root, fullSize: false, adjustments: gray)!
        precondition(abs(mean(grayImage.histogram[0]) - mean(grayImage.histogram[2])) < 2)
        var vibrant = PhotoAdjustments(); vibrant.vibrance = 80
        let vibrantImage = await renderer.render(photo: file, root: root, fullSize: false, adjustments: vibrant)!
        precondition(vibrantImage.histogram != baseline.histogram)
        let quick = await renderer.render(photo: file, root: root, fullSize: false, adjustments: settings, interactive: true)!
        let refined = await renderer.render(photo: file, root: root, fullSize: false, adjustments: settings)!
        precondition(max(quick.image.width, quick.image.height) == 1280 && max(refined.image.width, refined.image.height) == 2560)
        print("PASS: individual-channel curves preserve other channels, saturation/vibrance change pixels, interactive previews refine to final quality")
        var endpoints = PhotoAdjustments()
        endpoints.curves.rgb = [CurvePoint(x: 0.15, y: 0), CurvePoint(x: 0.85, y: 1)]
        precondition(endpoints.valid && !endpoints.curves.isIdentity)
        precondition(PhotoCurves.value(0.05, points: endpoints.curves.rgb) == 0 && PhotoCurves.value(0.95, points: endpoints.curves.rgb) == 1)
        precondition(abs(PhotoCurves.value(0.5, points: endpoints.curves.rgb) - 0.5) < 0.000001)
        let endpointData = try JSONEncoder().encode(endpoints)
        let endpointRead = try JSONDecoder().decode(PhotoAdjustments.self, from: endpointData)
        precondition(endpointRead == endpoints)
        let stretched = await renderer.render(photo: file, root: root, fullSize: false, adjustments: endpoints)!
        precondition(stretched.histogram != baseline.histogram && stretched.curveHistogram.count == 4)
        endpoints.curves.rgb = [CurvePoint(x: 0.25, y: 0), CurvePoint(x: 0.75, y: 1)]
        let further = await renderer.render(photo: file, root: root, fullSize: false, adjustments: endpoints)!
        precondition(further.curveHistogram == stretched.curveHistogram && further.histogram != stretched.histogram)
        endpoints.curves.rgb = [CurvePoint(x: 0.15, y: 0.15), CurvePoint(x: 0.85, y: 0.85)]
        precondition(!endpoints.curves.isIdentity, "Clipped diagonal endpoints must still render")
        precondition(!PhotoCurves.valid([CurvePoint(x: 0.85, y: 0), CurvePoint(x: 0.15, y: 1)]))
        print("PASS: inward black/white endpoints stretch and clip the input range, round trip safely, prevent crossing and retain a stable pre-curve RGB/luminance histogram")


        let disk = PhotoDiskCache(directory: root.appendingPathComponent("Cache"))
        let thumbnails = AdjustedThumbnailService(disk: disk)
        let edited = await thumbnails.thumbnail(photo: file, root: root, adjustments: settings)!
        precondition(max(edited.width, edited.height) <= 360)
        let fresh = AdjustedThumbnailService(disk: disk)
        var named = settings; named.presetID = UUID()
        let cached = await fresh.thumbnail(photo: file, root: root, adjustments: named)!
        precondition(cached.width == edited.width)
        let hits = await fresh.diskHits, renders = await fresh.renders
        precondition(hits == 1 && renders == 0)
        _ = await fresh.thumbnail(photo: file, root: root, adjustments: red)
        let rerenders = await fresh.renders
        precondition(rerenders == 1 && disk.usage().thumbnails == 1)
        let restored = await fresh.thumbnail(photo: file, root: root, adjustments: PhotoAdjustments())!
        precondition(restored.width > 0)
        let after = try Data(contentsOf: photo); precondition(after == bytes)
        paint(CGColor(red: 0.7, green: 0.3, blue: 0.2, alpha: 1))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: photo.path)
        _ = await fresh.thumbnail(photo: file, root: root, adjustments: red)
        let invalidated = await fresh.renders; precondition(invalidated == 2)
        print("PASS: edited thumbnails persist, ignore preset-name-only changes, replace old settings, reset to originals and invalidate on source changes")

        if let path = ProcessInfo.processInfo.environment["PIXELROLL_PERFORMANCE_SAMPLE"] {
            let raw = PhotoFile(url: URL(fileURLWithPath: path))
            let rawRenderer = DevelopRenderer()
            let start = Date()
            let original = await rawRenderer.render(photo: raw, root: raw.url.deletingLastPathComponent(), fullSize: false, interactive: true)!
            let cold = Date().timeIntervalSince(start)
            var warm = [Double]()
            for exposure in [0.25, 0.5, 0.75] {
                var edit = PhotoAdjustments(); edit.exposure = exposure
                let start = Date()
                _ = await rawRenderer.render(photo: raw, root: raw.url.deletingLastPathComponent(), fullSize: false, adjustments: edit, interactive: true)
                warm.append(Date().timeIntervalSince(start))
            }
            var white = PhotoAdjustments(); white.whiteBalance = .custom; white.temperature = 8500; white.tint = 12
            _ = await rawRenderer.render(photo: raw, root: raw.url.deletingLastPathComponent(), fullSize: false, adjustments: white, interactive: true)
            let reset = await rawRenderer.render(photo: raw, root: raw.url.deletingLastPathComponent(), fullSize: false, interactive: true)!
            let decoders = await rawRenderer.rawDecoderCreations
            precondition(original.status == "Developed RAW" && decoders == 1 && reset.histogram == original.histogram)
            print("PASS: RAW decoder reused across exposure/white-balance edits and As Shot reset; cold \(Int(cold*1000)) ms, warm average \(Int(warm.reduce(0,+)/Double(warm.count)*1000)) ms")
        }
    }
}
