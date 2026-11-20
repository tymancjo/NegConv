import SwiftUI
import simd

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            HistogramView(histogram: model.histogram)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 2)

            Form {
                RawDecodeSection()

                Section("Geometry") {
                    HStack {
                        Button { model.rotateCounterClockwise() } label: { Image(systemName: "rotate.left") }
                            .help("Rotate left (⌘[)")
                        Button { model.rotateClockwise() } label: { Image(systemName: "rotate.right") }
                            .help("Rotate right (⌘])")
                        Toggle("Flip", isOn: Binding(get: { model.recipe.geometry.flipHorizontal },
                                                     set: { _ in model.toggleFlip() }))
                            .toggleStyle(.button)
                        Spacer()
                        Toggle("Crop", isOn: Binding(get: { model.tool == .crop },
                                                     set: { model.tool = $0 ? .crop : .none }))
                            .toggleStyle(.button)
                    }
                    HStack {
                        Text("Straighten")
                        Spacer()
                        Toggle(isOn: Binding(get: { model.tool == .straighten },
                                             set: { model.tool = $0 ? .straighten : .none })) {
                            Label("Draw Line", systemImage: "level")
                        }
                        .toggleStyle(.button)
                        .help("Draw along a horizon or vertical edge (⌘L)")
                        Button("0°") { model.setStraighten(0) }
                            .help("Reset straighten")
                    }
                    ValueSlider(title: "Angle",
                                value: Binding(get: { model.recipe.geometry.straighten },
                                               set: { model.setStraighten($0) }),
                                range: -10...10, format: "%+.2f°")
                    LabeledContent("Rotation", value: "\(model.recipe.geometry.quarterTurns * 90)°")
                    if let size = model.outputPixelSize {
                        LabeledContent("Output", value: "\(Int(size.width)) × \(Int(size.height)) px")
                    }
                    HStack {
                        Button("Reset Crop") { model.resetCrop() }
                        Button("Reset All") { model.resetGeometry() }
                    }
                }

                InversionSection()
                RollSection()
                ReferenceSection()
                ExposureSection()
                PaperSection()
                LevelsSection()
                CurvesSection()
                ColorMixSection()
                PresenceSection()
                SharpenSection()
                SpotSection()
                ShootingDataSection()

                Section("Scan Info") {
                    if let p = model.preview {
                        LabeledContent("Scan camera", value: p.camera)
                        LabeledContent("Sensor",
                                       value: "\(Int(p.nativeSize.width)) × \(Int(p.nativeSize.height))")
                        LabeledContent("Preview",
                                       value: "\(Int(p.image.extent.width)) × \(Int(p.image.extent.height)) (×\(String(format: "%.2f", Double(p.scale))))")
                        LabeledContent("Decode time", value: String(format: "%.0f ms", p.seconds * 1000))
                    } else {
                        Text("No image").foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

// MARK: - Exposure & white balance

struct ExposureSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Section {
            ValueSlider(title: "Exposure", value: $model.recipe.tone.exposureEV,
                        range: -3...3, format: "%+.2f EV")

            HStack {
                Text("White Balance")
                Spacer()
                Toggle(isOn: Binding(get: { model.tool == .whiteBalance },
                                     set: { model.tool = $0 ? .whiteBalance : .none })) {
                    Label("Pick Neutral", systemImage: "eyedropper.halffull")
                }
                .toggleStyle(.button)
                .help("Click something that should be neutral grey")
            }
            ValueSlider(title: "Temperature", value: $model.recipe.tone.temperature,
                        range: -1...1, format: "%+.2f", scale: 100)
            ValueSlider(title: "Tint", value: $model.recipe.tone.tint,
                        range: -1...1, format: "%+.2f", scale: 100)

            HStack {
                Spacer()
                Button("Reset Exposure & WB") { model.resetExposureWB() }
            }
        } header: {
            Text("Exposure & White Balance")
        } footer: {
            Text("Linear-light gain, applied before the paper curve.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!model.recipe.inversion.isReady)
    }
}

// MARK: - Levels

struct LevelsSection: View {
    @Environment(AppModel.self) private var model
    @State private var levelsChannel = 0     // 0 = RGB master, 1…3 = R, G, B

    var body: some View {
        @Bindable var model = model

        Section {
            Picker("Channel", selection: $levelsChannel) {
                Text("RGB").tag(0)
                Text("R").tag(1)
                Text("G").tag(2)
                Text("B").tag(3)
            }
            .pickerStyle(.segmented)

            let binding = levelsBinding(levelsChannel)
            ValueSlider(title: "Black", value: binding.black, range: -0.2...0.6, format: "%.3f")
            ValueSlider(title: "Midtone", value: binding.gamma, range: 0.3...3.0, format: "%.2f", defaultValue: 1)
            ValueSlider(title: "White", value: binding.white, range: 0.4...1.5, format: "%.3f", defaultValue: 1)

            HStack {
                Spacer()
                Button("Reset Levels") { model.recipe.tone.levels = Levels() }
            }
        } header: {
            Text("Levels")
        } footer: {
            Text("After the paper curve, on γ 2.2 values; per-channel levels first, then RGB.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!model.recipe.inversion.isReady)
    }

    private func levelsBinding(_ ch: Int) -> Binding<ChannelLevels> {
        Binding(
            get: {
                let l = model.recipe.tone.levels
                return [l.master, l.red, l.green, l.blue][ch]
            },
            set: { v in
                switch ch {
                case 1: model.recipe.tone.levels.red = v
                case 2: model.recipe.tone.levels.green = v
                case 3: model.recipe.tone.levels.blue = v
                default: model.recipe.tone.levels.master = v
                }
            })
    }
}

// MARK: - RAW decode (per roll)

struct RawDecodeSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage("rawDecodeExpanded") private var expanded = false

    var body: some View {
        @Bindable var model = model

        Section {
            DisclosureGroup(isExpanded: $expanded) {
                ValueSlider(title: "Temperature", value: $model.rollDecode.temperature,
                            range: 2000...10000, format: "%.0f K", defaultValue: 5500)
                ValueSlider(title: "Tint", value: $model.rollDecode.tint,
                            range: -150...150, format: "%+.0f")
                ValueSlider(title: "Exposure", value: $model.rollDecode.exposureEV,
                            range: -3...3, format: "%+.2f EV")
                Button("Reset Decode Settings") { model.rollDecode = DecodeSettings() }
                Toggle("Compare: Apple default decode", isOn: $model.compareAppleDefault)
            } label: {
                HStack {
                    Text("RAW Decode — fixed per roll")
                    Spacer()
                    Text(String(format: "%.0f K · %+.0f · %+.2f EV",
                                model.rollDecode.temperature, model.rollDecode.tint,
                                model.rollDecode.exposureEV))
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            if expanded {
                Text("Linear decode, no tone curve, sharpening or noise reduction. Only sets headroom before inversion — keep it fixed for the roll.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Paper

struct PaperSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let paper = model.recipe.paper

        Section {
            Toggle("Print on paper", isOn: $model.recipe.paper.enabled)

            Group {
                PaperCurveView(paper: paper)
                    .frame(height: 96)

                HStack(spacing: 6) {
                    Text("Grade").foregroundStyle(.secondary)
                    presetButton("Soft", Paper.soft.grade)
                    presetButton("Normal", Paper.normal.grade)
                    presetButton("Hard", Paper.hard.grade)
                    Spacer()
                    Menu("Surface") {
                        Button("Glossy (D 2.05)") { model.recipe.paper.blackDensity = 2.05 }
                        Button("Satin (D 1.85)") { model.recipe.paper.blackDensity = 1.85 }
                        Button("Matte (D 1.60)") { model.recipe.paper.blackDensity = 1.60 }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .controlSize(.small)

                ValueSlider(title: "Contrast (grade)", value: $model.recipe.paper.grade,
                            range: 0.6...2.4, format: "%.2f", defaultValue: Paper().grade)
                ValueSlider(title: "Paper black", value: $model.recipe.paper.blackDensity,
                            range: 1.2...2.4, format: "D %.2f", defaultValue: Paper().blackDensity)
                ValueSlider(title: "Highlight roll-off", value: $model.recipe.paper.shoulder,
                            range: 0.05...0.8, format: "%.2f", defaultValue: Paper().shoulder)
                ValueSlider(title: "Shadow roll-off", value: $model.recipe.paper.toe,
                            range: 0.1...1.5, format: "%.2f", defaultValue: Paper().toe)

                HStack {
                    Text(String(format: "Input white → %.0f %%   ·   black %.1f %%",
                                Double(paper.map(1) * 100), Double(expf(paper.lnBlack) * 100)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") {
                        model.recipe.paper = Paper(enabled: model.recipe.paper.enabled)
                    }
                    .disabled(paper == Paper(enabled: paper.enabled))
                }
            }
            .disabled(!paper.enabled)
        } header: {
            Text("Paper")
        } footer: {
            Text("A print curve after exposure & white balance, before levels: contrast pivots on mid-grey, highlights roll into paper white instead of clipping, shadows into the paper's black (glossy deep, matte lifted). Set brightness with Exposure.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!model.recipe.inversion.isReady)
    }

    private func presetButton(_ title: String, _ grade: Float) -> some View {
        Button(title) { model.recipe.paper.grade = grade }
            .buttonStyle(.bordered)
            .tint(abs(model.recipe.paper.grade - grade) < 0.005 ? .accentColor : nil)
    }
}

/// Tone curve of the paper stage, drawn in γ 2.2 (perceptual) coordinates: input → output,
/// with the identity diagonal for reference.
struct PaperCurveView: View {
    let paper: Paper

    var body: some View {
        Canvas { ctx, size in
            let r = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            ctx.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(.secondary.opacity(0.35)), lineWidth: 0.5)
            for f in [0.25, 0.5, 0.75] {
                var g = Path()
                g.move(to: CGPoint(x: r.minX + f * r.width, y: r.minY))
                g.addLine(to: CGPoint(x: r.minX + f * r.width, y: r.maxY))
                g.move(to: CGPoint(x: r.minX, y: r.minY + f * r.height))
                g.addLine(to: CGPoint(x: r.maxX, y: r.minY + f * r.height))
                ctx.stroke(g, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
            }
            var diag = Path()
            diag.move(to: CGPoint(x: r.minX, y: r.maxY))
            diag.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            ctx.stroke(diag, with: .color(.secondary.opacity(0.4)), style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))

            var curve = Path()
            let n = 96
            for i in 0...n {
                let e = Float(i) / Float(n)                       // γ-encoded input
                let out = powf(max(paper.map(powf(e, 2.2)), 0), 1 / 2.2)
                let p = CGPoint(x: r.minX + CGFloat(e) * r.width,
                                y: r.maxY - CGFloat(min(out, 1)) * r.height)
                if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
            }
            ctx.stroke(curve, with: .color(.accentColor), lineWidth: 1.5)
        }
        .opacity(paper.enabled ? 1 : 0.4)
        .accessibilityLabel("Paper tone curve")
    }
}

// MARK: - Presence

struct PresenceSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Section {
            ValueSlider(title: "Vibrance", value: $model.recipe.presence.vibrance,
                        range: -1...1, format: "", scale: 100)
            ValueSlider(title: "Saturation", value: $model.recipe.presence.saturation,
                        range: -1...1, format: "", scale: 100)
            HStack {
                Spacer()
                Button("Reset") { model.recipe.presence = Presence() }
                    .disabled(model.recipe.presence.isIdentity)
            }
        } header: {
            Text("Presence")
        } footer: {
            Text("Colour intensity in OkLab: brightness stays put. Vibrance favours muted colours and protects skin tones; Saturation −100 gives black & white.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!model.recipe.inversion.isReady)
    }
}

// MARK: - Sharpen

struct SharpenSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Section {
            ValueSlider(title: "Amount", value: $model.recipe.sharpen.amount,
                        range: 0...3, format: "", scale: 100, defaultValue: 0,
                        scaledFormat: "%.0f %%")
            ValueSlider(title: "Radius", value: $model.recipe.sharpen.radius,
                        range: Sharpen.radiusRange, format: "%.1f px", defaultValue: Sharpen().radius)
            ValueSlider(title: "Threshold", value: $model.recipe.sharpen.threshold,
                        range: 0...20, format: "%.0f", defaultValue: Sharpen().threshold)
            HStack {
                if model.recipe.sharpen.amount > 0 && !model.actualSize {
                    Label("Judge at 1:1 (Z or loupe)", systemImage: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset") { model.recipe.sharpen = Sharpen() }
                    .disabled(model.recipe.sharpen == Sharpen())
            }
        } header: {
            Text("Sharpen")
        } footer: {
            Text("Luminance-only unsharp mask, applied last. Radius is in full-resolution pixels (≈ 0.6–1 for D810, 0.8–1.2 for D750). Threshold leaves grain and smooth areas alone; raise it if grain gets gritty.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!model.recipe.inversion.isReady)
    }
}

// MARK: - Colour mixer

struct ColorMixSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let band = model.selectedColorBand
        let i = band.rawValue

        Section {
            HStack(spacing: 6) {
                ForEach(ColorMix.Band.allCases) { b in
                    Button {
                        model.selectedColorBand = b
                    } label: {
                        Circle()
                            .fill(Color(hue: b.centre / 360, saturation: 0.85, brightness: 0.9))
                            .frame(width: 18, height: 18)
                            .overlay(Circle().stroke(b == band ? Color.primary : .clear, lineWidth: 2).padding(-3))
                            .overlay(alignment: .bottomTrailing) {
                                if model.recipe.color.isModified(b) {
                                    Circle().fill(Color.primary).frame(width: 5, height: 5).offset(x: 3, y: 3)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(b.name)
                }
                Spacer()
                Toggle(isOn: Binding(get: { model.tool == .colorPick },
                                     set: { model.tool = $0 ? .colorPick : .none })) {
                    Image(systemName: "eyedropper")
                }
                .toggleStyle(.button)
                .help("Click a colour in the image to select its band")
            }
            .padding(.vertical, 2)

            HStack {
                Text(band.name).fontWeight(.medium)
                if let h = model.lastPickedHue, ColorMix.Band.nearest(to: h) == band {
                    Text(String(format: "picked %.0f°", h)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset \(band.name)") { model.recipe.color.reset(band) }
                    .disabled(!model.recipe.color.isModified(band))
            }

            VStack(alignment: .leading, spacing: 2) {
                ValueSlider(title: "Hue", value: $model.recipe.color.hue[i], range: -30...30, format: "%+.1f°")
                // Where the hue goes: left end = slider at −30°, right end = +30°.
                LinearGradient(colors: stride(from: -30.0, through: 30.0, by: 10).map {
                    Color(hue: ((band.centre + $0 + 360).truncatingRemainder(dividingBy: 360)) / 360,
                          saturation: 0.75, brightness: 0.9)
                }, startPoint: .leading, endPoint: .trailing)
                .frame(height: 4)
                .clipShape(Capsule())
            }
            ValueSlider(title: "Saturation", value: $model.recipe.color.saturation[i],
                        range: -1...1, format: "", scale: 100)
            ValueSlider(title: "Luminance", value: $model.recipe.color.luminance[i],
                        range: -1...1, format: "", scale: 100)

            HStack {
                Spacer()
                Button("Reset All Colours") { model.recipe.color = ColorMix() }
                    .disabled(model.recipe.color.isIdentity)
            }
        } header: {
            Text("Colour Mixer")
        } footer: {
            Text("Per-colour hue, saturation and luminance. Neutral greys are protected. For a greener sky: pick Blue, move Hue left (towards aqua).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!model.recipe.inversion.isReady)
    }
}

// MARK: - Spots

struct SpotSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            HStack {
                Toggle(isOn: Binding(get: { model.tool == .spot },
                                     set: { model.tool = $0 ? .spot : .none })) {
                    Label("Remove Spots", systemImage: "bandage")
                }
                .toggleStyle(.button)
                .help("⌘J — click specks on the image")
                Spacer()
                Text("\(model.recipe.spots.count) spot\(model.recipe.spots.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack(spacing: 8) {
                Text("Size").foregroundStyle(.secondary)
                Slider(value: Binding(get: { log2(Double(model.brushRadius)) },
                                      set: { model.brushRadius = CGFloat(pow(2, $0)) }),
                       in: log2(0.0008)...log2(0.05))
                Text(String(format: "%.0f px", Double(model.brushRadius)
                            * Double(model.preview.map { max($0.nativeSize.width, $0.nativeSize.height) } ?? 7360)))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
            HStack {
                Button("Re-pick Source") { model.reAutoSourceSelected() }
                    .disabled(model.selectedSpotID == nil)
                Button("Delete") { model.deleteSelectedSpot() }
                    .disabled(model.selectedSpotID == nil)
                Spacer()
                Button("Clear All", role: .destructive) { model.clearSpots() }
                    .disabled(model.recipe.spots.isEmpty)
            }
        } header: {
            Text("Spot Removal")
        } footer: {
            Text("Each spot copies a nearby patch (picked automatically by matching texture and brightness) with a soft edge. Spots stay attached to the film when you rotate or re-crop. Size shown as radius in full-resolution pixels.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!model.recipe.inversion.isReady)
    }
}

// MARK: - Inversion

struct InversionSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let inv = model.recipe.inversion

        Section {
            HStack {
                Toggle(isOn: Binding(get: { model.tool == .sampleBase },
                                     set: { model.tool = $0 ? .sampleBase : .none })) {
                    Label("Sample Base", systemImage: "eyedropper")
                }
                .toggleStyle(.button)
                Spacer()
                Toggle("Negative", isOn: $model.showNegative).toggleStyle(.button)
            }

            if let base = inv.base {
                LabeledContent("Film base") {
                    HStack(spacing: 6) {
                        Text(rgb(base, "%.3f")).monospacedDigit()
                        RoundedRectangle(cornerRadius: 3)
                            .fill(swatch(base))
                            .frame(width: 18, height: 12)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary, lineWidth: 0.5))
                    }
                }
                HStack {
                    Text(baseSource).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if inv.baseRect != nil, !model.isRollBaseFrame {
                        Button("Use for Whole Roll") { model.useBaseForRoll() }
                            .help("Frames without their own base sample use this one")
                    }
                    if inv.baseRect != nil {
                        if model.rollBase != nil && !model.isRollBaseFrame {
                            Button("Use Roll Base") { model.clearBase() }
                                .help("Drop this frame's own sample and use the roll base")
                        } else {
                            Button("Clear", role: .destructive) { model.clearBase() }
                        }
                    }
                }
                ValueSlider(title: "Range", value: $model.recipe.inversion.range,
                            range: 1.0...3.0, format: "%.2f D", defaultValue: 2)

                Picker("Points", selection: Binding(get: { inv.pointSource },
                                                    set: { model.setPointSource($0) })) {
                    ForEach(PointSource.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Where the automatic black/white points come from")

                HStack {
                    Text(pointsStatus(inv))
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(inv.autoPoints ? Color.green.opacity(0.2) : Color.orange.opacity(0.25),
                                    in: Capsule())
                    Spacer()
                    Button(inv.autoPoints ? "Re-measure" : "Back to Auto") { model.remeasurePoints() }
                        .help("Return to automatic black/white points")
                }
                ForEach(0..<3, id: \.self) { c in
                    channelPoints(c)
                }
            } else if inv.baseRect != nil || model.rollBase != nil {
                Text("Measuring…").foregroundStyle(.secondary)
            } else {
                Text("Not sampled").foregroundStyle(.secondary)
            }
        } header: {
            Text("Inversion")
        } footer: {
            Text("Points — Frame: this frame's 0.3 % / 99.7 % densities. Roll: the whole roll's. Roll colour: colour balance from the roll, fitted to the frame's range so no channel clips — neighbouring frames match. Editing a density slider switches to manual.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var baseSource: String {
        let inv = model.recipe.inversion
        if inv.baseRect == nil, let rb = model.rollBase {
            return "Roll base · from \((rb.frame as NSString).deletingPathExtension)"
        }
        return model.isRollBaseFrame ? "This frame · roll base" : "This frame"
    }

    private func pointsStatus(_ inv: Inversion) -> String {
        guard inv.autoPoints else { return "Manual" }
        if inv.pointSource != .frame {
            switch model.rollAnalysisState {
            case .none: return "Auto · roll not analysed, using frame"
            case .stale: return "Auto · roll analysis out of date"
            case .current: break
            }
        }
        return "Auto"
    }

    private func channelPoints(_ c: Int) -> some View {
        let name = ["Red", "Green", "Blue"][c]
        let tint: Color = [.red, .green, .blue][c]
        let inv = model.recipe.inversion
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text(name).fontWeight(.medium)
            }
            densityRow("Black", value: inv.dBlack[c], range: 0...1.5) {
                model.setDensityPoint(white: false, channel: c, value: $0)
            }
            densityRow("White", value: inv.dWhite[c], range: 0.3...3.0) {
                model.setDensityPoint(white: true, channel: c, value: $0)
            }
        }
        .tint(tint)
    }

    /// Full-width slider row: label, slider, value.
    private func densityRow(_ label: String, value: Float, range: ClosedRange<Float>,
                            set: @escaping (Float) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
            let binding = Binding(get: { value }, set: set)
            PrecisionTrack(value: binding, range: range)
            ScrubValue(value: binding, range: range, text: String(format: "%.3f", Double(value)))
                .font(.callout)
                .frame(minWidth: 46, alignment: .trailing)
        }
    }

    private func rgb(_ v: SIMD3<Float>, _ f: String) -> String {
        "\(String(format: f, Double(v.x)))  \(String(format: f, Double(v.y)))  \(String(format: f, Double(v.z)))"
    }

    /// Rough display swatch: normalise to the brightest channel, then sRGB-ish gamma.
    private func swatch(_ v: SIMD3<Float>) -> Color {
        let m = max(v.max(), 1e-6)
        let g = { (x: Float) in Double(powf(max(x / m, 0), 1 / 2.2)) }
        return Color(red: g(v.x), green: g(v.y), blue: g(v.z))
    }
}

// MARK: - Roll analysis

struct RollSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cands = model.analysisCandidates()
        Section {
            HStack {
                Image(systemName: icon).foregroundStyle(iconColor)
                Text(status)
                Spacer()
            }
            .font(.callout)

            Text(counts(cands)).font(.caption).foregroundStyle(.secondary)

            if model.isAnalysing {
                HStack {
                    ProgressView(value: model.analysisProgress)
                    Button("Cancel") { model.cancelAnalysis() }
                }
            } else {
                HStack {
                    Button(model.rollAnalysis == nil ? "Analyse Roll" : "Re-analyse") { model.analyseRoll() }
                        .disabled(cands.frames.isEmpty)
                    Spacer()
                    if let url = model.selection {
                        Toggle("Exclude frame", isOn: Binding(get: { model.isExcluded(url) },
                                                              set: { _ in model.toggleExcluded(url) }))
                            .toggleStyle(.button)
                            .help("Leave this frame out of the roll analysis (blank frames, test shots)")
                    }
                }
            }

            if let a = model.rollAnalysis {
                LabeledContent("Roll black D", value: rgb(a.dBlack)).monospacedDigit()
                LabeledContent("Roll white D", value: rgb(a.dWhite)).monospacedDigit()
            }
        } header: {
            Text("Roll")
        } footer: {
            Text("Pools the densities of all cropped frames into one black/white point set. Uncropped frames are skipped: rebate and holder would distort it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var status: String {
        if model.isAnalysing { return "Analysing…" }
        switch model.rollAnalysisState {
        case .none: return "Not analysed"
        case .stale: return "Out of date — re-analyse"
        case .current:
            let d = model.rollAnalysis.map { $0.date.formatted(date: .omitted, time: .shortened) } ?? ""
            return "Analysed \(d)"
        }
    }

    private var icon: String {
        switch model.rollAnalysisState {
        case .none: "circle.dashed"
        case .stale: "exclamationmark.triangle"
        case .current: "checkmark.circle"
        }
    }

    private var iconColor: Color {
        switch model.rollAnalysisState {
        case .none: .secondary
        case .stale: .orange
        case .current: .green
        }
    }

    private func counts(_ c: (frames: [AppModel.AnalysisCandidate], uncropped: Int, noBase: Int)) -> String {
        var parts = ["\(c.frames.count) frame\(c.frames.count == 1 ? "" : "s") to analyse"]
        if !model.rollExcluded.isEmpty { parts.append("\(model.rollExcluded.count) excluded") }
        if c.uncropped > 0 { parts.append("\(c.uncropped) not cropped") }
        if c.noBase > 0 { parts.append("\(c.noBase) without base") }
        return parts.joined(separator: " · ")
    }

    private func rgb(_ v: SIMD3<Float>) -> String {
        String(format: "%.3f  %.3f  %.3f", Double(v.x), Double(v.y), Double(v.z))
    }
}

// MARK: - Controls

// ValueSlider lives in PrecisionSlider.swift.

/// C5: pin a finished frame and match others against it by eye (side by side / hold R) or by
/// white balance.
struct ReferenceSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            HStack {
                Image(systemName: model.referenceURL == nil ? "pin.slash" : "pin.fill")
                    .foregroundStyle(.secondary)
                Text(model.referenceName.map { model.isReferenceFrame ? "\($0) (this frame)" : $0 } ?? "None")
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if model.isRenderingReference { ProgressView().controlSize(.small) }
            }
            .font(.callout)
            HStack {
                Button(model.isReferenceFrame ? "Pinned" : "Pin This Frame") { model.setReference() }
                    .disabled(model.isReferenceFrame || model.selection == nil)
                    .help("Use this frame as the reference (⇧R)")
                Spacer()
                Toggle("Side by Side", isOn: $model.referenceSideBySide)
                    .toggleStyle(.button)
                    .disabled(model.referenceURL == nil)
                    .help("Show the reference next to this frame (⌥⌘R)")
            }
            HStack {
                Button("Match WB to Reference") { model.matchWhiteBalanceToReference() }
                    .disabled(!model.canMatchReference)
                    .help("Set temperature/tint so this frame's neutral midtones match the reference (⇧⌥⌘W)")
                Spacer()
                Button("Clear") { model.clearReference() }
                    .disabled(model.referenceURL == nil)
            }
        } header: {
            Text("Reference")
        } footer: {
            Text("Hold R to flash the reference in place of this frame — best for judging casts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
