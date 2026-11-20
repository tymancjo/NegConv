import CoreImage
import Foundation

// MARK: - Model

/// A curve control point on γ 2.2-encoded values, both axes 0…1.
struct CurvePoint: Codable, Equatable {
    var x: Float
    var y: Float
}

/// Tone curves after levels (on the print): one master curve and one per channel.
/// Applied as master(channel(x)) — channel first, then master, like levels.
struct Curves: Codable, Equatable {
    static let identityPoints = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
    static let maxPoints = 16
    /// Points can't sit closer than this in x (keeps the spline well-defined).
    static let minGap: Float = 0.01

    var master = identityPoints
    var red = identityPoints
    var green = identityPoints
    var blue = identityPoints

    /// 0 = master, 1…3 = R, G, B.
    subscript(channel: Int) -> [CurvePoint] {
        get { [master, red, green, blue][channel] }
        set {
            switch channel {
            case 1: red = newValue
            case 2: green = newValue
            case 3: blue = newValue
            default: master = newValue
            }
        }
    }

    static func isIdentity(_ pts: [CurvePoint]) -> Bool {
        guard let f = pts.first, let l = pts.last,
              f.x == 0, f.y == 0, l.x == 1, l.y == 1 else { return false }
        return pts.allSatisfy { abs($0.x - $0.y) < 1e-6 }
    }

    var isIdentity: Bool { (0..<4).allSatisfy { Self.isIdentity(self[$0]) } }

    /// Sorted, clamped to 0…1, at least two points, x gaps ≥ minGap.
    static func sanitized(_ pts: [CurvePoint]) -> [CurvePoint] {
        var p = pts.map { CurvePoint(x: min(max($0.x, 0), 1), y: min(max($0.y, 0), 1)) }
            .sorted { $0.x < $1.x }
        var out: [CurvePoint] = []
        for q in p where out.last.map({ q.x - $0.x >= minGap }) ?? true { out.append(q) }
        p = out
        if p.count < 2 { return identityPoints }
        return Array(p.prefix(maxPoints))
    }
}

extension Curves {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func pts(_ k: CodingKeys) -> [CurvePoint] {
            Curves.sanitized((try? c.decodeIfPresent([CurvePoint].self, forKey: k)) ?? Curves.identityPoints)
        }
        self.init(master: pts(.master), red: pts(.red), green: pts(.green), blue: pts(.blue))
    }
}

// MARK: - Monotone cubic spline

/// Monotone cubic Hermite interpolation (Fritsch–Carlson): passes through every point, never
/// overshoots between them, so a curve can't create tone reversals or ringing. Flat outside
/// the end points (an end point moved inwards acts like a levels black/white point).
struct MonotoneSpline {
    private let xs: [Float], ys: [Float], ms: [Float]

    init(_ points: [CurvePoint]) {
        let p = Curves.sanitized(points)
        xs = p.map(\.x)
        ys = p.map(\.y)
        let n = p.count
        var d = [Float](repeating: 0, count: n - 1)
        for k in 0..<(n - 1) { d[k] = (ys[k + 1] - ys[k]) / (xs[k + 1] - xs[k]) }
        var m = [Float](repeating: 0, count: n)
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        if n > 2 {
            for k in 1..<(n - 1) {
                m[k] = d[k - 1] * d[k] <= 0 ? 0 : (d[k - 1] + d[k]) / 2
            }
        }
        // Limit tangents so each segment stays monotone.
        for k in 0..<(n - 1) {
            if d[k] == 0 {
                m[k] = 0; m[k + 1] = 0
                continue
            }
            let a = m[k] / d[k], b = m[k + 1] / d[k]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                m[k] = t * a * d[k]
                m[k + 1] = t * b * d[k]
            }
        }
        ms = m
    }

    func callAsFunction(_ x: Float) -> Float {
        let n = xs.count
        if x <= xs[0] { return ys[0] }
        if x >= xs[n - 1] { return ys[n - 1] }
        var k = 0
        while k < n - 2 && x > xs[k + 1] { k += 1 }
        let h = xs[k + 1] - xs[k]
        let t = (x - xs[k]) / h
        let t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * ys[k] + (t3 - 2 * t2 + t) * h * ms[k]
            + (-2 * t3 + 3 * t2) * ys[k + 1] + (t3 - t2) * h * ms[k + 1]
    }
}

// MARK: - LUT

/// The curves baked into a 1024 × 1 RGBA float image: entry i holds, per channel,
/// master(channel(i / 1023)). The kernel interpolates linearly between entries and
/// extrapolates beyond 0…1 with the end slopes.
enum CurveLUT {
    static let size = 1024

    /// CPU copy of the baked table (also used to check the GPU path).
    static func table(_ c: Curves) -> [SIMD3<Float>] {
        let m = MonotoneSpline(c.master)
        let ch = [MonotoneSpline(c.red), MonotoneSpline(c.green), MonotoneSpline(c.blue)]
        return (0..<size).map { i in
            let x = Float(i) / Float(size - 1)
            return SIMD3(m(ch[0](x)), m(ch[1](x)), m(ch[2](x)))
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (curves: Curves, image: CIImage)?

    /// LUT image for `c`, cached for the last curves value (rebuilt only when points change).
    static func image(_ c: Curves) -> CIImage {
        lock.lock(); defer { lock.unlock() }
        if let hit = cached, hit.curves == c { return hit.image }
        var data = [Float](repeating: 1, count: size * 4)
        for (i, v) in table(c).enumerated() {
            data[i * 4] = v.x; data[i * 4 + 1] = v.y; data[i * 4 + 2] = v.z
        }
        let bytes = data.withUnsafeBufferPointer { Data(buffer: $0) }
        // No colour space: the table holds plain numbers and must not be colour-managed.
        let img = CIImage(bitmapData: bytes, bytesPerRow: size * 16,
                          size: CGSize(width: size, height: 1), format: .RGBAf, colorSpace: nil)
        cached = (c, img)
        return img
    }
}
