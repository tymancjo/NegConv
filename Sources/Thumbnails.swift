import AppKit
import CoreImage
import ImageIO
import Observation
import UniformTypeIdentifiers

// MARK: - What a thumbnail is made from

/// Everything an edited frame's small positive depends on — and nothing else (shooting data
/// is excluded via `EditRecipe.rendering`), so its fingerprint is a stable disk-cache key.
struct ThumbnailPositiveInputs: Encodable {
    var name: String
    var recipe: EditRecipe
    var decode: DecodeSettings
    /// Roll base, only for frames without a base sample of their own.
    var rollBase: SIMD3<Float>?
    /// Roll analysis, only for frames using a roll point source.
    var analysis: RollAnalysis?
}

enum ThumbnailSource {
    /// RAW file: the camera's embedded preview — the negative, as the camera rendered it.
    case embedded
    /// JPEG / TIFF: the image itself.
    case file
    /// Edited RAW frame: a small positive through the real pipeline.
    case positive(ThumbnailPositiveInputs)

    var key: String {
        switch self {
        case .embedded: "neg"
        case .file: "file"
        case .positive(let i): "pos-" + Fingerprint.of(i)
        }
    }

    /// Fast sources are served first, so a roll shows negatives at once and positives follow.
    var isSlow: Bool {
        if case .positive = self { return true }
        return false
    }
}

// MARK: - Store (one per window)

/// Thumbnails for a list of files. Requests are idempotent: asking again for the same source
/// does nothing, asking for a new one replaces the queued job. Work runs one job at a time in
/// the background (RAW decodes are memory-hungry); finished images are published on the main
/// actor. Positives are cached on disk, so a roll opened again shows them instantly.
@MainActor
@Observable
final class ThumbnailStore {
    private(set) var images: [URL: CGImage] = [:]

    private struct Job {
        let url: URL
        let key: String
        let source: ThumbnailSource
    }

    /// Key of the image currently in `images`.
    @ObservationIgnored private var shown: [URL: String] = [:]
    /// Key of the newest request.
    @ObservationIgnored private var wanted: [URL: String] = [:]
    @ObservationIgnored private var queue: [Job] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var epoch = 0

    /// Forget everything (new folder).
    func reset() {
        epoch += 1
        worker?.cancel()
        worker = nil
        queue = []
        images = [:]
        shown = [:]
        wanted = [:]
    }

    func isCurrent(_ url: URL, _ source: ThumbnailSource) -> Bool { wanted[url] == source.key }

    func request(_ url: URL, _ source: ThumbnailSource) {
        let key = source.key
        guard wanted[url] != key else { return }
        wanted[url] = key
        queue.removeAll { $0.url == url }
        if shown[url] == key { return }
        // A positive takes a moment: show the negative first if there is nothing yet.
        if source.isSlow, images[url] == nil {
            queue.append(Job(url: url, key: ThumbnailSource.embedded.key, source: .embedded))
        }
        queue.append(Job(url: url, key: key, source: source))
        startWorker()
    }

    /// An image made elsewhere — the open frame's live thumbnail from its preview decode.
    /// Positives are also written to the disk cache.
    func set(_ image: CGImage, for url: URL, source: ThumbnailSource) {
        let key = source.key
        wanted[url] = key
        queue.removeAll { $0.url == url }
        images[url] = image
        shown[url] = key
        if source.isSlow {
            Task.detached(priority: .utility) { ThumbnailCache.write(image, for: url, key: key) }
        }
    }

    private func startWorker() {
        guard worker == nil else { return }
        let myEpoch = epoch
        worker = Task { [weak self] in
            while true {
                guard let self, myEpoch == self.epoch, let job = self.nextJob() else { break }
                let url = job.url, key = job.key, source = job.source
                let image = await Task.detached(priority: .utility) {
                    autoreleasepool { ThumbnailRenderer.make(url, source, key: key) }
                }.value
                guard myEpoch == self.epoch else { break }
                self.finish(url: url, key: key, image: image)
            }
            if let self, myEpoch == self.epoch { self.worker = nil }
        }
    }

    private func nextJob() -> Job? {
        if let i = queue.firstIndex(where: { !$0.source.isSlow }) { return queue.remove(at: i) }
        return queue.isEmpty ? nil : queue.removeFirst()
    }

    private func finish(url: URL, key: String, image: CGImage?) {
        guard let image else { return }                 // keep whatever is shown
        if key == wanted[url] || images[url] == nil {
            images[url] = image
            shown[url] = key
        }
    }
}

// MARK: - Rendering (background)

