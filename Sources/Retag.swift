import AppKit
import Foundation
import ImageIO
import Observation
import SwiftUI

// MARK: - File names

/// `<date>_<camera code>_<film>_<roll#>_<frame#>`, e.g. `2026-10-22_FEa_Portra160_1131_07`.
/// The date and the camera code are optional (`Portra160_1131_07` also parses); roll and frame
/// must be numbers. Anything else is not a roll frame (contact sheets, covers…).
struct ParsedFrameName: Equatable {
    var date: Date?
    var dateText: String
    var camera: String
    var film: String
    var roll: String
    var frame: Int

    static func parse(_ fileName: String) -> ParsedFrameName? {
        let base = (fileName as NSString).deletingPathExtension
        let parts = base.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3,
              let frame = Int(parts[parts.count - 1]),
              !parts[parts.count - 2].isEmpty,
              parts[parts.count - 2].allSatisfy(\.isNumber) else { return nil }
        let roll = parts[parts.count - 2]
        var rest = Array(parts[0..<(parts.count - 2)])
        var date: Date?
        var dateText = ""
        if let first = rest.first, let d = dayFormatter.date(from: first) {
            date = d
            dateText = first
            rest.removeFirst()
        }
        guard !rest.isEmpty, rest.allSatisfy({ !$0.isEmpty }) else { return nil }
        let camera = rest.count >= 2 ? rest[0] : ""
        let film = rest.count >= 2 ? rest[1...].joined(separator: " ") : rest[0]
        return ParsedFrameName(date: date, dateText: dateText, camera: camera, film: film,
                               roll: roll, frame: frame)
    }

    var rollKey: String { [dateText, camera, film, roll].joined(separator: "_") }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f
    }()
}

// MARK: - Camera codes and film names

/// Camera body code from the file name (e.g. `FEa`) → make / model. Seeded with the two FE
/// bodies; whatever make/model the user sets for a roll is remembered for its code.
struct CameraAlias: Codable, Equatable {
    var make: String
    var model: String
}

enum CameraAliases {
    private static let key = "retagCameraAliases"

    static func load() -> [String: CameraAlias] {
        if let data = UserDefaults.standard.data(forKey: key),
           let a = try? JSONDecoder().decode([String: CameraAlias].self, from: data) {
            return a
        }
        return ["FEa": CameraAlias(make: "Nikon", model: "FE"),
                "FEb": CameraAlias(make: "Nikon", model: "FE")]
    }

