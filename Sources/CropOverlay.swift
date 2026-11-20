import SwiftUI

/// Interactive crop rectangle drawn over the (uncropped, oriented) preview.
/// Works in normalised y-up coordinates so it shares the recipe's representation directly.
struct CropOverlay: View {
    /// Size of the oriented image being displayed (any resolution; only the aspect matters).
    let imageSize: CGSize
    @Binding var crop: CGRect

    @State private var dragStart: CGRect?

    enum Handle: CaseIterable, Hashable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
        var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
        var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
        var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }
    }

    var body: some View {
        GeometryReader { geo in
            let fit = FitLayout.fitRect(content: imageSize, in: geo.size)
            let r = viewRect(fit)

            ZStack(alignment: .topLeading) {
                // Dim everything outside the crop.
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: geo.size))
                    p.addRect(r)
                }
                .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                // Rule of thirds.
                Path { p in
                    for i in 1...2 {
                        let x = r.minX + r.width * CGFloat(i) / 3
                        let y = r.minY + r.height * CGFloat(i) / 3
                        p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                        p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                .allowsHitTesting(false)

                // Drag inside to move.
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                    .gesture(moveGesture(fit))

                Rectangle()
                    .stroke(Color.white, lineWidth: 1)
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                    .allowsHitTesting(false)

                ForEach(Handle.allCases, id: \.self) { h in
                    handleView(h)
                        .position(point(h, r))
                        .gesture(resizeGesture(h, fit))
                }

                Text("Drag the edges or corners  ·  Return to apply")
                    .font(.callout)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .position(x: geo.size.width / 2, y: 22)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Geometry

    /// Normalised y-up crop → SwiftUI (y-down) rect in points.
    private func viewRect(_ fit: CGRect) -> CGRect {
        CGRect(x: fit.minX + crop.minX * fit.width,
               y: fit.minY + (1 - crop.maxY) * fit.height,
               width: crop.width * fit.width,
               height: crop.height * fit.height)
    }

    private func point(_ h: Handle, _ r: CGRect) -> CGPoint {
        let x = h.movesLeft ? r.minX : (h.movesRight ? r.maxX : r.midX)
        let y = h.movesTop ? r.minY : (h.movesBottom ? r.maxY : r.midY)
        return CGPoint(x: x, y: y)
    }

    @ViewBuilder
    private func handleView(_ h: Handle) -> some View {
        let size: CGSize = h.isCorner ? CGSize(width: 12, height: 12)
            : (h.movesTop || h.movesBottom ? CGSize(width: 22, height: 6) : CGSize(width: 6, height: 22))
        Rectangle()
            .fill(Color.white)
            .overlay(Rectangle().stroke(Color.black.opacity(0.5), lineWidth: 0.5))
            .frame(width: size.width, height: size.height)
            .frame(width: 28, height: 28)          // larger hit area
            .contentShape(Rectangle())
    }

    // MARK: - Gestures

    private func moveGesture(_ fit: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                let start = dragStart ?? crop
                if dragStart == nil { dragStart = crop }
                let du = v.translation.width / fit.width
                let dv = -v.translation.height / fit.height      // view y-down → y-up
                let dx = min(max(du, -start.minX), 1 - start.maxX)
                let dy = min(max(dv, -start.minY), 1 - start.maxY)
                crop = start.offsetBy(dx: dx, dy: dy)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(_ h: Handle, _ fit: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let start = dragStart ?? crop
                if dragStart == nil { dragStart = crop }
                crop = Self.resize(start, h,
                                   du: v.translation.width / fit.width,
                                   dv: -v.translation.height / fit.height)
            }
            .onEnded { _ in dragStart = nil }
    }

    static func resize(_ r: CGRect, _ h: Handle, du: CGFloat, dv: CGFloat) -> CGRect {
        let m = Geometry.minCropSize
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        if h.movesLeft { minX = min(max(0, r.minX + du), maxX - m) }
        if h.movesRight { maxX = max(min(1, r.maxX + du), minX + m) }
        if h.movesTop { maxY = max(min(1, r.maxY + dv), minY + m) }      // top = maxY in y-up
        if h.movesBottom { minY = min(max(0, r.minY + dv), maxY - m) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
