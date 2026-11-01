import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@MainActor enum Release14Checks {
    static func run(base: URL) async throws {
        let legacy = try JSONDecoder().decode(PhotoAdjustments.self, from: Data("{}".utf8))
        precondition(legacy.crop == PhotoCrop())
        for crop in [PhotoCrop(x: -0.01), PhotoCrop(width: 0), PhotoCrop(x: 0.2), PhotoCrop(angle: 46), PhotoCrop(angle: .nan)] { precondition(!crop.valid) }
        for source in [0.5, 1, 1.5, 2.0] {
            for aspect in PhotoCrop.Aspect.allCases {
                for flipped in [false, true] {
                    let crop = PhotoCrop(x: 0.1, y: 0.1, width: 0.8, height: 0.8, aspect: aspect, flipped: flipped).fitted(sourceAspect: source)
                    precondition(crop.valid)
                    if let ratio = crop.ratio(sourceAspect: source) { precondition(abs(crop.width/crop.height-ratio) < 1e-8) }
                    for corner in PhotoCrop.Corner.allCases {
                        for dx in [-2.0, -0.3, 0, 0.3, 2] { for dy in [-2.0, -0.3, 0, 0.3, 2] {
                            let changed = crop.resized(corner, dx: dx, dy: dy, sourceAspect: source)
                            precondition(changed.valid)
                            if let ratio = crop.ratio(sourceAspect: source) { precondition(abs(changed.width/changed.height-ratio) < 1e-8) }
                        }}
                    }
                    precondition(crop.moved(dx: -10, dy: 10).valid)
                }
            }
        }
        print("PASS: crop ratios/orientation and corner resizing remain bounded for landscape/portrait; legacy sidecars default to uncropped")
        let root = base.appendingPathComponent("Release14")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let photo = root.appendingPathComponent("Quadrants.png")
        let w = 400, h = 300
        var bytes = [UInt8](repeating: 255, count: w*h*4)
        let colors: [[UInt8]] = [[220,30,30], [30,220,30], [30,30,220], [220,220,30]]
        for y in 0..<h { for x in 0..<w {
            let color = colors[(y < h/2 ? 0 : 2)+(x < w/2 ? 0 : 1)]
            for c in 0..<3 { bytes[(y*w+x)*4+c] = color[c] }
        }}
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w*4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(photo as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil); precondition(CGImageDestinationFinalize(destination))
        let originalData = try Data(contentsOf: photo)
        let renderer = DevelopRenderer(), file = PhotoFile(url: photo)
        let neutral = await renderer.render(photo: file, root: root, fullSize: true)!
        var adjustments = PhotoAdjustments(); adjustments.crop = PhotoCrop(x: 0, y: 0, width: 0.5, height: 0.5, aspect: .free)
        let topLeft = await renderer.render(photo: file, root: root, fullSize: true, adjustments: adjustments)!
        precondition(topLeft.image.width == 200 && topLeft.image.height == 150)
        precondition(abs(topLeft.sourceAspect - 4.0/3) < 1e-8)
        let bins = topLeft.histogram
        precondition(bins[0].enumerated().max(by: {$0.element < $1.element})!.offset > 90)
        precondition(bins[2].enumerated().max(by: {$0.element < $1.element})!.offset < 30, "Top-left crop must preserve top-left orientation")
        print("PASS: crop render dimensions and top-left coordinates match the selected region; source aspect stays stable")
        adjustments.crop = PhotoCrop(angle: 25)
        let turned = await renderer.render(photo: file, root: root, fullSize: true, adjustments: adjustments)!
        precondition(turned.image.width < w && turned.image.height < h)
        let expected = PhotoCrop.straightenedSize(CGSize(width: w,height: h), angle: 25)
        precondition(abs(Double(turned.image.width)-expected.width) < 2)
        var rgba = [UInt8](repeating: 0, count: turned.image.width*turned.image.height*4)
        rgba.withUnsafeMutableBytes { storage in
            let cg = CGContext(data: storage.baseAddress, width: turned.image.width, height: turned.image.height, bitsPerComponent: 8,
                bytesPerRow: turned.image.width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            cg.draw(turned.image, in: CGRect(x: 0,y: 0,width: turned.image.width,height: turned.image.height))
        }
        precondition(stride(from: 3,to: rgba.count,by: 4).allSatisfy { rgba[$0] >= 254 }, "Straightening must leave no transparent corners")
        let reset = await renderer.render(photo: file, root: root, fullSize: true)!
        precondition(reset.histogram == neutral.histogram && reset.image.width == w && reset.image.height == h)
        let dataAfter = try Data(contentsOf: photo); precondition(dataAfter == originalData)
        print("PASS: straighten trims empty corners; reset restores full original composition without rewriting the photo")
        let cache = PhotoDiskCache(directory: root.appendingPathComponent("Cache"))
        let service = AdjustedThumbnailService(disk: cache)
        let thumbnail = await service.thumbnail(photo: file, root: root, adjustments: adjustments)!
        precondition(thumbnail.width < 360 && thumbnail.height < 270)
        let reopened = AdjustedThumbnailService(disk: cache)
        let cached = await reopened.thumbnail(photo: file, root: root, adjustments: adjustments)!
        precondition(cached.width == thumbnail.width && cached.height == thumbnail.height)
        let hits = await reopened.diskHits; precondition(hits == 1)
        print("PASS: library thumbnails use straighten/crop geometry and survive a fresh cache connection")
    }
}
