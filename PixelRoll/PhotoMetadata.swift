import Foundation
import ImageIO

struct MetadataField: Identifiable, Sendable {
    let id: String
    let label: String
    let value: String
}

struct MetadataSection: Identifiable, Sendable {
    let title: String
    let fields: [MetadataField]
    nonisolated var id: String { title }
}

struct PhotoMetadata: Sendable {
    let sections: [MetadataSection]
    let allFields: [MetadataField]
    let notice: String?
}

actor MetadataService {
    static let shared = MetadataService()

    func read(_ url: URL, root: URL) -> PhotoMetadata {
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        var file = [MetadataField(id: "file.name", label: "Filename", value: url.lastPathComponent),
                    MetadataField(id: "file.folder", label: "Folder", value: url.deletingLastPathComponent().path),
                    MetadataField(id: "file.format", label: "Extension", value: url.pathExtension.uppercased())]
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey]) {
            if let size = values.fileSize { file.append(MetadataField(id: "file.size", label: "File Size", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))) }
            for (key, label, date) in [("created", "File Created", values.creationDate), ("modified", "File Modified", values.contentModificationDate)] {
                if let date { file.append(MetadataField(id: "file." + key, label: label, value: date.formatted(date: .abbreviated, time: .standard))) }
            }
        }
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return PhotoMetadata(sections: [MetadataSection(title: "File", fields: file)], allFields: file,
                                 notice: "Embedded metadata couldn’t be read. File details are still available.")
        }
        if let type = CGImageSourceGetType(source) { file.append(MetadataField(id: "file.type", label: "Image Type", value: type as String)) }
        if let width = properties["PixelWidth"] as? NSNumber, let height = properties["PixelHeight"] as? NSNumber {
            let orientation = (properties["Orientation"] as? NSNumber)?.intValue ?? 1
            let rotated = (5...8).contains(orientation)
            file.append(MetadataField(id: "file.dimensions", label: "Dimensions", value: "\(rotated ? height : width) × \(rotated ? width : height) pixels"))
        }
        let exif = properties["{Exif}"] as? [String: Any] ?? [:]
        let tiff = properties["{TIFF}"] as? [String: Any] ?? [:]
        let aux = properties["{ExifAux}"] as? [String: Any] ?? [:]
        let iptc = properties["{IPTC}"] as? [String: Any] ?? [:]
        var sections = [MetadataSection(title: "File", fields: file)]
        func fields(_ dictionary: [String: Any], _ keys: [(String, String)], prefix: String) -> [MetadataField] {
            keys.compactMap { key, label in
                guard let value = dictionary[key] else { return nil }
                let text = Self.describe(value)
                guard !text.isEmpty else { return nil }
                return MetadataField(id: prefix + key, label: label, value: text)
            }
        }
        var camera = fields(tiff, [("Make", "Maker"), ("Model", "Camera"), ("Software", "Software")], prefix: "tiff.")
        camera += fields(exif, [("LensMake", "Lens Maker"), ("LensModel", "Lens"), ("BodySerialNumber", "Camera Serial"), ("LensSerialNumber", "Lens Serial")], prefix: "exif.")
        camera += fields(aux, [("LensModel", "Lens"), ("LensInfo", "Lens Specification"), ("SerialNumber", "Camera Serial"), ("LensSerialNumber", "Lens Serial"), ("ImageNumber", "Image Number"), ("ShutterCount", "Shutter Count")], prefix: "aux.")
        sections.append(MetadataSection(title: "Camera & Lens", fields: camera))
        var exposure: [MetadataField] = []
        func number(_ key: String, label: String, format: (Double) -> String) {
            if let n = exif[key] as? NSNumber { exposure.append(MetadataField(id: "exposure." + key, label: label, value: format(n.doubleValue))) }
        }
        number("ExposureTime", label: "Shutter Speed") { value in
            value > 0 && value < 1 ? "1/\(Self.decimal(1 / value)) s" : "\(Self.decimal(value)) s"
        }
        number("FNumber", label: "Aperture") { "ƒ/" + Self.decimal($0) }
        exposure += fields(exif, [("ISOSpeedRatings", "ISO")], prefix: "exposure.")
        number("FocalLength", label: "Focal Length") { Self.decimal($0) + " mm" }
        number("FocalLenIn35mmFilm", label: "35 mm Equivalent") { Self.decimal($0) + " mm" }
        number("ExposureBiasValue", label: "Exposure Compensation") { Self.decimal($0) + " EV" }
        for (key, label, names) in [
            ("ExposureProgram", "Exposure Program", [0: "Not defined", 1: "Manual", 2: "Program", 3: "Aperture priority", 4: "Shutter priority", 5: "Creative program", 6: "Action program", 7: "Portrait", 8: "Landscape"]),
            ("MeteringMode", "Metering", [0: "Unknown", 1: "Average", 2: "Center-weighted", 3: "Spot", 4: "Multi-spot", 5: "Pattern", 6: "Partial", 255: "Other"]),
            ("WhiteBalance", "White Balance", [0: "Auto", 1: "Manual"])
        ] {
            if let n = exif[key] as? NSNumber { exposure.append(MetadataField(id: "exposure." + key, label: label, value: names[n.intValue] ?? n.stringValue)) }
        }
        number("SubjectDistance", label: "Subject Distance") { Self.decimal($0) + " m" }
        if let flash = exif["Flash"] as? NSNumber {
            exposure.append(MetadataField(id: "exposure.Flash", label: "Flash", value: (flash.intValue & 1) == 1 ? "Fired" : "Did not fire"))
        }
        sections.append(MetadataSection(title: "Exposure", fields: exposure))
        sections.append(MetadataSection(title: "Capture Time", fields: fields(exif, [
            ("DateTimeOriginal", "Captured"), ("OffsetTimeOriginal", "Capture UTC Offset"), ("SubsecTimeOriginal", "Subsecond"),
            ("DateTimeDigitized", "Digitized"), ("OffsetTimeDigitized", "Digitized UTC Offset")
        ], prefix: "capture.") + fields(tiff, [("DateTime", "Metadata Date")], prefix: "capture.tiff.")))
        sections.append(MetadataSection(title: "Color & Image", fields: fields(properties, [
            ("ProfileName", "Color Profile"), ("ColorModel", "Color Model"), ("Depth", "Bit Depth"),
            ("DPIWidth", "Horizontal DPI"), ("DPIHeight", "Vertical DPI"), ("Orientation", "EXIF Orientation")
        ], prefix: "image.")))
        sections.append(MetadataSection(title: "Description & Rights", fields:
            fields(tiff, [("ImageDescription", "Description"), ("Artist", "Artist"), ("Copyright", "Copyright")], prefix: "rights.tiff.") +
            fields(iptc, [("ObjectName", "Title"), ("Headline", "Headline"), ("Caption/Abstract", "Caption"), ("Keywords", "Keywords"),
                          ("Byline", "Creator"), ("CopyrightNotice", "Copyright"), ("Credit", "Credit"), ("Source", "Source"),
                          ("City", "City"), ("Province/State", "State / Province"), ("Country/PrimaryLocationName", "Country")], prefix: "rights.iptc.") +
            fields(exif, [("UserComment", "Comment"), ("ImageUniqueID", "Image ID")], prefix: "rights.exif.")))
        if let gps = properties["{GPS}"] as? [String: Any], !gps.isEmpty {
            sections.append(MetadataSection(title: "Location (GPS)", fields: Self.flatten(gps, prefix: "GPS")))
        }
        var xmpFields: [MetadataField] = []
        if let embedded = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            CGImageMetadataEnumerateTagsUsingBlock(embedded, nil, [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { path, tag in
                if let value = CGImageMetadataTagCopyValue(tag) {
                    xmpFields.append(MetadataField(id: "xmp." + (path as String), label: "XMP › " + (path as String), value: Self.describe(value)))
                }
                return true
            }
        }
        return PhotoMetadata(sections: sections, allFields: file + Self.flatten(properties) + xmpFields, notice: nil)
    }

    nonisolated static func decimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...3)).grouping(.never))
    }

    nonisolated static func describe(_ value: Any) -> String {
        if let data = value as? Data { return "Binary data (\(data.count) bytes)" }
        if let array = value as? [Any] { return array.map { describe($0) }.joined(separator: ", ") }
        if let dictionary = value as? [String: Any] { return flatten(dictionary).map { "\($0.label): \($0.value)" }.joined(separator: "; ") }
        return String(describing: value)
    }

    nonisolated static func flatten(_ dictionary: [String: Any], prefix: String = "") -> [MetadataField] {
        dictionary.keys.sorted().flatMap { key -> [MetadataField] in
            let name = key.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
            let path = prefix.isEmpty ? name : prefix + " › " + name
            if let nested = dictionary[key] as? [String: Any] { return flatten(nested, prefix: path) }
            guard let value = dictionary[key] else { return [] }
            return [MetadataField(id: path, label: path, value: describe(value))]
        }
    }
}
