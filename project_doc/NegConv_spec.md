# NegConv — macOS film negative converter (spec)

_Last updated: 2026-11-23 · version 0.95 (build 10) · status: MVP 1 complete + Phase 2 (except B&W) · colour work: C1–C5 all done (see `NegConv_color_plan.md`) · 2026-11-17: colour mixer moved before Presence; inspector in workflow order; roll base + roll analysis; curves; v0.6: sharpening · v0.8: Canon/Fuji RAW · v0.9: grid view + thumbnails, Retag Exported Photos · v0.95: Capture One-style tool keys._

## Goal
Native macOS app to convert camera-scanned film negatives (Nikon D810 / D750, 14-bit lossless NEF) into high-quality positives, with non-destructive editing.

## Stack
- Swift + SwiftUI (macOS 14+), Xcode 27.2, Swift 5 language mode, default actor isolation `nonisolated`
- Core Image `CIRAWFilter` for NEF decoding (both cameras natively supported; avoid D810 "RAW S")
- Metal-backed `CIContext`; custom Metal `CIColorKernel`s (`Sources/NegKernels.metal`, built with `-fcikernel`)
- `MTKView` preview (frozen half-float preview decode @ 2560 px; full-res decode on demand for loupe/1:1 and export)
- Sidecar JSON recipe per image (`IMG_0001.NEF.negconv.json`), autosaved; roll file `NegConv Roll.json` per folder
- Export: 16-bit TIFF (Adobe RGB), JPEG (sRGB) — no DNG write
- Fallback decoder (only if needed later): LibRaw

## Processing pipeline (as built — order matters)
1. **RAW decode, linear** — boost/tone curve, NR, sharpening, local tone map, gamut mapping, lens correction off; fixed WB (default 5500 K) and exposure, **per roll**.
2. **Spot repair** — feathered clone discs, or brush strokes (chain of feathered discs along a polyline, max-merged, one clone offset), in source coordinates (survive later geometry changes). Fully transparent / premultiplied pixels are handled explicitly in every kernel.
3. **Geometry** — exact 90° turns + horizontal flip → fine straighten (same canvas; crop kept inside valid area) → crop.
4. **Film-base removal** — base RGB from the frame's own sample (rect in source coords, re-measured on every decode and at export) or, if it has none, from the **roll base** (sampled once per roll, re-measured on its frame when the decode changes) → divide each channel by base RGB. The sample tool always shows the uncropped, unstraightened frame, so base sampling is independent of the crop.
5. **Density inversion** (`negInvert`) — D = −log10(T); per-channel black/white densities; L = 10^(slope·(D − dWhite)), slope = range/(dWhite − dBlack); linear black point 10^−range. Point sources (auto) or manual:
   - **Frame**: 0.3 / 99.7 % of D in the crop.
   - **Roll**: pooled percentiles of all analysed frames (each frame weighs the same).
   - **Roll colour** (default for new frames): roll colour balance (per-channel deviation from the mean) fitted to the frame — white raised until no channel's white is below the frame's, black lowered until none is above the frame's. Neighbouring frames match; strongly coloured frames (sunsets) keep their colour without clipping.
   - Without a roll analysis, Roll / Roll colour fall back to Frame. Export resolves roll points itself, so unopened frames are right.
