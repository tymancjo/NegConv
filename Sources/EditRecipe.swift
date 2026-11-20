import CoreGraphics
import Foundation
import simd

/// RAW decode settings. Keep these FIXED for a whole roll.
///
/// Why they barely matter for the final colour: film-base removal divides every pixel by the
/// sampled base RGB, and the base was decoded with the same gain/WB, so per-channel gains here
/// cancel out (raw·g / base·g = raw / base). What they do control is headroom: too much exposure
/// clips the bright rebate/highlights before inversion, which is unrecoverable.
struct DecodeSettings: Codable, Equatable {
    /// Fixed white balance in Kelvin. Deliberately NOT "as shot", so every frame of a roll
    /// is decoded identically.
    var temperature: Float = 5500
    var tint: Float = 0
    /// Linear gain applied by the RAW decoder, in EV.
    var exposureEV: Float = 0
}

/// Frame geometry. Rotation is applied first, then the horizontal flip, then the crop.
/// Flip and crop are defined in the *displayed* orientation, so the UI behaves intuitively.
struct Geometry: Codable, Equatable {
    /// Clockwise quarter turns of the source image, 0...3.
    var quarterTurns: Int = 0
    /// Mirror left↔right (for frames shot through the base side).
    var flipHorizontal = false
    /// Crop in normalised coordinates of the oriented image, y-up (Core Image convention).
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Fine rotation in degrees, counter-clockwise positive, applied in the displayed orientation
    /// (after the 90° turns and flip) around the frame centre, on the same canvas.
    var straighten: Float = 0

    static let minCropSize: CGFloat = 0.05

    /// Largest centred rectangle with the frame's own aspect that stays inside the frame after
    /// rotating by `degrees` — as a fraction of the frame size. `aspect` = width / height.
    static func validScale(degrees: Float, aspect: CGFloat) -> CGFloat {
        let a = abs(CGFloat(degrees) * .pi / 180)
        let w = aspect, h: CGFloat = 1
        let c = cos(a), s = sin(a)
        return min(w / (w * c + h * s), h / (w * s + h * c))
    }

    /// Set the straighten angle and pull the crop inside the area with real image content,
    /// so no empty corners are exported.
    mutating func setStraighten(_ degrees: Float, aspect: CGFloat) {
        straighten = max(-45, min(45, degrees))
        let k = Self.validScale(degrees: straighten, aspect: aspect)
        let valid = CGRect(x: (1 - k) / 2, y: (1 - k) / 2, width: k, height: k)
        let inside = crop.intersection(valid)
        crop = (inside.isNull || inside.width < Self.minCropSize || inside.height < Self.minCropSize)
            ? valid : inside
    }

    // MARK: Normalised-rect transforms (y-up, unit square)

    /// (u, v) → (v, 1 − u)
    static func rotatedCW(_ r: CGRect) -> CGRect {
        CGRect(x: r.minY, y: 1 - r.maxX, width: r.height, height: r.width)
    }
    /// (u, v) → (1 − v, u)
    static func rotatedCCW(_ r: CGRect) -> CGRect {
        CGRect(x: 1 - r.maxY, y: r.minX, width: r.height, height: r.width)
    }
    static func flippedH(_ r: CGRect) -> CGRect {
        CGRect(x: 1 - r.maxX, y: r.minY, width: r.width, height: r.height)
    }

    /// Source (as decoded) normalised rect → displayed (oriented) normalised rect.
    func orientedRect(fromSource r: CGRect) -> CGRect {
        var o = r
        for _ in 0..<(((quarterTurns % 4) + 4) % 4) { o = Self.rotatedCW(o) }
        if flipHorizontal { o = Self.flippedH(o) }
        return o
    }

    /// Displayed (oriented) normalised rect → source normalised rect.
    func sourceRect(fromOriented r: CGRect) -> CGRect {
        var s = r
        if flipHorizontal { s = Self.flippedH(s) }
        for _ in 0..<(((quarterTurns % 4) + 4) % 4) { s = Self.rotatedCCW(s) }
        return s
    }

    // MARK: Point mapping (framed = what the user sees after straighten + crop)

