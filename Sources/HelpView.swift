import AppKit
import SwiftUI

// MARK: - About

/// Standard macOS About panel (name, icon, version and build come from the bundle) with the
/// author line as credits.
enum AboutPanel {
    static let credits = "vibecoded by TymancjO"

    @MainActor
    static func show() {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let text = NSAttributedString(string: credits, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style
        ])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: text])
        NSApp.activate()
    }
}

// MARK: - Help menu

/// Identity of the Help window. Plain enum (not on the View) so non-UI code can read it.
enum HelpWindow {
    static let id = "help"
    /// Also used by `AppModel.handle(_:)` to leave this window's keys and scrolls alone.
    static let title = "NegConv Help"
}

/// Help ▸ NegConv Help (⌘?). A View so it can read `openWindow` from the environment.
struct HelpMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("NegConv Help") { openWindow(id: HelpWindow.id) }
            .keyboardShortcut("?", modifiers: .command)
    }
}

// MARK: - Help window

/// In-app copy of the user-facing part of README.md (workflow, keyboard, files).
/// Keep it in sync when the README changes.
struct HelpView: View {

    @State private var topic: HelpTopic? = .overview

    var body: some View {
        NavigationSplitView {
            List(HelpTopic.allCases, selection: $topic) { t in
                Label(t.title, systemImage: t.symbol).tag(t)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text((topic ?? .overview).title)
                        .font(.largeTitle.weight(.semibold))
                        .padding(.bottom, 4)
                    switch topic ?? .overview {
                    case .overview: HelpParagraphs(HelpContent.overview)
                    case .workflow: HelpSteps(HelpContent.workflow)
                    case .keyboard: HelpShortcutTable(HelpContent.shortcuts)
                    case .files: HelpParagraphs(HelpContent.files)
                    }
                }
                .padding(24)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
        }
        .frame(minWidth: 640, minHeight: 460)
    }
}

enum HelpTopic: String, CaseIterable, Identifiable, Hashable {
    case overview, workflow, keyboard, files
    var id: Self { self }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .workflow: "Workflow"
        case .keyboard: "Keyboard"
        case .files: "Files"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "info.circle"
        case .workflow: "list.number"
        case .keyboard: "keyboard"
        case .files: "doc.on.doc"
        }
    }
}

/// Inline Markdown (bold, italics, `code`) → styled text; falls back to plain text.
private func md(_ s: String) -> Text {
    let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    if let a = try? AttributedString(markdown: s, options: opts) { return Text(a) }
    return Text(s)
}

private struct HelpParagraphs: View {
    let items: [String]
    init(_ items: [String]) { self.items = items }

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, p in
            if p.hasPrefix("## ") {
                Text(p.dropFirst(3)).font(.title3.weight(.semibold)).padding(.top, 6)
            } else if p.hasPrefix("- ") {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(.secondary)
                    md(String(p.dropFirst(2))).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                md(p).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct HelpSteps: View {
    let steps: [HelpStep]
    init(_ steps: [HelpStep]) { self.steps = steps }

    var body: some View {
        ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(i + 1)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.accentColor))
                VStack(alignment: .leading, spacing: 6) {
                    Text(step.title).font(.headline)
                    ForEach(Array(step.body.enumerated()), id: \.offset) { _, p in
                        md(p).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 4)
            Divider()
        }
    }
}

private struct HelpShortcutTable: View {
    let rows: [(keys: String, action: String)]
    init(_ rows: [(keys: String, action: String)]) { self.rows = rows }

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                GridRow {
                    Text(r.keys)
                        .font(.body.monospaced().weight(.medium))
                        .gridColumnAlignment(.trailing)
                    md(r.action).fixedSize(horizontal: false, vertical: true)
                }
                Divider().gridCellUnsizedAxes(.horizontal)
            }
        }
    }
}

struct HelpStep {
    let title: String
    let body: [String]
}

// MARK: - Content (from README.md)

