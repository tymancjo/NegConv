import SwiftUI

/// Lightroom-style contact sheet of the roll, shown in place of the preview (G; E or
/// double-click / Return back to the loupe). Tiles show the edited positive when a frame has
/// a film base (its own or the roll's), otherwise the camera's embedded negative.
struct RollGridView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("gridTileSize") private var tileSize: Double = 190

    private let spacing: CGFloat = 12
    private let padding: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize), spacing: spacing)],
                                  spacing: spacing) {
                            ForEach(Array(model.files.enumerated()), id: \.element) { i, url in
                                GridTile(url: url, number: i + 1, height: tileSize * 0.72)
                                    .id(url)
                                    .onTapGesture(count: 2) {
                                        model.selection = url
                                        model.viewMode = .loupe
                                    }
                                    .simultaneousGesture(TapGesture().onEnded { model.selection = url })
                                    .contextMenu { FrameContextMenu(url: url) }
                            }
                        }
                        .padding(padding)
                    }
                    .onAppear {
                        updateColumns(width: geo.size.width)
                        if let s = model.selection { proxy.scrollTo(s, anchor: .center) }
                    }
                    .onChange(of: model.selection) { _, s in
                        if let s { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(s) } }
                    }
                    .onChange(of: geo.size.width) { _, w in updateColumns(width: w) }
                    .onChange(of: tileSize) { _, _ in updateColumns(width: geo.size.width) }
                }
            }

            Divider()
            HStack(spacing: 8) {
                Text("\(model.files.count) frames · \(model.editedCount) edited")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text("E or double-click to edit · arrows to move")
                    .font(.caption).foregroundStyle(.tertiary)
                Image(systemName: "square.grid.3x3").foregroundStyle(.secondary)
                Slider(value: $tileSize, in: 110...380)
                    .frame(width: 150)
                    .controlSize(.small)
                Image(systemName: "square.grid.2x2").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)
        }
    }

    /// Same arithmetic as the adaptive grid: as many tiles of at least `tileSize` as fit.
    private func updateColumns(width: CGFloat) {
        let usable = width - 2 * padding + spacing
        model.gridColumns = max(1, Int(usable / (CGFloat(tileSize) + spacing)))
    }
}

private struct GridTile: View {
    @Environment(AppModel.self) private var model
    let url: URL
    let number: Int
    let height: Double

    var body: some View {
        let selected = model.selection == url
        VStack(spacing: 6) {
            FrameThumbnail(url: url)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .opacity(model.isExcluded(url) ? 0.45 : 1)
            HStack(spacing: 4) {
                Text("\(number)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                FrameBadges(url: url)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(selected ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
    }
}

/// A frame's thumbnail (aspect fit), or a spinner while it is being made.
struct FrameThumbnail: View {
    @Environment(AppModel.self) private var model
    let url: URL

    var body: some View {
        ThumbnailImage(image: model.thumbnails.images[url])
    }
}

/// Shared by the main window and the Retag window.
struct ThumbnailImage: View {
    let image: CGImage?

    var body: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            ZStack {
                Color.secondary.opacity(0.06)
                ProgressView().controlSize(.small)
            }
        }
    }
}

/// Status icons of a frame: excluded, reference, roll-base frame, edited.
struct FrameBadges: View {
    @Environment(AppModel.self) private var model
    let url: URL

    var body: some View {
        HStack(spacing: 4) {
            if model.isExcluded(url) {
                Image(systemName: "minus.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Excluded from roll analysis")
            }
            if model.referenceName == url.lastPathComponent {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Reference frame")
            }
            if model.rollBase?.frame == url.lastPathComponent {
                Image(systemName: "eyedropper")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Roll base sampled here")
            }
            if let r = model.recipes[url], r.inversion.baseRect != nil || r.inversion.base != nil {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .help("Edited")
            }
        }
    }
}

struct FrameContextMenu: View {
    @Environment(AppModel.self) private var model
    let url: URL

    var body: some View {
        Button("Paste Settings Here") { model.pasteSettings(into: url) }
            .disabled(model.clipboard == nil)
        Button("Set as Reference") { model.selection = url; model.setReference() }
        Button(model.isExcluded(url) ? "Include in Roll Analysis" : "Exclude from Roll Analysis") {
            model.toggleExcluded(url)
        }
    }
}