6. **Tone** (`negTone`) — linear gain (exposure × WB temp/tint) → optional **paper** print curve (log-log line of slope *grade* through mid-grey 0.18, soft shoulder into paper white, soft toe into paper black 10^−Dmax; same curve on R, G, B) → levels on γ 2.2 values (per channel, then master).
7. **Curves** (`negCurves`, general `CIKernel` with a LUT sampler) — master + R/G/B curves on γ 2.2 values, monotone cubic (Fritsch–Carlson, no overshoot/reversals), flat beyond moved end points; baked on the CPU into a 1024-entry LUT holding master(channel(x)), linear interpolation, end-slope extrapolation outside 0…1. Skipped when identity. GPU vs CPU rel. error ≈ 5e-5.
8. **Colour mixer** (`negColorMix`) — 8 bands, hue ±30° / saturation / luminance on γ-encoded HSV, interpolated between band centres, neutrals protected. Runs **before** Presence so per-colour luminance still works when Saturation −100 makes the image B&W (B&W channel mixing). The band eyedropper samples after curves, before the mixer.
9. **Presence** (`negPresence`) — global saturation and vibrance on OkLab chroma (lightness untouched); vibrance weighted to low chroma, skin hues (≈55°) protected. Saturation −100 = B&W.
10. **Sharpen** (`negSharpLuma` → `CIGaussianBlur` → `negSharpen`) — luminance-only unsharp mask, last step on the finished tones. Works on γ 2.2-encoded luma (Rec. 709 weights), because USM halos on linear values are lopsided (strong bright rims, weak dark ones). d = Y − blur(Y); soft threshold w = smoothstep(t/2, 3t/2, |d|) leaves grain and smooth areas alone; the same offset amount·w·d is added to R, G and B, so only brightness changes (no colour fringes, no boosted chroma noise). Radius = Gaussian σ in **full-resolution** scan pixels; the preview scales it by its decode scale (approximate in the fitted view, exact in the loupe/1:1 and export). Luma is clamped to extent before blurring (no dark frame edges). Skipped when Amount = 0 and for the reference-frame flash.
11. **Output transform** — preview: extended sRGB; export: Adobe RGB 16-bit TIFF or sRGB JPEG; optional Lanczos downsize (in linear) **after** sharpening, so the export is sharpened exactly as seen at 1:1.

Working colour space: extended linear sRGB, set explicitly once — never rely on implicit conversions. Preview context RGBAh, export context RGBAf.

## Roll analysis
- Candidates: frames not excluded, **cropped** (uncropped frames include rebate/holder and are skipped), with a base (own or roll).
- Per frame: small decode (1200 px long edge, same roll decode settings; < 2 s per 36 MP NEF on the dev Mac), geometry + crop, base-relative density histograms 3 × 2048 bins over D −0.25…3.75, normalised per channel. Cached in memory per frame with a fingerprint (decode, geometry, base source).
- Pooled = mean of frame histograms → 0.3 / 99.7 % percentiles → roll dBlack / dWhite.
- `NegConv Roll.json`: decode (authoritative over sidecars), roll base, excluded frames, reference frame, analysis (points + per-frame fingerprints). State shown as Not analysed / Analysed / Out of date (fingerprints differ: crop, base or decode changed, frame excluded/added). Excluding a frame re-pools instantly when all histograms are cached.

