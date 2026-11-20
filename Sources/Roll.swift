import CoreGraphics
import Foundation
import simd

// MARK: - Roll file

/// The film base for the whole roll, sampled once on one frame. Light source, film stock and
/// decode settings are fixed per roll, so the base is too. Frames without a base sample of
/// their own use it.
struct RollBase: Codable, Equatable {
    /// File name of the frame it was sampled on.
    var frame: String
    /// Sample area, normalised in that frame's SOURCE coordinates (y-up).
    var rect: CGRect
    /// Linear RGB of the base, valid for `decode` only (re-measured when the decode changes).
    var rgb: SIMD3<Float>
    var decode: DecodeSettings
}

/// Pooled density statistics of the roll (0.3 % / 99.7 % of all analysed frames together).
struct RollAnalysis: Codable, Equatable {
    var dBlack: SIMD3<Float>
    var dWhite: SIMD3<Float>
    /// Frame file name → fingerprint of the inputs it was measured with (staleness check).
    var frames: [String: String]
    var date: Date
}

/// `<roll folder>/NegConv Roll.json`.
struct RollFile: Codable {
    var app = "NegConv"
    var version = 1
    var decode: DecodeSettings
    var base: RollBase?
    var excluded: [String] = []
    var analysis: RollAnalysis?
    /// File name of the reference frame (C5), if one is pinned.
    var reference: String?
    /// Analog shooting data for the whole roll (camera, film, ISO, …).
    var metadata: RollMetadata?

    init(decode: DecodeSettings, base: RollBase?, excluded: [String], analysis: RollAnalysis?,
         reference: String?, metadata: RollMetadata?) {
        self.decode = decode
        self.base = base
        self.excluded = excluded
        self.analysis = analysis
        self.reference = reference
        self.metadata = metadata
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        decode = (try? c.decodeIfPresent(DecodeSettings.self, forKey: .decode)) ?? DecodeSettings()
        base = try? c.decodeIfPresent(RollBase.self, forKey: .base)
        excluded = (try? c.decodeIfPresent([String].self, forKey: .excluded)) ?? []
        analysis = try? c.decodeIfPresent(RollAnalysis.self, forKey: .analysis)
        reference = try? c.decodeIfPresent(String.self, forKey: .reference)
        metadata = try? c.decodeIfPresent(RollMetadata.self, forKey: .metadata)
    }
}

enum RollStore {
    static func url(for folder: URL) -> URL {
        folder.appendingPathComponent("NegConv Roll.json")
    }

    static func load(folder: URL) -> RollFile? {
        guard let data = try? Data(contentsOf: url(for: folder)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(RollFile.self, from: data)
    }

    static func save(_ file: RollFile, folder: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(file).write(to: url(for: folder), options: .atomic)
    }
}

// MARK: - Density histograms

/// Per-channel density histogram, each channel normalised to sum 1.
struct DensityHistogram {
    static let bins = 2048
    static let dMin: Float = -0.25
    static let dMax: Float = 3.75          // ≈ 0.002 D per bin

    var counts: [[Float]] = Array(repeating: Array(repeating: 0, count: bins), count: 3)

    /// Mean of several histograms: every frame weighs the same, whatever its crop size.
    static func pooled(_ hs: [DensityHistogram]) -> DensityHistogram? {
        guard !hs.isEmpty else { return nil }
        var out = DensityHistogram()
        let k = 1 / Float(hs.count)
        for h in hs {
            for c in 0..<3 {
                for b in 0..<bins { out.counts[c][b] += h.counts[c][b] * k }
            }
        }
        return out
    }

    /// Density at cumulative `fraction`, linearly interpolated inside the bin.
    func percentile(_ fraction: Float, channel c: Int) -> Float {
        let width = (Self.dMax - Self.dMin) / Float(Self.bins)
        var cum: Float = 0
        for b in 0..<Self.bins {
            let v = counts[c][b]
            if v > 0, cum + v >= fraction {
                let t = (fraction - cum) / v
                return Self.dMin + (Float(b) + t) * width
            }
            cum += v
        }
        return Self.dMax
    }

    /// (dBlack, dWhite) with the same 0.3 % / 99.7 % rule and flat-frame guard as
    /// `Analyzer.densityPoints`.
    func points(low: Float = 0.003, high: Float = 0.997) -> (black: SIMD3<Float>, white: SIMD3<Float>) {
        var black = SIMD3<Float>(repeating: 0), white = SIMD3<Float>(repeating: 1)
        for c in 0..<3 {
            black[c] = percentile(low, channel: c)
            white[c] = max(percentile(high, channel: c), black[c] + 0.05)
        }
        return (black, white)
    }
}

// MARK: - Point resolution

enum PointResolver {
    typealias Points = (black: SIMD3<Float>, white: SIMD3<Float>)

    /// Does `source` need this frame's own percentiles?
    static func needsFramePoints(_ source: PointSource, roll: RollAnalysis?) -> Bool {
        roll == nil || source != .roll
    }

    /// The black/white densities to use. Without a roll analysis every source falls back to
    /// the frame's own points.
    ///
    /// Roll colour: the colour part of each point (per-channel deviation from the mean over
    /// R, G, B) comes from the roll, so every frame gets the same colour balance. The level is
    /// then fitted to this frame so that no channel clips beyond the frame's own percentiles:
    /// white is raised until every channel's white ≥ the frame's, black lowered until every
    /// channel's black ≤ the frame's. A strongly coloured frame (sunset) keeps its colour —
    /// its dominant channel reaches white, the others stay below — instead of clipping.
    /// (An earlier version centred the level on the mean, which clipped the dominant channel.)
    static func resolve(_ source: PointSource, frame: Points?, roll: RollAnalysis?) -> Points? {
        guard let roll else { return frame }
        switch source {
        case .frame:
            return frame
        case .roll:
            return (roll.dBlack, roll.dWhite)
        case .rollColor:
            guard let frame else { return nil }
            func mean(_ v: SIMD3<Float>) -> Float { (v.x + v.y + v.z) / 3 }
            let cBlack = roll.dBlack - SIMD3<Float>(repeating: mean(roll.dBlack))
            let cWhite = roll.dWhite - SIMD3<Float>(repeating: mean(roll.dWhite))
            let black = cBlack + SIMD3<Float>(repeating: (frame.black - cBlack).min())
            var white = cWhite + SIMD3<Float>(repeating: (frame.white - cWhite).max())
            white = simd_max(white, black + 0.05)
            return (black, white)
        }
    }
}

// MARK: - Fingerprints

/// Stable (across launches) short hash of an Encodable value — Swift's `Hasher` is seeded per
/// process, so it can't be stored. FNV-1a 64 over sorted-key JSON.
enum Fingerprint {
    static func of<T: Encodable>(_ value: T) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        guard let data = try? enc.encode(value) else { return "" }
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in data {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return String(h, radix: 16)
    }

    /// Everything a frame's density histogram depends on.
    private struct FrameInputs: Encodable {
        let decode: DecodeSettings
        let geometry: Geometry
        let baseRect: CGRect?
        let rollBase: RollBase?
    }

    static func frame(_ recipe: EditRecipe, decode: DecodeSettings, rollBase: RollBase?) -> String {
        of(FrameInputs(decode: decode, geometry: recipe.geometry,
                       baseRect: recipe.inversion.baseRect,
                       rollBase: recipe.inversion.baseRect == nil ? rollBase : nil))
    }
}