    static func save(_ aliases: [String: CameraAlias]) {
        if let data = try? JSONEncoder().encode(aliases) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// Film code from a file name → stock name and box speed. Unknown codes are split into
/// letters and digits ("Foo400" → "Foo 400", ISO 400).
enum FilmNames {
    private static let known: [String: (String, Int)] = [
        "portra160": ("Kodak Portra 160", 160), "portra400": ("Kodak Portra 400", 400),
        "portra800": ("Kodak Portra 800", 800), "ektar": ("Kodak Ektar 100", 100),
        "ektar100": ("Kodak Ektar 100", 100), "gold": ("Kodak Gold 200", 200),
        "gold200": ("Kodak Gold 200", 200), "ultramax": ("Kodak UltraMax 400", 400),
        "ultramax400": ("Kodak UltraMax 400", 400), "colorplus": ("Kodak ColorPlus 200", 200),
        "colorplus200": ("Kodak ColorPlus 200", 200), "proimage": ("Kodak Pro Image 100", 100),
        "proimage100": ("Kodak Pro Image 100", 100), "ektachrome": ("Kodak Ektachrome E100", 100),
        "e100": ("Kodak Ektachrome E100", 100), "trix": ("Kodak Tri-X 400", 400),
        "trix400": ("Kodak Tri-X 400", 400), "tmax100": ("Kodak T-Max 100", 100),
        "tmax400": ("Kodak T-Max 400", 400), "hp5": ("Ilford HP5 Plus", 400),
        "fp4": ("Ilford FP4 Plus", 125), "panf": ("Ilford Pan F Plus", 50),
        "delta100": ("Ilford Delta 100", 100), "delta400": ("Ilford Delta 400", 400),
        "delta3200": ("Ilford Delta 3200", 3200), "xp2": ("Ilford XP2 Super", 400),
        "fuji200": ("Fujifilm 200", 200), "fuji400": ("Fujifilm 400", 400),
        "c200": ("Fujicolor C200", 200), "superia400": ("Fujicolor Superia X-TRA 400", 400),
        "provia": ("Fujifilm Provia 100F", 100), "velvia50": ("Fujifilm Velvia 50", 50),
        "cinestill800t": ("CineStill 800T", 800), "cinestill50d": ("CineStill 50D", 50),
        "cinestill400d": ("CineStill 400D", 400), "fomapan100": ("Fomapan 100", 100),
        "fomapan200": ("Fomapan 200", 200), "fomapan400": ("Fomapan 400", 400),
        "kentmere100": ("Kentmere Pan 100", 100), "kentmere400": ("Kentmere Pan 400", 400),
        "lomo100": ("Lomography Color 100", 100), "lomo400": ("Lomography Color 400", 400),
        "lomo800": ("Lomography Color 800", 800)
    ]

    static func parse(_ code: String) -> (stock: String, iso: Int?) {
        let k = code.lowercased().filter { $0.isLetter || $0.isNumber }
        if let hit = known[k] { return (hit.0, hit.1) }
        let letters = code.prefix { !$0.isNumber }
        let digits = code.dropFirst(letters.count)
        if !letters.isEmpty, !digits.isEmpty, digits.allSatisfy(\.isNumber), let iso = Int(digits) {
            return ("\(letters) \(digits)", iso)
        }
        return (code, nil)
    }
}

// MARK: - Model

struct RetagRoll: Identifiable, Equatable {
    let id: String
    var title: String
    /// Camera code from the file names ("" if none).
    var cameraCode: String
    var meta: RollMetadata
}

struct RetagFile: Identifiable, Equatable {
    enum Status: Equatable {
        case pending
        case done(String)
        case warning(String)
        case failed(String)
    }

    var id: URL { url }
    let url: URL
    let rollID: String
    let parsed: ParsedFrameName?
    /// Capture time of the scan (the scanning camera's DateTimeOriginal).
    let scanDate: Date?
    /// What the file says now: "FUJIFILM X-T30 · 21 mm f/--".
    let current: String
    let software: String
    let isNegConv: Bool
    /// Scanner model, serial and lens — must not survive the retag.
    let scannerStrings: [String]
    var include: Bool
    var meta = FrameMetadata()
    var status: Status = .pending

    var name: String { url.lastPathComponent }
}

/// What a file looked like before retagging (read in the background).
struct ScannedExport {
    let url: URL
    let parsed: ParsedFrameName?
    let scanDate: Date?
    let current: String
    let software: String
    let isNegConv: Bool
    let scannerStrings: [String]

    static let extensions: Set<String> = ["jpg", "jpeg", "tif", "tiff"]

    static func scan(folder: URL) -> [ScannedExport] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map(read)
    }

    static func read(_ url: URL) -> ScannedExport {
        var make = "", model = "", lens = "", serial = "", software = ""
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let exifAux = p[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
            make = (tiff[kCGImagePropertyTIFFMake] as? String ?? "").trimmingCharacters(in: .whitespaces)
            model = (tiff[kCGImagePropertyTIFFModel] as? String ?? "").trimmingCharacters(in: .whitespaces)
            software = tiff[kCGImagePropertyTIFFSoftware] as? String ?? ""
            lens = (exif[kCGImagePropertyExifLensModel] as? String
                    ?? exifAux[kCGImagePropertyExifAuxLensModel] as? String ?? "")
                .trimmingCharacters(in: .whitespaces)
            serial = (exif[kCGImagePropertyExifBodySerialNumber] as? String
                      ?? exifAux[kCGImagePropertyExifAuxSerialNumber] as? String ?? "")
                .trimmingCharacters(in: .whitespaces)
        }
        let current = [[make, model].filter { !$0.isEmpty }.joined(separator: " "), lens]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        let negConv = software.contains("NegConv")
        // The make is not checked: the analog camera may well be the same brand as the scanner.
        let scanner = negConv ? [] : [model, serial, lens].filter { $0.count >= 3 }
        return ScannedExport(url: url, parsed: ParsedFrameName.parse(url.lastPathComponent),
                             scanDate: ExportMetadata.scanDate(of: url),
                             current: current.isEmpty ? "no camera data" : current,
                             software: software, isNegConv: negConv, scannerStrings: scanner)
    }
}

/// Edits kept next to the files: `<folder>/NegConv Retag.json` (written on Retag).
struct RetagStoreFile: Codable {
    struct Roll: Codable { var meta: RollMetadata }
    struct Frame: Codable { var include: Bool; var meta: FrameMetadata }
    var rolls: [String: Roll] = [:]
    var frames: [String: Frame] = [:]

