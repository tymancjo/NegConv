import SwiftUI

/// Draws the brush and all spots (repair disc ● and source disc ○ joined by a line) over the
/// preview. Clicking empty image adds a spot (handled by MagnifierInteraction underneath);
/// the circles here can be dragged: the repair disc moves the whole spot, the source disc only
/// the source.
struct SpotOverlay: View {
    @Environment(AppModel.self) private var model
    let viewSize: CGSize

    @State private var drag: DragState?

    private struct DragState {
        let id: UUID
        let sourceOnly: Bool
        let startView: CGPoint
        let offset: CGVector     // source − centre, source-normalised
    }

    var body: some View {
        let g = model.recipe.geometry
        let aspect = model.orientedImage.map { $0.extent.width / max($0.extent.height, 1) } ?? 1
        let pxToPt = model.viewPointsPerSourcePreviewPixel(viewSize: viewSize) ?? 0
        let longEdge = model.sourceLongEdgePreview ?? 0

        ZStack(alignment: .topLeading) {
            ForEach(model.recipe.spots) { spot in
                let rPt = spot.radius * longEdge * pxToPt
                if let c = model.viewPoint(fromFramed: g.framedPoint(fromSource: spot.center, aspect: aspect),
                                           viewSize: viewSize),
                   let s = model.viewPoint(fromFramed: g.framedPoint(fromSource: spot.source, aspect: aspect),
                                           viewSize: viewSize) {
                    let selected = spot.id == model.selectedSpotID
                    Path { p in p.move(to: c); p.addLine(to: s) }
                        .stroke(Color.white.opacity(selected ? 0.8 : 0.35), lineWidth: 1)
                        .allowsHitTesting(false)
                    if spot.isStroke, let path = spot.path {
                        // The framing transform is affine, so the source offset is the same
                        // view-space vector for every point of the stroke.
                        let pts = path.compactMap {
                            model.viewPoint(fromFramed: g.framedPoint(fromSource: $0, aspect: aspect), viewSize: viewSize)
                        }
                        let srcPts = pts.map { CGPoint(x: $0.x + s.x - c.x, y: $0.y + s.y - c.y) }
                        strokeShape(srcPts, radius: rPt, dashed: true, selected: selected)
                            .gesture(dragGesture(spot, sourceOnly: true, startView: s))
                        strokeShape(pts, radius: rPt, dashed: false, selected: selected)
                            .gesture(dragGesture(spot, sourceOnly: false, startView: c))
                    } else {
                        circle(at: s, radius: rPt, dashed: true, selected: selected)
                            .gesture(dragGesture(spot, sourceOnly: true, startView: s))
                        circle(at: c, radius: rPt, dashed: false, selected: selected)
                            .gesture(dragGesture(spot, sourceOnly: false, startView: c))
                    }
                }
            }

            // Stroke being painted.
            if let painting = model.paintingStroke, !painting.isEmpty {
                let pts = painting.compactMap {
                    model.viewPoint(fromFramed: g.framedPoint(fromSource: $0, aspect: aspect), viewSize: viewSize)
                }
                let r = model.brushRadius * longEdge * pxToPt
                Path { p in
                    p.addLines(pts.count == 1 ? [pts[0], pts[0]] : pts)
                }
                .stroke(Color.white.opacity(0.35),
                        style: StrokeStyle(lineWidth: max(2 * r, 2), lineCap: .round, lineJoin: .round))
                .allowsHitTesting(false)
            }

            // Brush preview at the cursor.
            if let p = model.hoverViewPoint, drag == nil, model.paintingStroke == nil {
                let r = model.brushRadius * longEdge * pxToPt
                Circle()
                    .stroke(Color.white.opacity(0.9), lineWidth: 1)
                    .background(Circle().stroke(Color.black.opacity(0.5), lineWidth: 3))
                    .frame(width: 2 * r, height: 2 * r)
                    .position(p)
                    .allowsHitTesting(false)
            }

            Text("Click a speck  ·  drag to paint a hair  ·  ⇧-click straight line  ·  [ ] size  ·  drag ● to move, ○ to pick source  ·  ⌫ delete  ·  ⌥ loupe  ·  space+drag pan  ·  Return done")
                .font(.callout)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .position(x: viewSize.width / 2, y: 22)
                .allowsHitTesting(false)
        }
        .frame(width: viewSize.width, height: viewSize.height)
    }

    private func circle(at p: CGPoint, radius r: CGFloat, dashed: Bool, selected: Bool) -> some View {
        let d = max(2 * r, 8)
        return Circle()
            .stroke(selected ? Color.yellow : Color.white,
                    style: StrokeStyle(lineWidth: selected ? 2 : 1.25, dash: dashed ? [4, 3] : []))
            .background(Circle().stroke(Color.black.opacity(0.5), lineWidth: 3))
            .frame(width: d, height: d)
            .contentShape(Circle())
            .position(p)
    }

    /// Outline of a round brush stroke of radius `r` along `pts` (view points).
    private func strokeShape(_ pts: [CGPoint], radius r: CGFloat, dashed: Bool, selected: Bool) -> some View {
        let line = Path { p in p.addLines(pts) }
        let outline = line.strokedPath(StrokeStyle(lineWidth: max(2 * r, 8), lineCap: .round, lineJoin: .round))
        return ZStack {
            outline.stroke(Color.black.opacity(0.5), lineWidth: 3)
            outline.stroke(selected ? Color.yellow : Color.white,
                           style: StrokeStyle(lineWidth: selected ? 2 : 1.25, dash: dashed ? [4, 3] : []))
        }
        .contentShape(outline)
    }

    private func dragGesture(_ spot: Spot, sourceOnly: Bool, startView: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if drag == nil {
                    model.selectSpot(spot.id)
                    drag = DragState(id: spot.id, sourceOnly: sourceOnly, startView: startView,
                                     offset: CGVector(dx: spot.source.x - spot.center.x,
                                                      dy: spot.source.y - spot.center.y))
                }
                guard let d = drag, v.translation != .zero else { return }
                let p = CGPoint(x: d.startView.x + v.translation.width, y: d.startView.y + v.translation.height)
                model.moveSpot(d.id, sourceOnly: d.sourceOnly, toView: p, viewSize: viewSize, keepOffset: d.offset)
            }
            .onEnded { _ in drag = nil }
    }
}