    /// Rotate a normalised canvas point about the centre by `degrees` (CCW), respecting the
    /// canvas aspect (width / height) so the rotation is rigid in pixel space.
    static func rotate(_ p: CGPoint, degrees: Float, aspect: CGFloat) -> CGPoint {
        guard abs(degrees) > 0.0001 else { return p }
        let a = CGFloat(degrees) * .pi / 180
        let x = (p.x - 0.5) * aspect, y = p.y - 0.5
        let xr = x * cos(a) - y * sin(a), yr = x * sin(a) + y * cos(a)
        return CGPoint(x: xr / aspect + 0.5, y: yr + 0.5)
    }

    /// Framed (cropped, displayed) normalised point → source normalised point.
    /// `aspect` = oriented canvas width / height.
    func sourcePoint(fromFramed p: CGPoint, aspect: CGFloat) -> CGPoint {
        var q = CGPoint(x: crop.minX + p.x * crop.width, y: crop.minY + p.y * crop.height)
        q = Self.rotate(q, degrees: -straighten, aspect: aspect)
        return sourceRect(fromOriented: CGRect(origin: q, size: .zero)).origin
    }

    /// Source normalised point → framed normalised point.
    func framedPoint(fromSource s: CGPoint, aspect: CGFloat) -> CGPoint {
        var q = orientedRect(fromSource: CGRect(origin: s, size: .zero)).origin
        q = Self.rotate(q, degrees: straighten, aspect: aspect)
        return CGPoint(x: (q.x - crop.minX) / crop.width, y: (q.y - crop.minY) / crop.height)
    }

    // MARK: Edits

    /// Rotate what the user sees by 90° clockwise. With a flip active, a clockwise turn of the
    /// displayed image is a counter-clockwise turn of the source (F·Rcw = Rccw·F).
    mutating func rotateClockwise() {
        quarterTurns = (quarterTurns + (flipHorizontal ? 3 : 1)) % 4
        crop = Self.rotatedCW(crop)
    }

    mutating func rotateCounterClockwise() {
        quarterTurns = (quarterTurns + (flipHorizontal ? 1 : 3)) % 4
        crop = Self.rotatedCCW(crop)
    }

    mutating func toggleFlip() {
        flipHorizontal.toggle()
        crop = Self.flippedH(crop)
        straighten = -straighten          // a mirrored tilt tilts the other way
    }
}

/// Film-base removal and density inversion parameters.
struct Inversion: Codable, Equatable {
    /// Where the film base was sampled, normalised in SOURCE (unrotated) coordinates, y-up,
    /// so it survives later rotation/flip.
    var baseRect: CGRect?
    /// Linear RGB of the film base under the current decode settings.
    var base: SIMD3<Float>?
    /// Density (above base) that maps to black, per channel.
    var dBlack = SIMD3<Float>(repeating: 0.1)
    /// Density (above base) that maps to white, per channel.
    var dWhite = SIMD3<Float>(repeating: 1.2)
    /// Output dynamic range in log10 units (2.0 ≈ 6.6 stops). Higher = flatter, lower = punchier.
    var range: Float = 2.0
    /// When true, dBlack/dWhite are re-measured whenever base, crop or decode change.
    var autoPoints = true
    /// Where automatic points come from (ignored while `autoPoints` is false = manual).
    /// New frames default to roll colour; sidecars written before roll analysis load as `.frame`.
    var pointSource: PointSource = .rollColor

    var isReady: Bool { base != nil }
}

/// Source of the automatic black/white density points.
enum PointSource: String, Codable, CaseIterable, Identifiable {
    /// This frame's own 0.3 % / 99.7 % percentiles (content decides the colour balance).
    case frame
    /// The roll's pooled percentiles: identical inversion for every frame.
    case roll
    /// Colour balance from the roll, density level (mean over channels) from the frame.
    case rollColor

    var id: Self { self }
    var label: String {
        switch self {
        case .frame: "Frame"
        case .roll: "Roll"
        case .rollColor: "Roll colour"
        }
    }
}

/// Levels for one channel (or master), on γ 2.2-encoded values.
struct ChannelLevels: Codable, Equatable {
    var black: Float = 0
    var white: Float = 1
    /// Midtone: > 1 brightens, < 1 darkens (Photoshop convention).
    var gamma: Float = 1
}

struct Levels: Codable, Equatable {
    var master = ChannelLevels()
    var red = ChannelLevels()
    var green = ChannelLevels()
    var blue = ChannelLevels()
}