enum HelpContent {
    static let overview: [String] = [
        "NegConv converts camera-scanned colour negatives (Nikon NEF, Canon CR2/CR3, Fujifilm RAF) into positives. Developed on a Nikon D810 / D750.",
        "Everything is **non-destructive**: each frame's edits live in a JSON sidecar next to the RAW file, and roll-wide settings live in `NegConv Roll.json` in the roll folder. Nothing touches your RAW files.",
        "## How the inspector is organised",
        "The inspector runs **top → bottom in processing order**: RAW decode → geometry → inversion (film base and density points) → roll → reference → exposure & white balance → paper → levels → curves → colour mixer → presence → sharpening → spots → shooting data. Work through it in that order.",
        "## Sliders",
        "- Drag = relative; hold **⇧** for 10× finer control (any time, no jump).",
        "- Click the track to jump; **double-click** the slider or its title to reset.",
        "- Drag the number to scrub (⇧ fine), or click it to type (Return / Esc, ↑↓ step, ⇧↑↓ ×10).",
        "- Drag the inspector's left edge to widen the panel (300–560 pt) for longer sliders.",
        "## Checking your work",
        "- Hold `\\` for **before** — the plain inversion (crop, spots, base and points kept; everything after is reset).",
        "- Press **J** for the **clipping overlay**: red = will export as pure white, blue = pure black, magenta = both. Tested in the export colour space, so out-of-gamut colours show too.",
        "- Tap **Z** (or ⌘1, or double-click) for 1:1; hold **Z** or **⌥** for a loupe at the cursor.",
        "## Retag exported photos",
        "**File → Retag Exported Photos…** rewrites the metadata of JPEG / TIFF scans converted elsewhere (Capture One, Lightroom, older NegConv) so they describe the analog shot instead of the scanning camera.",
        "- Rolls come from file names `<date>_<camera code>_<film>_<roll#>_<frame#>` (date and camera code optional); camera code → make / model (remembered), film code → stock and box ISO, date from the name.",
        "- All old metadata (scan camera, lens, serial, XMP / IPTC copies, GPS, converter captions, embedded preview) is replaced by the same analog fields as an export. Image data is copied unchanged; each file is read back and gets ✓ only if nothing of the scanner is left.",
        "- Copies go to `Retagged/` unless you choose Replace originals. Edits are kept in `NegConv Retag.json`."
    ]

    static let workflow: [HelpStep] = [
        HelpStep(title: "Open the roll", body: [
            "**⌘O** opens the roll folder. Keep the RAW Decode settings (top of the inspector, collapsed) fixed for the whole roll.",
            "**G** shows the roll as a contact sheet in place of the preview; **E**, double-click or Return goes back to editing, arrows move between frames. Unedited frames show the camera's embedded negative, edited ones a small positive that follows your edits.",
            "**⌘I** Roll Info: camera, lens, film stock, box ISO / shot-at EI, development, date, location, credits. This — not the scan camera — goes into the exports."
        ]),
        HelpStep(title: "Geometry", body: [
            "Rotate (**⌘[ ⌘]**), flip (**⌥⌘F**), straighten (**⌘L**, draw along a horizon or vertical), crop (**⌘K**, Return to apply).",
            "Crop inside the image, excluding the rebate and sprocket holes — the automatic points are measured inside the crop."
        ]),
        HelpStep(title: "Sample the film base", body: [
            "**⌘B**, then drag a box on clear rebate (not on sprocket holes) on one frame.",
            "**Use for Whole Roll** — every frame without its own sample then uses it."
        ]),
        HelpStep(title: "Crop the rest and analyse the roll", body: [
            "Crop the other frames (paste the crop with **⇧⌘V** if the holder didn't move), then **Analyse Roll** in the Roll section (~2 s per frame). Exclude blank frames and test shots (**Exclude frame**, or right-click in the list).",
            "**Points** — **Roll colour** (default): the roll's colour balance, fitted to each frame's range so no channel clips; neighbouring frames match and a sunset stays a sunset. **Frame**: each frame's own percentiles. **Roll**: identical points for the whole roll. Editing a density slider switches to manual."
        ]),
        HelpStep(title: "Exposure & white balance", body: [
            "**⌥⌘W** and click something neutral, then set Exposure."
        ]),
        HelpStep(title: "Paper (optional)", body: [
            "Turn on **Print on paper** for a print look. Grade (Soft / Normal / Hard) sets contrast around mid-grey; highlights roll off instead of clipping; Surface / Paper black sets how deep the blacks go (matte = lifted). Brightness stays on Exposure."
        ]),
        HelpStep(title: "Levels & curves", body: [
            "Levels: per channel first, then RGB — trims on the print.",
            "Curves (RGB / R / G / B): click to add a point (it lands on the curve), drag to move (hold ⇧ for fine), drag a point off the graph to remove it (red ring) or use −. End points move like levels black / white. In / Out are shown 0–255, with the result's histogram behind the graph."
        ]),
        HelpStep(title: "Colour mixer", body: [
            "**⌥⌘M** and click a colour (e.g. the sky), then shift its hue / saturation / luminance. Works in B&W too — it runs before Presence."
        ]),
        HelpStep(title: "Presence, sharpening, checking", body: [
            "**Vibrance** lifts muted colours (skin protected), **Saturation** scales all colour; both keep brightness (OkLab). Saturation −100 = B&W.",
            "**Sharpen** is a luminance-only unsharp mask applied last. Amount 0–300 %, Radius in full-resolution pixels (≈ 0.6–1 for D810, 0.8–1.2 for D750), Threshold in levels (raise it if grain gets gritty). Judge it at 1:1 — the fitted preview only approximates it.",
            "Hold `\\` for before, press **J** for the clipping overlay.",
            "**Match frames**: pin a finished frame as **reference** (**⇧R**). On the next frames show it side by side (**⌥⌘R**) or hold **R** to flash it in place, and use **Match WB to Reference** (**⇧⌥⌘W**) to copy its colour balance (neutral midtones; exposure untouched)."
        ]),
        HelpStep(title: "Dust & shooting data", body: [
            "**⌘J**, click specks; **drag to paint** along hairs and scratches; **⇧-click** draws a straight stroke from the last spot. Hold ⌥ for the 100 % loupe; space + drag pans at 1:1.",
            "Shooting Data (near the bottom): date & time, aperture, shutter (`1/125`, `2s`), lens, focal length, caption per frame — empty fields use the roll info."
        ]),
        HelpStep(title: "Copy to other frames", body: [
            "**⇧⌘C** copy settings → next frame **⇧⌘V** (choose what to paste, or Paste to All Frames)."
        ]),
        HelpStep(title: "Export", body: [
            "**⌘E** exports the frame, **⇧⌘E** the roll, into `NegConv Export/`. Format and size: **⌥⌘E**."
        ])
    ]

