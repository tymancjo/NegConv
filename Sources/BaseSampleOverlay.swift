import SwiftUI

/// Drag a rectangle over clear film rebate to sample the film base (orange mask).
struct BaseSampleOverlay: View {
    let imageSize: CGSize
    /// Existing sample, normalised in the displayed orientation (y-up), if any.
    let existing: CGRect?
    /// Called with the new sample, normalised in the displayed orientation (y-up).
    let onSample: (CGRect) -> Void

    @State private var dragRect: CGRect?

    var body: some View {
        GeometryReader { geo in
            let fit = FitLayout.fitRect(content: imageSize, in: geo.size)

            ZStack(alignment: .topLeading) {
                Color.white.opacity(0.001)          // catch drags everywhere
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { v in
                                dragRect = CGRect(x: min(v.startLocation.x, v.location.x),
                                                  y: min(v.startLocation.y, v.location.y),
                                                  width: abs(v.location.x - v.startLocation.x),
                                                  height: abs(v.location.y - v.startLocation.y))
                                    .intersection(fit)
                            }
                            .onEnded { _ in
                                if let r = dragRect, r.width >= 3, r.height >= 3 {
                                    onSample(FitLayout.normalizedRect(view: r, fit: fit))
                                }
                                dragRect = nil
                            }
                    )

                if let existing, dragRect == nil {
                    marker(FitLayout.viewRect(normalized: existing, fit: fit), dashed: false)
                }
                if let dragRect {
                    marker(dragRect, dashed: true)
                }

                Text("Drag over clear film rebate — avoid sprocket holes and the holder")
                    .font(.callout)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .position(x: geo.size.width / 2, y: 22)
                    .allowsHitTesting(false)
            }
        }
    }

    private func marker(_ r: CGRect, dashed: Bool) -> some View {
        Rectangle()
            .stroke(Color.cyan, style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [5, 3] : []))
            .background(Rectangle().stroke(Color.black.opacity(0.6), lineWidth: 3))
            .frame(width: r.width, height: r.height)
            .position(x: r.midX, y: r.midY)
            .allowsHitTesting(false)
    }
}