## Reference frame (C5)
- Pin with ⇧R (or file-list context menu); one per roll, stored as `reference` in `NegConv Roll.json`, pin icon in the file list.
- Rendered once: 2560 px linear decode cached per (frame, decode); base + auto points re-measured on it without side effects (`AppModel.measuredInversion`); positive frozen to RGBAh. Re-rendered only when its recipe, roll decode, roll base or roll analysis change (`ReferenceKey` → `.task(id:)`).
- Views: side by side (reference pane left, non-interactive) · hold R = reference in place of the current frame (clipping overlay applies, histogram follows).
- Match WB: grey-world over neutral midtones (after each frame's own gain: luminance 0.03…0.6 linear, (max−min)/max < 0.35, ≥ 2 % of pixels) of both inverted positives before tone; g = g_ref · mean_ref / mean_cur normalised to green → temperature/tint (exposure untouched), two passes. Ignores the reference's paper/curves/mixer — it matches the linear balance.

## Shooting data (exports)
- Roll: `RollMetadata` in `NegConv Roll.json` (`metadata`), edited in the Roll Info sheet (⌘I), saved debounced. Frame: `EditRecipe.meta` (`FrameMetadata`) in the sidecar; excluded from render/histogram/reference keys (`EditRecipe.rendering`). Paste option "Lens, aperture, shutter, focal length" (off by default).
- Mapping (`ExportMetadata.properties`): TIFF Make/Model/Artist/Copyright/Software/ImageDescription; EXIF LensModel, FocalLength, FNumber, ExposureTime, ISOSpeedRatings (EI, else box), DateTimeOriginal (frame date+time, else roll date 12:00 + frame index s → roll order), DateTimeDigitized (scan NEF's capture time), UserComment (film · development · "Scan of <NEF> with NegConv x.y", ASCII-folded incl. Ł/ł); IPTC Caption-Abstract, Keywords (film stock + user keywords), ContentLocationName, By-line, CopyrightNotice, DateCreated + TimeCreated; local UTC offsets (EXIF OffsetTimeOriginal/Digitized, IPTC times "HHmmss±hhmm"), IPTC DigitalCreationDate/Time = scan. Verified by round-trip read-back for JPEG and TIFF.
- Scan EXIF (D810 etc.) is never copied.

## Grid view & thumbnails (v0.9)
- **G** = grid (contact sheet) in place of the preview, **E** = loupe (bare keys via the key monitor, not while typing); also toolbar segmented control and View menu. In the grid: ←→ ±1, ↑↓ ± one row (columns computed like the adaptive grid), Return / double-click → loupe. Tile size slider (`gridTileSize`). Sidebar rows get 44 × 32 thumbnails.
- `ThumbnailStore` per window: idempotent requests keyed by source, one background job at a time, fast jobs first. Sources: **embedded** (RAW's embedded preview via ImageIO, fallback reduced decode if < 256 px), **positive** (frames that would export: `smallLinearImage` 800 px → `measuredInversion` → `Pipeline.positive`, no sharpening → Lanczos to 640 px → sRGB 8-bit), **file** (JPEG/TIFF). Edited frames show the negative first.
- Positive key = fingerprint of `EditRecipe.rendering` + roll decode + roll base (if no own base) + roll analysis (if roll point source). Disk cache `Caches/<bundle>/Thumbnails/<path hash>-<key>.jpg`, older keys of the same file removed.
- Open frame: thumbnail from its 2560 px preview decode (no extra decode), 350 ms after the last edit. Roll decode / base / analysis changes refresh all frames.

## Retag exported photos (v0.9)
- Window **File → Retag Exported Photos…** for JPEG/TIFF converted elsewhere (Capture One etc.). Rolls from file names `<yyyy-MM-dd>_<camera>_<film>_<roll#>_<frame#>` (date and camera optional; roll and frame numeric), other files → "Other files" (unticked if the folder has roll frames). NegConv exports (Software contains "NegConv") unticked.
- Prefill: camera code → make/model (`CameraAliases` in UserDefaults, seeded FEa/FEb → Nikon FE, learnt when edited), film code → stock + box ISO (`FilmNames`, else letters/digits split), date from the name, code as keyword, last photographer/copyright. Frame order: frame#, then scan time, then name → frame index for the 12:00 + index s rule.
- Writing (`MetadataRewriter`): `CGImageDestinationCopyImageSource` with a new `CGImageMetadata` (`kCGImageDestinationMergeMetadata: false`, GPS excluded, no thumbnail): whitelist from the source (orientation, resolution, colour space, pixel size) + `ExportMetadata.properties` (Software = "<old software>; NegConv x.y"). ISO also as scalar + `exifEX:PhotographicSensitivity` (an array only reached XMP). Copies to `Retagged/` or in place (temp file + atomic replace, confirmation). Read-back: no scanner model/serial/lens string in properties or XMP tags (unless part of the new data), JPEG SOS…EOI byte-identical → ✓, else ⚠.
- `NegConv Retag.json` in the folder: roll metadata + per-frame include/overrides, saved on Retag.
- User test 2026-11-23 (74 Capture One JPEGs, in place): scanner data (X-T30, serial, 21 mm, "645 Yashica" preset caption) gone everywhere; open in 0.9: EXIF ISO, old thumbnail, IPTC time zone (fixed, re-test).

## Inspector order (workflow order, top → bottom)
Histogram · RAW Decode (per roll, collapsed, summary in the header) · Geometry · Inversion (base, range, point source, density points) · Roll (analyse, exclude, roll points) · Reference · Exposure & White Balance · Paper · Levels · Curves · Colour Mixer · Presence · Sharpen · Spot Removal · Shooting Data · Scan Info.

Follows the order you work in, which mostly follows the pipeline: geometry before inversion because auto density points are measured in the crop; Exposure/WB → Paper → Levels as in `negTone`; Mixer → Presence → Sharpen as in the pipeline. Exception: Spot Removal is first in the pipeline (source coordinates) but last in the panel — dust is cleaned on the finished positive.

## Features & status
| Feature | Status |
|---|---|
| Open roll folder, file list, edited marker | ✅ |
| Linear RAW decode, roll-level decode settings, compare vs Apple default | ✅ |
| Rotate 90° / flip / crop (Return applies) | ✅ |
| Straighten: draw-a-line tool + angle slider | ✅ |
| Film-base sampling + density inversion + auto points | ✅ |
| Roll base (one sample for the whole roll) | ✅ 2026-11-17 |
| Roll analysis + point sources Frame / Roll / Roll colour, exclude frames | ✅ 2026-11-17 |
| Manual per-channel black/white density points | ✅ |
| Exposure, WB temp/tint + neutral eyedropper | ✅ |
| Levels (master + per channel) | ✅ |
| Colour mixer (8 bands HSL) + band eyedropper | ✅ |
| Saturation + vibrance (OkLab, "Presence") | ✅ |
| Sharpening: luminance-only unsharp mask (Amount 0–300 %, Radius 0.3–3 px full-res, Threshold 0–20 levels), last in the pipeline, paste option, part of before/after | ✅ 2026-11-17 (v0.6) |
| Paper / print stage (grade, paper black, highlight/shadow roll-off, Soft/Normal/Hard, surface) | ✅ |
| Precision sliders (⇧ fine drag, scrub/type value, double-click reset), resizable inspector | ✅ |
| Inspector in workflow order; Tone split into Exposure & WB / Levels | ✅ 2026-11-17 |
| Live RGB histogram with clipping % | ✅ |
| Loupe (hold Z / ⌥) 100–400 %, 1:1 view with pan/zoom | ✅ |
| Spot removal (auto-source clone): discs + brush strokes for hairs (auto source across the stroke), ⇧-click straight strokes | ✅ |
| Space + drag pan in 1:1 | ✅ |
| Copy / paste settings (selective, incl. point source), paste to whole roll | ✅ |
| JSON sidecars (autosave, tolerant loading) + roll file | ✅ |
| Release builds: 0.1, 0.2, 0.3 (roll analysis, curves, workflow-order inspector), 0.4 (before/after, clipping overlay, reference frame), 0.5 (shooting data in exports), 0.6 (sharpening), 0.8 (Canon/Fuji RAW), 0.9 (grid view, retag exports), **0.95** (tool keys) | ✅ `./build_release.sh` → `dist/` |
| Export TIFF 16-bit Adobe RGB / JPEG sRGB, resize, frame or roll | ✅ |
| Curves (master + R/G/B, monotone spline, histogram behind, ⇧ fine drag, drag-off delete, paste option) | ✅ 2026-11-17 (v0.3) |
| Before/after: hold `\` = plain inversion (geometry, spots, base, points kept; tone/paper/curves/mixer/presence/sharpening reset) | ✅ 2026-11-17 |
| Clipping overlay (J): red highlights / blue shadows / magenta both, tested in the export space (Adobe RGB or sRGB) at 8-bit-equivalent black/white | ✅ 2026-11-17 |
| Curves on-image picker (hover marker, ⌘-click adds point) | ⏳ optional |
| Reference frame (C5): ⇧R pin (roll file, pin in file list), side by side (⌥⌘R), hold R to flash, Match WB to reference (⇧⌥⌘W) | ✅ 2026-11-17 (user-tested) |
| B&W conversion (mixer before desaturation ✅; single-channel inversion) | ⏳ Phase 2 |
| Shooting data in exports: roll info (⌘I: camera, lens, film, box ISO / EI, development, date, location, credits, keywords, notes) + per-frame overrides (date/time, f, shutter, lens, focal length, caption) → EXIF/TIFF/IPTC; scan only as Software, DateTimeDigitized, "Scan of <NEF>" | ✅ 2026-11-17 (v0.5) |
| Canon CR2/CR3 and Fujifilm RAF input (same linear CIRAWFilter decode; body support depends on macOS version) + app icon | ✅ 2026-11-20 (v0.8) |
| Grid view (G/E, contact sheet in place of the preview) + sidebar thumbnails; positives of edited frames, disk cache | ✅ 2026-11-23 (v0.9) |
| Retag Exported Photos: replace the scan camera's metadata of existing JPEG/TIFF exports with the analog data, lossless, verified | ✅ 2026-11-23 (v0.9, user-tested) |
| Capture One-style single-key tools: C crop, L straighten, W film base, ⇧W white-balance picker, Q spots, ⌘F flip (key monitor, ignored while typing, press again to leave, from the grid opens the loupe) | ✅ 2026-11-23 (v0.95) |
| Compressed TIFF (Predictor 2 + Deflate) | ⏳ todo |
| Output sharpening for downsized exports (export setting, radius in output pixels) | ⏳ optional |
| Auto-crop to film frame | ⏳ Phase 3 |
| Presets | ⏳ low priority (each roll is treated separately; roll analysis covers consistency) |
| Heal (texture + colour-matched) instead of clone | ⏳ later |

## Out of scope (for now)
- Negative Lab Pro–grade auto colour per frame (roll analysis + WB eyedropper instead)
- Film-stock profiles (later as presets)
- Infrared dust removal (no IR channel; spot tool instead)
- Catalog/database (folder + file list only)
- DNG export

## Phases
1. **MVP** ✅ — open NEF, preview, crop, sample film base, density inversion, exposure + per-channel levels, export 16-bit TIFF, JSON recipes.
2. **Usable** — ✅ WB eyedropper, histogram, JSON recipes, copy/paste across a roll, colour mixer, spots, straighten, loupe, saturation/vibrance, paper, roll analysis, curves ✅ (v0.3), sharpening ✅ (v0.6); B&W single-channel inversion open.
3. **Nice** — ✅ batch export, auto-levels, JPEG, before/after, clipping overlay, reference frame, grid view, retag exports · ⏳ auto-crop, presets.

## Known issues
- Sharpening in the fitted preview is only an approximation (radius scaled to the 2560 px preview, often sub-pixel); judge it at 1:1. Downsized exports lose much of the 1:1 sharpening in the Lanczos resize.
- With Z held, macOS palm rejection suppresses trackpad scroll/pinch → use +/− (or hold ⌥ instead of Z).
- Pasted straighten angle doesn't pull the target frame's crop inside the valid area until its angle is touched.
- TIFFs are uncompressed (ImageIO ignores the TIFF Predictor tag; LZW without it is ~30 % larger).
- High Saturation can push colours outside sRGB/Adobe RGB (negative channel values); they clip at export. With Paper on, highlights roll off below 1.0, but the mixer/Presence run after it and can still push colours out of gamut.
- Sidecars saved before 2026-11-17 that use **both** the colour mixer and Presence render slightly differently now (mixer moved before Presence).
- **Roll** point source (not Roll colour) is not fitted per frame: on strongly coloured or unusually dense/thin frames it can clip. Use Roll colour or Exposure.
- Retag: removing the old EXIF thumbnail relies on `kCGImageDestinationEmbedThumbnail: false` being honoured by `CopyImageSource` (to be confirmed).
- Roll analysis histograms are kept in memory only: after reopening a roll, the first re-analyse decodes all frames again.

## References
- darktable `negadoctor` module (density-based approach)
- RawTherapee Film Negative tool
- Negative Lab Pro (quality benchmark)
- OkLab (Björn Ottosson, 2020) — perceptual space for saturation/vibrance
- Note: darktable/RawTherapee are GPL — use for ideas, not code, if the app stays closed.

## Shooting tips (affect results most)
- Always include unexposed film rebate in frame.
- Keep light source and camera WB fixed for the whole roll.
- Full 14-bit lossless NEF.