enum ThumbnailRenderer {
    /// Long edge of stored thumbnails: sharp at the largest grid tile on a Retina screen.
    static let maxPixels: CGFloat = 640
    /// Linear decode size for positives (before crop).
    static let decodeLongEdge: CGFloat = 800

    static func make(_ url: URL, _ source: ThumbnailSource, key: String) -> CGImage? {
        switch source {
        case .embedded:
            return imageIOThumbnail(url, fromImage: false)
        case .file:
            return imageIOThumbnail(url, fromImage: true)
        case .positive(let inputs):
            if let cached = ThumbnailCache.read(for: url, key: key) { return cached }
            guard let image = positive(url, inputs) else { return nil }
            ThumbnailCache.write(image, for: url, key: key)
            return image
        }
    }

    /// ImageIO thumbnail. For RAW files this is the camera's embedded JPEG preview (fast, no
    /// RAW decode); if that is only a tiny IFD thumbnail, fall back to a reduced decode.
    static func imageIOThumbnail(_ url: URL, fromImage: Bool) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL,
                                                   [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        func thumb(always: Bool) -> CGImage? {
            let opts: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                kCGImageSourceCreateThumbnailWithTransform: true,
                (always ? kCGImageSourceCreateThumbnailFromImageAlways
                        : kCGImageSourceCreateThumbnailFromImageIfAbsent): true,
                kCGImageSourceShouldCacheImmediately: true
            ]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }
        if fromImage { return thumb(always: true) }
        if let t = thumb(always: false), max(t.width, t.height) >= 256 { return t }
        return thumb(always: true)
    }

    /// The real pipeline on a small neutral decode: base and (auto) density points are
    /// re-measured on this decode exactly as for the reference frame. No sharpening (the
    /// radius means nothing at thumbnail size).
    static func positive(_ url: URL, _ i: ThumbnailPositiveInputs) -> CGImage? {
        guard let linear = try? RawDecoder.smallLinearImage(url: url, settings: i.decode,
                                                            maxLongEdge: decodeLongEdge),
              let r = AppModel.measuredInversion(i.recipe, on: linear, rollBase: i.rollBase,
                                                 roll: i.analysis)
        else { return nil }
        return render(Pipeline.positive(Pipeline.framed(linear, r), r, detailScale: 0))
    }

    /// Downsize in linear light (Lanczos), then encode once to 8-bit sRGB for display.
    static func render(_ image: CIImage) -> CGImage? {
        var img = image
        let e = img.extent
        let long = max(e.width, e.height)
        guard long.isFinite, long > 0 else { return nil }
        if long > maxPixels {
            let s = maxPixels / long
            img = img
                .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                .clampedToExtent()
                .applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: s, kCIInputAspectRatioKey: 1.0])
                .cropped(to: CGRect(x: 0, y: 0, width: max(1, (e.width * s).rounded(.down)),
                                    height: max(1, (e.height * s).rounded(.down))))
        }
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return RenderEngine.previewContext.createCGImage(img, from: img.extent.integral,
                                                         format: .RGBA8, colorSpace: srgb,
                                                         deferred: false)
    }
}

// MARK: - Disk cache

/// `~/Library/Caches/<bundle id>/Thumbnails/<file hash>-<key>.jpg`. One file per source file:
/// writing a new key removes the older ones of the same file.
enum ThumbnailCache {
    static let folder: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "NegConv", isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
    }()

    private static func prefix(_ url: URL) -> String { Fingerprint.of(url.standardizedFileURL.path) }

    private static func file(_ url: URL, key: String) -> URL {
        folder.appendingPathComponent("\(prefix(url))-\(key).jpg")
    }

    static func read(for url: URL, key: String) -> CGImage? {
        let f = file(url, key: key)
        guard let src = CGImageSourceCreateWithURL(f as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    static func write(_ image: CGImage, for url: URL, key: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = file(url, key: key)
        let tmp = folder.appendingPathComponent(".\(UUID().uuidString).jpg")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString,
                                                         1, nil) else { return }
        CGImageDestinationAddImage(dest, image,
                                   [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { try? fm.removeItem(at: tmp); return }
        try? fm.removeItem(at: target)
        try? fm.moveItem(at: tmp, to: target)

        // Drop stale versions of this file's thumbnail.
        let p = prefix(url) + "-"
        let keep = target.lastPathComponent
        if let names = try? fm.contentsOfDirectory(atPath: folder.path) {
            for n in names where n.hasPrefix(p) && n != keep {
                try? fm.removeItem(at: folder.appendingPathComponent(n))
            }
        }
    }
}
