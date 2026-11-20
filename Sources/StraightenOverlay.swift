import SwiftUI

/// Draw a line along something that should be horizontal or vertical; on release the frame is
/// rotated so that line becomes exactly level/plumb.
struct StraightenOverlay: View {
    let imageSize: CGSize
    let onLine: (CGPoint, CGPoint) -> Void

    @State private var start: CGPoint?
    @State private var end: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let fit = FitLayout.fitRect(content: imageSize, in: geo.size)

            ZStack(alignment: .topLeading) {
                // Fine grid to judge verticals/horizontals.
                Path { p in
                    let n = 8
                    for i in 1..<n {
                        let x = fit.minX + fit.width * CGFloat(i) / CGFloat(n)
                        let y = fit.minY + fit.height * CGFloat(i) / CGFloat(n)
                        p.move(to: CGPoint(x: x, y: fit.minY)); p.addLine(to: CGPoint(x: x, y: fit.maxY))
                        p.move(to: CGPoint(x: fit.minX, y: y)); p.addLine(to: CGPoint(x: fit.maxX, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                .allowsHitTesting(false)

                Color.white.opacity(0.001)
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { v in
                                start = v.startLocation
                                end = v.location
                            }
                            .onEnded { v in
                                onLine(v.startLocation, v.location)
                                start = nil; end = nil
                            }
                    )

                if let start, let end {
                    Path { p in p.move(to: start); p.addLine(to: end) }
                        .stroke(Color.black.opacity(0.6), lineWidth: 4)
                        .allowsHitTesting(false)
                    Path { p in p.move(to: start); p.addLine(to: end) }
                        .stroke(Color.yellow, lineWidth: 1.5)
                        .allowsHitTesting(false)
                    Text(angleLabel(start, end))
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.regularMaterial, in: Capsule())
                        .position(x: end.x, y: end.y - 18)
                        .allowsHitTesting(false)
                }

                Text("Draw a line along a horizon or a vertical edge")
                    .font(.callout)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .position(x: geo.size.width / 2, y: 22)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Deviation from the nearest axis, as it will be corrected.
    private func angleLabel(_ a: CGPoint, _ b: CGPoint) -> String {
        var deg = atan2(-(b.y - a.y), b.x - a.x) * 180 / .pi
        if deg > 90 { deg -= 180 } else if deg <= -90 { deg += 180 }
        let dev = abs(deg) <= 45 ? deg : (deg > 0 ? deg - 90 : deg + 90)
        return String(format: "%@ %+.2f°", abs(deg) <= 45 ? "H" : "V", Double(dev))
    }
}
