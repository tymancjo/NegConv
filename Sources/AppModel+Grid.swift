import AppKit
import CoreImage

/// Grid view (contact sheet) and roll thumbnails.
extension AppModel {

    // MARK: - Thumbnails

    /// What a frame's thumbnail should show: an edited frame (one that would export) as a small
    /// positive through the real pipeline, everything else as the camera's embedded negative.
    func thumbnailSource(for url: URL) -> ThumbnailSource {
        guard let r = recipes[url], r.inversion.baseRect != nil || rollBaseRGB != nil else {
            return .embedded
        }
        return .positive(ThumbnailPositiveInputs(
            name: url.lastPathComponent,
            recipe: r.rendering,
            decode: rollDecode,
            rollBase: r.inversion.baseRect == nil ? rollBaseRGB : nil,
            analysis: r.inversion.pointSource == .frame ? nil : rollAnalysis))
    }

    /// Refresh the thumbnails of `urls` after a short pause, so slider drags coalesce.
    func scheduleThumbnails(_ urls: Set<URL>, delay: Duration = .milliseconds(350)) {
        guard !urls.isEmpty else { return }
        thumbnailDirty.formUnion(urls)
        thumbnailTask?.cancel()
        thumbnailTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            let dirty = self.thumbnailDirty
            self.thumbnailDirty = []
            // Selected frame first, then roll order.
            if let s = self.selection, dirty.contains(s) { self.updateThumbnail(s) }
            for u in self.files where dirty.contains(u) && u != self.selection { self.updateThumbnail(u) }
        }
    }

    private func updateThumbnail(_ url: URL) {
        let source = thumbnailSource(for: url)
        guard !thumbnails.isCurrent(url, source) else { return }
        // The open frame: downsize its already-decoded preview (no extra RAW decode), so the
        // thumbnail follows every edit.
        if source.isSlow, url == selection, let image = liveThumbnail() {
            thumbnails.set(image, for: url, source: source)
            return
        }
        thumbnails.request(url, source)
    }

    /// The open frame's positive from its 2560 px preview decode, with the base and points
    /// measured on that decode (as shown in the editor), downsized to thumbnail size.
    private func liveThumbnail() -> CGImage? {
        guard let selection, let decode = preview, decode.url == selection,
              !compareAppleDefault, recipe.inversion.isReady else { return nil }
        let r = recipe
        return ThumbnailRenderer.render(Pipeline.positive(Pipeline.framed(decode.image, r), r, detailScale: 0))
    }

    // MARK: - Keys

    /// G = grid, E = loupe (no modifiers). In the grid: arrows move the selection, Return
    /// opens it in the loupe. Returns true if the event was consumed.
    func handleGridKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        let down = event.type == .keyDown
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "g":
            if down, !files.isEmpty { viewMode = .grid }
            return true
        case "e":
            if down { viewMode = .loupe }
            return true
        default:
            break
        }
        guard viewMode == .grid else { return false }
        switch event.keyCode {
        case 123: if down { moveSelection(by: -1) }; return true                 // ←
        case 124: if down { moveSelection(by: 1) }; return true                  // →
        case 126: if down { moveSelection(by: -max(gridColumns, 1)) }; return true // ↑
        case 125: if down { moveSelection(by: max(gridColumns, 1)) }; return true  // ↓
        case 36, 76:                                                            // Return
            if down, selection != nil { viewMode = .loupe }
            return true
        default:
            return false
        }
    }

    func moveSelection(by step: Int) {
        guard !files.isEmpty else { return }
        let i = selection.flatMap { files.firstIndex(of: $0) } ?? 0
        selection = files[min(max(i + step, 0), files.count - 1)]
    }

    /// Frames the grid footer counts as edited (they show positives and would export).
    var editedCount: Int {
        files.filter { u in
            guard let r = recipes[u] else { return false }
            return r.inversion.baseRect != nil || rollBaseRGB != nil
        }.count
    }
}

extension AppModel {
    /// Single-key tool shortcuts (Capture One style): C crop, L straighten, W film base,
    /// ⇧W white-balance picker, Q spot removal. Pressing the key again leaves the tool; in the
    /// grid it opens the selected frame in the loupe with that tool. Returns true if consumed.
    func handleToolKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        let shift = event.modifierFlags.contains(.shift)
        let t: EditTool?
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c" where !shift: t = .crop
        case "l" where !shift: t = .straighten
        case "w": t = shift ? .whiteBalance : .sampleBase
        case "q" where !shift: t = .spot
        default: t = nil
        }
        guard let t else { return false }
        if event.type == .keyDown, !event.isARepeat, selection != nil {
            if viewMode == .grid {
                viewMode = .loupe
                tool = t
            } else {
                toggleTool(t)
            }
        }
        return true
    }
}
