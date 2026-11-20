import CoreImage
import simd

/// Measurements on linear images (always in RenderEngine.workingSpace).
enum Analyzer {

    /// Mean linear RGB inside `rect` (pixels). Used for the film-base sample.
    static func average(_ image: CIImage, in rect: CGRect) -> SIMD3<Float>? {
        let r = rect.integral.intersection(image.extent)
        guard r.width >= 1, r.height >= 1 else { return nil }
        let avg = image.applyingFilter("CIAreaAverage",
                                       parameters: [kCIInputExtentKey: CIVector(cgRect: r)])
        var px = [Float](repeating: 0, count: 4)
        px.withUnsafeMutableBytes { buf in
            RenderEngine.previewContext.render(
                avg, toBitmap: buf.baseAddress!, rowBytes: 16,
                bounds: CGRect(origin: avg.extent.origin, size: CGSize(width: 1, height: 1)),
                format: .RGBAf, colorSpace: RenderEngine.workingSpace)
        }
        let v = SIMD3<Float>(px[0], px[1], px[2])
        guard v.min() > 0, v.x.isFinite, v.y.isFinite, v.z.isFinite else { return nil }
        return v
    }

    /// RGB histogram of what the user sees: values encoded to the display space (extended sRGB),
    /// so bin positions match perceived tones. Out-of-range pixels are counted as clipped.
    static func histogram(_ image: CIImage, bins: Int = 128) -> Histogram? {
        guard let (buf, count) = renderSmall(image, maxEdge: 400, colorSpace: RenderEngine.displaySpace),
              count > 0 else { return nil }
        var h = Histogram(bins: bins)
        for i in 0..<count {
            for c in 0..<3 {
                let v = buf[i * 4 + c]
                guard v.isFinite else { continue }
                if v <= 0.0 { h.clipLow[c] += 1 }
                if v >= 1.0 { h.clipHigh[c] += 1 }
                let b = min(max(Int(v * Float(bins)), 0), bins - 1)
                h.counts[c][b] += 1
            }
        }
        h.clipLow /= Float(count)
        h.clipHigh /= Float(count)
        return h
    }

