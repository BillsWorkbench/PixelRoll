import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@MainActor enum Release13Checks {
    static func run(base: URL) async throws {
        let legacy = try JSONDecoder().decode(PhotoAdjustments.self, from: Data("{}".utf8))
        precondition(legacy.sharpening == 0 && legacy.luminanceNoise == 0 && legacy.colorNoise == 0 && !legacy.hasEdits)
        for key in [\PhotoAdjustments.sharpening, \.luminanceNoise, \.colorNoise] {
            for value in [-1.0, Double.infinity, Double.nan, 151] {
                var bad = PhotoAdjustments(); bad[keyPath: key] = value; precondition(!bad.valid)
            }
        }
        var contrast = PhotoAdjustments(); contrast.contrast = 5
        precondition(abs(contrast.contrastMultiplier - 1.05) < 1e-9)
        contrast.contrast = -5; precondition(abs(contrast.contrastMultiplier - 0.95) < 1e-9)
        print("PASS: legacy detail defaults stay neutral, invalid detail amounts rejected, contrast ±5 keeps original strength")

        let root = base.appendingPathComponent("Release13")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let photo = root.appendingPathComponent("Noise.png")
        let size = 128
        var bytes = [UInt8](repeating: 255, count: size*size*4)
        var seed: UInt64 = 42
        for y in 0..<size { for x in 0..<size {
            let base = x < size/2 ? 100 : 150
            for c in 0..<3 {
                seed = seed &* 6364136223846793005 &+ 1
                bytes[(y*size+x)*4+c] = UInt8(base + Int((seed >> 32) % 17)-8)
            }
        }}
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size*4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithURL(photo as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil); precondition(CGImageDestinationFinalize(dest))
        let originalBytes = try Data(contentsOf: photo)
        let renderer = DevelopRenderer()
        let file = PhotoFile(url: photo)
        let neutral = await renderer.render(photo: file, root: root, fullSize: true)!
        func pixels(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: size*size*4)
            data.withUnsafeMutableBytes { buffer in
                let cg = CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8,
                    bytesPerRow: size*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                cg.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            }
            return data
        }
        func noise(_ data: [UInt8], color: Bool) -> Double {
            var values: [Double] = []
            for y in 8..<56 { for x in 8..<56 {
                let i = (y*size+x)*4
                let r=Double(data[i]), g=Double(data[i+1]), b=Double(data[i+2])
                values.append(color ? r-g : 0.2126*r+0.7152*g+0.0722*b)
            }}
            let mean = values.reduce(0,+)/Double(values.count)
            return values.map { pow($0-mean,2) }.reduce(0,+)/Double(values.count)
        }
        let baseline = pixels(neutral.image)
        for key in [\PhotoAdjustments.sharpening, \.luminanceNoise, \.colorNoise] {
            var setting = PhotoAdjustments(); setting[keyPath: key] = 100
            let result = await renderer.render(photo: file, root: root, fullSize: true, adjustments: setting)!
            let changed = pixels(result.image)
            precondition(changed != baseline, "Every detail control must affect pixels")
            precondition(result.image.width == size && result.image.height == size)
            if key == \.colorNoise { precondition(noise(changed, color: true) < noise(baseline, color: true)*0.6) }
            if key == \.luminanceNoise { precondition(noise(changed, color: false) < noise(baseline, color: false)*0.9) }
        }
        let reset = await renderer.render(photo: file, root: root, fullSize: true)!
        precondition(pixels(reset.image) == baseline)
        let finalBytes = try Data(contentsOf: photo); precondition(originalBytes == finalBytes)
        print("PASS: sharpening changes pixels; independent noise controls reduce luminance/chroma variance; reset is exact and source untouched")
    }
}
