import CoreImage
import Foundation
import ImageIO

enum DecodeMode: Equatable {
    /// What NegConv uses: linear response, no tone curve, no sharpening/NR, fixed WB.
    case neutralLinear
    /// Apple's default rendering of the file. Only for comparing against the neutral decode.
    case appleDefault
}

struct DecodedRaw {
    let id = UUID()
    let url: URL
    /// Linear image in `RenderEngine.workingSpace`, origin at (0, 0), already rendered to
    /// memory, so later pipeline stages don't re-run the RAW decoder on every slider move.
    let image: CIImage
    let nativeSize: CGSize
    let scale: Float
    let camera: String
    let seconds: Double
}

enum RawDecodeError: LocalizedError {
    case unsupported(URL)
    case renderFailed(URL)

    var errorDescription: String? {
        switch self {
        case .unsupported(let url):
            return "macOS can't decode \(url.lastPathComponent). The camera may be too new for this "
                 + "version of macOS (RAW support arrives with system updates), or the file is damaged."
        case .renderFailed(let url): return "Rendering \(url.lastPathComponent) failed."
        }
    }
}

/// Owns the CIRAWFilter for the current file and serialises access to it.
/// Keeping one filter per file avoids re-parsing the RAW file when only settings change.
///
/// Decoding is camera-agnostic: Apple's RAW engine applies each camera's own colour matrix
/// (incl. Fujifilm X-Trans demosaicing), so the linear output feeds the same inversion maths.
actor RawDecoder {
    /// File extensions offered when opening a roll (lowercased). Whether a given camera body
    /// actually decodes depends on the macOS version — see `RawDecodeError.unsupported`.
    static let supportedExtensions: Set<String> = ["nef", "cr2", "cr3", "raf"]

    private var cachedURL: URL?
    private var cachedFilter: CIRAWFilter?
    private var cachedCamera = "—"

    func decode(url: URL,
                settings: DecodeSettings,
                mode: DecodeMode,
                maxLongEdge: CGFloat?) throws -> DecodedRaw {
        let start = Date()

        let filter: CIRAWFilter
        switch mode {
        case .neutralLinear:
            filter = try cachedNeutralFilter(for: url)
            Self.configureNeutral(filter, settings)
        case .appleDefault:
            guard let fresh = CIRAWFilter(imageURL: url) else { throw RawDecodeError.unsupported(url) }
            filter = fresh
            if cachedURL != url { cachedCamera = Self.cameraModel(url) }
        }

        let native = filter.nativeSize
        let longEdge = max(native.width, native.height)
        let scale: Float = {
            guard let maxLongEdge, longEdge > 0 else { return 1 }
            return Float(min(1, maxLongEdge / longEdge))
        }()
        filter.scaleFactor = scale

        guard var image = filter.outputImage else { throw RawDecodeError.renderFailed(url) }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX,
                                                        y: -image.extent.minY))

        // Render once to a half-float bitmap in the working space ("freeze" the decode).
        guard let cg = RenderEngine.previewContext.createCGImage(
            image, from: image.extent,
            format: .RGBAh,
            colorSpace: RenderEngine.workingSpace,
            deferred: false
        ) else { throw RawDecodeError.renderFailed(url) }

        let frozen = CIImage(cgImage: cg, options: [.colorSpace: RenderEngine.workingSpace])

        return DecodedRaw(url: url,
                          image: frozen,
                          nativeSize: native,
                          scale: scale,
                          camera: cachedCamera,
                          seconds: Date().timeIntervalSince(start))
    }

    // MARK: - Private

    private func cachedNeutralFilter(for url: URL) throws -> CIRAWFilter {
        if url == cachedURL, let cachedFilter { return cachedFilter }
        guard let filter = CIRAWFilter(imageURL: url) else { throw RawDecodeError.unsupported(url) }
        cachedURL = url
        cachedFilter = filter
        cachedCamera = Self.cameraModel(url)
        return filter
    }

    /// Full-resolution, NOT frozen linear image from a fresh filter — for export, so it can be
    /// rendered in full float precision and never shares state with the preview decoder.
    static func linearImage(url: URL, settings: DecodeSettings) throws -> CIImage {
        guard let f = CIRAWFilter(imageURL: url) else { throw RawDecodeError.unsupported(url) }
        configureNeutral(f, settings)
        f.scaleFactor = 1
        guard let img = f.outputImage else { throw RawDecodeError.renderFailed(url) }
        return img.transformed(by: CGAffineTransform(translationX: -img.extent.minX,
                                                     y: -img.extent.minY))
    }

    /// Small, frozen linear decode for measurements (roll analysis, roll base). Same neutral
    /// settings as the preview; Core Image's scaled RAW path keeps this fast.
    static func smallLinearImage(url: URL, settings: DecodeSettings, maxLongEdge: CGFloat) throws -> CIImage {
        guard let f = CIRAWFilter(imageURL: url) else { throw RawDecodeError.unsupported(url) }
        configureNeutral(f, settings)
        let n = f.nativeSize
        f.scaleFactor = Float(min(1, maxLongEdge / max(n.width, n.height, 1)))
        guard var img = f.outputImage else { throw RawDecodeError.renderFailed(url) }
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        guard let cg = RenderEngine.previewContext.createCGImage(
            img, from: img.extent, format: .RGBAh,
            colorSpace: RenderEngine.workingSpace, deferred: false
        ) else { throw RawDecodeError.renderFailed(url) }
        return CIImage(cgImage: cg, options: [.colorSpace: RenderEngine.workingSpace])
    }

    /// A linear decode: the output should be proportional to the light that hit the sensor.
    /// That is the precondition for transmittance = raw / base to mean anything physically.
    private static func configureNeutral(_ f: CIRAWFilter, _ s: DecodeSettings) {
        f.boostAmount = 0                 // 0 = linear response, no base tone curve
        f.shadowBias = 0
        f.localToneMapAmount = 0
        f.extendedDynamicRangeAmount = 0
        f.contrastAmount = 0
        f.detailAmount = 0
        f.sharpnessAmount = 0
        f.luminanceNoiseReductionAmount = 0
        f.colorNoiseReductionAmount = 0
        f.moireReductionAmount = 0
        f.isGamutMappingEnabled = false   // don't let Apple compress saturated colours
        f.isLensCorrectionEnabled = false
        f.isDraftModeEnabled = false

        f.neutralTemperature = s.temperature
        f.neutralTint = s.tint
        f.exposure = s.exposureEV
    }

    private static func cameraModel(_ url: URL) -> String {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
              let model = tiff[kCGImagePropertyTIFFModel] as? String
        else { return "—" }
        return model
    }
}