/// Positive adjustments after inversion.
struct Tone: Codable, Equatable {
    /// Linear exposure, in EV.
    var exposureEV: Float = 0
    /// White balance in log2 gain units: red × 2^(T+M), blue × 2^(−T+M), green × 1.
    /// Temperature T > 0 is warmer; tint M > 0 is more magenta.
    var temperature: Float = 0
    var tint: Float = 0
    var levels = Levels()

    /// Linear per-channel gain = exposure × white balance.
    var gain: SIMD3<Float> {
        let e = powf(2, exposureEV)
        return SIMD3(e * powf(2, temperature + tint), e, e * powf(2, -temperature + tint))
    }

    /// White balance that makes `sample` (linear RGB) neutral.
    static func whiteBalance(neutralizing sample: SIMD3<Float>) -> (temperature: Float, tint: Float)? {
        guard sample.min() > 0 else { return nil }
        let a = log2f(sample.y / sample.x)      // wanted log2 red gain
        let b = log2f(sample.y / sample.z)      // wanted log2 blue gain
        guard a.isFinite, b.isFinite else { return nil }
        return ((a - b) / 2, (a + b) / 2)
    }
}

/// Per-band colour adjustments (HSL mixer). Arrays are indexed by `ColorMix.Band`.
struct ColorMix: Codable, Equatable {
    enum Band: Int, CaseIterable, Identifiable {
        case red, orange, yellow, green, aqua, blue, purple, magenta
        var id: Int { rawValue }
        /// Band centre hue in degrees (must match the kernel).
        var centre: Double { [0, 30, 60, 120, 180, 225, 270, 315][rawValue] }
        var name: String { ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"][rawValue] }

        /// Nearest band to a hue (degrees).
        static func nearest(to hue: Double) -> Band {
            allCases.min { a, b in
                func d(_ c: Double) -> Double { let x = abs(hue - c).truncatingRemainder(dividingBy: 360); return min(x, 360 - x) }
                return d(a.centre) < d(b.centre)
            }!
        }
    }

    /// Hue shift in degrees (±30).
    var hue = [Float](repeating: 0, count: 8)
    /// Saturation change, −1…1 (−1 = grey, +1 = double).
    var saturation = [Float](repeating: 0, count: 8)
    /// Luminance change, −1…1 (±50 % brightness).
    var luminance = [Float](repeating: 0, count: 8)

    var isIdentity: Bool { self == ColorMix() }

    func isModified(_ b: Band) -> Bool {
        hue[b.rawValue] != 0 || saturation[b.rawValue] != 0 || luminance[b.rawValue] != 0
    }

    mutating func reset(_ b: Band) {
        hue[b.rawValue] = 0; saturation[b.rawValue] = 0; luminance[b.rawValue] = 0
    }

    /// Guard against malformed sidecars.
    var sanitized: ColorMix {
        func fix(_ a: [Float]) -> [Float] { a.count == 8 ? a : Array((a + Array(repeating: 0, count: 8)).prefix(8)) }
        return ColorMix(hue: fix(hue), saturation: fix(saturation), luminance: fix(luminance))
    }
}

/// Print / paper stage: turns the scene-linear positive into a print-like tone, applied after
/// exposure and white balance, before levels.
///
/// Model, in natural-log units (Y = ln reflectance, X = ln(linear / 0.18)):
///   straight line   Y = grade · X + ln 0.18          (mid-grey stays at 18 %; grade = log-log contrast)
///   shoulder        Y = −softmax(−Y, 0; shoulder)    (highlights roll into paper white instead of clipping)
///   toe             Y =  softmax(Y, Yb; toe)         (shadows roll into paper black, Yb = −blackDensity · ln 10)
/// where softmax(a, b; s) = b + s · ln(1 + e^((a − b)/s)). Same curve on R, G and B, so neutrals stay
/// neutral; saturated highlights desaturate a little as they roll off, like a real print.
/// Brightness is set with Exposure (a gain before the curve is the same as print exposure).
struct Paper: Codable, Equatable {
    var enabled = false
    /// Contrast (slope through mid-grey in log-log). 1 = unchanged midtone contrast.
    var grade: Float = 1.2
    /// Paper black density above paper white: ≈ 2.05 glossy, 1.85 satin/pearl, 1.6 matte (lifted blacks).
    var blackDensity: Float = 2.05
    /// Highlight roll-off softness (ln units). Larger = gentler shoulder, dimmer near-whites.
    var shoulder: Float = 0.25
    /// Shadow roll-off softness (ln units). Larger = longer toe, more open shadows near black.
    var toe: Float = 0.5

