import AppKit
import SwiftUI

// Precision controls for the inspector.
//
// - PrecisionTrack: a slider whose drag is RELATIVE (the value moves by how far you drag, not
//   to where the pointer is), so holding ⇧ can slow it down 10× at any moment without a jump.
//   Clicking the bare track still jumps there (like a normal slider). Double-click resets to the
//   default; a tick marks the default and an unmodified drag sticks to it briefly.
// - ScrubValue: the number next to the title. Drag it left/right to scrub (⇧ = fine), click to
//   type an exact value (Return commits, Esc cancels, ↑/↓ step, ⇧↑/⇧↓ ×10).
// - ValueSlider: title + ScrubValue + PrecisionTrack, used by every inspector slider.

enum Precision {
    /// Drag speed while ⇧ is held, relative to normal.
    static let fineFactor: Float = 0.1
    /// Sticky zone around the default, as a fraction of the slider span.
    static let snapFraction: Float = 0.006
    /// Number-scrub sensitivity: full span per this many points of drag.
    static let scrubPointsPerSpan: CGFloat = 250

    static var isFine: Bool { NSEvent.modifierFlags.contains(.shift) }
}

// MARK: - Track

struct PrecisionTrack: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    var defaultValue: Float? = nil

    @Environment(\.isEnabled) private var isEnabled
    @State private var drag: DragState?
    @State private var lastTap: (time: TimeInterval, x: CGFloat)?

    private struct DragState {
        var lastX: CGFloat
        var startX: CGFloat
        var raw: Float           // unsnapped value, so you can drag through the sticky default
        var consumed = false     // double-click handled; ignore the rest of this gesture
    }

    private let thumb: CGFloat = 14
    private let trackHeight: CGFloat = 4

    private var span: Float { max(range.upperBound - range.lowerBound, 1e-6) }
    private var anchor: Float {
        if let d = defaultValue, range.contains(d) { return d }
        return range.lowerBound
    }

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width - thumb, 1)
            let x = position(of: value, width: w)
            let ax = position(of: anchor, width: w)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: trackHeight)
                    .padding(.horizontal, thumb / 2)

                // Fill from the default (or the minimum) to the value — bipolar for ±sliders.
                Rectangle()
                    .fill(.tint)
                    .opacity(isEnabled ? 1 : 0.35)
                    .frame(width: abs(x - ax), height: trackHeight)
                    .offset(x: min(x, ax))

                if let d = defaultValue, range.contains(d) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.8))
                        .frame(width: 1, height: 10)
                        .offset(x: position(of: d, width: w) - 0.5)
                }

                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                    .frame(width: thumb, height: thumb)
                    .offset(x: x - thumb / 2)
                    .opacity(isEnabled ? 1 : 0.5)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { g in changed(g, width: w, thumbX: x) }
                    .onEnded { g in ended(g) }
            )
        }
        .frame(height: 20)
        .accessibilityElement()
        .accessibilityValue(Text(String(format: "%.3f", Double(value))))
        .accessibilityAdjustableAction { dir in
            let step = span / 100
            switch dir {
            case .increment: value = clamp(value + step)
            case .decrement: value = clamp(value - step)
            @unknown default: break
            }
        }
    }

    // MARK: Gesture

    private func changed(_ g: DragGesture.Value, width w: CGFloat, thumbX: CGFloat) {
        guard isEnabled else { return }

        guard var d = drag else {
            // Gesture start. Double-click (two quick clicks at the same spot) → reset.
            let now = ProcessInfo.processInfo.systemUptime
            if let t = lastTap, now - t.time < NSEvent.doubleClickInterval,
               abs(g.startLocation.x - t.x) < 5, let def = defaultValue {
                value = clamp(def)
                lastTap = nil
                drag = DragState(lastX: g.location.x, startX: g.startLocation.x, raw: value, consumed: true)
                return
            }
            var start = value
            if abs(g.startLocation.x - thumbX) > thumb * 0.75 {
                start = value(at: g.startLocation.x, width: w)     // click on the track: jump
                value = start
            }
            drag = DragState(lastX: g.location.x, startX: g.startLocation.x, raw: start)
            return
        }
        guard !d.consumed else { return }

        let dx = g.location.x - d.lastX
        d.lastX = g.location.x
        let speed: Float = Precision.isFine ? Precision.fineFactor : 1
        d.raw = clamp(d.raw + Float(dx / w) * span * speed)
        drag = d
        value = snapped(d.raw)
    }

    private func ended(_ g: DragGesture.Value) {
        let wasClick = abs(g.location.x - g.startLocation.x) < 3 && !(drag?.consumed ?? false)
        lastTap = wasClick ? (ProcessInfo.processInfo.systemUptime, g.startLocation.x) : nil
        drag = nil
    }

    // MARK: Helpers

    private func clamp(_ v: Float) -> Float { min(max(v, range.lowerBound), range.upperBound) }

    private func fraction(_ v: Float) -> CGFloat {
        CGFloat((clamp(v) - range.lowerBound) / span)
    }

    private func position(of v: Float, width w: CGFloat) -> CGFloat {
        fraction(v) * w + thumb / 2
    }

    private func value(at px: CGFloat, width w: CGFloat) -> Float {
        let f = min(max((px - thumb / 2) / w, 0), 1)
        return range.lowerBound + Float(f) * span
    }

    /// Sticky default: an unmodified drag rests on the default while within a small zone.
    private func snapped(_ raw: Float) -> Float {
        guard !Precision.isFine, let d = defaultValue,
              abs(raw - d) < span * Precision.snapFraction else { return raw }
        return d
    }
}

