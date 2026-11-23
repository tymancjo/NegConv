import AppKit
import CoreImage
import Observation
import SwiftUI

enum EditTool: Equatable {
    case none, crop, sampleBase, whiteBalance, straighten, spot, colorPick

    /// Tools that work on the uncropped negative (need to see the rebate / full frame).
    var showsNegative: Bool { self == .crop || self == .sampleBase }
}

@MainActor
@Observable
final class AppModel {
    /// Long edge of the preview decode. 2560 px ≈ scale 0.35 on a D810/D750 frame.
    static let previewLongEdge: CGFloat = 2560

    // MARK: - Grid view & thumbnails

    enum ViewMode: Hashable { case loupe, grid }
    /// Lightroom-style: G = grid (contact sheet) in place of the preview, E = back to the loupe.
    var viewMode: ViewMode = .loupe {
        didSet { if viewMode == .grid { tool = .none } }
    }
    /// Thumbnails of the roll (sidebar + grid).
    let thumbnails = ThumbnailStore()
    /// Columns of the grid as laid out (for ↑/↓ navigation).
    @ObservationIgnored var gridColumns = 1
    @ObservationIgnored var thumbnailTask: Task<Void, Never>?
    @ObservationIgnored var thumbnailDirty = Set<URL>()

    private(set) var folderURL: URL?
    private(set) var files: [URL] = []

    var selection: URL? {
        didSet { if oldValue != selection { scheduleDecode(debounce: false) } }
    }

    /// Roll-level decode settings: identical for every frame of the roll.
    var rollDecode = DecodeSettings() {
        didSet {
            guard oldValue != rollDecode else { return }
            scheduleDecode(debounce: true)
            // Every sidecar records the decode settings: re-save all edited frames.
            markDirty(Set(recipes.keys))
            saveRoll()
            scheduleRollBaseRemeasure()
            scheduleThumbnails(Set(files))
        }
    }

    // MARK: - Roll (shared base, pooled analysis) — `NegConv Roll.json`

    /// Film base shared by the roll; frames without their own sample use it.
    private(set) var rollBase: RollBase? { didSet { if oldValue != rollBase { saveRoll(); scheduleThumbnails(Set(files)) } } }
    /// Frames (file names) left out of the roll analysis.
    private(set) var rollExcluded: Set<String> = [] { didSet { if oldValue != rollExcluded { saveRoll() } } }
    private(set) var rollAnalysis: RollAnalysis? { didSet { if oldValue != rollAnalysis { saveRoll(); scheduleThumbnails(Set(files)) } } }

    private(set) var isAnalysing = false
    private(set) var analysisProgress: Double = 0

    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var rollBaseTask: Task<Void, Never>?
    /// Per-frame density histograms of the last analysis, keyed by file name (memory only).
    @ObservationIgnored private var histogramCache: [String: (fingerprint: String, hist: DensityHistogram)] = [:]

    /// Per-frame edits. Autosaved (debounced) to `<name>.<ext>.negconv.json` next to each RAW file.
    private(set) var recipes: [URL: EditRecipe] = [:] {
        didSet {
            var changed = Set<URL>()
            for (k, v) in recipes where oldValue[k] != v { changed.insert(k) }
            markDirty(changed)
            scheduleThumbnails(changed)
        }
    }

    // MARK: - Sidecar autosave

    @ObservationIgnored private var dirty = Set<URL>()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var suppressSave = false
    @ObservationIgnored private var terminateObserver: Any?