    /// Mean linear RGB in a small square around a normalised point (y-up).
    static func average(_ image: CIImage, around p: CGPoint, radiusFraction: CGFloat = 0.006) -> SIMD3<Float>? {
        let e = image.extent
        let r = max(2, radiusFraction * max(e.width, e.height))
        let c = CGPoint(x: e.minX + p.x * e.width, y: e.minY + p.y * e.height)
        return average(image, in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    /// Grey-world mean of a linear positive over its midtones, for matching white balance.
    /// `image` is the inverted positive BEFORE tone; `gain` the tone gain (exposure × WB) it is
    /// viewed with. A pixel counts when, after the gain, its luminance is a midtone
    /// (0.03…0.6 linear ≈ L* 20…80) and it is fairly neutral ((max − min) / max < 0.35), so
    /// skies, foliage and clipped areas don't decide the cast. Returns the mean of the
    /// ungained pixels, or nil if fewer than 2 % of pixels qualify.
    static func greyWorld(_ image: CIImage, gain: SIMD3<Float>) -> SIMD3<Float>? {
        guard let (buf, count) = renderSmall(image, maxEdge: 400, colorSpace: RenderEngine.workingSpace),
              count > 0 else { return nil }
        var sum = SIMD3<Double>(repeating: 0)
        var n = 0
        for i in 0..<count {
            guard buf[i * 4 + 3] > 0.99 else { continue }          // skip frame edges / corners
            let c = SIMD3<Float>(buf[i * 4], buf[i * 4 + 1], buf[i * 4 + 2])
            guard c.min() > 0, c.max().isFinite else { continue }
            let v = c * gain
            let y = 0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z
            guard y > 0.03, y < 0.6, (v.max() - v.min()) / v.max() < 0.35 else { continue }
            sum += SIMD3<Double>(Double(c.x), Double(c.y), Double(c.z))
            n += 1
        }
        guard n >= max(50, count / 50) else { return nil }
        let m = sum / Double(n)
        return SIMD3<Float>(Float(m.x), Float(m.y), Float(m.z))
    }

    /// Downscale to `maxEdge` and read back RGBAf in `colorSpace`. Returns (buffer, pixel count).
    private static func renderSmall(_ image: CIImage, maxEdge: CGFloat,
                                    colorSpace: CGColorSpace) -> ([Float], Int)? {
        let e = image.extent
        guard e.width >= 2, e.height >= 2, !e.isInfinite else { return nil }
        let s = min(1, maxEdge / max(e.width, e.height))
        var img = image
        if s < 1 {
            img = image.applyingFilter("CILanczosScaleTransform",
                                       parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1.0])
        }
        let ie = img.extent
        let x0 = ie.minX.rounded(.up), y0 = ie.minY.rounded(.up)
        let w = Int(ie.maxX.rounded(.down) - x0), h = Int(ie.maxY.rounded(.down) - y0)
        guard w > 0, h > 0 else { return nil }
        var buf = [Float](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { raw in
            RenderEngine.previewContext.render(
                img, toBitmap: raw.baseAddress!, rowBytes: w * 16,
                bounds: CGRect(x: x0, y: y0, width: CGFloat(w), height: CGFloat(h)),
                format: .RGBAf, colorSpace: colorSpace)
        }
        return (buf, w * h)
    }

    /// Per-channel density percentiles of a (cropped) linear negative, relative to `base`.
    /// Returns (dBlack, dWhite): the densities that will map to black and to white.
    /// Low density = thin negative = scene shadows; high density = scene highlights.
    static func densityPoints(_ image: CIImage,
                              base: SIMD3<Float>,
                              lowFraction: Float = 0.003,
                              highFraction: Float = 0.997) -> (black: SIMD3<Float>, white: SIMD3<Float>)? {
        let e = image.extent
        guard e.width >= 4, e.height >= 4 else { return nil }

        // ~512 px long edge is plenty for percentiles and keeps this well under 50 ms.
        let s = min(1, 512 / max(e.width, e.height))
        var img = image
        if s < 1 {
            img = image.applyingFilter("CILanczosScaleTransform",
                                       parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1.0])
        }
        let ie = img.extent
        let x0 = ie.minX.rounded(.up), y0 = ie.minY.rounded(.up)
        let w = Int(ie.maxX.rounded(.down) - x0), h = Int(ie.maxY.rounded(.down) - y0)
        guard w > 2, h > 2 else { return nil }

        var buf = [Float](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { raw in
            RenderEngine.previewContext.render(
                img, toBitmap: raw.baseAddress!, rowBytes: w * 16,
                bounds: CGRect(x: x0, y: y0, width: CGFloat(w), height: CGFloat(h)),
                format: .RGBAf, colorSpace: RenderEngine.workingSpace)
        }

        // Inset by a few pixels: Lanczos ringing at the crop edge.
        let inset = 2
        var channels: [[Float]] = [[], [], []]
        for c in 0..<3 { channels[c].reserveCapacity(w * h) }
        for y in inset..<(h - inset) {
            for x in inset..<(w - inset) {
                let i = (y * w + x) * 4
                for c in 0..<3 {
                    let t = max(buf[i + c] / base[c], 1e-6)
                    let d = -log10f(t)
                    if d.isFinite { channels[c].append(d) }
                }
            }
        }

        var black = SIMD3<Float>(repeating: 0), white = SIMD3<Float>(repeating: 1)
        for c in 0..<3 {
            var v = channels[c]
            guard v.count > 16 else { return nil }
            v.sort()
            let lo = v[min(v.count - 1, Int(Float(v.count - 1) * lowFraction))]
            let hi = v[min(v.count - 1, Int(Float(v.count - 1) * highFraction))]
            black[c] = lo
            white[c] = max(hi, lo + 0.05)           // guard against flat frames
        }
        return (black, white)
    }

    // MARK: - Density histograms (roll analysis)

    /// Per-channel histogram of density above `base` over the cropped frame, normalised so each
    /// channel sums to 1 (every frame weighs the same when pooled). Same sampling as
    /// `densityPoints`: ≤ 512 px long edge, 2 px inset against Lanczos ringing.
    static func densityHistogram(_ image: CIImage, base: SIMD3<Float>) -> DensityHistogram? {
        let e = image.extent
        guard e.width >= 4, e.height >= 4 else { return nil }
        let s = min(1, 512 / max(e.width, e.height))
        var img = image
        if s < 1 {
            img = image.applyingFilter("CILanczosScaleTransform",
                                       parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1.0])
        }
        let ie = img.extent
        let x0 = ie.minX.rounded(.up), y0 = ie.minY.rounded(.up)
        let w = Int(ie.maxX.rounded(.down) - x0), h = Int(ie.maxY.rounded(.down) - y0)
        guard w > 6, h > 6 else { return nil }
        var buf = [Float](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { raw in
            RenderEngine.previewContext.render(
                img, toBitmap: raw.baseAddress!, rowBytes: w * 16,
                bounds: CGRect(x: x0, y: y0, width: CGFloat(w), height: CGFloat(h)),
                format: .RGBAf, colorSpace: RenderEngine.workingSpace)
        }
        var hist = DensityHistogram()
        let n = DensityHistogram.bins
        let scale = Float(n) / (DensityHistogram.dMax - DensityHistogram.dMin)
        var total = SIMD3<Float>(repeating: 0)
        let inset = 2
        for y in inset..<(h - inset) {
            for x in inset..<(w - inset) {
                let i = (y * w + x) * 4
                for c in 0..<3 {
                    let d = -log10f(max(buf[i + c] / base[c], 1e-6))
                    guard d.isFinite else { continue }
                    let b = min(max(Int((d - DensityHistogram.dMin) * scale), 0), n - 1)
                    hist.counts[c][b] += 1
                    total[c] += 1
                }
            }
        }
        for c in 0..<3 {
            guard total[c] > 16 else { return nil }
            for b in 0..<n { hist.counts[c][b] /= total[c] }
        }
        return hist
    }

    // MARK: - Clone source search

    /// Find a good clone source for a spot at `center` (source-normalised, y-up) with
    /// `radius` (fraction of the long edge), in a linear source image.
    ///
    /// Candidates sit on rings 2.2–4.5 radii away (never overlapping the defect). Each is
    /// scored in log space (≈ perceptual, exposure-invariant) by:
    ///  - how well its surroundings match the defect's surroundings (annulus r…1.6r) — so the
    ///    patch continues texture and gradients,
    ///  - how close its interior brightness is to the defect's surroundings,
    ///  - how busy its interior is — so we don't clone another speck or an edge.
    static func findCloneSource(in image: CIImage, center: CGPoint, radius: CGFloat) -> CGPoint? {
        let e = image.extent
        let longEdge = max(e.width, e.height)
        let r = max(1.5, radius * longEdge)
        let ring = r * 1.6
        let maxDist = r * 4.5
        let half = (maxDist + ring + 3).rounded(.up)
        let c = CGPoint(x: e.minX + center.x * e.width, y: e.minY + center.y * e.height)
        let win = CGRect(x: c.x - half, y: c.y - half, width: 2 * half, height: 2 * half)
            .integral.intersection(e.integral)
        guard win.width > 4, win.height > 4,
              let cg = RenderEngine.previewContext.createCGImage(image, from: win, format: .RGBAf,
                                                                 colorSpace: RenderEngine.workingSpace,
                                                                 deferred: false),
              let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }

        let w = cg.width, h = cg.height
        let rowFloats = cg.bytesPerRow / 4
        // CGImage rows run top → bottom, so buffer y is "down".
        var lum = [Float](repeating: 0, count: w * h * 3)
        bytes.withMemoryRebound(to: Float.self, capacity: rowFloats * h) { f in
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * rowFloats + x * 4
                    for ch in 0..<3 { lum[(y * w + x) * 3 + ch] = logf(max(f[i + ch], 1e-4)) }
                }
            }
        }
        @inline(__always) func v(_ x: Int, _ y: Int, _ ch: Int) -> Float { lum[(y * w + x) * 3 + ch] }