    static let shortcuts: [(keys: String, action: String)] = [
        ("⌘O", "Open roll folder"),
        ("G  E", "Grid (contact sheet) / loupe — in the grid: arrows move, Return or double-click edits"),
        ("⌘[  ⌘]", "Rotate left / right"),
        ("⌥⌘F", "Flip horizontal"),
        ("⌘K, Return", "Crop, apply crop"),
        ("⌘L", "Straighten (draw line)"),
        ("⌘B", "Sample film base"),
        ("⌘\\", "Show negative / positive"),
        ("hold \\", "Before (plain inversion)"),
        ("J", "Clipping overlay on/off (red highlights, blue shadows, magenta both)"),
        ("⇧R", "Pin current frame as reference"),
        ("hold R", "Flash the reference in place of this frame"),
        ("⌥⌘R", "Reference side by side"),
        ("⇧⌥⌘W", "Match white balance to reference"),
        ("⌥⌘W", "White-balance picker"),
        ("⌥⌘M", "Colour-mixer picker"),
        ("⌘J", "Spot removal — click = spot, drag = brush stroke, ⇧-click = straight stroke, `[` `]` size, ⌫ delete, Return done"),
        ("Space + drag", "Pan the 1:1 view (any tool; in the spot tool plain drag paints)"),
        ("hold Z or ⌥", "Loupe at cursor (⌥ + scroll/pinch or +/− for 100 / 200 / 400 %)"),
        ("Z, ⌘1, dbl-click", "1:1 view (drag/scroll to pan, pinch or +/− to zoom, Esc to fit)"),
        ("⇧⌘C  ⇧⌘V", "Copy / paste settings"),
        ("⌘E  ⇧⌘E  ⌥⌘E", "Export frame / roll / export settings"),
        ("⌘I", "Roll Info (shooting data for the whole roll)"),
        ("Esc", "Exit current tool"),
        ("⌘?", "This help")
    ]

    static let files: [String] = [
        "## Next to each RAW file",
        "`<name>.NEF.negconv.json` (or `.CR3`, `.RAF`, …) — the frame's recipe (incl. per-frame shooting data) plus the roll decode settings. Autosaved.",
        "## In the roll folder",
        "`NegConv Roll.json` — roll decode settings (authoritative), roll film base (frame, area, RGB), excluded frames, reference frame, roll info (shooting data) and the roll analysis (pooled density points + per-frame fingerprints for the “out of date” check).",
        "## In a folder of retagged exports",
        "`NegConv Retag.json` — roll info and per-frame overrides of the Retag window.",
        "## Exports",
        "`NegConv Export/<name>.tif | .jpg`",
        "- **TIFF**: 16-bit RGB, Adobe RGB (1998), uncompressed.",
        "- **JPEG**: 8-bit sRGB.",
        "Both carry the analog shooting data: Make / Model / Lens / ISO (EI) / f / shutter / date taken, description + IPTC caption (caption — film — development — notes), IPTC keywords (film stock + yours), location, artist, copyright, local time-zone offsets. The scan itself appears only as Software, DateTimeDigitized and `Scan of <NEF>` in the user comment."
    ]
}
