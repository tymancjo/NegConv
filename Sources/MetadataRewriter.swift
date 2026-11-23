import Foundation
import ImageIO

/// Replaces ALL metadata of an existing JPEG / TIFF without touching its image data.
///
/// `CGImageDestinationCopyImageSource` copies the compressed image as is (no decode, no second
/// JPEG generation) and writes the metadata we give it in place of the old one
/// (`kCGImageDestinationMergeMetadata: false`). The new metadata is built from scratch:
/// a short whitelist of technical tags from the source (orientation, resolution, colour space,
/// pixel size) plus the analog shooting data. Everything else — the scan camera's make, model,
/// serial, lens, exposure, the XMP and IPTC copies of them, GPS, the EXIF thumbnail — is dropped.
///
/// Afterwards the file is read back: no scanner string may survive, and for JPEG the entropy-
/// coded scan data (SOS … EOI) must be byte-identical to the original.
enum MetadataRewriter {
    enum Failure: LocalizedError {
        case unreadable(String)
        case writeFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let n): return "\(n): can't read the image"
            case .writeFailed(let n, let why): return "\(n): write failed (\(why))"
            }
        }
    }

    struct Report {
        /// Scanner strings (model, serial, lens) still found in the written file.
        var leftovers: [String]
        /// JPEG: scan data identical to the original. nil for formats not checked (TIFF).
        var imageDataUnchanged: Bool?

        var isClean: Bool { leftovers.isEmpty && imageDataUnchanged != false }
    }

    /// Technical tags carried over from the source; nothing descriptive.
    static func kept(from props: [CFString: Any]) -> [CFString: Any] {
        var out: [CFString: Any] = [:]
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            var t: [CFString: Any] = [:]
            for k in [kCGImagePropertyTIFFOrientation, kCGImagePropertyTIFFXResolution,
                      kCGImagePropertyTIFFYResolution, kCGImagePropertyTIFFResolutionUnit] {
                if let v = tiff[k] { t[k] = v }
            }
            if !t.isEmpty { out[kCGImagePropertyTIFFDictionary] = t }
        }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            var e: [CFString: Any] = [:]
            for k in [kCGImagePropertyExifColorSpace, kCGImagePropertyExifPixelXDimension,
                      kCGImagePropertyExifPixelYDimension] {
                if let v = exif[k] { e[k] = v }
            }
            if !e.isEmpty { out[kCGImagePropertyExifDictionary] = e }
        }
        return out
    }

    /// Write `source` with new metadata to `dest` (may be the same file: replaced atomically).
    static func rewrite(source: URL, to dest: URL, properties: [CFString: Any],
                        scannerStrings: [String]) throws -> Report {
        let name = source.lastPathComponent
        let originalData = try? Data(contentsOf: source)
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
              let type = CGImageSourceGetType(src) else { throw Failure.unreadable(name) }
        let old = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let all = ExportMetadata.merged(kept(from: old), properties)

        let meta = CGImageMetadataCreateMutable()
        for (dictionary, value) in all {
            guard let sub = value as? [CFString: Any] else { continue }
            for (key, v) in sub {
                var v = v
                // ISO as an array only reaches XMP; a single number also reaches the EXIF tag.
                if dictionary == kCGImagePropertyExifDictionary, key == kCGImagePropertyExifISOSpeedRatings,
                   let a = v as? [Any], let first = a.first {
                    v = first
                }
                _ = CGImageMetadataSetValueMatchingImageProperty(meta, dictionary, key, v as AnyObject)
            }
        }
        // EXIF 2.3 name of the same ISO tag, so readers of either spelling find it.
        if let exif = all[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first {
            CGImageMetadataRegisterNamespaceForPrefix(meta, "http://cipa.jp/exif/1.0/" as CFString,
                                                      "exifEX" as CFString, nil)
            _ = CGImageMetadataSetValueWithPath(meta, nil, "exifEX:PhotographicSensitivity" as CFString,
                                                NSNumber(value: iso))
        }

        let fm = FileManager.default
        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent(".\(dest.lastPathComponent).negconv-tmp")
        try? fm.removeItem(at: tmp)
        guard let out = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else {
            throw Failure.writeFailed(name, "can't create file")
        }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: meta,
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeGPS: true,
            // The old EXIF thumbnail (the converter's preview) is not wanted either.
            kCGImageDestinationEmbedThumbnail: false
        ]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(out, src, options as CFDictionary, &error) else {
            try? fm.removeItem(at: tmp)
            let why = error?.takeRetainedValue().localizedDescription ?? "ImageIO refused the copy"
            throw Failure.writeFailed(name, why)
        }
        do {
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: dest)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw Failure.writeFailed(name, error.localizedDescription)
        }

        return verify(dest, original: originalData, isJPEG: (type as String) == "public.jpeg",
                      scannerStrings: scannerStrings, intended: flatten(properties))
    }

    // MARK: - Verification

    static func verify(_ url: URL, original: Data?, isJPEG: Bool,
                       scannerStrings: [String], intended: [String]) -> Report {
        var found: [String] = []
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
            if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) {
                found += flatten(props as NSDictionary)
            }
            if let m = CGImageSourceCopyMetadataAtIndex(src, 0, nil) {
                var tagStrings: [String] = []
                CGImageMetadataEnumerateTagsUsingBlock(
                    m, nil, [kCGImageMetadataEnumerateRecursively: true] as CFDictionary
                ) { _, tag in
                    if let v = CGImageMetadataTagCopyValue(tag) { tagStrings += flatten(v) }
                    return true
                }
                found += tagStrings
            }
        }
        // A scanner string that is also part of what we meant to write (e.g. scanning with a
        // Nikon and shooting a Nikon) is not a leftover.
        let leftovers = scannerStrings.filter { s in
            s.count >= 3
                && found.contains { $0.localizedCaseInsensitiveContains(s) }
                && !intended.contains { $0.localizedCaseInsensitiveContains(s) }
        }

        var unchanged: Bool?
        if isJPEG, let original, let written = try? Data(contentsOf: url),
           let a = jpegScanData(original), let b = jpegScanData(written) {
            unchanged = a == b
        }
        return Report(leftovers: leftovers, imageDataUnchanged: unchanged)
    }

    /// Every string inside a property-list-like value.
    static func flatten(_ value: Any) -> [String] {
        switch value {
        case let s as String: return [s]
        case let d as [AnyHashable: Any]: return d.values.flatMap { flatten($0) }
        case let a as [Any]: return a.flatMap { flatten($0) }
        default: return []
        }
    }

    /// JPEG bytes from the first Start-of-Scan marker to the end: the compressed image itself.
    static func jpegScanData(_ d: Data) -> Data? {
        let b = [UInt8](d)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i + 4 <= b.count {
            guard b[i] == 0xFF else { return nil }
            let m = b[i + 1]
            if m == 0xFF { i += 1; continue }                         // fill byte
            if m == 0xDA { return d.subdata(in: (d.startIndex + i)..<d.endIndex) }
            if m == 0x01 || (0xD0...0xD7).contains(m) { i += 2; continue }   // no length
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            i += 2 + length
        }
        return nil
    }
}