    init() {
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushSaves() }
        }
    }

    private func markDirty(_ urls: Set<URL>) {
        guard !suppressSave, !urls.isEmpty else { return }
        dirty.formUnion(urls)
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            flushSaves()
        }
    }

    func flushSaves() {
        saveTask?.cancel()
        if rollSaveTask != nil { rollSaveTask?.cancel(); rollSaveTask = nil; saveRoll() }
        let urls = dirty
        dirty = []
        for url in urls {
            guard let r = recipes[url] else { continue }
            do {
                try Sidecar.save(SidecarFile(decode: rollDecode, recipe: r), for: url)
            } catch {
                errorMessage = "Couldn't save settings for \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Export

    var exportSettings = ExportSettings.load() {
        didSet { if oldValue != exportSettings { exportSettings.save() } }
    }
    var isExportSettingsShown = false

    private(set) var isExporting = false
    private(set) var exportStatus: String?
    private(set) var exportProgress: Double = 0
    private(set) var lastExportFolder: URL?

    /// Frames that can be exported: edited, with a base of their own or a roll base.
    var exportableCount: Int { files.filter(canExport).count }

    private func canExport(_ url: URL) -> Bool {
        guard let r = recipes[url] else { return false }
        return r.inversion.baseRect != nil || rollBaseRGB != nil
    }

    func exportCurrentFrame() {
        guard let s = selection else { return }
        export([s])
    }

    func exportRoll() { export(files) }

    func dismissExportStatus() { exportStatus = nil }

    func revealExports() {
        guard let f = lastExportFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([f])
    }

    private func export(_ urls: [URL]) {
        guard let folder = folderURL, !isExporting else { return }
        flushSaves()
        let outDir = folder.appendingPathComponent("NegConv Export", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            exportStatus = "Can't create \(outDir.lastPathComponent): \(error.localizedDescription)"
            return
        }

        let jobs: [Exporter.Job] = urls.compactMap { u in
            guard canExport(u), let r = recipes[u] else { return nil }
            let name = u.deletingPathExtension().lastPathComponent
            return Exporter.Job(source: u, recipe: r, decode: rollDecode,
                                rollBase: r.inversion.baseRect == nil ? rollBaseRGB : nil,
                                rollAnalysis: rollAnalysis,
                                destination: outDir.appendingPathComponent(name)
                                    .appendingPathExtension(exportSettings.format.fileExtension),
                                settings: exportSettings,
                                rollMeta: rollMeta,
                                frameIndex: files.firstIndex(of: u) ?? 0)
        }
        let skipped = urls.count - jobs.count
        guard !jobs.isEmpty else {
            exportStatus = "Nothing to export — sample the film base first."
            return
        }

        isExporting = true
        exportProgress = 0
        lastExportFolder = outDir
        exportStatus = "Exporting 1 of \(jobs.count)…"

        // Orchestrate on the main actor (UI state); each heavy export runs in a detached task.
        Task { @MainActor in
            var failures: [String] = []
            let start = Date()
            for (i, job) in jobs.enumerated() {
                exportStatus = "Exporting \(i + 1) of \(jobs.count) — \(job.source.deletingPathExtension().lastPathComponent)"
                exportProgress = Double(i) / Double(jobs.count)
                let error: String? = await Task.detached(priority: .userInitiated) {
                    do {
                        try autoreleasepool { try Exporter.export(job) }
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                }.value
                if let error { failures.append(error) }
            }
            let secs = Date().timeIntervalSince(start)
            isExporting = false
            exportProgress = 1
            var msg = "Exported \(jobs.count - failures.count) × \(jobs.first?.settings.summary ?? "") to \(outDir.lastPathComponent) in \(String(format: "%.0f", secs)) s"
            if skipped > 0 { msg += " · skipped \(skipped) without film base" }
            if !failures.isEmpty { msg += " · failed: " + failures.joined(separator: "; ") }
            exportStatus = msg
        }
    }

    /// The recipe of the selected frame.
    var recipe: EditRecipe {
        get { selection.flatMap { recipes[$0] } ?? EditRecipe() }
        set {
            guard let selection else { return }
            recipes[selection] = newValue
        }
    }

    var compareAppleDefault = false {
        didSet { if oldValue != compareAppleDefault { scheduleDecode(debounce: false) } }
    }

    /// Active interactive tool. Leaving the crop tool re-measures the auto black/white points,
    /// because they must be computed on the cropped area only.
    var tool: EditTool = .none {
        didSet { if oldValue == .crop && tool != .crop { refreshInversion() } }
    }

    /// Bypass the inversion and show the linear negative.
    var showNegative = false

    /// Held `\`: show "before" — the plain inversion (see `EditRecipe.before`).
    private(set) var showBefore = false
    /// Output clipping overlay (J): red highlights, blue shadows, in the export's colour space.
    var showClipping = false

    /// Recipe the positive is rendered with: the real one, or "before" while `\` is held.
    private var displayRecipe: EditRecipe { showBefore ? recipe.before : recipe }

    private(set) var preview: DecodedRaw?
    private(set) var isDecoding = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let decoder = RawDecoder()
    @ObservationIgnored private var decodeTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    // MARK: - Derived images

    /// Decoded preview of the selected frame, if it has arrived.
    private var currentDecode: DecodedRaw? {
        guard let preview, preview.url == selection else { return nil }
        return preview
    }

    /// Oriented (rotated + flipped), uncropped negative.
    var orientedImage: CIImage? {
        currentDecode.map { Pipeline.oriented($0.image, recipe.geometry) }
    }

    /// What the preview shows. Tools show the whole uncropped negative so the rebate is visible.
    var displayImage: CIImage? { shownImage(clip: showClipping) }

    /// `clip: false` for measurements (histogram) — the overlay is only paint.
    private func shownImage(clip: Bool) -> CIImage? {
        // Hold R: the reference frame in place of the current one.
        if showReferenceFlash, let ref = referenceImage,
           tool == .none || tool == .spot || tool == .whiteBalance || tool == .colorPick {
            return clip ? Pipeline.clipWarning(ref, format: exportSettings.format) : ref
        }
        guard let decode = currentDecode else { return nil }
        let g = recipe.geometry
        switch tool {
        case .sampleBase:
            // Unstraightened: the base rect maps 1:1 to source coordinates.
            return Pipeline.oriented(decode.image, g)
        case .crop:
            return Pipeline.straightened(Pipeline.oriented(Pipeline.spotted(decode.image, recipe.spots), g), g)
        case .straighten:
            // Whole frame, as a positive if possible, so horizons/verticals are easy to see.
            let full = Pipeline.straightened(Pipeline.oriented(Pipeline.spotted(decode.image, recipe.spots), g), g)
            guard recipe.inversion.isReady, !showNegative else { return full }
            return Pipeline.positive(full, displayRecipe, detailScale: CGFloat(decode.scale))
        case .none, .whiteBalance, .spot, .colorPick:
            return processed(decode.image, scale: CGFloat(decode.scale), clip: clip)
        }
    }

    /// Geometry + inversion + tone (unless showing the negative). Resolution-independent, so it
    /// is used for the preview and for the full-res loupe alike. `scale` = decode scale of
    /// `linear` (1 = full resolution), so the sharpening radius matches the export.
    private func processed(_ linear: CIImage, scale: CGFloat, clip: Bool) -> CIImage {
        let cropped = Pipeline.framed(linear, recipe)
        if showNegative || compareAppleDefault || !recipe.inversion.isReady { return cropped }
        let positive = Pipeline.positive(cropped, displayRecipe, detailScale: scale)
        return clip ? Pipeline.clipWarning(positive, format: exportSettings.format) : positive
    }

    // MARK: - Tone

    /// Set white balance so the clicked point (normalised in the displayed, cropped image)
    /// becomes neutral. Sampled after inversion, before the current tone, so it is absolute.
    func pickWhiteBalance(at p: CGPoint) {
        guard let decode = currentDecode, recipe.inversion.isReady else { return }
        let cropped = Pipeline.framed(decode.image, recipe)
        let positive = Pipeline.inverted(cropped, recipe.inversion)
        guard let sample = Analyzer.average(positive, around: p),
              let wb = Tone.whiteBalance(neutralizing: sample) else {
            errorMessage = "That spot is too dark or clipped for a white-balance sample."
            return
        }
        recipe.tone.temperature = wb.temperature
        recipe.tone.tint = wb.tint
        tool = .none
    }

    func resetTone() { recipe.tone = Tone() }

    /// Exposure and white balance only; levels are untouched.
    func resetExposureWB() {
        recipe.tone.exposureEV = 0
        recipe.tone.temperature = 0
        recipe.tone.tint = 0
    }

    // MARK: - Colour mixer

    var selectedColorBand: ColorMix.Band = .blue
    private(set) var lastPickedHue: Double?

    /// Click a colour in the image → select the band it belongs to. Sampled after tone, before
    /// the mixer (and before presence), so it reflects the colour as the mixer sees it — this
    /// also works when the image is shown in B&W.
    func pickColorBand(at p: CGPoint) {
        guard let decode = currentDecode, recipe.inversion.isReady else { return }
        let positive = Pipeline.curved(
            Pipeline.toned(Pipeline.inverted(Pipeline.framed(decode.image, recipe), recipe.inversion),
                           recipe.tone, recipe.paper),
            recipe.curves)
        guard let lin = Analyzer.average(positive, around: p) else { return }
        // γ-encode like the kernel, then HSV.
        let r = Double(powf(max(lin.x, 0), 1 / 2.2)), g = Double(powf(max(lin.y, 0), 1 / 2.2)),
            b = Double(powf(max(lin.z, 0), 1 / 2.2))
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        guard mx > 0, d / mx > 0.06 else {
            errorMessage = "That spot is almost neutral — pick a more colourful area."
            return
        }
        var h: Double
        if mx == r { h = 60 * ((g - b) / d).truncatingRemainder(dividingBy: 6) }
        else if mx == g { h = 60 * ((b - r) / d + 2) }
        else { h = 60 * ((r - g) / d + 4) }
        if h < 0 { h += 360 }
        lastPickedHue = h
        selectedColorBand = ColorMix.Band.nearest(to: h)
        errorMessage = nil
        tool = .none
    }

    // MARK: - View ↔ framed-image mapping (fit view and 1:1 view)

    private var backingScale: CGFloat { NSScreen.main?.backingScaleFactor ?? 2 }

    /// View point (SwiftUI points, y-down) → normalised point in the framed image (y-up).
    func framedNormalized(fromView p: CGPoint, viewSize: CGSize) -> CGPoint? {
        if actualSize, let src = detailSource {
            let size = src.image.extent.size
            let z = loupeZoom / src.scale
            return CGPoint(x: actualCenter.x + (p.x - viewSize.width / 2) * backingScale / z / size.width,
                           y: actualCenter.y - (p.y - viewSize.height / 2) * backingScale / z / size.height)
        }
        guard let img = displayImage else { return nil }
        let fit = FitLayout.fitRect(content: img.extent.size, in: viewSize)
        return CGPoint(x: (p.x - fit.minX) / fit.width, y: 1 - (p.y - fit.minY) / fit.height)
    }

    /// Normalised framed point → view point.
    func viewPoint(fromFramed n: CGPoint, viewSize: CGSize) -> CGPoint? {
        if actualSize, let src = detailSource {
            let size = src.image.extent.size
            let z = loupeZoom / src.scale
            return CGPoint(x: viewSize.width / 2 + (n.x - actualCenter.x) * size.width * z / backingScale,
                           y: viewSize.height / 2 - (n.y - actualCenter.y) * size.height * z / backingScale)
        }
        guard let img = displayImage else { return nil }
        let fit = FitLayout.fitRect(content: img.extent.size, in: viewSize)
        return CGPoint(x: fit.minX + n.x * fit.width, y: fit.minY + (1 - n.y) * fit.height)
    }

    /// View points per source pixel of the preview decode (for drawing spot radii).
    func viewPointsPerSourcePreviewPixel(viewSize: CGSize) -> CGFloat? {
        guard let decode = currentDecode, let img = displayImage, img.extent.width > 0 else { return nil }
        // Framed preview pixels and source preview pixels have the same scale.
        if actualSize, let src = detailSource {
            let z = loupeZoom / src.scale            // device px per detail-image px
            let detailPerPreview = src.image.extent.width / img.extent.width
            return z * detailPerPreview / backingScale
        }
        _ = decode
        let fit = FitLayout.fitRect(content: img.extent.size, in: viewSize)
        return fit.width / img.extent.width
    }

    // MARK: - Spots

    /// Brush radius as a fraction of the source long edge (0.004 ≈ 29 px on a D810 frame).
    var brushRadius: CGFloat = 0.004
    private(set) var selectedSpotID: UUID?

    var sourceLongEdgePreview: CGFloat? {
        currentDecode.map { max($0.image.extent.width, $0.image.extent.height) }
    }

    func resizeBrush(_ factor: CGFloat) {
        brushRadius = min(max(brushRadius * factor, 0.0008), 0.05)
        if let id = selectedSpotID, let i = recipe.spots.firstIndex(where: { $0.id == id }) {
            recipe.spots[i].radius = min(max(recipe.spots[i].radius * factor, 0.0008), 0.05)
        }
    }

    /// Click in spot mode: add a spot there with an automatically chosen source.
    func addSpot(atView p: CGPoint, viewSize: CGSize) {
        guard let center = sourcePoint(fromView: p, viewSize: viewSize, clamp: false) else { return }
        addSpot(atSource: center)
    }

    private func addSpot(atSource center: CGPoint) {
        let source = autoSource(center: center, radius: brushRadius)
        let spot = Spot(center: center, source: source, radius: brushRadius)
        recipe.spots.append(spot)
        selectedSpotID = spot.id
    }

    /// View point → source-normalised point. Outside the frame: nil, or clamped to its edge.
    private func sourcePoint(fromView p: CGPoint, viewSize: CGSize, clamp: Bool) -> CGPoint? {
        guard var n = framedNormalized(fromView: p, viewSize: viewSize),
              let aspect = orientedAspect else { return nil }
        if clamp {
            n = CGPoint(x: min(max(n.x, 0), 1), y: min(max(n.y, 0), 1))
        } else if !(0...1).contains(n.x) || !(0...1).contains(n.y) {
            return nil
        }
        return recipe.geometry.sourcePoint(fromFramed: n, aspect: aspect)
    }

    /// Distance between two source-normalised points, in source preview pixels.
    private func sourcePixelDistance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        guard let e = currentDecode?.image.extent else { return 0 }
        return hypot((a.x - b.x) * e.width, (a.y - b.y) * e.height)
    }

    // MARK: Brush strokes

    /// Stroke being painted (source-normalised points), drawn by the overlay until release.
    private(set) var paintingStroke: [CGPoint]?

    func beginStroke(atView p: CGPoint, viewSize: CGSize) {
        guard sourcePoint(fromView: p, viewSize: viewSize, clamp: false) != nil else { return }
        paintingStroke = []
        continueStroke(atView: p, viewSize: viewSize)
    }

    func continueStroke(atView p: CGPoint, viewSize: CGSize) {
        guard paintingStroke != nil,
              let s = sourcePoint(fromView: p, viewSize: viewSize, clamp: true) else { return }
        let brushPx = brushRadius * (sourceLongEdgePreview ?? 1)
        if let last = paintingStroke?.last, sourcePixelDistance(last, s) < max(brushPx * 0.25, 0.5) { return }
        paintingStroke?.append(s)
    }

    /// Release: a real stroke becomes a brush spot; a tiny one becomes an ordinary disc.
    func endStroke() {
        guard let pts = paintingStroke else { return }
        paintingStroke = nil
        let brushPx = brushRadius * (sourceLongEdgePreview ?? 1)
        let length = zip(pts, pts.dropFirst()).reduce(0) { $0 + sourcePixelDistance($1.0, $1.1) }
        if pts.count >= 2 && length >= brushPx * 0.5 {
            addStroke(pts)
        } else if let p = pts.first {
            addSpot(atSource: p)
        }
    }

    /// ⇧-click: straight stroke from the end of the selected (or last) spot to the click.
    func addLine(toView p: CGPoint, viewSize: CGSize) {
        guard let end = sourcePoint(fromView: p, viewSize: viewSize, clamp: false) else { return }
        let from = recipe.spots.first(where: { $0.id == selectedSpotID }) ?? recipe.spots.last
        guard let start = from?.end else { addSpot(atSource: end); return }
        addStroke([start, end])
    }

    private func addStroke(_ pts: [CGPoint]) {
        let off = autoStrokeOffset(pts, radius: brushRadius)
        let spot = Spot(center: pts[0], source: CGPoint(x: pts[0].x + off.dx, y: pts[0].y + off.dy),
                        radius: brushRadius, path: pts)
        recipe.spots.append(spot)
        selectedSpotID = spot.id
    }

    /// Clone offset for a stroke, searched like `autoSource`; fallback 3 radii across the stroke.
    private func autoStrokeOffset(_ pts: [CGPoint], radius: CGFloat, excluding id: UUID? = nil) -> CGVector {
        let base: CIImage? = (fullRes?.url == selection ? fullRes?.image : nil) ?? currentDecode?.image
        let others = recipe.spots.filter { $0.id != id }
        if let img = base,
           let off = Analyzer.findStrokeSource(in: Pipeline.spotted(img, others), path: pts, radius: radius) {
            return off
        }
        let e = currentDecode?.image.extent ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let L = max(e.width, e.height)
        let a = pts.first!, b = pts.last!
        var nx = -(b.y - a.y) * e.height, ny = (b.x - a.x) * e.width      // perpendicular, pixels
        let len = max(hypot(nx, ny), 1e-6)
        if len < 1e-3 { nx = 1; ny = 0 } else { nx /= len; ny /= len }
        return CGVector(dx: nx * 3 * radius * L / e.width, dy: ny * 3 * radius * L / e.height)
    }

    /// Best nearby source, searched on the full-res decode if it's loaded, else the preview.
    /// (Searched on the image *with* earlier spots applied, so repairs can chain.)
    private func autoSource(center: CGPoint, radius: CGFloat) -> CGPoint {
        let base: CIImage? = {
            if let fullRes, fullRes.url == selection { return fullRes.image }
            return currentDecode?.image
        }()
        if let img = base,
           let s = Analyzer.findCloneSource(in: Pipeline.spotted(img, recipe.spots),
                                            center: center, radius: radius) {
            return s
        }
        // Fallback: three radii to the right in the source image.
        let e = currentDecode?.image.extent ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let L = max(e.width, e.height)
        return CGPoint(x: min(center.x + 3 * radius * L / e.width, 1), y: center.y)
    }

    func selectSpot(_ id: UUID?) { selectedSpotID = id }

    /// Move a spot (or just its source) to a view point.
    func moveSpot(_ id: UUID, sourceOnly: Bool, toView p: CGPoint, viewSize: CGSize, keepOffset: CGVector) {
        guard let i = recipe.spots.firstIndex(where: { $0.id == id }),
              let n = framedNormalized(fromView: p, viewSize: viewSize),
              let aspect = orientedAspect else { return }
        let pt = recipe.geometry.sourcePoint(fromFramed: n, aspect: aspect)
        if sourceOnly {
            recipe.spots[i].source = pt
        } else {
            recipe.spots[i].move(to: pt, sourceOffset: keepOffset)      // strokes keep their shape
        }
    }

    /// Re-run the automatic source search for the selected spot.
    func reAutoSourceSelected() {
        guard let id = selectedSpotID, let i = recipe.spots.firstIndex(where: { $0.id == id }) else { return }
        let s = recipe.spots[i]
        if s.isStroke, let path = s.path {
            let off = autoStrokeOffset(path, radius: s.radius, excluding: s.id)
            recipe.spots[i].source = CGPoint(x: s.center.x + off.dx, y: s.center.y + off.dy)
            return
        }
        var others = recipe
        others.spots.remove(at: i)
        if let img = (fullRes?.url == selection ? fullRes?.image : currentDecode?.image),
           let src = Analyzer.findCloneSource(in: Pipeline.spotted(img, others.spots),
                                              center: s.center, radius: s.radius) {
            recipe.spots[i].source = src
        }
    }

    func deleteSelectedSpot() {
        guard let id = selectedSpotID else { return }
        recipe.spots.removeAll { $0.id == id }
        selectedSpotID = recipe.spots.last?.id
    }

    func clearSpots() {
        recipe.spots = []
        selectedSpotID = nil
    }

    // MARK: - Straighten

    /// Width / height of the oriented frame (straighten works on this canvas).
    private var orientedAspect: CGFloat? {
        orientedImage.map { $0.extent.width / max($0.extent.height, 1) }
    }

    func setStraighten(_ degrees: Float) {
        guard let aspect = orientedAspect else { return }
        recipe.geometry.setStraighten(degrees, aspect: aspect)
        refreshInversion()
    }

    /// Level a line drawn on the displayed (already straightened) frame. Points in view
    /// coordinates (y-down); the uniform fit scale doesn't change angles.
    /// Within ±45° of horizontal it is levelled to horizontal, otherwise to vertical.
    func straighten(lineFrom p0: CGPoint, to p1: CGPoint) {
        let dx = p1.x - p0.x, dy = -(p1.y - p0.y)            // to y-up
        guard hypot(dx, dy) > 10 else { return }
        var a = atan2(dy, dx) * 180 / .pi                    // −180…180
        if a > 90 { a -= 180 } else if a <= -90 { a += 180 } // a line has no direction
        let correction: CGFloat = abs(a) <= 45 ? -a : (a > 0 ? 90 - a : -90 - a)
        setStraighten(recipe.geometry.straighten + Float(correction))
        tool = .none
    }

    // MARK: - Copy / paste settings

    struct PasteOptions: Equatable {
        var orientation = true      // 90° turns, flip, straighten
        var crop = false
        var baseArea = true
        var inversion = true        // range + density points (auto stays auto)
        var exposure = true
        var whiteBalance = true
        var levels = true
        var colorMix = true
        var presence = true
        var sharpen = true
        var paper = true
        var curves = true
        var shootingData = false    // lens, aperture, shutter, focal length (not date/caption)
    }

    private(set) var clipboard: EditRecipe?
    var pasteOptions = PasteOptions()
    var isPasteSheetShown = false

    func copySettings() { clipboard = recipe }

    func showPasteSheet() {
        guard clipboard != nil, selection != nil else { return }
        isPasteSheetShown = true
    }

    func pasteSettings(toAll: Bool) {
        guard let src = clipboard else { return }
        let targets = toAll ? files : (selection.map { [$0] } ?? [])
        for url in targets { recipes[url] = pasted(src, into: recipes[url] ?? EditRecipe()) }
        isPasteSheetShown = false
        refreshInversion()          // current frame now; others re-measure when opened
    }

    private func pasted(_ s: EditRecipe, into target: EditRecipe) -> EditRecipe {
        let o = pasteOptions
        var r = target
        if o.orientation {
            r.geometry.quarterTurns = s.geometry.quarterTurns
            r.geometry.flipHorizontal = s.geometry.flipHorizontal
            r.geometry.straighten = s.geometry.straighten
        }
        if o.crop { r.geometry.crop = s.geometry.crop }
        if o.baseArea {
            r.inversion.baseRect = s.inversion.baseRect
            r.inversion.base = nil                     // each frame measures its own base
        }
        if o.inversion {
            r.inversion.range = s.inversion.range
            r.inversion.autoPoints = s.inversion.autoPoints
            r.inversion.pointSource = s.inversion.pointSource
            if !s.inversion.autoPoints {
                r.inversion.dBlack = s.inversion.dBlack
                r.inversion.dWhite = s.inversion.dWhite
            }
        }
        if o.exposure { r.tone.exposureEV = s.tone.exposureEV }
        if o.whiteBalance {
            r.tone.temperature = s.tone.temperature
            r.tone.tint = s.tone.tint
        }
        if o.levels { r.tone.levels = s.tone.levels }
        if o.colorMix { r.color = s.color }
        if o.presence { r.presence = s.presence }
        if o.sharpen { r.sharpen = s.sharpen }
        if o.paper { r.paper = s.paper }
        if o.curves { r.curves = s.curves }
        if o.shootingData {
            r.meta.lens = s.meta.lens
            r.meta.aperture = s.meta.aperture
            r.meta.shutter = s.meta.shutter
            r.meta.focalLength = s.meta.focalLength
        }
        return r
    }

    /// Paste into a specific frame (list context menu).
    func pasteSettings(into url: URL) {
        guard let src = clipboard else { return }
        recipes[url] = pasted(src, into: recipes[url] ?? EditRecipe())
        if url == selection { refreshInversion() }
    }

    /// Manual edit of a density point switches the frame from auto to manual points.
    func setDensityPoint(white: Bool, channel: Int, value: Float) {
        recipe.inversion.autoPoints = false
        if white { recipe.inversion.dWhite[channel] = value } else { recipe.inversion.dBlack[channel] = value }
    }

    // MARK: - Histogram

    private(set) var histogram: Histogram?

    /// Changes whenever the displayed pixels may have changed; drives `.task(id:)`.
    struct HistogramKey: Equatable {
        var decodeID: UUID?
        var recipe: EditRecipe
        var showNegative: Bool
        var showBefore: Bool
        var showReference: Bool
        var tool: EditTool
    }

    var histogramKey: HistogramKey {
        HistogramKey(decodeID: currentDecode?.id, recipe: recipe.rendering, showNegative: showNegative,
                     showBefore: showBefore, showReference: showReferenceFlash && referenceImage != nil,
                     tool: tool)
    }

    func updateHistogram() {
        histogram = shownImage(clip: false).flatMap { Analyzer.histogram($0) }
    }

    // MARK: - Loupe / 1:1

    static let loupeZooms: [CGFloat] = [1, 2, 4]
    static let loupeRadius: CGFloat = 140

    /// Full-resolution linear decode of the selected frame (≈290 MB), loaded on demand.
    private(set) var fullRes: DecodedRaw?
    private(set) var isLoadingFullRes = false
    @ObservationIgnored private var fullResKey: FullResKey?
    @ObservationIgnored private var fullResTask: Task<Void, Never>?

    private struct FullResKey: Equatable {
        let url: URL
        let settings: DecodeSettings
        let mode: DecodeMode
    }

    /// Cursor position over the preview (points, y-down) and normalised in the displayed image.
    private(set) var hoverViewPoint: CGPoint?
    private(set) var hoverNormalized: CGPoint?

    private(set) var loupeKeyHeld = false
    private(set) var loupeOptionHeld = false
    private(set) var loupeZoom: CGFloat = 1
    private(set) var actualSize = false
    var actualCenter = CGPoint(x: 0.5, y: 0.5)

    /// Space held: drag pans the 1:1 view in any tool (in the spot tool a plain drag paints).
    private(set) var spaceHeld = false

    @ObservationIgnored private var zDownAt: Date?
    @ObservationIgnored private var scrollAccumulator: CGFloat = 0

    var isLoupeVisible: Bool {
        (loupeKeyHeld || loupeOptionHeld) && !actualSize && magnifierTool && hoverNormalized != nil
    }

    /// Image + scale used for magnification: full-res when ready, else the (blurry) preview.
    private var detailSource: (image: CIImage, scale: CGFloat, isFull: Bool)? {
        if let fullRes, fullRes.url == selection, fullResKey == currentKey {
            return (processed(fullRes.image, scale: CGFloat(fullRes.scale), clip: showClipping), 1, true)
        }
        guard let decode = currentDecode else { return nil }
        return (processed(decode.image, scale: CGFloat(decode.scale), clip: showClipping),
                CGFloat(decode.scale), false)
    }

    /// Tools during which the loupe / 1:1 view are available.
    var magnifierTool: Bool { tool == .none || tool == .spot }

    var detailRequest: DetailRequest? {
        guard magnifierTool else { return nil }
        if actualSize, let src = detailSource {
            return DetailRequest(kind: .actual, image: src.image, center: actualCenter,
                                 pixelZoom: loupeZoom / src.scale, isFullRes: src.isFull)
        }
        if isLoupeVisible, let p = hoverViewPoint, let n = hoverNormalized, let src = detailSource {
            return DetailRequest(kind: .loupe(viewPoint: p, radius: Self.loupeRadius),
                                 image: src.image, center: n,
                                 pixelZoom: loupeZoom / src.scale, isFullRes: src.isFull)
        }
        return nil
    }

    /// Size of the full-res processed image (for 1:1 panning maths).
    var detailImageSize: CGSize? { detailSource?.image.extent.size }
    var detailIsFullRes: Bool { detailSource?.isFull ?? false }

    private var currentKey: FullResKey? {
        selection.map { FullResKey(url: $0, settings: rollDecode,
                                   mode: compareAppleDefault ? .appleDefault : .neutralLinear) }
    }

    func updateHover(_ point: CGPoint?, viewSize: CGSize) {
        guard let point, let img = displayImage, magnifierTool else {
            hoverViewPoint = nil; hoverNormalized = nil; return
        }
        if actualSize {
            hoverViewPoint = point
            hoverNormalized = framedNormalized(fromView: point, viewSize: viewSize)
            return
        }
        let fit = FitLayout.fitRect(content: img.extent.size, in: viewSize)
        guard fit.contains(point) else {
            hoverViewPoint = nil; hoverNormalized = nil; return
        }
        hoverViewPoint = point
        hoverNormalized = CGPoint(x: (point.x - fit.minX) / fit.width,
                                  y: 1 - (point.y - fit.minY) / fit.height)
    }

    func toggleActualSize() {
        if actualSize {
            actualSize = false
        } else {
            actualCenter = hoverNormalized ?? CGPoint(x: 0.5, y: 0.5)
            actualSize = true
            ensureFullRes()
        }
    }

    func exitActualSize() { actualSize = false }

    /// Step the magnification (shared by the loupe and the 1:1 view): +1 = in, −1 = out.
    func stepZoom(_ direction: Int) {
        let zooms = Self.loupeZooms
        let i = zooms.firstIndex(of: loupeZoom) ?? 0
        loupeZoom = zooms[min(max(i + direction, 0), zooms.count - 1)]
    }

    /// Whether zoom gestures/keys currently have something to act on.
    private var magnifierActive: Bool { isLoupeVisible || actualSize }

    /// Pan the 1:1 view by a scroll delta in points (trackpad two-finger scroll).
    private func pan(byScroll dx: CGFloat, _ dy: CGFloat) {
        guard let src = detailSource else { return }
        let zoom = loupeZoom / src.scale
        let size = src.image.extent.size
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let du = -dx * scale / zoom / size.width
        let dv = dy * scale / zoom / size.height
        actualCenter = CGPoint(x: min(max(actualCenter.x + du, 0), 1),
                               y: min(max(actualCenter.y + dv, 0), 1))
    }

    /// Pan the 1:1 view by a drag translation in points.
    func pan(byPoints t: CGSize, from start: CGPoint, displayScale: CGFloat) {
        guard let src = detailSource else { return }
        let zoom = loupeZoom / src.scale
        let size = src.image.extent.size
        let du = -t.width * displayScale / zoom / size.width
        let dv = t.height * displayScale / zoom / size.height       // y-down drag → y-up centre
        actualCenter = CGPoint(x: min(max(start.x + du, 0), 1), y: min(max(start.y + dv, 0), 1))
    }

    func ensureFullRes() {
        guard let key = currentKey else { return }
        if fullResKey == key, fullRes != nil || isLoadingFullRes { return }
        fullResTask?.cancel()
        fullRes = nil
        fullResKey = key
        isLoadingFullRes = true
        fullResTask = Task { [decoder] in
            defer { if fullResKey == key { isLoadingFullRes = false } }
            do {
                let result = try await decoder.decode(url: key.url, settings: key.settings,
                                                      mode: key.mode, maxLongEdge: nil)
                guard !Task.isCancelled, fullResKey == key else { return }
                fullRes = result
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "Full-resolution decode failed: \(error.localizedDescription)"
            }
        }
    }

    private func dropFullResIfStale() {
        guard fullResKey != currentKey else { return }
        fullResTask?.cancel()
        fullRes = nil
        fullResKey = nil
        isLoadingFullRes = false
    }

    /// Keyboard/scroll handling for the loupe. Returns true if the event was consumed.
    func handle(_ event: NSEvent) -> Bool {
        guard NSApp.keyWindow != nil else { return false }
        // The Help window is just text: its keys and scrolls must not drive the editor.
        // Neither may the Retag window's.
        let windowTitle = (event.window ?? NSApp.keyWindow)?.title
        if windowTitle == HelpWindow.title || windowTitle == RetagWindow.title { return false }
        let isKey = event.type == .keyDown || event.type == .keyUp
        // Typing in a text field (shooting data, slider values): never steal its keys.
        if isKey, NSApp.keyWindow?.firstResponder is NSText { return false }

        // G / E switch grid and loupe; in the grid only its own keys apply.
        if isKey, handleGridKey(event) { return true }
        if isKey, handleToolKey(event) { return true }
        if viewMode == .grid { return false }

        // Return / Enter applies the crop.
        if event.type == .keyDown, tool == .crop, event.keyCode == 36 || event.keyCode == 76 {
            tool = .none
            return true
        }

        // Spot tool keys: [ ] brush size, ⌫ delete selected, Return to finish.
        if tool == .spot, event.type == .keyDown {
            switch event.keyCode {
            case 51, 117: deleteSelectedSpot(); return true
            case 36, 76: tool = .none; return true
            default: break
            }
            switch event.charactersIgnoringModifiers {
            case "[": resizeBrush(1 / 1.25); return true
            case "]": resizeBrush(1.25); return true
            default: break
            }
        }

        guard magnifierTool, currentDecode != nil else { return false }

        // Hold \ = before (plain inversion); J toggles the clipping overlay. No modifiers
        // (⌘\ is Show Negative, ⌘J used to be the spot tool), and not while typing in a value field.
        if isKey, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           !(NSApp.keyWindow?.firstResponder is NSText) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "\\":
                if event.type == .keyDown {
                    if !event.isARepeat { showBefore = true }
                } else {
                    showBefore = false
                }
                return true
            case "j":
                if event.type == .keyDown && !event.isARepeat { showClipping.toggle() }
                return true
            // ⇧R pins the reference; hold R flashes it.
            case "r" where event.modifierFlags.contains(.shift):
                if event.type == .keyDown && !event.isARepeat { setReference() }
                return true
            case "r":
                if event.type == .keyDown {
                    if !event.isARepeat {
                        if referenceURL == nil {
                            errorMessage = "No reference frame — pin one with ⇧R."
                        } else {
                            showReferenceFlash = true
                        }
                    }
                } else {
                    showReferenceFlash = false
                    if errorMessage?.hasPrefix("No reference frame") == true { errorMessage = nil }
                }
                return true
            default:
                break
            }
        }

        // Space + drag pans (Photoshop convention). Not while typing in a text field.
        if isKey, event.keyCode == 49 {
            if event.type == .keyDown {
                if NSApp.keyWindow?.firstResponder is NSText { return false }
                if !event.isARepeat { spaceHeld = true }
                return true
            }
            if spaceHeld { spaceHeld = false; return true }
            return false
        }
        // NB: `characters…` may only be read on key events — on scroll/pinch/flags events it
        // raises an exception, which silently swallowed every scroll event app-wide.
        let plainZ = isKey
            && event.charactersIgnoringModifiers?.lowercased() == "z"
            && event.modifierFlags.intersection([.command, .control, .option]).isEmpty

        switch event.type {
        case .keyDown where plainZ:
            if !event.isARepeat {
                zDownAt = Date()
                loupeKeyHeld = true
                ensureFullRes()
            }
            return true
        case .keyUp where plainZ:
            loupeKeyHeld = false
            if let t = zDownAt, Date().timeIntervalSince(t) < 0.25 { toggleActualSize() }
            zDownAt = nil
            return true
        case .keyDown where event.keyCode == 53 && actualSize:      // Escape
            actualSize = false
            return true
        case .flagsChanged:
            let option = event.modifierFlags.contains(.option)
            if option != loupeOptionHeld {
                loupeOptionHeld = option
                if option { ensureFullRes() }
            }
            return false
        // + / − (also = and _) step the zoom. Works with Z held, unlike trackpad scrolling,
        // which macOS suppresses while a letter key is down (palm rejection).
        case .keyDown where magnifierActive
            && ["=", "+", "-", "_"].contains(event.charactersIgnoringModifiers ?? ""):
            let c = event.charactersIgnoringModifiers ?? ""
            stepZoom(c == "=" || c == "+" ? 1 : -1)
            return true
        // Trackpad pinch: zoom the loupe or the 1:1 view.
        case .magnify where magnifierActive:
            scrollAccumulator += event.magnification * 6
            if abs(scrollAccumulator) >= 1 {
                stepZoom(scrollAccumulator > 0 ? 1 : -1)
                scrollAccumulator = 0
            }
            return true
        // 1:1 view: two-finger scroll pans.
        case .scrollWheel where actualSize:
            let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            pan(byScroll: event.scrollingDeltaX * k, event.scrollingDeltaY * k)
            return true
        // Loupe (e.g. with Option held, which palm rejection allows): scroll steps the zoom.
        case .scrollWheel where isLoupeVisible:
            scrollAccumulator += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 12 : event.scrollingDeltaY
            if abs(scrollAccumulator) >= 1 {
                stepZoom(scrollAccumulator > 0 ? 1 : -1)
                scrollAccumulator = 0
            }
            return true
        default:
            return false
        }
    }

    /// Full-resolution output size for the current geometry.
    var outputPixelSize: CGSize? {
        currentDecode.map { Pipeline.outputSize(nativeSize: $0.nativeSize, recipe.geometry) }
    }

    /// Base sample rect in displayed orientation, for drawing.
    var orientedBaseRect: CGRect? {
        recipe.inversion.baseRect.map { recipe.geometry.orientedRect(fromSource: $0) }
    }

    // MARK: - Geometry commands

    func rotateClockwise() { recipe.geometry.rotateClockwise() }
    func rotateCounterClockwise() { recipe.geometry.rotateCounterClockwise() }
    func toggleFlip() { recipe.geometry.toggleFlip() }
    func resetCrop() { recipe.geometry.crop = Geometry().crop; refreshInversion() }
    func resetGeometry() { recipe.geometry = Geometry(); refreshInversion() }

    func toggleTool(_ t: EditTool) { tool = (tool == t) ? .none : t }

    // MARK: - Inversion commands

    /// `orientedRect` is normalised in the displayed orientation (from the overlay).
    func sampleBase(orientedRect: CGRect) {
        recipe.inversion.baseRect = recipe.geometry.sourceRect(fromOriented: orientedRect)
        tool = .none
        showNegative = false
        refreshInversion()
    }

    /// Copy this frame's base-sample position to every frame of the roll. Each frame then
    /// measures its own base RGB at that position when it is decoded.
    func copyBaseAreaToAllFrames() {
        guard let rect = recipe.inversion.baseRect else { return }
        for url in files where url != selection {
            var r = recipes[url] ?? EditRecipe()
            r.inversion.baseRect = rect
            r.inversion.base = nil
            recipes[url] = r
        }
    }

    func remeasurePoints() {
        recipe.inversion.autoPoints = true
        refreshInversion()
    }

    /// Remove this frame's own base sample. With a roll base the frame falls back to it.
    func clearBase() {
        recipe.inversion.baseRect = nil
        recipe.inversion.base = nil
        refreshInversion()
    }

    /// Automatic points from `source` (leaves manual mode).
    func setPointSource(_ source: PointSource) {
        recipe.inversion.pointSource = source
        recipe.inversion.autoPoints = true
        refreshInversion()
    }

    /// Re-measure the film base (from its rect, or the roll base) and, if auto, the density
    /// points on the current decode of `url`. Cheap (~tens of ms) on the 2560 px preview.
    func refreshInversion(for url: URL? = nil) {
        guard let url = url ?? selection,
              let decode = preview, decode.url == url else { return }
        var r = recipes[url] ?? EditRecipe()
        let name = url.lastPathComponent

        let base: SIMD3<Float>
        if let srcRect = r.inversion.baseRect {
            let e = decode.image.extent
            let px = CGRect(x: e.minX + srcRect.minX * e.width, y: e.minY + srcRect.minY * e.height,
                            width: srcRect.width * e.width, height: srcRect.height * e.height)
            guard let measured = Analyzer.average(decode.image, in: px) else {
                errorMessage = "Film-base sample is empty or clipped — sample a larger clear area."
                return
            }
            base = measured
            // The roll base's own frame keeps the roll base current for free.
            if var rb = rollBase, rb.frame == name, rb.rect == srcRect,
               rb.rgb != measured || rb.decode != rollDecode {
                rb.rgb = measured
                rb.decode = rollDecode
                rollBaseTask?.cancel()
                rollBase = rb
            }
        } else if let rb = rollBaseRGB {
            base = rb
        } else {
            // No base of its own and no (current) roll base: not invertible (yet).
            if recipes[url] != nil, r.inversion.base != nil {
                r.inversion.base = nil
                recipes[url] = r
            }
            return
        }
        r.inversion.base = base

        if r.inversion.autoPoints {
            let source = r.inversion.pointSource
            let framePoints = PointResolver.needsFramePoints(source, roll: rollAnalysis)
                ? Analyzer.densityPoints(Pipeline.framed(decode.image, r), base: base) : nil
            if let pts = PointResolver.resolve(source, frame: framePoints, roll: rollAnalysis) {
                r.inversion.dBlack = pts.black
                r.inversion.dWhite = pts.white
            }
        }
        if recipes[url] != r { recipes[url] = r }
        errorMessage = nil
    }

    // MARK: - Roll commands

    /// Roll base RGB, if it is valid for the current decode settings.
    var rollBaseRGB: SIMD3<Float>? {
        guard let b = rollBase, b.decode == rollDecode else { return nil }
        return b.rgb
    }

    /// The selected frame's base becomes the roll base.
    func useBaseForRoll() {
        guard let url = selection, let rect = recipe.inversion.baseRect,
              let rgb = recipe.inversion.base else { return }
        rollBase = RollBase(frame: url.lastPathComponent, rect: rect, rgb: rgb, decode: rollDecode)
    }

    var isRollBaseFrame: Bool {
        guard let url = selection, let rb = rollBase else { return false }
        return rb.frame == url.lastPathComponent && rb.rect == recipe.inversion.baseRect
    }

    /// Roll base out of date after a decode change: re-measure it on a small decode of its frame.
    private func scheduleRollBaseRemeasure() {
        guard let rb = rollBase, rb.decode != rollDecode, let folder = folderURL else { return }
        rollBaseTask?.cancel()
        let url = folder.appendingPathComponent(rb.frame)
        let settings = rollDecode
        rollBaseTask = Task {
            try? await Task.sleep(for: .milliseconds(300))           // coalesce slider drags
            guard !Task.isCancelled else { return }
            let rgb: SIMD3<Float>? = await Task.detached(priority: .userInitiated) {
                guard let img = try? RawDecoder.smallLinearImage(url: url, settings: settings, maxLongEdge: 1200)
                else { return nil }
                let e = img.extent
                return Analyzer.average(img, in: CGRect(x: rb.rect.minX * e.width, y: rb.rect.minY * e.height,
                                                        width: rb.rect.width * e.width,
                                                        height: rb.rect.height * e.height))
            }.value
            guard !Task.isCancelled, settings == rollDecode, var cur = rollBase, cur.frame == rb.frame else { return }
            guard let rgb else {
                errorMessage = "Couldn't re-measure the roll base on \(rb.frame)."
                return
            }
            cur.rgb = rgb
            cur.decode = settings
            rollBase = cur
            refreshInversion()
        }
    }

    func isExcluded(_ url: URL) -> Bool { rollExcluded.contains(url.lastPathComponent) }

    func toggleExcluded(_ url: URL) {
        let n = url.lastPathComponent
        if rollExcluded.contains(n) { rollExcluded.remove(n) } else { rollExcluded.insert(n) }
        // Re-pool at once when every histogram is already in memory (no decoding needed).
        if rollAnalysis != nil, !isAnalysing,
           analysisCandidates().frames.allSatisfy({ histogramCache[$0.name]?.fingerprint == $0.fingerprint }) {
            analyseRoll()
        }
    }

    struct AnalysisCandidate {
        let url: URL
        let name: String
        let recipe: EditRecipe
        let fingerprint: String
    }

    /// Frames that go into the roll analysis: not excluded, cropped (an uncropped frame
    /// includes rebate and holder, which would wreck the percentiles), with a base.
    func analysisCandidates() -> (frames: [AnalysisCandidate], uncropped: Int, noBase: Int) {
        var out: [AnalysisCandidate] = []
        var uncropped = 0, noBase = 0
        let rb = rollBaseRGB != nil ? rollBase : nil
        for url in files {
            let name = url.lastPathComponent
            guard !rollExcluded.contains(name) else { continue }
            guard let r = recipes[url], r.geometry.crop != Geometry().crop else { uncropped += 1; continue }
            guard r.inversion.baseRect != nil || rb != nil else { noBase += 1; continue }
            out.append(AnalysisCandidate(url: url, name: name, recipe: r,
                                         fingerprint: Fingerprint.frame(r, decode: rollDecode, rollBase: rb)))
        }
        return (out, uncropped, noBase)
    }

    enum RollAnalysisState: Equatable { case none, current, stale }

    var rollAnalysisState: RollAnalysisState {
        guard let a = rollAnalysis else { return .none }
        let now = analysisCandidates().frames
        let current = Dictionary(uniqueKeysWithValues: now.map { ($0.name, $0.fingerprint) })
        return current == a.frames ? .current : .stale
    }

    /// Measure every candidate frame (small decode, cached per frame) and pool the histograms.
    func analyseRoll() {
        guard !isAnalysing else { return }
        let cands = analysisCandidates().frames
        guard !cands.isEmpty else {
            errorMessage = "Nothing to analyse — crop the frames and sample a film base (or set a roll base) first."
            return
        }
        let decode = rollDecode
        let rollRGB = rollBaseRGB
        isAnalysing = true
        analysisProgress = 0
        analysisTask = Task {
            defer { isAnalysing = false }
            var hists: [DensityHistogram] = []
            var used: [String: String] = [:]
            for (i, c) in cands.enumerated() {
                guard !Task.isCancelled else { return }
                if let cached = histogramCache[c.name], cached.fingerprint == c.fingerprint {
                    hists.append(cached.hist)
                    used[c.name] = c.fingerprint
                } else {
                    let h = await Task.detached(priority: .userInitiated) {
                        Self.measureFrame(url: c.url, recipe: c.recipe, decode: decode, rollBase: rollRGB)
                    }.value
                    if let h {
                        histogramCache[c.name] = (c.fingerprint, h)
                        hists.append(h)
                        used[c.name] = c.fingerprint
                    }
                }
                analysisProgress = Double(i + 1) / Double(cands.count)
            }
            guard !Task.isCancelled, decode == rollDecode else { return }
            guard let pooled = DensityHistogram.pooled(hists) else {
                errorMessage = "Roll analysis failed — no frame could be measured."
                return
            }
            let pts = pooled.points()
            rollAnalysis = RollAnalysis(dBlack: pts.black, dWhite: pts.white, frames: used, date: Date())
            refreshInversion()
        }
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        isAnalysing = false
    }

    /// Small decode → base (own sample or roll base) → framed density histogram.
    nonisolated private static func measureFrame(url: URL, recipe: EditRecipe, decode: DecodeSettings,
                                                 rollBase: SIMD3<Float>?) -> DensityHistogram? {
        guard let img = try? RawDecoder.smallLinearImage(url: url, settings: decode, maxLongEdge: 1200)
        else { return nil }
        let base: SIMD3<Float>
        if let r = recipe.inversion.baseRect {
            let e = img.extent
            guard let b = Analyzer.average(img, in: CGRect(x: r.minX * e.width, y: r.minY * e.height,
                                                           width: r.width * e.width, height: r.height * e.height))
            else { return nil }
            base = b
        } else if let rollBase {
            base = rollBase
        } else {
            return nil
        }
        return Analyzer.densityHistogram(Pipeline.framed(img, recipe), base: base)
    }

    private func saveRoll() {
        guard !suppressSave, let folder = folderURL else { return }
        let file = RollFile(decode: rollDecode, base: rollBase,
                            excluded: rollExcluded.sorted(), analysis: rollAnalysis,
                            reference: referenceName,
                            metadata: rollMeta.isEmpty ? nil : rollMeta)
        do {
            try RollStore.save(file, folder: folder)
        } catch {
            errorMessage = "Couldn't save the roll file: \(error.localizedDescription)"
        }
    }

    // MARK: - Shooting data (analog metadata for exports)

    /// Roll-level shooting data, stored in the roll file. Saved debounced (typing).
    var rollMeta = RollMetadata() {
        didSet { if oldValue != rollMeta { scheduleRollSave() } }
    }
    var isRollInfoShown = false
    @ObservationIgnored private var rollSaveTask: Task<Void, Never>?

    private func scheduleRollSave() {
        rollSaveTask?.cancel()
        rollSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            saveRoll()
        }
    }

    // MARK: - Reference frame (C5)

    /// File name of the pinned reference frame (stored in the roll file).
    private(set) var referenceName: String? {
        didSet { if oldValue != referenceName { saveRoll() } }
    }
    /// Show the reference next to the current frame.
    var referenceSideBySide = false
    /// Held R: the reference replaces the current frame in the preview.
    private(set) var showReferenceFlash = false
    /// The reference's positive, rendered once to memory (RGBAh, working space). Re-rendered
    /// only when its recipe, the roll decode, roll base or roll analysis change.
    private(set) var referenceImage: CIImage?
    private(set) var isRenderingReference = false

    /// Linear preview-size decode of the reference (survives recipe edits).
    @ObservationIgnored private var referenceDecode: (url: URL, decode: DecodeSettings, image: CIImage)?
    /// Reference recipe with base + points measured on `referenceDecode`, and its inverted
    /// positive before tone — inputs for Match WB.
    @ObservationIgnored private var referenceMeasured: (recipe: EditRecipe, inverted: CIImage)?
    @ObservationIgnored private var renderedReferenceKey: ReferenceKey?

    var referenceURL: URL? {
        referenceName.flatMap { n in files.first { $0.lastPathComponent == n } }
    }

    var isReferenceFrame: Bool {
        selection != nil && selection?.lastPathComponent == referenceName
    }

    /// Everything the rendered reference depends on; drives `.task(id:)` in the view.
    struct ReferenceKey: Equatable {
        var url: URL
        var decode: DecodeSettings
        var recipe: EditRecipe
        var rollBase: SIMD3<Float>?
        var analysis: RollAnalysis?
    }

    var referenceKey: ReferenceKey? {
        guard let url = referenceURL, let r = recipes[url] else { return nil }
        return ReferenceKey(url: url, decode: rollDecode, recipe: r.rendering,
                            rollBase: r.inversion.baseRect == nil ? rollBaseRGB : nil,
                            analysis: rollAnalysis)
    }

    /// Pin the selected frame as the roll's reference (⇧R).
    func setReference() {
        guard let url = selection else { return }
        guard recipes[url]?.inversion.isReady == true else {
            errorMessage = "Invert this frame first (sample the film base), then pin it as reference."
            return
        }
        referenceName = url.lastPathComponent
        errorMessage = nil
    }

    func clearReference() {
        referenceName = nil
        referenceSideBySide = false
        showReferenceFlash = false
    }

    /// Render the reference positive if its inputs changed. Decodes only when the frame or the
    /// decode settings changed; a recipe edit just re-renders from the cached decode.
    func renderReference() async {
        guard let key = referenceKey else {
            referenceImage = nil
            referenceMeasured = nil
            renderedReferenceKey = nil
            return
        }
        if key == renderedReferenceKey, referenceImage != nil { return }
        isRenderingReference = true
        defer { isRenderingReference = false }

        let linear: CIImage
        if let d = referenceDecode, d.url == key.url, d.decode == key.decode {
            linear = d.image
        } else if let p = preview, p.url == key.url, !compareAppleDefault {
            linear = p.image                                   // reference is the open frame
        } else {
            let url = key.url, settings = key.decode, edge = Self.previewLongEdge
            let img: CIImage? = await Task.detached(priority: .userInitiated) {
                try? RawDecoder.smallLinearImage(url: url, settings: settings, maxLongEdge: edge)
            }.value
            guard !Task.isCancelled else { return }
            guard let img else {
                errorMessage = "Couldn't decode the reference frame \(key.url.lastPathComponent)."
                return
            }
            linear = img
        }
        referenceDecode = (key.url, key.decode, linear)

        guard let r = Self.measuredInversion(key.recipe, on: linear, rollBase: key.rollBase,
                                             roll: key.analysis) else {
            referenceImage = nil
            referenceMeasured = nil
            return
        }
        let framed = Pipeline.framed(linear, r)
        // No sharpening: the reference flash is for comparing colour and tone, and this decode's
        // scale isn't known here.
        let positive = Pipeline.positive(framed, r, detailScale: 0)
        guard let cg = RenderEngine.previewContext.createCGImage(
            positive, from: positive.extent, format: .RGBAh,
            colorSpace: RenderEngine.workingSpace, deferred: false) else { return }
        guard !Task.isCancelled else { return }
        referenceImage = CIImage(cgImage: cg, options: [.colorSpace: RenderEngine.workingSpace])
        referenceMeasured = (r, Pipeline.inverted(framed, r.inversion))
        renderedReferenceKey = key
    }

    /// `r` with its film base and (if auto) density points measured on `image`, a decode of its
    /// own frame — as `refreshInversion` does for the open frame, without side effects.
    /// nil when the frame has no base of its own and no roll base applies.
    nonisolated static func measuredInversion(_ recipe: EditRecipe, on image: CIImage,
                                  rollBase: SIMD3<Float>?, roll: RollAnalysis?) -> EditRecipe? {
        var r = recipe
        if let src = r.inversion.baseRect {
            let e = image.extent
            let px = CGRect(x: e.minX + src.minX * e.width, y: e.minY + src.minY * e.height,
                            width: src.width * e.width, height: src.height * e.height)
            guard let b = Analyzer.average(image, in: px) else { return nil }
            r.inversion.base = b
        } else if let rollBase {
            r.inversion.base = rollBase
        } else {
            return nil
        }
        if r.inversion.autoPoints, let base = r.inversion.base {
            let source = r.inversion.pointSource
            let framePoints = PointResolver.needsFramePoints(source, roll: roll)
                ? Analyzer.densityPoints(Pipeline.framed(image, r), base: base) : nil
            if let pts = PointResolver.resolve(source, frame: framePoints, roll: roll) {
                r.inversion.dBlack = pts.black
                r.inversion.dWhite = pts.white
            }
        }
        return r
    }

    var canMatchReference: Bool {
        referenceMeasured != nil && !isReferenceFrame && recipe.inversion.isReady
    }

    /// Set temperature/tint so this frame's midtone grey-world balance matches the reference's.
    /// Compared on the inverted positives before tone (linear), with each frame's own tone gain:
    /// wanted gain g = g_ref · mean_ref / mean_cur, normalised to green (exposure untouched).
    /// Two passes, because the midtone mask depends on the gain.
    func matchWhiteBalanceToReference() {
        guard let ref = referenceMeasured, let decode = currentDecode, recipe.inversion.isReady else { return }
        guard let refMean = Analyzer.greyWorld(ref.inverted, gain: ref.recipe.tone.gain) else {
            errorMessage = "The reference has too few neutral midtones to match against."
            return
        }
        let cur = Pipeline.inverted(Pipeline.framed(decode.image, recipe), recipe.inversion)
        var tone = recipe.tone
        for _ in 0..<2 {
            guard let curMean = Analyzer.greyWorld(cur, gain: tone.gain) else {
                errorMessage = "This frame has too few neutral midtones to match."
                return
            }
            let g = ref.recipe.tone.gain * refMean / curMean
            let a = log2f(g.x / g.y), b = log2f(g.z / g.y)
            guard a.isFinite, b.isFinite else { return }
            tone.temperature = min(max((a - b) / 2, -1), 1)
            tone.tint = min(max((a + b) / 2, -1), 1)
        }
        recipe.tone.temperature = tone.temperature
        recipe.tone.tint = tone.tint
        errorMessage = nil
    }

    // MARK: - Folder

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Roll"
        panel.message = "Choose a folder of RAW files (Nikon NEF, Canon CR2/CR3, Fujifilm RAF)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadFolder(url)
    }

    func loadFolder(_ url: URL) {
        flushSaves()                     // finish writing the previous roll first
        cancelAnalysis()
        rollBaseTask?.cancel()
        histogramCache = [:]
        thumbnails.reset()
        thumbnailTask?.cancel()
        thumbnailDirty = []
        folderURL = url
        tool = .none
        exportStatus = nil
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        files = items
            .filter { RawDecoder.supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        // Load sidecars without immediately re-writing them.
        suppressSave = true
        var loaded: [URL: EditRecipe] = [:]
        var rollSettings: DecodeSettings?
        for f in files {
            if let s = Sidecar.load(for: f) {
                loaded[f] = s.recipe
                if rollSettings == nil { rollSettings = s.decode }
            }
        }
        recipes = loaded
        let roll = RollStore.load(folder: url)
        rollBase = roll?.base
        rollExcluded = Set(roll?.excluded ?? [])
        rollAnalysis = roll?.analysis
        referenceName = roll?.reference.flatMap { n in files.contains { $0.lastPathComponent == n } ? n : nil }
        referenceSideBySide = false
        rollMeta = roll?.metadata ?? RollMetadata()
        rollDecode = roll?.decode ?? rollSettings ?? DecodeSettings()   // roll file is authoritative
        suppressSave = false

        selection = files.first
        scheduleThumbnails(Set(files), delay: .zero)
        if files.isEmpty {
            preview = nil
            errorMessage = "No RAW files (NEF, CR2, CR3, RAF) in \(url.lastPathComponent)."
        }
    }

    // MARK: - Decoding

    private func scheduleDecode(debounce: Bool) {
        decodeTask?.cancel()
        generation += 1
        let myGeneration = generation

        guard let url = selection else {
            preview = nil
            isDecoding = false
            return
        }
        let settings = rollDecode
        let mode: DecodeMode = compareAppleDefault ? .appleDefault : .neutralLinear
        dropFullResIfStale()        // new frame or new decode settings: the full-res copy is invalid

        decodeTask = Task { [decoder] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(120))   // coalesce slider drags
            }
            guard !Task.isCancelled else { return }
            isDecoding = true
            defer { if myGeneration == generation { isDecoding = false } }

            do {
                let result = try await decoder.decode(url: url, settings: settings, mode: mode,
                                                      maxLongEdge: Self.previewLongEdge)
                guard !Task.isCancelled else { return }
                preview = result
                errorMessage = nil
                // Base RGB depends on the decode settings: re-measure on every new decode.
                if mode == .neutralLinear { refreshInversion(for: url) }
            } catch {
                guard !Task.isCancelled else { return }
                preview = nil
                errorMessage = error.localizedDescription
            }
        }
    }
}
