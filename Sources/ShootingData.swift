import Foundation
import ImageIO

// MARK: - Model

/// What was shot: the analog roll, not the scan. One per roll (`NegConv Roll.json`).
/// Every field is optional; empty fields are simply not written.
struct RollMetadata: Codable, Equatable {
    var cameraMake = ""             // "Nikon"
    var cameraModel = ""            // "FM2"
    var lens = ""                   // "Nikkor 50mm f/1.4 AI-S"
    var focalLength: Float?         // mm
    var filmStock = ""              // "Kodak Portra 400"
    var filmFormat = ""             // "35mm", "120 6×7"
    var boxISO: Int?                // rated speed
    var exposureIndex: Int?         // shot at (push/pull); nil = box speed
    var development = ""            // "C-41, home, Tetenal kit" / "HC-110 B 7 min"
    var photographer = ""
    var copyright = ""
    var date: Date?                 // day the roll was shot (date only)
    var location = ""
    var notes = ""
    var keywords = ""               // comma separated

    var isEmpty: Bool { self == RollMetadata() }

    /// ISO written to EXIF: what the film was exposed at.
    var effectiveISO: Int? { exposureIndex ?? boxISO }

    /// "Kodak Portra 400 · 35mm · EI 800 (+1 stop)"
    var filmSummary: String {
        var parts: [String] = []
        if !filmStock.isEmpty { parts.append(filmStock) }
        if !filmFormat.isEmpty { parts.append(filmFormat) }
        if let ei = exposureIndex, let box = boxISO, ei != box, ei > 0, box > 0 {
            let stops = log2(Double(ei) / Double(box))
            parts.append(String(format: "EI %d (%+.1f stop%@)", ei, stops, abs(stops) == 1 ? "" : "s")
                .replacingOccurrences(of: ".0 ", with: " "))
        } else if let iso = effectiveISO {
            parts.append("ISO \(iso)")
        }
        return parts.joined(separator: " · ")
    }

