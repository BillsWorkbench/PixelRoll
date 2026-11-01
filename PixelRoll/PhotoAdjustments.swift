import Foundation
import CryptoKit

nonisolated struct PhotoAdjustments: Codable, Equatable, Sendable {
    enum LensProfile: String, Codable, CaseIterable, Sendable { case automatic = "Automatic", enabled = "On", disabled = "Off" }
    enum WhiteBalance: String, Codable, Sendable { case asShot, custom, gray }
    var exposure = 0.0
    var contrast = 0.0
    var highlights = 0.0
    var shadows = 0.0
    var whites = 0.0
    var blacks = 0.0
    var whiteBalance = WhiteBalance.asShot
    var temperature = 6500.0
    var tint = 0.0
    var redGain = 1.0
    var greenGain = 1.0
    var blueGain = 1.0
    var vibrance = 0.0
    var saturation = 0.0
    var sharpening = 0.0
    var luminanceNoise = 0.0
    var colorNoise = 0.0
    var texture = 0.0
    var clarity = 0.0
    var dehaze = 0.0
    var lensProfile = LensProfile.automatic
    var distortion = 0.0
    var vignette = 0.0
    var redFringe = 0.0
    var blueFringe = 0.0
    var crop = PhotoCrop()
    var curves = PhotoCurves()
    var presetID: UUID?
    var valid: Bool {
        [exposure, contrast, highlights, shadows, whites, blacks, temperature, tint, redGain, greenGain, blueGain].allSatisfy(\.isFinite) &&
        (-5...5).contains(exposure) && [contrast, highlights, shadows, whites, blacks, tint, vibrance, saturation, texture, clarity, dehaze, distortion, vignette].allSatisfy { (-100...100).contains($0) } &&
        (2000...12000).contains(temperature) && [redGain, greenGain, blueGain].allSatisfy { (0.1...8).contains($0) } && (0...150).contains(sharpening) && [luminanceNoise, colorNoise].allSatisfy { (0...100).contains($0) } && [redFringe, blueFringe].allSatisfy { (-10...10).contains($0) } && crop.valid && curves.valid
    }
    var contrastMultiplier: Double { 1 + contrast / 100 }
    var visual: Self { var copy = self; copy.presetID = nil; return copy }
    var cacheToken: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: (try? encoder.encode(visual)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    var hasEdits: Bool { var copy = self; copy.presetID = nil; return copy != Self() }
}

extension PhotoAdjustments {
    enum CodingKeys: String, CodingKey { case exposure, contrast, highlights, shadows, whites, blacks, whiteBalance, temperature, tint, redGain, greenGain, blueGain, vibrance, saturation, sharpening, luminanceNoise, colorNoise, texture, clarity, dehaze, lensProfile, distortion, vignette, redFringe, blueFringe, crop, curves, presetID }
    nonisolated init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try values.decodeIfPresent(Double.self, forKey: .exposure) ?? exposure
        contrast = try values.decodeIfPresent(Double.self, forKey: .contrast) ?? contrast
        highlights = try values.decodeIfPresent(Double.self, forKey: .highlights) ?? highlights
        shadows = try values.decodeIfPresent(Double.self, forKey: .shadows) ?? shadows
        whites = try values.decodeIfPresent(Double.self, forKey: .whites) ?? whites
        blacks = try values.decodeIfPresent(Double.self, forKey: .blacks) ?? blacks
        whiteBalance = try values.decodeIfPresent(WhiteBalance.self, forKey: .whiteBalance) ?? whiteBalance
        temperature = try values.decodeIfPresent(Double.self, forKey: .temperature) ?? temperature
        tint = try values.decodeIfPresent(Double.self, forKey: .tint) ?? tint
        redGain = try values.decodeIfPresent(Double.self, forKey: .redGain) ?? redGain
        greenGain = try values.decodeIfPresent(Double.self, forKey: .greenGain) ?? greenGain
        blueGain = try values.decodeIfPresent(Double.self, forKey: .blueGain) ?? blueGain
        vibrance = try values.decodeIfPresent(Double.self, forKey: .vibrance) ?? vibrance
        saturation = try values.decodeIfPresent(Double.self, forKey: .saturation) ?? saturation
        sharpening = try values.decodeIfPresent(Double.self, forKey: .sharpening) ?? sharpening
        luminanceNoise = try values.decodeIfPresent(Double.self, forKey: .luminanceNoise) ?? luminanceNoise
        colorNoise = try values.decodeIfPresent(Double.self, forKey: .colorNoise) ?? colorNoise
        texture = try values.decodeIfPresent(Double.self, forKey: .texture) ?? texture
        clarity = try values.decodeIfPresent(Double.self, forKey: .clarity) ?? clarity
        dehaze = try values.decodeIfPresent(Double.self, forKey: .dehaze) ?? dehaze
        distortion = try values.decodeIfPresent(Double.self, forKey: .distortion) ?? distortion
        vignette = try values.decodeIfPresent(Double.self, forKey: .vignette) ?? vignette
        redFringe = try values.decodeIfPresent(Double.self, forKey: .redFringe) ?? redFringe
        blueFringe = try values.decodeIfPresent(Double.self, forKey: .blueFringe) ?? blueFringe
        lensProfile = try values.decodeIfPresent(LensProfile.self, forKey: .lensProfile) ?? lensProfile
        crop = try values.decodeIfPresent(PhotoCrop.self, forKey: .crop) ?? crop
        curves = try values.decodeIfPresent(PhotoCurves.self, forKey: .curves) ?? curves
        presetID = try values.decodeIfPresent(UUID.self, forKey: .presetID)
        guard valid else { throw NotesError.invalid }
    }
}