// MARK: - Scrubbable / editable number

struct ScrubValue: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    /// Formatted value as shown.
    let text: String
    /// Display multiplier (typed numbers are divided by it).
    var scale: Float = 1

    @Environment(\.isEnabled) private var isEnabled
    @State private var editing = false
    @State private var draft = ""
    @State private var cancelled = false
    @State private var lastX: CGFloat?
    @State private var hovering = false
    @FocusState private var focused: Bool

    private var span: Float { max(range.upperBound - range.lowerBound, 1e-6) }

    var body: some View {
        if editing {
            TextField("", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .frame(width: 84)
                .focused($focused)
                .onAppear { cancelled = false; focused = true }
                .onSubmit { commit() }
                .onExitCommand { cancelled = true; editing = false }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused && editing && !cancelled { commit() }   // click elsewhere commits
                }
                .onKeyPress(.upArrow) { nudge(+1); return .handled }
                .onKeyPress(.downArrow) { nudge(-1); return .handled }
        } else {
            Text(text)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 3)
                .background(hovering && isEnabled ? Color.secondary.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 3))
                .contentShape(Rectangle())
                .onHover { inside in
                    guard isEnabled || !inside else { return }
                    hovering = inside
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .onDisappear { if hovering { NSCursor.pop(); hovering = false } }
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { g in
                            guard isEnabled else { return }
                            let dx = g.location.x - (lastX ?? g.startLocation.x)
                            lastX = g.location.x
                            let speed: Float = Precision.isFine ? Precision.fineFactor : 1
                            value = clamp(value + Float(dx / Precision.scrubPointsPerSpan) * span * speed)
                        }
                        .onEnded { _ in lastX = nil }
                )
                .onTapGesture {
                    guard isEnabled else { return }
                    draft = plain(value)
                    editing = true
                }
                .help("Drag to scrub (hold ⇧ for fine) · click to type a value")
        }
    }

    private func clamp(_ v: Float) -> Float { min(max(v, range.lowerBound), range.upperBound) }

    /// Number only, in display units, for the text field.
    private func plain(_ v: Float) -> String {
        String(format: "%.5g", Double(v * scale))
    }

    private func parse(_ s: String) -> Float? {
        let t = s.replacingOccurrences(of: ",", with: ".")
        guard let r = t.range(of: #"[-+]?(\d+\.?\d*|\.\d+)"#, options: .regularExpression) else { return nil }
        return Float(t[r]).map { $0 / scale }
    }

    private func commit() {
        if let v = parse(draft) { value = clamp(v) }
        editing = false
    }

    private func nudge(_ dir: Float) {
        let base = parse(draft) ?? value
        let step = span / 200 * (Precision.isFine ? 10 : 1)     // ⇧ = big step while typing
        value = clamp(base + dir * step)
        draft = plain(value)
    }
}

// MARK: - Inspector slider row

struct ValueSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let format: String
    /// Display multiplier (e.g. 100 to show −1…1 as −100…100). Formats the shown number only.
    var scale: Float = 1
    /// Reset target for double-click. nil → 0 when the range contains 0, otherwise no reset.
    var defaultValue: Float? = nil
    /// Format for the scaled number (when `scale` ≠ 1). nil → signed integer, e.g. "+25".
    var scaledFormat: String? = nil

    private var resolvedDefault: Float? {
        defaultValue ?? (range.contains(0) ? 0 : nil)
    }

    private var display: String {
        String(format: scale == 1 ? format : (scaledFormat ?? "%+.0f"), Double(value * scale))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .onTapGesture(count: 2) { if let d = resolvedDefault { value = d } }
                    .help(resolvedDefault == nil ? "" : "Double-click to reset")
                Spacer()
                ScrubValue(value: $value, range: range, text: display, scale: scale)
            }
            PrecisionTrack(value: $value, range: range, defaultValue: resolvedDefault)
        }
    }
}
