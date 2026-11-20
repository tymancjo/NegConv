import CoreImage
import Foundation
import simd

/// The processing pipeline as pure functions of (image, recipe). The same code path is used
/// for the preview (scaled decode) and for export (full-res decode); geometry is stored in
/// normalised coordinates so it is resolution-independent.
enum Pipeline {

    // MARK: Geometry

    /// Exact 90° rotations and mirror via integer affine matrices (no resampling), then the
    /// result is moved back to origin (0, 0).
    static func oriented(_ image: CIImage, _ g: Geometry) -> CIImage {
        var t: CGAffineTransform
        switch ((g.quarterTurns % 4) + 4) % 4 {
        case 1: t = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)   // (x,y) → (y, −x)  clockwise
        case 2: t = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)  // 180°
        case 3: t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)   // (x,y) → (−y, x)  counter-clockwise
        default: t = .identity
        }
        if g.flipHorizontal {
            t = t.concatenating(CGAffineTransform(scaleX: -1, y: 1))
        }
        guard !t.isIdentity else { return image }
        let out = image.transformed(by: t)
        return out.transformed(by: CGAffineTransform(translationX: -out.extent.minX,
                                                     y: -out.extent.minY))
    }

    /// Fine rotation about the centre, kept on the same canvas (corners become transparent;
    /// `Geometry.setStraighten` keeps the crop clear of them).
    static func straightened(_ image: CIImage, _ g: Geometry) -> CIImage {
        guard abs(g.straighten) > 0.001 else { return image }
        let e = image.extent
        let t = CGAffineTransform(translationX: -e.midX, y: -e.midY)
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(g.straighten) * .pi / 180))
            .concatenating(CGAffineTransform(translationX: e.midX, y: e.midY))
        return image.transformed(by: t).cropped(to: e)
    }

    /// Full geometry: 90° turns + flip → straighten → crop.
    static func framed(_ image: CIImage, _ g: Geometry) -> CIImage {
        cropped(straightened(oriented(image, g), g), g)
    }

    /// Spot repair, then full geometry. Spots live in source coordinates, so they are applied
    /// first, on the linear negative.
    static func framed(_ image: CIImage, _ r: EditRecipe) -> CIImage {
        framed(spotted(image, r.spots), r.geometry)
    }

    // MARK: Spots

    /// Clone each spot's source onto it with a feathered edge (55 % solid core), in order, so
    /// later spots can sample already-repaired areas. A disc spot uses one feathered disc; a brush
    /// stroke uses a chain of them along its path, merged with max (a soft round brush).
    static func spotted(_ image: CIImage, _ spots: [Spot]) -> CIImage {
        guard !spots.isEmpty else { return image }
        let e = image.extent
        let longEdge = max(e.width, e.height)
        func px(_ p: CGPoint) -> CGPoint { CGPoint(x: e.minX + p.x * e.width, y: e.minY + p.y * e.height) }
        var out = image
        for s in spots {
            let d = px(s.center), src = px(s.source)
            let r = max(1, s.radius * longEdge)
            let centres = s.isStroke ? Polyline.resample(s.path!.map(px), step: r * 0.35, maxCount: 160) : [d]
            guard let mask = discMask(centres, radius: r) else { continue }
            let patch = out.transformed(by: CGAffineTransform(translationX: d.x - src.x, y: d.y - src.y))
            out = patch.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: out,
                kCIInputMaskImageKey: mask
            ]).cropped(to: e)
        }
        return out
    }

    /// Union (max) of feathered discs: alpha 1 inside 55 % of the radius, falling to 0 at r.
    static func discMask(_ centres: [CGPoint], radius r: CGFloat) -> CIImage? {
        var mask: CIImage?
        for c in centres {
            let box = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
            guard let g = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: c.x, y: c.y),
                "inputRadius0": r * 0.55,
                "inputRadius1": r,
                "inputColor0": CIColor.white,
                "inputColor1": CIColor.clear
            ])?.outputImage?.cropped(to: box) else { continue }
            mask = mask.map { g.applyingFilter("CIMaximumCompositing",
                                               parameters: [kCIInputBackgroundImageKey: $0]) } ?? g
        }
        return mask
    }

    /// Crop rectangle in pixels of an oriented image with the given extent (whole pixels).
    static func cropRect(_ g: Geometry, in extent: CGRect) -> CGRect {
        let c = g.crop.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let r = CGRect(x: extent.minX + c.minX * extent.width,
                       y: extent.minY + c.minY * extent.height,
                       width: c.width * extent.width,
                       height: c.height * extent.height)
        return r.integral.intersection(extent)
    }

    static func cropped(_ image: CIImage, _ g: Geometry) -> CIImage {
        let r = cropRect(g, in: image.extent)
        return image.cropped(to: r)
            .transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
    }

    // MARK: Inversion

    /// Film-base division + density inversion. Returns the input unchanged until a base exists.
    static func inverted(_ image: CIImage, _ inv: Inversion) -> CIImage {
        guard let base = inv.base else { return image }
        let span = simd_max(inv.dWhite - inv.dBlack, SIMD3<Float>(repeating: 0.05))
        let slope = SIMD3<Float>(repeating: inv.range) / span
        let lbp = powf(10, -inv.range)
        return Kernels.invert.apply(extent: image.extent, arguments: [
            image,
            CIVector(x: CGFloat(base.x), y: CGFloat(base.y), z: CGFloat(base.z)),
            CIVector(x: CGFloat(inv.dWhite.x), y: CGFloat(inv.dWhite.y), z: CGFloat(inv.dWhite.z)),
            CIVector(x: CGFloat(slope.x), y: CGFloat(slope.y), z: CGFloat(slope.z)),
            NSNumber(value: lbp)
        ]) ?? image
    }

    // MARK: Tone

    /// Exposure/WB gain → optional paper curve → levels, in one kernel.
    static func toned(_ image: CIImage, _ t: Tone, _ p: Paper = Paper()) -> CIImage {
        guard t != Tone() || p.enabled else { return image }
        let l = t.levels
        func v3(_ a: Float, _ b: Float, _ c: Float) -> CIVector {
            CIVector(x: CGFloat(a), y: CGFloat(b), z: CGFloat(c))
        }
        let g = t.gain
        return Kernels.tone.apply(extent: image.extent, arguments: [
            image,
            v3(g.x, g.y, g.z),
            v3(l.red.black, l.green.black, l.blue.black),
            v3(l.red.white, l.green.white, l.blue.white),
            v3(max(l.red.gamma, 0.01), max(l.green.gamma, 0.01), max(l.blue.gamma, 0.01)),
            v3(l.master.black, l.master.white, max(l.master.gamma, 0.01)),
            CIVector(x: p.enabled ? 1 : 0, y: CGFloat(max(p.grade, 0.05)), z: CGFloat(p.lnBlack), w: 0),
            CIVector(x: CGFloat(max(p.shoulder, 0.01)), y: CGFloat(max(p.toe, 0.01)))
        ]) ?? image
    }

    // MARK: Curves

    /// Master ∘ channel tone curves on γ 2.2 values, after levels. Skipped when identity.
    static func curved(_ image: CIImage, _ c: Curves) -> CIImage {
        guard !c.isIdentity else { return image }
        let lut = CurveLUT.image(c)
        let lutExtent = lut.extent
        return Kernels.curves.apply(
            extent: image.extent,
            roiCallback: { index, rect in index == 0 ? rect : lutExtent },
            arguments: [image, lut, Float(CurveLUT.size)]
        ) ?? image
    }

    // MARK: Colour mixer

    static func colorMixed(_ image: CIImage, _ m: ColorMix) -> CIImage {
        guard !m.isIdentity else { return image }
        let m = m.sanitized
        func v4(_ a: [Float], _ o: Int) -> CIVector {
            CIVector(x: CGFloat(a[o]), y: CGFloat(a[o + 1]), z: CGFloat(a[o + 2]), w: CGFloat(a[o + 3]))
        }
        return Kernels.colorMix.apply(extent: image.extent, arguments: [
            image,
            v4(m.hue, 0), v4(m.hue, 4),
            v4(m.saturation, 0), v4(m.saturation, 4),
            v4(m.luminance, 0), v4(m.luminance, 4)
        ]) ?? image
    }

    // MARK: Presence

    /// Global saturation / vibrance (OkLab). Skipped when neutral.
    static func presenced(_ image: CIImage, _ p: Presence) -> CIImage {
        guard !p.isIdentity else { return image }
        return Kernels.presence.apply(extent: image.extent, arguments: [
            image, NSNumber(value: p.saturation), NSNumber(value: p.vibrance)
        ]) ?? image
    }

    // MARK: Sharpen

    /// Luminance-only unsharp mask on γ 2.2 values (see `negSharpen`).
    /// `detailScale` = pixels of `image` per full-resolution scan pixel (1 for the full-res loupe
    /// and export, the decode scale for the preview); the radius is scaled by it so the preview
    /// approximates what the export will do. ≤ 0 skips sharpening.
    static func sharpened(_ image: CIImage, _ s: Sharpen, detailScale: CGFloat) -> CIImage {
        guard !s.isIdentity, detailScale > 0 else { return image }
        let sigma = CGFloat(s.radius) * detailScale
        guard sigma >= 0.1 else { return image }                 // below this the blur is a no-op
        let e = image.extent
        guard let luma = Kernels.sharpLuma.apply(extent: e, arguments: [image]) else { return image }
        // Clamp before blurring so the frame edges aren't darkened by transparent pixels.
        let blurred = luma.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(sigma))
            .cropped(to: e)
        return Kernels.sharpen.apply(extent: e, arguments: [
            image, blurred, NSNumber(value: s.amount), NSNumber(value: s.threshold / 255)
        ]) ?? image
    }

    /// Everything after geometry: inversion → tone (gain, paper, levels) → curves → colour mixer
    /// → presence → sharpen. The mixer runs before presence so its per-colour luminance still sees
    /// colour when Saturation −100 turns the image black & white (B&W channel mixing).
    /// Sharpening is last, on the finished tones, so contrast changes don't re-shape its halos.
    static func positive(_ framed: CIImage, _ r: EditRecipe, detailScale: CGFloat) -> CIImage {
        let toned = presenced(colorMixed(curved(toned(inverted(framed, r.inversion), r.tone, r.paper),
                                                r.curves), r.color), r.presence)
            .cropped(to: framed.extent)     // nothing outside the frame, ever
        return sharpened(toned, r.sharpen, detailScale: detailScale)
    }

    // MARK: Clipping overlay

    /// Paints pixels that will clip in the export: red = highlights, blue = shadows, magenta =
    /// both. Tested in the export's own primaries (Adobe RGB for TIFF, sRGB for JPEG), so
    /// saturated colours outside that gamut show too. Limits are the 8-bit-equivalent black /
    /// white of the output encoding (what prints or displays as pure black / white), even for
    /// 16-bit TIFF — a value of 0.4/65535 is still black on paper.
    static func clipWarning(_ image: CIImage, format: ExportSettings.Format) -> CIImage {
        let rows: [CIVector]
        let lim: CIVector
        switch format {
        case .tiff16:
            // Linear sRGB → linear Adobe RGB (1998), both D65. Encoding γ = 563/256.
            rows = [CIVector(x: 0.7152, y: 0.2848, z: 0),
                    CIVector(x: 0, y: 1, z: 0),
                    CIVector(x: 0, y: 0.0412, z: 0.9588)]
            let g = 563.0 / 256.0
            lim = CIVector(x: pow(0.5 / 255, g), y: pow(254.5 / 255, g))
        case .jpeg:
            // Same primaries; sRGB piecewise transfer curve.
            rows = [CIVector(x: 1, y: 0, z: 0), CIVector(x: 0, y: 1, z: 0), CIVector(x: 0, y: 0, z: 1)]
            lim = CIVector(x: (0.5 / 255) / 12.92, y: pow((254.5 / 255 + 0.055) / 1.055, 2.4))
        }
        return Kernels.clip.apply(extent: image.extent,
                                  arguments: [image, rows[0], rows[1], rows[2], lim]) ?? image
    }

    /// Output size in pixels of a full-resolution render.
    static func outputSize(nativeSize: CGSize, _ g: Geometry) -> CGSize {
        let swapped = g.quarterTurns % 2 == 1
        let w = swapped ? nativeSize.height : nativeSize.width
        let h = swapped ? nativeSize.width : nativeSize.height
        return cropRect(g, in: CGRect(x: 0, y: 0, width: w, height: h)).size
    }
}