    var cameraSummary: String {
        [cameraMake, cameraModel].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Per-frame overrides (stored in the frame's sidecar recipe). Empty = use the roll value.
struct FrameMetadata: Codable, Equatable {
    var date: Date?                 // date + time, overrides the roll date
    var aperture: Float?            // f-number
    var shutter = ""                // "1/125", "1/2", "2", "2s", "B 30s"
    var lens = ""
    var focalLength: Float?
    var caption = ""

    var isEmpty: Bool { self == FrameMetadata() }

    /// Seconds from the shutter text, nil if it can't be parsed.
    var exposureTime: Double? {
        var s = shutter.lowercased().trimmingCharacters(in: .whitespaces)
        for junk in ["b ", "t ", "sec", "s", "\""] { s = s.replacingOccurrences(of: junk, with: "") }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        let parts = s.split(separator: "/")
        if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d > 0 { return n / d }
        if parts.count == 1, let v = Double(s.replacingOccurrences(of: ",", with: ".")), v > 0 { return v }
        return nil
    }
}

// MARK: - Tolerant decoding (missing keys → defaults)

private extension KeyedDecodingContainer {
    func v<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
    func opt<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

extension RollMetadata {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        cameraMake = c.v(.cameraMake, ""); cameraModel = c.v(.cameraModel, "")
        lens = c.v(.lens, ""); focalLength = c.opt(.focalLength)
        filmStock = c.v(.filmStock, ""); filmFormat = c.v(.filmFormat, "")
        boxISO = c.opt(.boxISO); exposureIndex = c.opt(.exposureIndex)
        development = c.v(.development, "")
        photographer = c.v(.photographer, ""); copyright = c.v(.copyright, "")
        date = c.opt(.date); location = c.v(.location, "")
        notes = c.v(.notes, ""); keywords = c.v(.keywords, "")
    }
}

extension FrameMetadata {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        date = c.opt(.date); aperture = c.opt(.aperture)
        shutter = c.v(.shutter, ""); lens = c.v(.lens, "")
        focalLength = c.opt(.focalLength); caption = c.v(.caption, "")
    }
}

// MARK: - Export metadata

/// Builds the ImageIO property dictionary for an exported frame: the ANALOG shot (camera, lens,
/// film, ISO, date, exposure) goes in the standard EXIF/TIFF/IPTC fields that Lightroom, Photos
/// and Finder read. The scan only leaves a small trace: Software, the source NEF name (in the
/// user comment) and the scan time as DateTimeDigitized — never the scan camera as "Camera".
enum ExportMetadata {
    struct Input {
        var roll: RollMetadata
        var frame: FrameMetadata
        var sourceName: String
        /// Position in the roll (0-based); orders frames that share a date-only roll date.
        var frameIndex: Int
        var scanDate: Date?
        var software: String
    }

    static func properties(_ i: Input) -> [CFString: Any] {
        let r = i.roll, f = i.frame
        var tiff: [CFString: Any] = [kCGImagePropertyTIFFSoftware: i.software]
        var exif: [CFString: Any] = [:]
        var iptc: [CFString: Any] = [:]

        if !r.cameraMake.isEmpty { tiff[kCGImagePropertyTIFFMake] = r.cameraMake }
        if !r.cameraModel.isEmpty { tiff[kCGImagePropertyTIFFModel] = r.cameraModel }
        if !r.photographer.isEmpty {
            tiff[kCGImagePropertyTIFFArtist] = r.photographer
            iptc[kCGImagePropertyIPTCByline] = [r.photographer]
        }
        if !r.copyright.isEmpty {
            tiff[kCGImagePropertyTIFFCopyright] = r.copyright
            iptc[kCGImagePropertyIPTCCopyrightNotice] = r.copyright
        }

        let lens = f.lens.isEmpty ? r.lens : f.lens
        if !lens.isEmpty { exif[kCGImagePropertyExifLensModel] = lens }
        if let fl = f.focalLength ?? (f.lens.isEmpty ? r.focalLength : nil), fl > 0 {
            exif[kCGImagePropertyExifFocalLength] = Double(fl)
        }
        if let a = f.aperture, a > 0 { exif[kCGImagePropertyExifFNumber] = Double(a) }
        if let t = f.exposureTime { exif[kCGImagePropertyExifExposureTime] = t }
        if let iso = r.effectiveISO, iso > 0 { exif[kCGImagePropertyExifISOSpeedRatings] = [iso] }

        // Shot date: the frame's own date+time, else the roll date at 12:00 + frame index
        // seconds, so frames keep roll order when sorted by capture time.
        if let shot = f.date ?? r.date.map({ Self.noon($0).addingTimeInterval(TimeInterval(i.frameIndex)) }) {
            let s = exifDate(shot)
            exif[kCGImagePropertyExifDateTimeOriginal] = s
            exif[kCGImagePropertyExifOffsetTimeOriginal] = offset(shot, colon: true)
            iptc[kCGImagePropertyIPTCDateCreated] = iptcDate(shot)
            iptc[kCGImagePropertyIPTCTimeCreated] = iptcTime(shot)
        }
        if let scan = i.scanDate {
            exif[kCGImagePropertyExifDateTimeDigitized] = exifDate(scan)
            exif[kCGImagePropertyExifOffsetTimeDigitized] = offset(scan, colon: true)
            iptc[kCGImagePropertyIPTCDigitalCreationDate] = iptcDate(scan)
            iptc[kCGImagePropertyIPTCDigitalCreationTime] = iptcTime(scan)
        }

        // Description: caption — film — development — roll notes.
        let film = r.filmSummary
        let description = [f.caption, film, r.development, r.notes]
            .filter { !$0.isEmpty }.joined(separator: " — ")
        if !description.isEmpty {
            tiff[kCGImagePropertyTIFFImageDescription] = description
            iptc[kCGImagePropertyIPTCCaptionAbstract] = description
        }
        var comment = [film, r.development].filter { !$0.isEmpty }
        comment.append("Scan of \(i.sourceName) with \(i.software)")
        // UserComment is written as ASCII by ImageIO: fold accents and symbols ("·" → ",").
        let ascii = comment.joined(separator: " | ")
            .replacingOccurrences(of: " · ", with: ", ")
            .replacingOccurrences(of: "©", with: "(c)")
            .replacingOccurrences(of: "Ł", with: "L").replacingOccurrences(of: "ł", with: "l")
            .replacingOccurrences(of: "Ø", with: "O").replacingOccurrences(of: "ø", with: "o")
            .replacingOccurrences(of: "ß", with: "ss")
            .applyingTransform(.stripDiacritics, reverse: false) ?? ""
        exif[kCGImagePropertyExifUserComment] = String(ascii.unicodeScalars.map { $0.isASCII ? Character($0) : "?" })

        if !r.location.isEmpty { iptc[kCGImagePropertyIPTCContentLocationName] = r.location }
        var keywords = r.keywords.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !r.filmStock.isEmpty { keywords.insert(r.filmStock, at: 0) }
        if !keywords.isEmpty { iptc[kCGImagePropertyIPTCKeywords] = keywords }

        var out: [CFString: Any] = [kCGImagePropertyTIFFDictionary: tiff,
                                    kCGImagePropertyExifDictionary: exif]
        if !iptc.isEmpty { out[kCGImagePropertyIPTCDictionary] = iptc }
        return out
    }

    /// Merge `extra` into `base`; nested dictionaries are merged key by key.
    static func merged(_ base: [CFString: Any], _ extra: [CFString: Any]) -> [CFString: Any] {
        var out = base
        for (k, v) in extra {
            if let a = out[k] as? [CFString: Any], let b = v as? [CFString: Any] {
                out[k] = a.merging(b) { _, new in new }
            } else {
                out[k] = v
            }
        }
        return out
    }

    /// Capture time of the scan NEF (its own EXIF), else the file's modification date.
    static func scanDate(of url: URL) -> Date? {
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
           let d = exifFormatter.date(from: s) {
            return d
        }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    private static func exifDate(_ d: Date) -> String { exifFormatter.string(from: d) }

    private static func iptcDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f.string(from: d)
    }

    /// "120001+0100": IPTC time with the local UTC offset (without it readers assume UTC).
    private static func iptcTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HHmmss"
        return f.string(from: d) + offset(d, colon: false)
    }

    /// Local UTC offset at `d`: "+01:00" (EXIF OffsetTime*) or "+0100" (IPTC).
    private static func offset(_ d: Date, colon: Bool) -> String {
        let secs = TimeZone.current.secondsFromGMT(for: d)
        let sign = secs < 0 ? "-" : "+"
        let h = abs(secs) / 3600, m = abs(secs) % 3600 / 60
        return String(format: colon ? "%@%02d:%02d" : "%@%02d%02d", sign, h, m)
    }

    private static func noon(_ d: Date) -> Date {
        Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: d) ?? d
    }
}
