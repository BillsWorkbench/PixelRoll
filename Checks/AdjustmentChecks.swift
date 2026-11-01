import Foundation
import CoreGraphics

@MainActor enum AdjustmentChecks {
    static func run(base: URL, imageData: Data) async throws {
        let root = base.appendingPathComponent("Editing")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("First.jpg"), second = root.appendingPathComponent("Second.jpg")
        try imageData.write(to: first); try imageData.write(to: second)
        var notes = PhotoNotes(rating: 4, keywords: ["Travel"], caption: "Keep caption")
        var adjustments = PhotoAdjustments(); adjustments.exposure = 1.25; adjustments.contrast = 12; adjustments.shadows = 20
        adjustments.whiteBalance = .custom; adjustments.temperature = 7200; adjustments.tint = 8
        adjustments.sharpening = 45; adjustments.luminanceNoise = 25; adjustments.colorNoise = 35
        adjustments.crop = PhotoCrop(x: 0.1, y: 0.1, width: 0.7, height: 0.8, angle: 3, aspect: .free)
        adjustments.texture = 25; adjustments.clarity = -20; adjustments.dehaze = 15
        adjustments.lensProfile = .disabled; adjustments.distortion = 12; adjustments.vignette = 15
        adjustments.redFringe = 2.5; adjustments.blueFringe = -1.5
        notes.adjustments = adjustments
        let saved = try await NotesStore.shared.save(notes, photo: first, access: root, expected: nil)
        let read = try NotesStore.read(first)
        precondition(read.notes == notes)
        var object = try JSONSerialization.jsonObject(with: saved.revision!) as! [String: Any]
        var fields = object["adjustments"] as! [String: Any]; fields["futureAdjustment"] = 42
        object["adjustments"] = fields
        try JSONSerialization.data(withJSONObject: object).write(to: NotesStore.sidecar(for: first))
        let unknown = try NotesStore.read(first)
        var reset = unknown.notes; reset.adjustments = PhotoAdjustments()
        let resetSaved = try await NotesStore.shared.save(reset, photo: first, access: root, expected: unknown.revision)
        let resetObject = try JSONSerialization.jsonObject(with: resetSaved.revision!) as! [String: Any]
        precondition((resetObject["adjustments"] as! [String: Any])["futureAdjustment"] as? Int == 42)
        object.removeValue(forKey: "adjustments")
        try JSONSerialization.data(withJSONObject: object).write(to: NotesStore.sidecar(for: first))
        let legacy = try NotesStore.read(first)
        precondition(legacy.notes.adjustments == PhotoAdjustments())
        var invalid = adjustments; invalid.exposure = 100
        var invalidNotes = notes; invalidNotes.adjustments = invalid
        do { _ = try await NotesStore.shared.save(invalidNotes, photo: second, access: root, expected: nil); preconditionFailure("Invalid adjustments accepted") }
        catch { precondition(error is NotesError) }
        print("PASS: adjustment sidecar round trip, legacy defaults, unknown adjustment preservation, range validation and reset")

        let presets = PresetStore()
        let empty = try await presets.read(root: root)
        let preset = DevelopPreset(name: "Warm Travel", adjustments: adjustments)
        let stored = try await presets.save([preset], root: root, expected: empty.revision)
        let fresh = try await PresetStore().read(root: root)
        precondition(fresh.presets == [preset])
        do { _ = try await presets.save([], root: root, expected: nil); preconditionFailure("Preset conflict ignored") } catch { precondition(error is NotesError) }
        _ = try await presets.save([DevelopPreset(id: preset.id, name: preset.name, adjustments: PhotoAdjustments())], root: root, expected: stored.revision)
        print("PASS: portable presets survive fresh reads, update by identity and protect concurrent writes")

        let suite = "PixelRoll.adjustments.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LibraryModel(defaults: defaults)
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        model.open(root)
        for _ in 0..<400 { if !model.isScanning { break }; try await Task.sleep(for: .milliseconds(20)) }
        precondition(model.photos.count == 2)
        let firstID = model.photos.first { $0.url.lastPathComponent == "First.jpg" }!.id
        let secondID = model.photos.first { $0.url.lastPathComponent == "Second.jpg" }!.id
        undo.beginUndoGrouping()
        model.setAdjustments(adjustments, for: [firstID, secondID], action: "Paste Adjustments")
        undo.endUndoGrouping()
        precondition(model.draft(for: firstID).adjustments == adjustments && model.draft(for: secondID).adjustments == adjustments)
        precondition(model.draft(for: firstID).caption == "Keep caption" && model.draft(for: secondID).rating == 0)
        undo.undo()
        precondition(model.draft(for: firstID).adjustments == PhotoAdjustments() && model.draft(for: secondID).adjustments == PhotoAdjustments())
        undo.redo()
        for _ in 0..<400 { if model.currentPendingIDs.isEmpty { break }; try await Task.sleep(for: .milliseconds(20)) }
        precondition(model.currentPendingIDs.isEmpty)
        let reopened = try NotesStore.read(second)
        precondition(reopened.notes.adjustments == adjustments)
        print("PASS: batch adjustment paste preserves notes, grouped undo/redo and automatic sidecar saving")

        let renderer = DevelopRenderer()
        let original = await renderer.render(photo: PhotoFile(url: first), root: root, fullSize: false)!
        let changed = await renderer.render(photo: PhotoFile(url: first), root: root, fullSize: false, adjustments: adjustments)!
        precondition(original.histogram != changed.histogram && original.image.width > changed.image.width)
        for key in [\PhotoAdjustments.exposure, \.contrast, \.highlights, \.shadows, \.whites, \.blacks, \.temperature, \.tint] {
            var one = PhotoAdjustments()
            one[keyPath: key] = key == \.exposure ? 1 : key == \.temperature ? 8500 : 40
            if key == \.temperature || key == \.tint { one.whiteBalance = .custom }
            let result = await renderer.render(photo: PhotoFile(url: first), root: root, fullSize: false, adjustments: one)!
            precondition(result.histogram != original.histogram, "Each active control must affect pixels")
        }
        let before = await renderer.render(photo: PhotoFile(url: first), root: root, fullSize: false)!
        precondition(before.histogram == original.histogram)
        let color = CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        color.setFillColor(CGColor(red: 0.6, green: 0.4, blue: 0.3, alpha: 1)); color.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        let gains = GrayBalance.gains(image: color.makeImage()!, x: 0.5, y: 0.5)!
        precondition(gains.0 < gains.1 && gains.1 < gains.2)
        color.setFillColor(CGColor(gray: 0, alpha: 1)); color.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        precondition(GrayBalance.gains(image: color.makeImage()!, x: 0.5, y: 0.5) == nil)
        let firstBytes = try Data(contentsOf: first), secondBytes = try Data(contentsOf: second)
        precondition(firstBytes == imageData && secondBytes == imageData)
        print("PASS: adjustments change rendered pixels/histogram, before restores baseline, gray sampling corrects channel bias, originals unchanged")
    }
}