nonisolated struct DevelopPreset: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var adjustments: PhotoAdjustments
}

// Presets travel with the photo library, just like the individual adjustment sidecars.
actor PresetStore {
    static let shared = PresetStore()
    nonisolated static func url(_ root: URL) -> URL { root.appendingPathComponent(".pixelroll-presets.json") }
    nonisolated struct Snapshot: Sendable { var presets: [DevelopPreset]; var revision: Data? }
    private struct Document: Codable { var version = 1; var presets: [DevelopPreset] }
    func read(root: URL) throws -> Snapshot {
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        let path = Self.url(root)
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) == nil else { throw NotesError.unsafeLink }
        guard FileManager.default.fileExists(atPath: path.path) else { return Snapshot(presets: [], revision: nil) }
        let data = try Data(contentsOf: path)
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1, document.presets.allSatisfy({ $0.adjustments.valid && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), Set(document.presets.map(\.id)).count == document.presets.count else { throw NotesError.invalid }
        return Snapshot(presets: document.presets, revision: data)
    }
    func save(_ presets: [DevelopPreset], root: URL, expected: Data?) throws -> Snapshot {
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        let current = try read(root: root)
        guard current.revision == expected else { throw NotesError.conflict }
        guard presets.allSatisfy({ $0.adjustments.valid && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), Set(presets.map(\.id)).count == presets.count else { throw NotesError.invalid }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(presets: presets))
        try data.write(to: Self.url(root), options: .atomic)
        return Snapshot(presets: presets, revision: data)
    }
}

import CoreGraphics

nonisolated enum GrayBalance {
    static func gains(image: CGImage, x: Double, y: Double) -> (Double, Double, Double)? {
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        let pixelX = min(image.width - 1, Int(x * Double(image.width)))
        let pixelY = min(image.height - 1, Int((1-y) * Double(image.height)))
        guard let patch = image.cropping(to: CGRect(x: max(0, pixelX - 2), y: max(0, pixelY - 2), width: min(5, image.width - max(0, pixelX - 2)), height: min(5, image.height - max(0, pixelY - 2)))) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        let success = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(patch, in: CGRect(x: 0, y: 0, width: 1, height: 1)); return true
        }
        guard success, bytes[3] > 250 else { return nil }
        let linear = bytes.prefix(3).map { byte -> Double in let v = Double(byte)/255; return v <= 0.04045 ? v/12.92 : pow((v+0.055)/1.055, 2.4) }
        guard linear.min()! > 0.015, linear.max()! < 0.98 else { return nil }
        let gray = linear.reduce(0,+)/3
        let gains = linear.map { min(8, max(0.1, gray/$0)) }
        return (gains[0], gains[1], gains[2])
    }
}
