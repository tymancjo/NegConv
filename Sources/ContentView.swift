import SwiftUI
import simd

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showInspector = true
    @State private var keyMonitor = KeyMonitor()

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            List(model.files, id: \.self, selection: $model.selection) { url in
                HStack(spacing: 8) {
                    FrameThumbnail(url: url)
                        .frame(width: 44, height: 32)
                    Text(url.deletingPathExtension().lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    FrameBadges(url: url)
                }
                .contextMenu { FrameContextMenu(url: url) }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 230)
            .overlay {
                if model.files.isEmpty {
                    ContentUnavailableView {
                        Label("No Roll Open", systemImage: "film")
                    } description: {
                        Text("Choose a folder containing RAW files (NEF, CR2, CR3 or RAF).")
                    } actions: {
                        Button("Open Roll Folder…") { model.chooseFolder() }
                    }
                }
            }
        } detail: {
            Group {
            if model.viewMode == .grid {
                RollGridView()
            } else {
            HStack(spacing: 2) {
            if model.referenceSideBySide {
                ReferencePane()
            }
            GeometryReader { geo in
            ZStack {
                PreviewView(image: model.displayImage, detail: model.detailRequest)
                if model.magnifierTool {
                    MagnifierInteraction(viewSize: geo.size)
                }
                if let oriented = model.orientedImage {
                    switch model.tool {
                    case .crop:
                        CropOverlay(imageSize: oriented.extent.size,
                                    crop: $model.recipe.geometry.crop)
                    case .sampleBase:
                        BaseSampleOverlay(imageSize: oriented.extent.size,
                                          existing: model.orientedBaseRect) { rect in
                            model.sampleBase(orientedRect: rect)
                        }
                    case .spot:
                        SpotOverlay(viewSize: geo.size)
                    case .straighten:
                        StraightenOverlay(imageSize: oriented.extent.size) { a, b in
                            model.straighten(lineFrom: a, to: b)
                        }
                    case .colorPick:
                        if let shown = model.displayImage {
                            WhiteBalanceOverlay(imageSize: shown.extent.size,
                                                message: "Click the colour you want to adjust (e.g. the sky)") { p in
                                model.pickColorBand(at: p)
                            }
                        }
                    case .whiteBalance:
                        if let shown = model.displayImage {
                            WhiteBalanceOverlay(imageSize: shown.extent.size) { p in
                                model.pickWhiteBalance(at: p)
                            }
                        }
                    case .none:
                        EmptyView()
                    }
                }
            }
            }
            }
            }
            }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    if model.showReferenceFlash, model.referenceImage != nil {
                        badge("Reference · \(model.referenceName ?? "")", systemImage: "pin.fill")
                    }
                    if model.showBefore {
                        badge("Before · plain inversion", systemImage: "circle.lefthalf.filled.inverse")
                    }
                    if model.showClipping {
                        badge("Clipping (\(model.exportSettings.format == .jpeg ? "sRGB" : "Adobe RGB")) · red highlights · blue shadows · J to hide",
                              systemImage: "exclamationmark.triangle")
                    }
                }
                .padding(12)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .topTrailing) {
                if model.isDecoding {
                    ProgressView().controlSize(.small).padding(10)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let status = model.exportStatus {
                    HStack(spacing: 8) {
                        if model.isExporting {
                            ProgressView(value: model.exportProgress)
                                .frame(width: 80)
                        } else {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                        Text(status).font(.callout).lineLimit(2)
                        if !model.isExporting {
                            Button("Show in Finder") { model.revealExports() }
                                .disabled(model.lastExportFolder == nil)
                            Button {
                                model.dismissExportStatus()
                            } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(14)
                }
            }
            .overlay(alignment: .bottom) {
                if model.viewMode == .loupe, model.tool == .none, model.orientedImage != nil, !model.recipe.inversion.isReady {
                    Label("Sample the film base (W) to invert", systemImage: "eyedropper")
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(14)
                }
            }
            .overlay {
                if let message = model.errorMessage {
                    Text(message)
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .inspector(isPresented: $showInspector) {
                InspectorView()
                    .inspectorColumnWidth(min: 300, ideal: 360, max: 560)
            }
        }
        .task(id: model.referenceKey) {
            try? await Task.sleep(for: .milliseconds(80))     // coalesce edits of the reference
            guard !Task.isCancelled else { return }
            await model.renderReference()
        }
        .task(id: model.histogramKey) {
            try? await Task.sleep(for: .milliseconds(60))     // coalesce slider drags
            guard !Task.isCancelled else { return }
            model.updateHistogram()
        }
        .sheet(isPresented: $model.isPasteSheetShown) {
            PasteSettingsSheet()
        }
        .sheet(isPresented: $model.isRollInfoShown) {
            RollInfoSheet()
        }
        .sheet(isPresented: $model.isExportSettingsShown) {
            ExportSettingsSheet()
        }
        .onAppear { keyMonitor.start(model) }
        .onDisappear { keyMonitor.stop() }
        .navigationTitle(model.folderURL?.lastPathComponent ?? "NegConv")
        .navigationSubtitle(model.selection?.lastPathComponent ?? "")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("View", selection: $model.viewMode) {
                    Label("Loupe", systemImage: "rectangle").tag(AppModel.ViewMode.loupe)
                    Label("Grid", systemImage: "square.grid.2x2").tag(AppModel.ViewMode.grid)
                }
                .pickerStyle(.segmented)
                .help("Loupe (E) · Grid (G)")
                .disabled(model.files.isEmpty)
            }
            ToolbarItemGroup(placement: .principal) {
                Button { model.rotateCounterClockwise() } label: {
                    Label("Rotate Left", systemImage: "rotate.left")
                }
                .help("Rotate left (⌘[)")
                Button { model.rotateClockwise() } label: {
                    Label("Rotate Right", systemImage: "rotate.right")
                }
                .help("Rotate right (⌘])")
                Button { model.toggleFlip() } label: {
                    Label("Flip", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .help("Flip horizontal (⌘F)")
                Toggle(isOn: toolBinding(.crop)) {
                    Label("Crop", systemImage: "crop")
                }
                .help("Crop (C)")
                Toggle(isOn: toolBinding(.straighten)) {
                    Label("Straighten", systemImage: "level")
                }
                .help("Straighten: draw a line (L)")
                Toggle(isOn: toolBinding(.spot)) {
                    Label("Remove Spots", systemImage: "bandage")
                }
                .help("Remove dust spots (Q)")
                Toggle(isOn: toolBinding(.sampleBase)) {
                    Label("Sample Film Base", systemImage: "eyedropper")
                }
                .help("Sample film base (W)")
                Toggle(isOn: Binding(get: { model.referenceSideBySide },
                                     set: { on in
                                         if on && model.referenceURL == nil { model.setReference() }
                                         model.referenceSideBySide = on && model.referenceURL != nil
                                     })) {
                    Label("Reference Side by Side", systemImage: "rectangle.split.2x1")
                }
                .help("Reference frame side by side · ⇧R pins the current frame · hold R to flash it")
                Toggle(isOn: $model.showClipping) {
                    Label("Show Clipping", systemImage: "exclamationmark.triangle")
                }
                .help("Show clipping in the export colour space (J) · hold \\ for before")
                Toggle(isOn: $model.showNegative) {
                    Label("Show Negative", systemImage: "circle.lefthalf.filled")
                }
                .help("Show negative (⌘\\)")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Section(model.exportSettings.summary) {
                        Button("Export Frame (⌘E)") { model.exportCurrentFrame() }
                        Button("Export Roll — \(model.exportableCount) frames (⇧⌘E)") { model.exportRoll() }
                    }
                    Divider()
                    Button("Export Settings… (⌥⌘E)") { model.isExportSettingsShown = true }
                    Button("Show Exports in Finder") { model.revealExports() }
                        .disabled(model.lastExportFolder == nil)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(model.isExporting || model.files.isEmpty)
                .help("Export: \(model.exportSettings.summary)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.chooseFolder()
                } label: {
                    Label("Open Roll Folder", systemImage: "folder")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
            }
        }
    }

    private func badge(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
    }

    private func toolBinding(_ t: EditTool) -> Binding<Bool> {
        Binding(get: { model.tool == t }, set: { on in model.tool = on ? t : .none })
    }
}

/// Hover tracking, loupe ring, 1:1 double-click and drag-to-pan. Drawn above the Metal view;
/// the magnified pixels themselves are rendered by PreviewView.
struct MagnifierInteraction: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    let viewSize: CGSize

    @State private var panStart: CGPoint?
    @State private var painting = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white.opacity(0.001)
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let p): model.updateHover(p, viewSize: viewSize)
                    case .ended: model.updateHover(nil, viewSize: viewSize)
                    }
                }
                // Spot tool: click adds a spot, ⇧-click a straight stroke from the last one.
                // Otherwise: double-click toggles 1:1.
                .onTapGesture(count: model.tool == .spot ? 1 : 2, coordinateSpace: .local) { p in
                    if model.tool == .spot {
                        if NSEvent.modifierFlags.contains(.shift) {
                            model.addLine(toView: p, viewSize: viewSize)
                        } else {
                            model.addSpot(atView: p, viewSize: viewSize)
                        }
                    } else {
                        model.updateHover(p, viewSize: viewSize)
                        model.toggleActualSize()
                    }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { v in
                            // Spot tool without space: paint a brush stroke.
                            if model.tool == .spot && (painting || (panStart == nil && !model.spaceHeld)) {
                                if !painting {
                                    painting = true
                                    model.beginStroke(atView: v.startLocation, viewSize: viewSize)
                                }
                                model.continueStroke(atView: v.location, viewSize: viewSize)
                                return
                            }
                            // Otherwise (or with space held): pan the 1:1 view.
                            guard model.actualSize else { return }
                            if panStart == nil { panStart = model.actualCenter; NSCursor.closedHand.push() }
                            model.pan(byPoints: v.translation, from: panStart!, displayScale: displayScale)
                        }
                        .onEnded { _ in
                            if painting { model.endStroke(); painting = false }
                            if panStart != nil { NSCursor.pop(); panStart = nil }
                        }
                )

            if model.isLoupeVisible, let p = model.hoverViewPoint {
                let r = AppModel.loupeRadius
                Circle()
                    .stroke(Color.white, lineWidth: 2)
                    .shadow(color: .black.opacity(0.6), radius: 4)
                    .frame(width: 2 * r, height: 2 * r)
                    .position(p)
                    .allowsHitTesting(false)
                zoomBadge(String(format: "%.0f %%", model.loupeZoom * 100))
                    .position(x: p.x, y: p.y + r - 16)
                    .allowsHitTesting(false)
            }

            if model.actualSize {
                zoomBadge(String(format: "%.0f %%  ·  %@  ·  +/− to zoom  ·  Z or Esc to fit",
                                 model.loupeZoom * 100,
                                 model.tool == .spot ? "space + drag to pan" : "drag to pan"))
                    .position(x: viewSize.width / 2, y: 22)
                    .allowsHitTesting(false)
            }

            if model.isLoadingFullRes && (model.actualSize || model.isLoupeVisible) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading full resolution…").font(.callout)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .position(x: viewSize.width / 2, y: viewSize.height - 28)
                .allowsHitTesting(false)
            }
        }
        .frame(width: viewSize.width, height: viewSize.height)
        .onChange(of: model.spaceHeld) { _, held in
            if held { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
    }

    private func zoomBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule())
    }
}

/// The pinned reference frame, rendered once and shown without interaction (left pane).
struct ReferencePane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            PreviewView(image: model.referenceImage, detail: nil)
            if model.referenceImage == nil {
                if model.isRenderingReference {
                    ProgressView().controlSize(.small)
                } else {
                    Text("No reference").foregroundStyle(.secondary)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            Label("Reference · \(model.referenceName ?? "—")", systemImage: "pin.fill")
                .font(.callout)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .padding(12)
        }
        .allowsHitTesting(false)
    }
}
