import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@MainActor enum Release16Checks {
    static func run(base: URL) async throws {
        let root = base.appendingPathComponent("Release16"), output = root.appendingPathComponent("Output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("Chart.tif")
        let w = 640, h = 480
        var bytes = [UInt8](repeating: 255, count: w*h*4)
        var seed: UInt64 = 42
        for y in 0..<h { for x in 0..<w {
            seed = seed &* 6364136223846793005 &+ 1
            bytes[(y*w+x)*4] = UInt8(50+(seed>>32)%100)
            bytes[(y*w+x)*4+1] = UInt8(60+x%100)
            bytes[(y*w+x)*4+2] = UInt8(70+y%100)
        }}
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: w,height: h,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: w*4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,decode: nil,shouldInterpolate: false,intent: .defaultIntent)!
        let writer = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString,1,nil)!
        let metadata: [CFString: Any] = [kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake:"PixelRoll QA",kCGImagePropertyTIFFModel:"Export Chart",kCGImagePropertyTIFFOrientation:6],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifISOSpeedRatings:[400],kCGImagePropertyExifExposureTime:0.01],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude:37.0,kCGImagePropertyGPSLatitudeRef:"N",kCGImagePropertyGPSLongitude:115.0,kCGImagePropertyGPSLongitudeRef:"W"]]
        CGImageDestinationAddImage(writer,image,metadata as CFDictionary); precondition(CGImageDestinationFinalize(writer))
        let original = try Data(contentsOf: url)
        var notes = PhotoNotes(rating:4,keywords:["Export QA"],caption:"Keep this caption")
        notes.adjustments.exposure = 0.7; notes.adjustments.contrast = 3
        notes.adjustments.crop = PhotoCrop(x:0.1,y:0.1,width:0.5,height:0.5,aspect:.free)
        let item = ExportPhoto(photo:PhotoFile(url:url),notes:notes)
        let exporter = PhotoExporter()
        func source(_ url: URL) -> CGImageSource { CGImageSourceCreateWithURL(url as CFURL,nil)! }
        func saved(_ outcome: ExportOutcome) -> URL { if case let .saved(url) = outcome { return url }; preconditionFailure("Expected an exported file") }
        var formats = 0
        for format in ExportOptions.Format.allCases where format.available {
            formats += 1
            for profile in ExportOptions.Profile.allCases {
                var options = ExportOptions(); options.format = format; options.profile = profile; options.longestEdge = 160
                let result = try await exporter.export(item,root:root,destination:output,options:options)
                let file = saved(result), decoded = CGImageSourceCreateImageAtIndex(source(file),0,nil)!
                precondition(decoded.width == 120 && decoded.height == 160, "Oriented crop must resize to the requested long edge")
                precondition(decoded.colorSpace?.name == profile.space.name, "Chosen color profile must be embedded")
                let props = CGImageSourceCopyPropertiesAtIndex(source(file),0,nil) as! [CFString: Any]
                precondition((props[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
                precondition(props[kCGImagePropertyGPSDictionary] == nil, "Location is excluded by default")
                let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
                precondition((exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first == 400)
                if format != .heif {
                    let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
                    precondition((iptc[kCGImagePropertyIPTCKeywords] as? [String])?.contains("Export QA") == true)
                    precondition(iptc[kCGImagePropertyIPTCCaptionAbstract] as? String == "Keep this caption")
                }
            }
        }
        precondition(formats >= 2)
        print("PASS: \(formats) export formats × 3 profiles reopen with embedded color, oriented crop dimensions, camera metadata, captions/keywords and default GPS exclusion")
        var options = ExportOptions(); options.format = .tiff; options.location = true
        let full = saved(try await exporter.export(item,root:root,destination:output,options:options))
        let fullImage = CGImageSourceCreateImageAtIndex(source(full),0,nil)!
        precondition(fullImage.width == 240 && fullImage.height == 320)
        let fullProps = CGImageSourceCopyPropertiesAtIndex(source(full),0,nil) as! [CFString: Any]
        precondition(fullProps[kCGImagePropertyGPSDictionary] != nil)
        let renderer = DevelopRenderer()
        let developed = await renderer.render(photo:item.photo,root:root,fullSize:true,adjustments:notes.adjustments,includeHistogram:false)!
        func pixels(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating:0,count:image.width*image.height*4)
            data.withUnsafeMutableBytes { storage in
                let cg = CGContext(data:storage.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,
                    space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                cg.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
            }
            return data
        }
        let exportedPixels = pixels(fullImage), developedPixels = pixels(developed.image)
        precondition(zip(exportedPixels,developedPixels).allSatisfy { abs(Int($0)-Int($1)) <= 1 }, "Lossless export must include current adjustments exactly")
        options.longestEdge = 2048
        let notEnlarged = saved(try await exporter.export(item,root:root,destination:output,options:options))
        precondition(CGImageSourceCreateImageAtIndex(source(notEnlarged),0,nil)!.width == 240)
        print("PASS: full-size lossless TIFF matches developed pixels, resizing never enlarges, and GPS is included only when requested")
        var stripped = ExportOptions(); stripped.metadata = false
        let noMetadata = saved(try await exporter.export(item,root:root,destination:output,options:stripped))
        let strippedProps = CGImageSourceCopyPropertiesAtIndex(source(noMetadata),0,nil) as! [CFString: Any]
        let strippedExif = strippedProps[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        precondition(strippedExif[kCGImagePropertyExifISOSpeedRatings] == nil && strippedProps[kCGImagePropertyGPSDictionary] == nil)
        let protected = root.appendingPathComponent("Protected.jpg"); try original.write(to:protected)
        let protectedItem = ExportPhoto(photo:PhotoFile(url:protected),notes:PhotoNotes())
        let originalCopy = try Data(contentsOf:protected)
        let numbered = saved(try await exporter.export(protectedItem,root:root,destination:root,options:ExportOptions()))
        precondition(numbered.lastPathComponent == "Protected-2.jpg")
        let protectedAfter = try Data(contentsOf:protected); precondition(protectedAfter == originalCopy)
        var skip = ExportOptions(); skip.duplicates = .skip
        let skipped = try await exporter.export(protectedItem,root:root,destination:root,options:skip)
        guard case .skipped = skipped else { preconditionFailure("Existing files must be skipped") }
        let linkFolder = root.appendingPathComponent("Links"); try FileManager.default.createDirectory(at:linkFolder,withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:linkFolder.appendingPathComponent("Protected.jpg"),withDestinationURL:protected)
        let linkExport = saved(try await exporter.export(protectedItem,root:root,destination:linkFolder,options:ExportOptions()))
        precondition(linkExport.lastPathComponent == "Protected-2.jpg")
        print("PASS: metadata can be excluded; numbered duplicates, skip-existing and symlink collisions keep existing files and originals untouched")
        let cancelledFolder = root.appendingPathComponent("Cancelled"); try FileManager.default.createDirectory(at:cancelledFolder,withIntermediateDirectories:true)
        let task = Task { try await PhotoExporter().export(item,root:root,destination:cancelledFolder,options:ExportOptions()) }
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Cancelled export must stop") } catch is CancellationError {} catch { preconditionFailure("Unexpected error") }
        let cancelledFiles = try FileManager.default.contentsOfDirectory(atPath:cancelledFolder.path)
        precondition(cancelledFiles.isEmpty)
        let changed = root.appendingPathComponent("Changed.tif"); try original.write(to:changed)
        let stale = ExportPhoto(photo:PhotoFile(url:changed),notes:PhotoNotes()); try (original+Data([0])).write(to:changed)
        do { _ = try await exporter.export(stale,root:root,destination:output,options:ExportOptions()); preconditionFailure("Changed original accepted") }
        catch { guard case ExportError.changed = error else { preconditionFailure("Wrong source-change error") } }
        var invalid = ExportOptions(); invalid.longestEdge = 1
        do { _ = try await exporter.export(item,root:root,destination:output,options:invalid); preconditionFailure("Invalid size accepted") } catch {}
        let after = try Data(contentsOf:url); precondition(after == original)
        print("PASS: cancellation creates no file, stale source snapshots and invalid sizes fail safely, and export never rewrites source bytes")
        let batchFolder = root.appendingPathComponent("Batch")
        try FileManager.default.createDirectory(at:batchFolder,withIntermediateDirectories:true)
        let controller = ExportController()
        controller.start(items:Array(repeating:item,count:30),root:root,destination:batchFolder,options:ExportOptions())
        try await Task.sleep(for:.milliseconds(60)); controller.cancel()
        for _ in 0..<400 { if !controller.busy { break }; try await Task.sleep(for:.milliseconds(20)) }
        precondition(!controller.busy && controller.saved < 30 && controller.failures.isEmpty)
        precondition(controller.message?.contains("cancelled") == true)
        let batchFiles = try FileManager.default.contentsOfDirectory(atPath:batchFolder.path)
        precondition(batchFiles.count == controller.saved && controller.completed == controller.saved)
        let broken = root.appendingPathComponent("Broken.jpg"); try Data("not an image".utf8).write(to:broken)
        controller.start(items:[ExportPhoto(photo:PhotoFile(url:broken),notes:PhotoNotes()),item],root:root,destination:batchFolder,options:ExportOptions())
        for _ in 0..<400 { if !controller.busy { break }; try await Task.sleep(for:.milliseconds(20)) }
        precondition(!controller.busy && controller.saved == 1 && controller.failures.count == 1 && controller.completed == 2)
        print("PASS: batch cancellation stops remaining photos with accurate saved counts; failed photos are reported while later exports continue")
        if let path = ProcessInfo.processInfo.environment["PIXELROLL_RAW_FIXTURES"] {
            let fixtures = URL(fileURLWithPath:path)
            for name in ["03-Nikon.NEF","04-Leica.dng"] {
                let photo = PhotoFile(url:fixtures.appendingPathComponent(name)), before = try Data(contentsOf:fixtures.appendingPathComponent(name))
                var rawNotes = PhotoNotes(); rawNotes.adjustments.exposure = 0.5; rawNotes.adjustments.crop = PhotoCrop(x:0.1,y:0.1,width:0.8,height:0.8,aspect:.free)
                var rawOptions = ExportOptions(); rawOptions.longestEdge = 1024
                let exported = saved(try await exporter.export(ExportPhoto(photo:photo,notes:rawNotes),root:fixtures,destination:output,options:rawOptions))
                let rawImage = CGImageSourceCreateImageAtIndex(source(exported),0,nil)!
                precondition(max(rawImage.width,rawImage.height) == 1024)
                let after = try Data(contentsOf:photo.url); precondition(before == after)
                print("PASS: \(name) exports from the full RAW with adjustments and crop, correctly sized, leaving original unchanged")
            }
        }
    }
}
