import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

@MainActor enum Release15Checks {
    static func run(base: URL) async throws {
        let legacy = try JSONDecoder().decode(PhotoAdjustments.self, from: Data("{}".utf8))
        precondition(legacy.texture == 0 && legacy.clarity == 0 && legacy.dehaze == 0 && legacy.lensProfile == .automatic)
        precondition(legacy.distortion == 0 && legacy.vignette == 0 && legacy.redFringe == 0 && legacy.blueFringe == 0)
        for key in [\PhotoAdjustments.texture, \.clarity, \.dehaze, \.distortion, \.vignette, \.redFringe, \.blueFringe] {
            for value in [Double.nan, Double.infinity, -101, 101] {
                var bad = PhotoAdjustments(); bad[keyPath: key] = value; precondition(!bad.valid)
            }
        }
        print("PASS: legacy presence/lens defaults preserve previous rendering and invalid values are rejected")
        let root = base.appendingPathComponent("Release15")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("DetailChart.png")
        let w = 768, h = 512
        var bytes = [UInt8](repeating: 255, count: w*h*4)
        for y in 0..<h { for x in 0..<w {
            let fine = (x/3+y/3)%2 == 0 ? 12 : -12
            let broad = x < w/2 ? 20 : -20
            let level = 125+fine+broad
            let edge = x%128 < 12 || y%128 < 12
            bytes[(y*w+x)*4] = UInt8(edge ? 210 : level+20)
            bytes[(y*w+x)*4+1] = UInt8(edge ? 190 : level)
            bytes[(y*w+x)*4+2] = UInt8(edge ? 170 : level-10)
        }}
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w*4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil); precondition(CGImageDestinationFinalize(dest))
        let originalBytes = try Data(contentsOf: url)
        let renderer = DevelopRenderer(), file = PhotoFile(url: url)
        let neutral = await renderer.render(photo: file, root: root, fullSize: true)!
        func pixels(_ image: CGImage) -> [UInt8] {
            var result = [UInt8](repeating: 0, count: w*h*4)
            result.withUnsafeMutableBytes { storage in
                let cg = CGContext(data: storage.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                cg.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            return result
        }
        let baseline = pixels(neutral.image)
        var outputs: [[UInt8]] = []
        for key in [\PhotoAdjustments.texture, \.clarity, \.dehaze, \.distortion, \.vignette, \.redFringe, \.blueFringe] {
            for sign in [-1.0, 1.0] {
                var settings = PhotoAdjustments()
                settings[keyPath: key] = sign * ((key == \.redFringe || key == \.blueFringe) ? 8 : 70)
                let result = await renderer.render(photo: file, root: root, fullSize: true, adjustments: settings)!
                precondition(result.image.width == w && result.image.height == h)
                let output = pixels(result.image)
                precondition(output != baseline, "Each enabled Presence and manual lens control must affect pixels in both directions")
                precondition(stride(from: 3,to: output.count,by: 4).allSatisfy { output[$0] == 255 }, "Corrections must not introduce empty borders")
                if key == \.redFringe || key == \.blueFringe {
                    let unchanged = key == \.redFringe ? [1,2] : [0,1]
                    for channel in unchanged {
                        precondition(stride(from: channel,to: output.count,by: 4).allSatisfy { abs(Int(output[$0])-Int(baseline[$0])) <= 1 }, "Fringe alignment must preserve other channels")
                    }
                }
                outputs.append(output)
            }
        }
        precondition(outputs[0] != outputs[2], "Texture and clarity must use different spatial scales")
        print("PASS: all seven Presence/manual lens controls change pixels in both directions; fringe alignment preserves other channels and borders remain opaque")
        var on = PhotoAdjustments(); on.lensProfile = .enabled
        let raster = await renderer.render(photo: file, root: root, fullSize: true, adjustments: on)!
        precondition(!raster.lensProfileSupported && !raster.lensProfileEnabled && pixels(raster.image) == baseline)
        let reset = await renderer.render(photo: file, root: root, fullSize: true)!
        precondition(pixels(reset.image) == baseline)
        let after = try Data(contentsOf: url); precondition(after == originalBytes)
        print("PASS: unsupported profiles are reported honestly, resetting is exact and source bytes remain untouched")
        // Real RAW fixtures are optional, supplied as disposable copies for release verification.
        if let path = ProcessInfo.processInfo.environment["PIXELROLL_RAW_FIXTURES"] {
            let fixtures = URL(fileURLWithPath: path)
            for name in ["03-Nikon.NEF", "04-Leica.dng"] {
                let photo = PhotoFile(url: fixtures.appendingPathComponent(name))
                let before = try Data(contentsOf: photo.url)
                let fresh = DevelopRenderer()
                let auto = await fresh.render(photo: photo, root: fixtures, fullSize: false, maximumDimension: 800)!
                var off = PhotoAdjustments(); off.lensProfile = .disabled
                let disabled = await fresh.render(photo: photo, root: fixtures, fullSize: false, adjustments: off, maximumDimension: 800)!
                if auto.lensProfileSupported { precondition(!disabled.lensProfileEnabled) }
                var enabled = PhotoAdjustments(); enabled.lensProfile = .enabled
                let active = await fresh.render(photo: photo, root: fixtures, fullSize: false, adjustments: enabled, maximumDimension: 800)!
                if auto.lensProfileSupported { precondition(active.lensProfileEnabled) }
                let restored = await fresh.render(photo: photo, root: fixtures, fullSize: false, maximumDimension: 800)!
                precondition(restored.lensProfileEnabled == auto.lensProfileEnabled && restored.histogram == auto.histogram)
                let creations = await fresh.rawDecoderCreations; precondition(creations == 1)
                let untouched = try Data(contentsOf: photo.url); precondition(before == untouched)
                print("PASS: \(name) native lens profile supported=\(auto.lensProfileSupported), automatic=\(auto.lensProfileEnabled); On/Off/Automatic restore cached RAW state without changing source")
            }
        }
    }
}
