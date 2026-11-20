import SwiftUI
import simd

struct Histogram: Equatable {
    var counts: [[Float]]
    /// Fraction of pixels at or below 0 / at or above 1, per channel.
    var clipLow = SIMD3<Float>(repeating: 0)
    var clipHigh = SIMD3<Float>(repeating: 0)

    init(bins: Int) {
        counts = Array(repeating: Array(repeating: 0, count: bins), count: 3)
    }
}

struct HistogramView: View {
    let histogram: Histogram?

    var body: some View {
        VStack(spacing: 4) {
            Canvas { ctx, size in
                guard let h = histogram else { return }
                let bins = h.counts[0].count
                // Normalise ignoring the end bins, so a clipped spike doesn't flatten the rest.
                var peak: Float = 1
                for c in 0..<3 { peak = max(peak, h.counts[c][1..<(bins - 1)].max() ?? 1) }
                let colors: [Color] = [.red, .green, .blue]
                ctx.blendMode = .plusLighter
                for c in 0..<3 {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: size.height))
                    for b in 0..<bins {
                        let x = size.width * CGFloat(b) / CGFloat(bins - 1)
                        // sqrt scale: keeps small populations visible
                        let v = CGFloat(min(sqrt(h.counts[c][b] / peak), 1))
                        path.addLine(to: CGPoint(x: x, y: size.height * (1 - v)))
                    }
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.closeSubpath()
                    ctx.fill(path, with: .color(colors[c].opacity(0.75)))
                }
            }
            .frame(height: 90)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 6))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                clipLabel("arrowtriangle.down.fill", h: histogram?.clipLow)
                Spacer()
                clipLabel("arrowtriangle.up.fill", h: histogram?.clipHigh)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func clipLabel(_ symbol: String, h: SIMD3<Float>?) -> some View {
        let v = h ?? .zero
        let worst = v.max()
        return HStack(spacing: 3) {
            Image(systemName: symbol)
                .foregroundStyle(worst > 0.005 ? Color.orange : Color.secondary)
            Text(String(format: "R %.1f  G %.1f  B %.1f %%", v.x * 100, v.y * 100, v.z * 100))
        }
        .help(symbol.contains("down") ? "Pixels clipped to black" : "Pixels clipped to white")
    }
}