/// Polyline helpers (any consistent 2-D coordinates, e.g. pixels).
enum Polyline {
    /// Evenly spaced points along the polyline, both ends included, at most `maxCount`.
    static func resample(_ pts: [CGPoint], step: CGFloat, maxCount: Int) -> [CGPoint] {
        guard pts.count > 1 else { return pts }
        var segs: [CGFloat] = []
        for i in 1..<pts.count { segs.append(hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)) }
        let total = segs.reduce(0, +)
        guard total > 0 else { return [pts[0]] }
        let n = min(max(maxCount - 1, 1), max(1, Int((total / max(step, 0.5)).rounded(.up))))
        let st = total / CGFloat(n)
        var out = [pts[0]]
        var seg = 0, segStart: CGFloat = 0
        for k in 1...n {
            let target = CGFloat(k) * st
            while seg < segs.count - 1 && segStart + segs[seg] < target { segStart += segs[seg]; seg += 1 }
            let t = segs[seg] > 0 ? min(max((target - segStart) / segs[seg], 0), 1) : 0
            let a = pts[seg], b = pts[seg + 1]
            out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        return out
    }

    static func length(_ pts: [CGPoint]) -> CGFloat {
        guard pts.count > 1 else { return 0 }
        return (1..<pts.count).reduce(0) { $0 + hypot(pts[$1].x - pts[$1 - 1].x, pts[$1].y - pts[$1 - 1].y) }
    }