    static let fileName = "NegConv Retag.json"
}

@MainActor
@Observable
final class RetagModel {
    private(set) var folder: URL?
    private(set) var rolls: [RetagRoll] = []
    private(set) var files: [RetagFile] = []
    var selectedRoll: RetagRoll.ID?
    /// false: write copies to `<folder>/Retagged/`; true: replace the originals.
    var inPlace = false
    private(set) var isLoading = false
    private(set) var isWriting = false
    private(set) var progress: Double = 0
    private(set) var status: String?
    let thumbnails = ThumbnailStore()

    @ObservationIgnored private var aliases = CameraAliases.load()

    static let outputFolderName = "Retagged"
    static let otherRollID = "_other"

    // MARK: Loading

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder of exported JPEG or TIFF scans"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    func load(_ url: URL) {
        folder = url
        rolls = []
        files = []
        status = nil
        thumbnails.reset()
        isLoading = true
        Task {
            let scanned = await Task.detached(priority: .userInitiated) {
                ScannedExport.scan(folder: url)
            }.value
            guard folder == url else { return }
            build(from: scanned, folder: url)
            isLoading = false
            for f in files { thumbnails.request(f.url, .file) }
        }
    }

    private func build(from scanned: [ScannedExport], folder: URL) {
        let stored = Self.loadStore(folder)
        let anyRoll = scanned.contains { $0.parsed != nil }
        let credits = Self.lastCredits()

        // Rolls from the file names; everything else in one group.
        var newRolls: [String: RetagRoll] = [:]
        for s in scanned {
            guard let p = s.parsed else { continue }
            let id = p.rollKey
            guard newRolls[id] == nil else { continue }
            var meta = RollMetadata()
            if let a = aliases[p.camera] { meta.cameraMake = a.make; meta.cameraModel = a.model }
            let film = FilmNames.parse(p.film)
            meta.filmStock = film.stock
            meta.boxISO = film.iso
            meta.date = p.date
            meta.keywords = p.camera
            meta.photographer = credits.photographer
            meta.copyright = credits.copyright
            if let saved = stored?.rolls[id] { meta = saved.meta }
            let title = [p.roll, p.film, p.camera].filter { !$0.isEmpty }.joined(separator: " · ")
            newRolls[id] = RetagRoll(id: id, title: title, cameraCode: p.camera, meta: meta)
        }
        if scanned.contains(where: { $0.parsed == nil }) {
            let meta = stored?.rolls[Self.otherRollID]?.meta ?? {
                var m = RollMetadata()
                m.photographer = credits.photographer
                m.copyright = credits.copyright
                return m
            }()
            newRolls[Self.otherRollID] = RetagRoll(id: Self.otherRollID,
                                                   title: anyRoll ? "Other files" : folder.lastPathComponent,
                                                   cameraCode: "", meta: meta)
        }

        var newFiles: [RetagFile] = scanned.map { s in
            let rollID = s.parsed?.rollKey ?? Self.otherRollID
            // Default: every roll frame not already tagged by NegConv. Unnamed extras (contact
            // sheets…) only when the folder has no roll frames at all.
            var f = RetagFile(url: s.url, rollID: rollID, parsed: s.parsed, scanDate: s.scanDate,
                              current: s.current, software: s.software, isNegConv: s.isNegConv,
                              scannerStrings: s.scannerStrings,
                              include: !s.isNegConv && (s.parsed != nil || !anyRoll))
            if let saved = stored?.frames[s.url.lastPathComponent] {
                f.include = saved.include
                f.meta = saved.meta
            }
            return f
        }
        // Roll order: frame number, then scan time, then name.
        newFiles.sort { a, b in
            if a.rollID != b.rollID { return a.rollID < b.rollID }
            if let fa = a.parsed?.frame, let fb = b.parsed?.frame, fa != fb { return fa < fb }
            if let da = a.scanDate, let db = b.scanDate, da != db { return da < db }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }

        rolls = newRolls.values.sorted { a, b in
            if a.id == Self.otherRollID { return false }
            if b.id == Self.otherRollID { return true }
            return a.id < b.id
        }
        files = newFiles
        selectedRoll = rolls.first?.id
        if scanned.isEmpty { status = "No JPEG or TIFF files in \(folder.lastPathComponent)." }
    }