    static let soft = Paper(enabled: true, grade: 1.0)
    static let normal = Paper(enabled: true, grade: 1.2)
    static let hard = Paper(enabled: true, grade: 1.5)

    /// ln of paper-black reflectance relative to paper white.
    var lnBlack: Float { -blackDensity * logf(10) }

    /// Same maths as the kernel, for the curve thumbnail and checks. Linear in, linear out.
    func map(_ linear: Float) -> Float {
        func softplus(_ z: Float) -> Float { max(z, 0) + log1pf(expf(-abs(z))) }
        let x = logf(max(linear, 1e-6) / 0.18)
        let y = grade * x + logf(0.18)
        let h = max(shoulder, 0.01), t = max(toe, 0.01)
        let y1 = -h * softplus(-y / h)
        let yo = lnBlack + t * softplus((y1 - lnBlack) / t)
        return expf(yo)
    }
}

/// Global colour intensity, applied in OkLab (perceptual: chroma changes, lightness stays).
struct Presence: Codable, Equatable {
    /// −1…+1: chroma × (1 + saturation). −1 = black & white with unchanged lightness.
    var saturation: Float = 0
    /// −1…+1: like saturation, but weighted towards low-chroma colours and away from skin tones.
    var vibrance: Float = 0

    var isIdentity: Bool { saturation == 0 && vibrance == 0 }
}

/// Luminance-only unsharp mask: the last step of the positive, after presence.
struct Sharpen: Codable, Equatable {
    /// Strength, 0…3 (0–300 %). 0 = off.
    var amount: Float = 0
    /// Gaussian σ in FULL-RESOLUTION scan pixels. The preview scales it by its decode scale, so
    /// the effect is only exact at 1:1 (loupe / actual size) and in the export.
    var radius: Float = 0.8
    /// Luma differences below this many 8-bit levels are not sharpened (soft knee), so grain
    /// and smooth areas (sky, skin) stay clean while real edges get crisper.
    var threshold: Float = 3

    var isIdentity: Bool { amount <= 0 }

    static let radiusRange: ClosedRange<Float> = 0.3...3
}

/// A dust/scratch repair: a feathered disc at `center` is replaced by the disc at `source`.
/// Coordinates are normalised in the SOURCE (as-decoded) image, y-up, so spots stay glued to
/// the film when the frame is later rotated, flipped, straightened or re-cropped.
struct Spot: Codable, Equatable, Identifiable {
    var id = UUID()
    var center: CGPoint
    var source: CGPoint
    /// Radius as a fraction of the source image's long edge.
    var radius: CGFloat
    /// Brush stroke (hairs, scratches): polyline in SOURCE normalised coordinates, first point ==
    /// `center`. The whole stroke is cloned from the same offset (`source − center`).
    /// nil = a single disc (older sidecars decode as discs).
    var path: [CGPoint]? = nil

    var isStroke: Bool { (path?.count ?? 0) >= 2 }
    /// Where the spot/stroke ends (for ⇧-click straight lines).
    var end: CGPoint { path?.last ?? center }

    /// Move the spot so it starts at `c`, keeping the stroke shape and the given source offset.
    mutating func move(to c: CGPoint, sourceOffset o: CGVector) {
        let dx = c.x - center.x, dy = c.y - center.y
        path = path?.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        center = c
        source = CGPoint(x: c.x + o.dx, y: c.y + o.dy)
    }
}

/// Per-image, non-destructive edit state. Saved as a JSON sidecar
/// (`<name>.NEF.negconv.json`) from milestone 6.
struct EditRecipe: Codable, Equatable {
    var version = 2
    var geometry = Geometry()
    var inversion = Inversion()
    var tone = Tone()
    var paper = Paper()
    var curves = Curves()
    var color = ColorMix()
    var presence = Presence()
    var sharpen = Sharpen()
    var spots: [Spot] = []
    /// Per-frame shooting data (analog), written into exports. Not part of the rendering.
    var meta = FrameMetadata()
}

// MARK: - Tolerant decoding
// Missing keys fall back to defaults, so sidecars written by older versions keep loading
// as new fields are added. (Encoding stays synthesized.)

private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

extension DecodeSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DecodeSettings()
        self.init(temperature: c.value(.temperature, d.temperature),
                  tint: c.value(.tint, d.tint),
                  exposureEV: c.value(.exposureEV, d.exposureEV))
    }
}

