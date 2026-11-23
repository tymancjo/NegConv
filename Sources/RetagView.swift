import SwiftUI

enum RetagWindow {
    static let id = "retag"
    static let title = "Retag Exports"
}

struct RetagMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Retag Exported Photos…") { openWindow(id: RetagWindow.id) }
    }
}

/// Rewrites the metadata of already-exported scans (Capture One, older NegConv…) so they
/// describe the analog shot instead of the scanning camera. Image data is copied unchanged.
/// Rolls come from the file names (`date_camera_film_roll_frame`); roll fields on the right,
/// rare per-frame overrides in the table.
struct RetagView: View {
    @State private var model = RetagModel()
    @State private var confirmInPlace = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(model.rolls, selection: $model.selectedRoll) { roll in
                let files = model.files(in: roll.id)
                VStack(alignment: .leading, spacing: 2) {
                    Text(roll.title).lineLimit(1)
                    Text("\(files.count) files · \(files.filter(\.include).count) selected")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .overlay {
                if model.folder == nil {
                    ContentUnavailableView {
                        Label("No Folder", systemImage: "photo.on.rectangle.angled")
                    } description: {
                        Text("Choose a folder of exported JPEG or TIFF scans.")
                    } actions: {
                        Button("Choose Folder…") { model.chooseFolder() }
                    }
                } else if model.isLoading {
                    ProgressView()
                }
            }
        } content: {
            RetagFileTable(model: model)
                .navigationSplitViewColumnWidth(min: 560, ideal: 820)
        } detail: {
            RetagRollPanel(model: model)
                .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 480)
        }
        .navigationSubtitle(model.folder?.lastPathComponent ?? "")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.chooseFolder() } label: {
                    Label("Choose Folder", systemImage: "folder")
                }
                .help("Choose a folder of exported scans")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 12) {
                    Picker("Write", selection: $model.inPlace) {
                        Text("Copies in “\(RetagModel.outputFolderName)” folder").tag(false)
                        Text("Replace originals").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .fixedSize()
                    .disabled(model.isWriting)

                    Spacer()
                    if let status = model.status {
                        Text(status).font(.callout).lineLimit(2)
                            .foregroundStyle(.secondary)
                    }
                    if model.isWriting {
                        ProgressView(value: model.progress).frame(width: 90)
                    } else if model.status?.hasPrefix("Retagged") == true {
                        Button("Show in Finder") { model.revealOutput() }
                    }
                    Button("Retag \(model.includedCount) File\(model.includedCount == 1 ? "" : "s")") {
                        if model.inPlace { confirmInPlace = true } else { model.run() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isWriting || model.includedCount == 0)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .background(.bar)
        }
        .confirmationDialog("Replace the metadata of \(model.includedCount) original files?",
                            isPresented: $confirmInPlace) {
            Button("Replace Originals", role: .destructive) { model.run() }
        } message: {
            Text("All existing metadata (scan camera, Capture One captions, XMP) is removed and replaced. The image data itself is copied unchanged. This can't be undone.")
        }
    }
}

// MARK: - Table

private struct RetagFileTable: View {
    @Bindable var model: RetagModel

    var body: some View {
        let rows = model.files(in: model.selectedRoll)
        let roll = model.roll?.meta ?? RollMetadata()
        VStack(spacing: 0) {
            if let r = model.roll {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("New: " + summary(r.meta)).font(.callout)
                        Text("Frames in roll order · date = roll date 12:00 + frame index s unless set per frame")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("All") { model.setInclude(true, roll: r.id) }
                    Button("None") { model.setInclude(false, roll: r.id) }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
            }
            Table(rows) {
                TableColumn("") { f in
                    HStack(spacing: 6) {
                        Toggle("", isOn: model.includeBinding(f.id)).labelsHidden()
                        ThumbnailImage(image: model.thumbnails.images[f.url])
                            .frame(width: 48, height: 34)
                    }
                }
                .width(84)
                TableColumn("File") { f in
                    HStack(spacing: 4) {
                        statusIcon(f.status)
                        Text(f.name).lineLimit(1).truncationMode(.middle)
                        if f.isNegConv {
                            Text("NegConv").font(.caption2)
                                .padding(.horizontal, 4)
                                .background(Color.accentColor.opacity(0.2), in: Capsule())
                                .help("Already tagged by NegConv — skipped unless you tick it")
                        }
                    }
                    .help(statusText(f.status) ?? f.name)
                }
                .width(min: 160, ideal: 230)
                TableColumn("Scanned") { f in
                    Text(f.scanDate?.formatted(date: .omitted, time: .standard) ?? "—")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                .width(70)
                TableColumn("Now") { f in
                    Text(f.current).lineLimit(1).foregroundStyle(.secondary)
                        .help(f.software.isEmpty ? f.current : "\(f.current) · \(f.software)")
                }
                .width(min: 110, ideal: 160)
                TableColumn("f/") { f in
                    TextField("", value: model.metaBinding(f.id).aperture, format: .number,
                              prompt: Text("—"))
                }
                .width(40)
                TableColumn("Shutter") { f in
                    TextField("", text: model.metaBinding(f.id).shutter, prompt: Text("—"))
                }
                .width(56)
                TableColumn("Lens") { f in
                    TextField("", text: model.metaBinding(f.id).lens,
                              prompt: Text(roll.lens.isEmpty ? "roll lens" : roll.lens))
                }
                .width(min: 90, ideal: 140)
                TableColumn("Date & time") { f in
                    OptionalDatePicker(title: "", date: model.metaBinding(f.id).date,
                                       components: [.date, .hourAndMinute])
                }
                .width(min: 150, ideal: 190)
                TableColumn("Caption") { f in
                    TextField("", text: model.metaBinding(f.id).caption, prompt: Text("—"))
                }
                .width(min: 90, ideal: 160)
            }
            .overlay {
                if model.folder != nil, !model.isLoading, rows.isEmpty {
                    Text("No files").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func summary(_ m: RollMetadata) -> String {
        var parts = [m.cameraSummary, m.filmSummary]
        if let d = m.date { parts.append(d.formatted(date: .abbreviated, time: .omitted)) }
        let s = parts.filter { !$0.isEmpty }.joined(separator: " · ")
        return s.isEmpty ? "nothing set — the scan data is removed, no analog data written" : s
    }

    @ViewBuilder private func statusIcon(_ s: RetagFile.Status) -> some View {
        switch s {
        case .pending: EmptyView()
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private func statusText(_ s: RetagFile.Status) -> String? {
        switch s {
        case .pending: nil
        case .done(let t), .warning(let t), .failed(let t): t
        }
    }
}

// MARK: - Roll panel

private struct RetagRollPanel: View {
    @Bindable var model: RetagModel

    var body: some View {
        if let roll = model.roll {
            Form {
                Section {
                    LabeledContent("Roll", value: roll.title)
                    if !roll.cameraCode.isEmpty {
                        LabeledContent("Camera code", value: roll.cameraCode)
                    }
                } footer: {
                    Text(roll.cameraCode.isEmpty
                         ? "Written into every selected file of this roll."
                         : "Make and model you set here are remembered for “\(roll.cameraCode)”.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                RollMetadataSections(meta: model.rollMetaBinding(roll.id))
            }
            .formStyle(.grouped)
        } else {
            Text("Choose a roll").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