        // Defect centre in buffer coordinates (y down).
        let cx = Int((c.x - win.minX).rounded()), cy = Int((win.maxY - c.y).rounded())
        let step = max(1, Int(r / 6))
        let R = Int(ring.rounded(.up))
        var annulus: [(Int, Int)] = [], interior: [(Int, Int)] = []
        for j in stride(from: -R, through: R, by: step) {
            for i in stride(from: -R, through: R, by: step) {
                let d = (Double(i * i + j * j)).squareRoot()
                if d >= Double(r) * 1.1 && d <= Double(ring) { annulus.append((i, j)) }
                else if d < Double(r) { interior.append((i, j)) }
            }
        }
        guard !annulus.isEmpty, !interior.isEmpty else { return nil }
        func inside(_ x: Int, _ y: Int) -> Bool { x - R >= 0 && y - R >= 0 && x + R < w && y + R < h }

        // Mean log-brightness of the defect's surroundings (clipped at the window edge).
        var annMean: Float = 0, annCount = 0
        for (i, j) in annulus {
            let x = cx + i, y = cy + j
            guard x >= 0, y >= 0, x < w, y < h else { continue }
            annMean += (v(x, y, 0) + v(x, y, 1) + v(x, y, 2)) / 3; annCount += 1
        }
        guard annCount > 0 else { return nil }
        annMean /= Float(annCount)