extension Geometry {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Geometry()
        self.init(quarterTurns: c.value(.quarterTurns, d.quarterTurns),
                  flipHorizontal: c.value(.flipHorizontal, d.flipHorizontal),
                  crop: c.value(.crop, d.crop),
                  straighten: c.value(.straighten, d.straighten))
    }
}

extension Inversion {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Inversion()
        self.init(baseRect: c.value(.baseRect, d.baseRect),
                  base: c.value(.base, d.base),
                  dBlack: c.value(.dBlack, d.dBlack),
                  dWhite: c.value(.dWhite, d.dWhite),
                  range: c.value(.range, d.range),
                  autoPoints: c.value(.autoPoints, d.autoPoints),
                  pointSource: c.value(.pointSource, PointSource.frame))   // pre-roll sidecars
    }
}

extension ChannelLevels {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ChannelLevels()
        self.init(black: c.value(.black, d.black), white: c.value(.white, d.white),
                  gamma: c.value(.gamma, d.gamma))
    }
}

extension Levels {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Levels()
        self.init(master: c.value(.master, d.master), red: c.value(.red, d.red),
                  green: c.value(.green, d.green), blue: c.value(.blue, d.blue))
    }
}

extension Tone {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Tone()
        self.init(exposureEV: c.value(.exposureEV, d.exposureEV),
                  temperature: c.value(.temperature, d.temperature),
                  tint: c.value(.tint, d.tint),
                  levels: c.value(.levels, d.levels))
    }
}

extension EditRecipe {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EditRecipe()
        self.init(version: c.value(.version, d.version),
                  geometry: c.value(.geometry, d.geometry),
                  inversion: c.value(.inversion, d.inversion),
                  tone: c.value(.tone, d.tone),
                  paper: c.value(.paper, d.paper),
                  curves: c.value(.curves, d.curves),
                  color: c.value(.color, d.color).sanitized,
                  presence: c.value(.presence, d.presence),
                  sharpen: c.value(.sharpen, d.sharpen),
                  spots: c.value(.spots, d.spots),
                  meta: c.value(.meta, d.meta))
    }
}

extension ColorMix {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ColorMix()
        self.init(hue: c.value(.hue, d.hue),
                  saturation: c.value(.saturation, d.saturation),
                  luminance: c.value(.luminance, d.luminance))
        self = self.sanitized
    }
}

extension Presence {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Presence()
        self.init(saturation: c.value(.saturation, d.saturation),
                  vibrance: c.value(.vibrance, d.vibrance))
    }
}

extension Sharpen {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Sharpen()
        self.init(amount: c.value(.amount, d.amount),
                  radius: c.value(.radius, d.radius),
                  threshold: c.value(.threshold, d.threshold))
    }
}

extension Paper {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Paper()
        self.init(enabled: c.value(.enabled, d.enabled),
                  grade: c.value(.grade, d.grade),
                  blackDensity: c.value(.blackDensity, d.blackDensity),
                  shoulder: c.value(.shoulder, d.shoulder),
                  toe: c.value(.toe, d.toe))
    }
}

extension EditRecipe {
    /// "Before" for the before/after view: the plain inversion. Keeps geometry, spots, film base
    /// and density points; resets exposure/WB, paper, levels, curves, colour mixer, presence
    /// and sharpening.
    /// Only what affects pixels — for render/histogram cache keys, so typing shooting data
    /// doesn't re-render anything.
    var rendering: EditRecipe {
        var r = self
        r.meta = FrameMetadata()
        return r
    }

    var before: EditRecipe {
        var r = self
        r.tone = Tone()
        r.paper = Paper()
        r.curves = Curves()
        r.color = ColorMix()
        r.presence = Presence()
        r.sharpen = Sharpen()
        return r
    }
}
