import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ExportError: LocalizedError {
    case noFilmBase(String)
    case renderFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noFilmBase(let n): return "\(n): film base not sampled"
        case .renderFailed(let n): return "\(n): render failed"
        case .writeFailed(let n): return "\(n): could not write TIFF"
        }
    }
}

/// Full-resolution export. Same `Pipeline` functions as the preview, but:
/// - a fresh CIRAWFilter at scale 1 (not the frozen half-float preview),
/// - a dedicated context with a 32-bit float working format (log/exp density math needs it),
/// - output encoded once, at the very end, to 16-bit Adobe RGB (1998).
enum Exporter {
    struct Job {
        let source: URL
        let recipe: EditRecipe
        let decode: DecodeSettings
        /// Roll base RGB, for frames without a base sample of their own.
        let rollBase: SIMD3<Float>?
        /// Pooled roll points, for frames using the Roll / Roll colour point source.
        let rollAnalysis: RollAnalysis?
        let destination: URL
        let settings: ExportSettings
        /// Analog shooting data of the roll (the frame's own is in `recipe.meta`).
        let rollMeta: RollMetadata
        /// Position in the roll, for ordering frames that share a date-only roll date.
        let frameIndex: Int
    }

    static var softwareName: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return v.isEmpty ? "NegConv" : "NegConv \(v)"
    }

    static let context = CIContext(mtlDevice: RenderEngine.device, options: [
        .workingColorSpace: RenderEngine.workingSpace,
        .workingFormat: CIFormat.RGBAf,
        .cacheIntermediates: false
    ])

    static func export(_ job: Job) throws {
        let name = job.source.lastPathComponent
        let linear = try RawDecoder.linearImage(url: job.source, settings: job.decode)

        // Always re-measure the base on this exact decode (it depends on the decode settings).
        // Frames that got a base *area* by paste but were never opened also get their auto
        // points measured here; otherwise the points the user saw in the preview are kept.
        var recipe = job.recipe
        let neverMeasured = recipe.inversion.base == nil
        if let r = recipe.inversion.baseRect {
            let e = linear.extent
            let px = CGRect(x: r.minX * e.width, y: r.minY * e.height,
                            width: r.width * e.width, height: r.height * e.height)
            recipe.inversion.base = Analyzer.average(linear, in: px) ?? recipe.inversion.base
        } else if let rb = job.rollBase {
            recipe.inversion.base = rb
        }
        // Auto points: frame mode keeps the points seen in the preview (measured here only if the
        // frame was never opened); roll modes are always resolved here, so frames that were never
        // opened after an analysis are still right.
        let inv = recipe.inversion
        if let base = inv.base, inv.autoPoints, neverMeasured || (inv.pointSource != .frame && job.rollAnalysis != nil) {
            let framePts = PointResolver.needsFramePoints(inv.pointSource, roll: job.rollAnalysis)
                ? Analyzer.densityPoints(Pipeline.framed(linear, recipe), base: base) : nil
            if let pts = PointResolver.resolve(inv.pointSource, frame: framePts, roll: job.rollAnalysis) {
                recipe.inversion.dBlack = pts.black
                recipe.inversion.dWhite = pts.white
            }
        }
        guard recipe.inversion.isReady else { throw ExportError.noFilmBase(name) }

        let framed = Pipeline.framed(linear, recipe)
        // Sharpened at full resolution, exactly as seen in the 1:1 loupe, then downsized.
        var positive = Pipeline.positive(framed, recipe, detailScale: 1)

        // Optional downsize (Lanczos, in linear light — correct averaging of bright/dark detail).
        let e = positive.extent
        let longEdge = max(e.width, e.height)
        if job.settings.maxLongEdge > 0, longEdge > CGFloat(job.settings.maxLongEdge) {
            let s = CGFloat(job.settings.maxLongEdge) / longEdge
            positive = positive
                .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                .clampedToExtent()
                .applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: s, kCIInputAspectRatioKey: 1.0])
                .cropped(to: CGRect(x: 0, y: 0, width: (e.width * s).rounded(.down),
                                    height: (e.height * s).rounded(.down)))
        }

        let meta = ExportMetadata.properties(.init(
            roll: job.rollMeta, frame: job.recipe.meta, sourceName: name, frameIndex: job.frameIndex,
            scanDate: ExportMetadata.scanDate(of: job.source), software: softwareName))

        switch job.settings.format {
        case .tiff16: try writeTIFF16(positive, to: job.destination, name: name, metadata: meta)
        case .jpeg: try writeJPEG(positive, quality: job.settings.jpegQuality, to: job.destination,
                                  name: name, metadata: meta)
        }
    }

    /// 8-bit sRGB JPEG with embedded profile. sRGB because that is what browsers, phones and
    /// sharing services assume; colours outside sRGB are clipped at this final step.
    static func writeJPEG(_ image: CIImage, quality: Double, to url: URL, name: String,
                          metadata: [CFString: Any] = [:]) throws {
        let e = image.extent.integral
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = context.createCGImage(image, from: e, format: .RGBA8,
                                             colorSpace: srgb, deferred: false) else {
            throw ExportError.renderFailed(name)
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString,
                                                         1, nil) else {
            throw ExportError.writeFailed(name)
        }
        let props = ExportMetadata.merged([
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: 1
        ], metadata)
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.writeFailed(name) }
    }

    /// 16-bit/channel RGB TIFF (no alpha), uncompressed, Adobe RGB (1998) ICC profile embedded.
    /// Why uncompressed: ImageIO ignores the TIFF Predictor tag, and without horizontal
    /// differencing LZW makes grainy 16-bit data ~30 % LARGER, Deflate saves only ~2 %.
    /// (A custom writer with Predictor 2 + Deflate could save ~20–30 % later.)
    /// Values are clipped to 0…1 here and only here — the single, final gamut/range decision.
    static func writeTIFF16(_ image: CIImage, to url: URL, name: String,
                            metadata: [CFString: Any] = [:]) throws {
        let e = image.extent.integral
        let w = Int(e.width), h = Int(e.height)
        let space = RenderEngine.exportSpace

        guard let rgba = context.createCGImage(image, from: e, format: .RGBA16,
                                               colorSpace: space, deferred: false) else {
            throw ExportError.renderFailed(name)
        }

        // Drop the (opaque) alpha channel: draw into a 16-bit RGBX context, so the TIFF is
        // plain 3-channel RGB that every editor treats as a normal photo.
        var output = rgba
        if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 16,
                               bytesPerRow: 0, space: space,
                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                                   | CGBitmapInfo.byteOrder16Little.rawValue) {
            ctx.interpolationQuality = .none
            ctx.draw(rgba, in: CGRect(x: 0, y: 0, width: w, height: h))
            if let rgb = ctx.makeImage() { output = rgb }
        }

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString,
                                                         1, nil) else {
            throw ExportError.writeFailed(name)
        }
        // Metadata first, so the fixed technical values below always win.
        let props = ExportMetadata.merged(metadata, [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFCompression: 1           // none (see above)
            ] as [CFString: Any],
            kCGImagePropertyOrientation: 1
        ])
        CGImageDestinationAddImage(dest, output, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.writeFailed(name) }
    }
}