    // MARK: Queries & bindings

    func files(in roll: RetagRoll.ID?) -> [RetagFile] { files.filter { $0.rollID == roll } }

    func frameIndex(of file: RetagFile) -> Int {
        files(in: file.rollID).firstIndex { $0.id == file.id } ?? 0
    }

    var includedCount: Int { files.filter(\.include).count }

    var roll: RetagRoll? { rolls.first { $0.id == selectedRoll } }

    func rollMetaBinding(_ id: RetagRoll.ID) -> Binding<RollMetadata> {
        Binding(get: { [weak self] in self?.rolls.first { $0.id == id }?.meta ?? RollMetadata() },
                set: { [weak self] in self?.setRollMeta($0, for: id) })
    }

    private func setRollMeta(_ meta: RollMetadata, for id: RetagRoll.ID) {
        guard let i = rolls.firstIndex(where: { $0.id == id }) else { return }
        let old = rolls[i].meta
        rolls[i].meta = meta
        // Remember the body for its code.
        let code = rolls[i].cameraCode
        if !code.isEmpty, old.cameraMake != meta.cameraMake || old.cameraModel != meta.cameraModel {
            aliases[code] = CameraAlias(make: meta.cameraMake, model: meta.cameraModel)
            CameraAliases.save(aliases)
        }
    }

    func includeBinding(_ id: URL) -> Binding<Bool> {
        Binding(get: { [weak self] in self?.files.first { $0.id == id }?.include ?? false },
                set: { [weak self] v in
                    guard let self, let i = self.files.firstIndex(where: { $0.id == id }) else { return }
                    self.files[i].include = v
                })
    }

    func metaBinding(_ id: URL) -> Binding<FrameMetadata> {
        Binding(get: { [weak self] in self?.files.first { $0.id == id }?.meta ?? FrameMetadata() },
                set: { [weak self] v in
                    guard let self, let i = self.files.firstIndex(where: { $0.id == id }) else { return }
                    self.files[i].meta = v
                })
    }

    func setInclude(_ value: Bool, roll: RetagRoll.ID?) {
        for i in files.indices where files[i].rollID == roll { files[i].include = value }
    }

    // MARK: Writing