    /// Shortest distance from `p` to the polyline.
    static func distance(_ p: CGPoint, to pts: [CGPoint]) -> CGFloat {
        guard let first = pts.first else { return .infinity }
        guard pts.count > 1 else { return hypot(p.x - first.x, p.y - first.y) }
        var best = CGFloat.infinity
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            let vx = b.x - a.x, vy = b.y - a.y
            let l2 = vx * vx + vy * vy
            let t = l2 > 0 ? min(max(((p.x - a.x) * vx + (p.y - a.y) * vy) / l2, 0), 1) : 0
            best = min(best, hypot(p.x - (a.x + t * vx), p.y - (a.y + t * vy)))
        }
        return best
    }
}

/// Aspect-fit layout shared by the Metal preview (pixels) and SwiftUI overlays (points),
/// so overlays line up exactly with the rendered image.
enum FitLayout {
    static let padding: CGFloat = 20

    static func fitRect(content: CGSize, in container: CGSize, padding: CGFloat = padding) -> CGRect {
        let availW = max(container.width - 2 * padding, 1)
        let availH = max(container.height - 2 * padding, 1)
        guard content.width > 0, content.height > 0 else { return .zero }
        let s = min(availW / content.width, availH / content.height)
        let w = content.width * s, h = content.height * s
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    /// Normalised y-up rect → SwiftUI (y-down) rect inside `fit`.
    static func viewRect(normalized r: CGRect, fit: CGRect) -> CGRect {
        CGRect(x: fit.minX + r.minX * fit.width,
               y: fit.minY + (1 - r.maxY) * fit.height,
               width: r.width * fit.width,
               height: r.height * fit.height)
    }

    /// SwiftUI (y-down) rect → normalised y-up rect, clamped to the unit square.
    static func normalizedRect(view r: CGRect, fit: CGRect) -> CGRect {
        guard fit.width > 0, fit.height > 0 else { return .zero }
        let n = CGRect(x: (r.minX - fit.minX) / fit.width,
                       y: 1 - (r.maxY - fit.minY) / fit.height,
                       width: r.width / fit.width,
                       height: r.height / fit.height)
        return n.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}

/// Compiled Core Image kernels from NegKernels.metal (built into default.metallib).
enum Kernels {
    static let invert: CIColorKernel = load("negInvert")
    static let tone: CIColorKernel = load("negTone")
    static let colorMix: CIColorKernel = load("negColorMix")
    static let presence: CIColorKernel = load("negPresence")
    static let curves: CIKernel = loadGeneral("negCurves")
    static let clip: CIColorKernel = load("negClip")
    static let sharpLuma: CIColorKernel = load("negSharpLuma")
    static let sharpen: CIColorKernel = load("negSharpen")

    private static func loadGeneral(_ name: String) -> CIKernel {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else {
            fatalError("default.metallib missing — is NegKernels.metal in the target?")
        }
        do {
            return try CIKernel(functionName: name, fromMetalLibraryData: data)
        } catch {
            fatalError("Can't load kernel \(name): \(error)")
        }
    }

    private static func load(_ name: String) -> CIColorKernel {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else {
            fatalError("default.metallib missing — is NegKernels.metal in the target?")
        }
        do {
            return try CIColorKernel(functionName: name, fromMetalLibraryData: data)
        } catch {
            fatalError("Can't load kernel \(name): \(error)")
        }
    }
}