        var best: (cost: Float, dx: Int, dy: Int)?
        for mult in [2.2, 2.8, 3.5, 4.5] {
            let dist = Double(r) * mult
            for k in 0..<24 {
                let a = Double(k) / 24 * 2 * .pi + (mult * 0.37)     // stagger rings
                let ox = Int((dist * cos(a)).rounded()), oy = Int((dist * sin(a)).rounded())
                let sx = cx + ox, sy = cy + oy
                guard inside(sx, sy) else { continue }

                var ssd: Float = 0, n = 0
                for (i, j) in annulus {
                    let dx = cx + i, dy = cy + j
                    guard dx >= 0, dy >= 0, dx < w, dy < h else { continue }
                    for ch in 0..<3 {
                        let t = v(dx, dy, ch) - v(sx + i, sy + j, ch)
                        ssd += t * t
                    }
                    n += 1
                }
                guard n > 0 else { continue }
                var m: Float = 0, m2: Float = 0
                for (i, j) in interior {
                    let l = (v(sx + i, sy + j, 0) + v(sx + i, sy + j, 1) + v(sx + i, sy + j, 2)) / 3
                    m += l; m2 += l * l
                }
                m /= Float(interior.count)
                let variance = max(0, m2 / Float(interior.count) - m * m)
                let cost = ssd / Float(n * 3) + 0.5 * variance + (m - annMean) * (m - annMean)
                if best == nil || cost < best!.cost { best = (cost, ox, oy) }
            }
        }
        guard let b = best else { return nil }
        // Buffer offset (y down) → image offset (y up) → normalised.
        let sxImg = c.x + CGFloat(b.dx), syImg = c.y - CGFloat(b.dy)
        return CGPoint(x: (sxImg - e.minX) / e.width, y: (syImg - e.minY) / e.height)
    }

    // MARK: - Brush-stroke clone source

    /// Best clone offset for a brush stroke (`path` in source-normalised coords, y-up), returned
    /// as a source-normalised vector (source = point + offset). Same scoring as `findCloneSource`,
    /// averaged over points along the stroke, with two stroke-specific rules:
    ///  - surroundings that lie on the stroke itself are ignored (a hair's neighbour along the
    ///    hair is more hair, not clean film);
    ///  - every source disc must stay ≥ 2 r away from the stroke, and offsets across the stroke
    ///    are preferred (cloning along a hair would copy the hair).
    static func findStrokeSource(in image: CIImage, path: [CGPoint], radius: CGFloat) -> CGVector? {
        let e = image.extent
        let longEdge = max(e.width, e.height)
        let r = max(1.5, radius * longEdge)
        let ring = r * 1.6
        let maxDist = r * 4.5
        let pts = path.map { CGPoint(x: e.minX + $0.x * e.width, y: e.minY + $0.y * e.height) }
        guard pts.count >= 2 else { return nil }

        var bb = CGRect(origin: pts[0], size: .zero)
        for p in pts { bb = bb.union(CGRect(origin: p, size: .zero)) }
        let half = (maxDist + ring + 3).rounded(.up)
        let win = bb.insetBy(dx: -half, dy: -half).integral.intersection(e.integral)
        guard win.width > 4, win.height > 4,
              let cg = RenderEngine.previewContext.createCGImage(image, from: win, format: .RGBAf,
                                                                 colorSpace: RenderEngine.workingSpace,
                                                                 deferred: false),
              let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }

        let w = cg.width, h = cg.height
        let rowFloats = cg.bytesPerRow / 4
        var lum = [Float](repeating: 0, count: w * h * 3)        // log RGB, rows top → bottom
        bytes.withMemoryRebound(to: Float.self, capacity: rowFloats * h) { f in
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * rowFloats + x * 4
                    for ch in 0..<3 { lum[(y * w + x) * 3 + ch] = logf(max(f[i + ch], 1e-4)) }
                }
            }
        }
        @inline(__always) func v(_ x: Int, _ y: Int, _ ch: Int) -> Float { lum[(y * w + x) * 3 + ch] }

        // Buffer coordinates are y-down.
        func toBuf(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - win.minX, y: win.maxY - p.y) }
        let bufPath = pts.map(toBuf)
        let line = Polyline.resample(bufPath, step: max(r * 0.5, 1), maxCount: 400)
        let samples = Polyline.resample(bufPath, step: max(r * 0.8, 1), maxCount: 24)

        let step = max(1, Int(r / 6))
        let R = Int(ring.rounded(.up))
        func inside(_ x: Int, _ y: Int) -> Bool { x - R >= 0 && y - R >= 0 && x + R < w && y + R < h }

        var annulusOffsets: [(Int, Int)] = [], interior: [(Int, Int)] = []
        for j in stride(from: -R, through: R, by: step) {
            for i in stride(from: -R, through: R, by: step) {
                let d = (Double(i * i + j * j)).squareRoot()
                if d >= Double(r) * 1.1 && d <= Double(ring) { annulusOffsets.append((i, j)) }
                else if d < Double(r) { interior.append((i, j)) }
            }
        }
        guard !interior.isEmpty else { return nil }

        struct Sample { let x: Int; let y: Int; let ann: [(Int, Int)]; let annMean: Float }
        var ss: [Sample] = []
        for sp in samples {
            let cx = Int(sp.x.rounded()), cy = Int(sp.y.rounded())
            var ann: [(Int, Int)] = []
            var mean: Float = 0
            for (i, j) in annulusOffsets {
                let x = cx + i, y = cy + j
                guard x >= 0, y >= 0, x < w, y < h,
                      Polyline.distance(CGPoint(x: x, y: y), to: line) >= r * 1.1 else { continue }
                ann.append((i, j))
                mean += (v(x, y, 0) + v(x, y, 1) + v(x, y, 2)) / 3
            }
            guard ann.count >= 4 else { continue }
            ss.append(Sample(x: cx, y: cy, ann: ann, annMean: mean / Float(ann.count)))
        }
        guard !ss.isEmpty else { return nil }

        let dir = CGPoint(x: bufPath.last!.x - bufPath[0].x, y: bufPath.last!.y - bufPath[0].y)
        let dirLen = hypot(dir.x, dir.y)

        var best: (cost: Float, dx: Int, dy: Int)?
        for mult in [2.2, 2.8, 3.5, 4.5] {
            let dist = Double(r) * mult
            for k in 0..<24 {
                let a = Double(k) / 24 * 2 * .pi + (mult * 0.37)
                let ox = Int((dist * cos(a)).rounded()), oy = Int((dist * sin(a)).rounded())

                // Every source disc inside the window and clear of the stroke.
                var ok = true
                for s in ss {
                    let sx = s.x + ox, sy = s.y + oy
                    if !inside(sx, sy) || Polyline.distance(CGPoint(x: sx, y: sy), to: line) < 2 * r {
                        ok = false; break
                    }
                }
                guard ok else { continue }

                var total: Float = 0
                for s in ss {
                    let sx = s.x + ox, sy = s.y + oy
                    var ssd: Float = 0
                    for (i, j) in s.ann {
                        for ch in 0..<3 {
                            let t = v(s.x + i, s.y + j, ch) - v(sx + i, sy + j, ch)
                            ssd += t * t
                        }
                    }
                    var m: Float = 0, m2: Float = 0
                    for (i, j) in interior {
                        let l = (v(sx + i, sy + j, 0) + v(sx + i, sy + j, 1) + v(sx + i, sy + j, 2)) / 3
                        m += l; m2 += l * l
                    }
                    m /= Float(interior.count)
                    let variance = max(0, m2 / Float(interior.count) - m * m)
                    total += ssd / Float(s.ann.count * 3) + 0.5 * variance + (m - s.annMean) * (m - s.annMean)
                }
                var cost = total / Float(ss.count)
                if dirLen > r {      // prefer offsets across the stroke
                    let cosA = abs((Double(ox) * Double(dir.x) + Double(oy) * Double(dir.y)) / (dist * Double(dirLen)))
                    cost *= Float(1 + 0.3 * cosA)
                }
                if best == nil || cost < best!.cost { best = (cost, ox, oy) }
            }
        }
        guard let b = best else { return nil }
        // Buffer offset (y down) → image offset (y up) → normalised.
        return CGVector(dx: CGFloat(b.dx) / e.width, dy: -CGFloat(b.dy) / e.height)
    }
}