    func run() {
        guard let folder, !isWriting else { return }
        let outDir = inPlace ? folder : folder.appendingPathComponent(Self.outputFolderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            status = "Can't create \(outDir.lastPathComponent): \(error.localizedDescription)"
            return
        }
        struct Job {
            let id: URL
            let dest: URL
            let props: [CFString: Any]
            let scanner: [String]
        }
        let jobs: [Job] = files.filter(\.include).compactMap { f in
            guard let roll = rolls.first(where: { $0.id == f.rollID }) else { return nil }
            let software = f.software.isEmpty ? Exporter.softwareName
                                              : "\(f.software); \(Exporter.softwareName)"
            let props = ExportMetadata.properties(.init(
                roll: roll.meta, frame: f.meta, sourceName: f.name, frameIndex: frameIndex(of: f),
                scanDate: f.scanDate, software: software))
            return Job(id: f.id, dest: outDir.appendingPathComponent(f.name), props: props,
                       scanner: f.scannerStrings)
        }
        guard !jobs.isEmpty else { status = "Nothing selected."; return }

        Self.saveStore(folder, rolls: rolls, files: files)
        if let r = rolls.first {
            Self.saveCredits(photographer: r.meta.photographer, copyright: r.meta.copyright)
        }
        for i in files.indices { files[i].status = .pending }
        isWriting = true
        progress = 0
        status = "Retagging 1 of \(jobs.count)…"

        Task { @MainActor in
            var clean = 0, warnings = 0, failures = 0
            for (n, job) in jobs.enumerated() {
                status = "Retagging \(n + 1) of \(jobs.count)…"
                progress = Double(n) / Double(jobs.count)
                let result: Result<MetadataRewriter.Report, Error> = await Task.detached(priority: .userInitiated) {
                    Result { try MetadataRewriter.rewrite(source: job.id, to: job.dest, properties: job.props,
                                                          scannerStrings: job.scanner) }
                }.value
                guard let i = files.firstIndex(where: { $0.id == job.id }) else { continue }
                switch result {
                case .success(let r) where r.isClean:
                    clean += 1
                    files[i].status = .done(r.imageDataUnchanged == true
                                            ? "Metadata replaced · image data unchanged"
                                            : "Metadata replaced")
                case .success(let r):
                    warnings += 1
                    var why: [String] = []
                    if !r.leftovers.isEmpty { why.append("still contains " + r.leftovers.joined(separator: ", ")) }
                    if r.imageDataUnchanged == false { why.append("image data changed") }
                    files[i].status = .warning(why.joined(separator: " · "))
                case .failure(let e):
                    failures += 1
                    files[i].status = .failed(e.localizedDescription)
                }
            }
            progress = 1
            isWriting = false
            var msg = "Retagged \(clean + warnings) file\(clean + warnings == 1 ? "" : "s")"
            msg += inPlace ? " in place" : " to \(Self.outputFolderName)/"
            if warnings > 0 { msg += " · \(warnings) with warnings" }
            if failures > 0 { msg += " · \(failures) failed" }
            if warnings == 0 && failures == 0 { msg += " · all clean" }
            status = msg
        }
    }

    func revealOutput() {
        guard let folder else { return }
        let out = inPlace ? folder : folder.appendingPathComponent(Self.outputFolderName)
        NSWorkspace.shared.activateFileViewerSelecting([out])
    }

    // MARK: Persistence

    private static func loadStore(_ folder: URL) -> RetagStoreFile? {
        let url = folder.appendingPathComponent(RetagStoreFile.fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RetagStoreFile.self, from: data)
    }

    private static func saveStore(_ folder: URL, rolls: [RetagRoll], files: [RetagFile]) {
        var s = RetagStoreFile()
        for r in rolls { s.rolls[r.id] = .init(meta: r.meta) }
        for f in files { s.frames[f.name] = .init(include: f.include, meta: f.meta) }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(s) {
            try? data.write(to: folder.appendingPathComponent(RetagStoreFile.fileName), options: .atomic)
        }
    }

    private static func lastCredits() -> (photographer: String, copyright: String) {
        (UserDefaults.standard.string(forKey: "retagPhotographer") ?? "",
         UserDefaults.standard.string(forKey: "retagCopyright") ?? "")
    }

    private static func saveCredits(photographer: String, copyright: String) {
        UserDefaults.standard.set(photographer, forKey: "retagPhotographer")
        UserDefaults.standard.set(copyright, forKey: "retagCopyright")
    }
}
