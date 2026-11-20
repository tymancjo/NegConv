import AppKit
import SwiftUI

// MARK: - Curves section

struct CurvesSection: View {
    @Environment(AppModel.self) private var model
    @State private var channel = 0          // 0 = RGB master, 1…3 = R, G, B
    @State private var selected: Int?

    var body: some View {
        let points = model.recipe.curves[channel]

        Section {
            Picker("Channel", selection: $channel) {
                Text("RGB").tag(0)
                Text("R").tag(1)
                Text("G").tag(2)
                Text("B").tag(3)
            }
            .pickerStyle(.segmented)
            .onChange(of: channel) { selected = nil }

            CurveEditor(points: Binding(get: { model.recipe.curves[channel] },
                                        set: { model.recipe.curves[channel] = $0 }),
                        channel: channel,
                        others: model.recipe.curves,
                        histogram: model.histogram,
                        selected: $selected)
                .aspectRatio(1, contentMode: .fit)
                .padding(.vertical, 4)

            HStack {
                if let i = selected, i < points.count {
                    Text("In \(Int((points[i].x * 255).rounded()))  ·  Out \(Int((points[i].y * 255).rounded()))")
                        .font(.callout).monospacedDigit()
                        .foregroundStyle(.secondary)
                    if i > 0 && i < points.count - 1 {
                        Button { deleteSelected() } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove this point")
                    }
                } else {
                    Text("\(points.count) points").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset Channel") {
                    model.recipe.curves[channel] = Curves.identityPoints
                    selected = nil
                }
                .disabled(Curves.isIdentity(points))
                Button("Reset All") {
                    model.recipe.curves = Curves()
                    selected = nil
                }
                .disabled(model.recipe.curves.isIdentity)
            }
        } header: {
            Text("Curves")
        } footer: {
            Text("On the print, after levels; per-channel curves first, then RGB. Click to add a point, drag to move (hold ⇧ for fine), drag a point off the graph to remove it. In/Out on a 0–255 scale.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!model.recipe.inversion.isReady)
    }

    private func deleteSelected() {
        guard let i = selected else { return }
        var p = model.recipe.curves[channel]
        guard i > 0, i < p.count - 1 else { return }
        p.remove(at: i)
        model.recipe.curves[channel] = p
        selected = nil
    }
}

// MARK: - Editor canvas

/// Square curve graph: γ 2.2 input on x, output on y, both 0…1. Histogram of the current
/// output behind it, identity diagonal, quarter grid. Other channels' curves are drawn faintly
/// so you see the whole adjustment while editing one.
struct CurveEditor: View {
    @Binding var points: [CurvePoint]
    let channel: Int
    let others: Curves
    let histogram: Histogram?
    @Binding var selected: Int?

    @State private var dragIndex: Int?
    @State private var lastLocation: CGPoint?
    @State private var pendingDelete = false

    private static let hitRadius: CGFloat = 10
    private static let deleteMargin: CGFloat = 24

    private var tint: Color { [Color.primary, .red, .green, .blue][channel] }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { ctx, _ in draw(&ctx, size) }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator, lineWidth: 1))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { changed($0.location, size) }
                    .onEnded { _ in ended() })
        }
    }

    // MARK: Drawing

    private func view(_ p: CurvePoint, _ s: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(p.x) * s.width, y: (1 - CGFloat(p.y)) * s.height)
    }

    private func draw(_ ctx: inout GraphicsContext, _ s: CGSize) {
        // Histogram (display-encoded output, close to the γ 2.2 axis).
        if let h = histogram {
            let bins = h.counts[0].count
            let counts: [Float] = channel == 0
                ? (0..<bins).map { (h.counts[0][$0] + h.counts[1][$0] + h.counts[2][$0]) / 3 }
                : h.counts[channel - 1]
            let peak = max(counts.dropFirst().dropLast().max() ?? 1, 1e-6)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: s.height))
            for (i, v) in counts.enumerated() {
                let x = (CGFloat(i) + 0.5) / CGFloat(bins) * s.width
                path.addLine(to: CGPoint(x: x, y: s.height * (1 - CGFloat(min(v / peak, 1)) * 0.9)))
            }
            path.addLine(to: CGPoint(x: s.width, y: s.height))
            path.closeSubpath()
            ctx.fill(path, with: .color((channel == 0 ? Color.gray : tint).opacity(0.18)))
        }

        // Grid and identity diagonal.
        var grid = Path()
        for q in 1...3 {
            let f = CGFloat(q) / 4
            grid.move(to: CGPoint(x: f * s.width, y: 0)); grid.addLine(to: CGPoint(x: f * s.width, y: s.height))
            grid.move(to: CGPoint(x: 0, y: f * s.height)); grid.addLine(to: CGPoint(x: s.width, y: f * s.height))
        }
        ctx.stroke(grid, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)
        var diag = Path()
        diag.move(to: CGPoint(x: 0, y: s.height)); diag.addLine(to: CGPoint(x: s.width, y: 0))
        ctx.stroke(diag, with: .color(.secondary.opacity(0.4)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))

        // Other channels, faint.
        let colours: [Color] = [.primary, .red, .green, .blue]
        for c in 0..<4 where c != channel && !Curves.isIdentity(others[c]) {
            ctx.stroke(curvePath(others[c], s), with: .color(colours[c].opacity(0.35)), lineWidth: 1)
        }

        // This channel.
        ctx.stroke(curvePath(points, s), with: .color(tint), lineWidth: 1.5)
        for (i, p) in points.enumerated() {
            let c = view(p, s)
            let r: CGFloat = i == selected ? 4.5 : 3.5
            let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            if i == dragIndex && pendingDelete {
                ctx.stroke(dot, with: .color(.red), lineWidth: 1.5)
            } else {
                ctx.fill(dot, with: .color(i == selected ? tint : Color(nsColor: .controlBackgroundColor)))
                ctx.stroke(dot, with: .color(tint), lineWidth: 1.2)
            }
        }
    }

    private func curvePath(_ pts: [CurvePoint], _ s: CGSize) -> Path {
        let spline = MonotoneSpline(pts)
        var path = Path()
        let n = 160
        for i in 0...n {
            let x = Float(i) / Float(n)
            let c = view(CurvePoint(x: x, y: spline(x)), s)
            if i == 0 { path.move(to: c) } else { path.addLine(to: c) }
        }
        return path
    }

    // MARK: Interaction

    private func changed(_ loc: CGPoint, _ s: CGSize) {
        guard s.width > 0, s.height > 0 else { return }
        if dragIndex == nil {
            // New press: grab the nearest point, or add one on the curve at this x.
            let hit = points.indices.min { dist(points[$0], loc, s) < dist(points[$1], loc, s) }
            if let h = hit, dist(points[h], loc, s) <= Self.hitRadius {
                dragIndex = h
            } else if points.count < Curves.maxPoints {
                let x = Float(min(max(loc.x / s.width, 0), 1))
                guard let k = points.firstIndex(where: { $0.x > x }), k > 0,
                      x - points[k - 1].x >= Curves.minGap, points[k].x - x >= Curves.minGap else { return }
                let y = MonotoneSpline(points)(x)
                points.insert(CurvePoint(x: x, y: y), at: k)
                dragIndex = k
            } else {
                return
            }
            selected = dragIndex
            lastLocation = loc
            return
        }

        guard let i = dragIndex, let last = lastLocation else { return }
        // Relative drag: ⇧ makes it 10× finer at any moment, without a jump.
        let k: CGFloat = Precision.isFine ? CGFloat(Precision.fineFactor) : 1
        let dx = Float((loc.x - last.x) * k / s.width)
        let dy = Float(-(loc.y - last.y) * k / s.height)
        lastLocation = loc

        // Dragging an interior point well outside the graph marks it for removal.
        let outside = loc.x < -Self.deleteMargin || loc.x > s.width + Self.deleteMargin
            || loc.y < -Self.deleteMargin || loc.y > s.height + Self.deleteMargin
        pendingDelete = outside && i > 0 && i < points.count - 1
        if pendingDelete { return }

        var p = points[i]
        let lo: Float = i == 0 ? 0 : points[i - 1].x + Curves.minGap
        let hi: Float = i == points.count - 1 ? 1 : points[i + 1].x - Curves.minGap
        p.x = min(max(p.x + dx, lo), hi)
        p.y = min(max(p.y + dy, 0), 1)
        points[i] = p
    }

    private func ended() {
        if pendingDelete, let i = dragIndex, i > 0, i < points.count - 1 {
            points.remove(at: i)
            selected = nil
        }
        dragIndex = nil
        lastLocation = nil
        pendingDelete = false
    }

    private func dist(_ p: CurvePoint, _ loc: CGPoint, _ s: CGSize) -> CGFloat {
        let c = view(p, s)
        return hypot(c.x - loc.x, c.y - loc.y)
    }
}
