# NegConv — the maths behind the conversion

What each stage and slider does to the numbers, in pipeline order. Formulas match the code
(`NegKernels.metal`, `Pipeline.swift`, `EditRecipe.swift`, `Roll.swift`, `Analyzer.swift`).

---

## 0. The big picture

A colour negative is a *record of density*: the more light a scene area sent to the film, the
more dye formed, the darker (denser) the negative. Density is logarithmic in light, and the
film's response in that log domain is close to a straight line. So the conversion is:

1. measure how much light got through the negative (linear RAW),
2. remove the orange mask (divide by the film base),
3. convert to **density** (a log),
4. map density back to **scene-linear light** with a straight line per channel (the inversion),
5. then make a picture out of that scene light (exposure, WB, paper, levels, curves, colour).

```
NEF ─► linear decode ─► spots ─► rotate/flip/straighten/crop
      ─► ÷ base ─► D = −log10 T ─► L = 10^(slope·(D − dWhite)) ─► black point      (INVERSION)
      ─► × exposure × WB gains   (linear)                                            (TONE)
      ─► paper curve             (log–log, optional)
      ─► levels                  (γ 2.2)
      ─► curves                  (γ 2.2, LUT)
      ─► colour mixer            (HSV on γ 2.2)
      ─► presence                (OkLab)
      ─► sharpen                 (luma on γ 2.2)
      ─► output colour space (Adobe RGB 16-bit TIFF / sRGB JPEG)
```

### Working space

Everything runs in **linear, extended-range sRGB (Rec. 709 primaries)**. *Linear* = values are
proportional to light, so multiplying by 2 is exactly +1 stop. *Extended* = nothing is clamped
between stages; values < 0 or > 1 survive until the output (or the paper curve) deals with them.

Some stages deliberately work on a **γ 2.2 encoding** (`e = lin^(1/2.2)`) because their sliders
should feel *perceptual* (levels, curves, mixer, sharpening); they encode, do their thing, and
decode back to linear. Kernels use a sign-preserving power so negative values don't turn into NaN.

---

## 1. RAW Decode (roll settings, top of the inspector)

| Slider | Range | What it does |
|---|---|---|
| Temperature | 2000–10000 K | Decoder white balance |
| Tint | −150…150 | Decoder green/magenta |
| Exposure | −3…+3 EV | Linear gain in the decoder |

The decode is **neutral linear**: `boostAmount = 0` (no base tone curve), no sharpening, no noise
reduction, fixed WB (not "as shot"). The output is proportional to sensor light.

**Why these barely affect the final colour:** the next step divides every pixel by the film base,
which was decoded with the same settings. A per-channel gain `g` cancels:

    (raw · g) / (base · g) = raw / base

It's only *approximately* exact (the decoder's WB acts through the camera→working-space matrix,
not as a pure per-channel gain in sRGB), which is one more reason to keep these fixed per roll.

What they **do** control is **headroom**: decoder exposure that pushes the clear rebate or the
thinnest parts of the negative above the sensor/decoder ceiling clips them *before* inversion —
unrecoverable. Keep the base comfortably below clipping.

---

## 2. Film base (⌘B)

`base = mean linear RGB inside the sampled box` (clear rebate, no image, no sprocket holes).

Per pixel, the **transmittance relative to the base**:

    T = raw / base           (per channel; floored at 1e-6)

This is the orange-mask removal. The orange mask is a *uniform* extra density in every pixel
(different per channel), so dividing by it (= subtracting its density) removes it exactly, with
no guessing. After this, clear base has `T = 1` in all three channels.

---

## 3. Density inversion — the core

### Density

    D = −log10(T)            "density above base"

`D = 0` is clear film (no exposure → **scene black**); larger `D` = more dye = **brighter scene**.
A density of 0.3 = half the light got through; 1.0 = a tenth; 2.0 = a hundredth.

The film's characteristic curve is close to linear in this domain:
`D ≈ γ_film · log10(scene light) + const`, with colour-negative γ ≈ 0.5–0.7 — **different for
each dye layer**. That difference is what makes naïve inversions look crossed (green shadows,
magenta highlights).

### Back to scene light

For each channel *c*, with the two **density points** `dBlack` and `dWhite` and the **Range** `R`:

    slope = R / (dWhite − dBlack)              (span floored at 0.05)
    L     = 10^( slope · (D − dWhite) )        → 1.0 at D = dWhite, 10^−R at D = dBlack
    lbp   = 10^(−R)
    out   = (L − lbp) / (1 − lbp)              → exactly 0 at dBlack, 1 at dWhite

- The first line is a straight line in log–log space: `log10 L = slope · (D − dWhite)`.
  Since `D ≈ γ_film · log10(scene)`, the slope works as **1/γ_film** — it undoes the film's
  compression, giving back scene-linear light.
- **Per-channel slopes** equalise the three layers' contrasts → this is what removes **colour
  crossover**. A single global slope can't.
- The last line is a linear black point: the pixel whose density is `dBlack` lands on exactly 0.

Rewriting with `u = (D − dBlack)/(dWhite − dBlack)` (position between black and white, 0…1):

    out = (10^(R·u) − 1) / (10^R − 1)

So the inversion only depends on **where between the two points** a pixel lies, and on **Range**.

### Density sliders (Black / White, per channel)

| Slider | Range | Meaning |
|---|---|---|
| Black (R/G/B) | 0…1.5 D | density that becomes output **0** (scene black). Low D = thin negative = shadows |
| White (R/G/B) | 0.3…3.0 D | density that becomes output **1.0** (scene white). High D = dense negative = highlights |

- **Raise White** of a channel → that channel needs more density to reach 1 → it gets *darker*
  through the mids/highlights. Lower it → brighter.
- **Raise Black** of a channel → more of its shadows go to 0 → *darker*, more contrast in the
  shadows of that channel.
- Moving one channel's White ≈ a colour cast in the highlights; moving one channel's Black ≈ a
  cast in the shadows; moving both changes that channel's **slope** = its contrast, which is the
  crossover fix.

> Useful equivalence: ignoring the small `lbp` term, multiplying a channel by a gain `g`
> afterwards (white balance) is the same as shifting its `dWhite` by `log10(g) / slope`.
> **WB ≈ moving the white points together; per-channel black points are what fix crossover.**

### Range

| Slider | Range | Default |
|---|---|---|
| Range | 1.0…3.0 D | 2.0 (= 10² = 100 : 1 ≈ 6.6 stops) |

Range is the scene contrast (in log10 units) that the span from Black to White is stretched to:
`out(white)/out(just above black)` spans about `10^R`. It is the **log–log contrast (gamma) about
the white point**; brightness of everything below white changes with it.

Worked example — tones at 10 %, 50 % and 90 % of the way from Black to White:

| Range | u = 0.1 | u = 0.5 (γ-encoded) | u = 0.9 | 90 % vs mid | 10 % vs mid |
|---|---|---|---|---|---|
| 1.0 | 0.029 | 0.240 (0.52) | 0.772 | +1.7 stops | −3.1 stops |
| 1.5 | 0.014 | 0.151 (0.42) | 0.698 | +2.2 | −3.5 |
| **2.0** | 0.006 | 0.091 (0.34) | 0.627 | +2.8 | −3.9 |
| 2.5 | 0.003 | 0.053 (0.26) | 0.561 | +3.4 | −4.4 |
| 3.0 | 0.001 | 0.031 (0.21) | 0.501 | +4.0 | −4.9 |

So **higher Range = tones spread over more stops = more contrast, darker mids** (then you'd add
Exposure); **lower Range = flatter, brighter, more "log-looking"**.
*(Note: the comment on `Inversion.range` in `EditRecipe.swift` says the opposite —
"Higher = flatter" — the formula says higher = more contrast.)*

Defaults example (`dBlack 0.1`, `dWhite 1.2`, Range 2): slope = 2/1.1 ≈ 1.82 (i.e. undoing a
film γ ≈ 0.55), and mid-grey 0.18 comes from a density of ≈ 0.80 above base.

---

## 4. Automatic points (Points: Frame / Roll / Roll colour)

**Frame**: per channel, the **0.3 %** and **99.7 %** percentiles of density inside the crop
(on a ≤ 512 px downscale, 2 px inset). `dBlack = p0.3`, `dWhite = max(p99.7, dBlack + 0.05)`.
→ The darkest 0.3 % of each channel go just below 0, the brightest 0.3 % just above 1.
Each channel is stretched independently → it's an **auto-levels per channel**, so the frame's
content decides the colour balance (a sunset gets "corrected" towards neutral).

**Roll**: **Analyse Roll** builds a density histogram per frame (each normalised so every frame
weighs the same), averages them, and takes the same 0.3 % / 99.7 % percentiles of the pooled
histogram. Every frame gets **identical** points → identical inversion, like printing the whole
roll with one filter pack.

**Roll colour** (default): splits each point into *colour* and *level*:

    cBlack = roll.dBlack − mean(roll.dBlack)          (colour part: deviation of R,G,B from their mean)
    cWhite = roll.dWhite − mean(roll.dWhite)
    black  = cBlack + min_c( frame.dBlack − cBlack )  (lowest offset ⇒ no channel's black is above the frame's)
    white  = cWhite + max_c( frame.dWhite − cWhite )  (highest offset ⇒ no channel's white is below the frame's)

The *relation between channels* (= colour balance, crossover) comes from the roll, the *level* is
fitted to this frame so nothing clips. A sunset's dominant channel reaches white, the others stay
below → it stays a sunset, and neighbouring frames match.

Editing any density slider switches the frame to **Manual**.

---

## 5. Exposure & White Balance

Applied as one **linear per-channel gain**, which is the physically correct place for both:

    gain = 2^EV · ( 2^(T + M),  1,  2^(−T + M) )        (R, G, B)
    lin' = lin · gain

| Slider | Range | Meaning |
|---|---|---|
| Exposure | −3…+3 EV | ×2 per EV on all channels |
| Temperature | ±100 (= ±1 in log2) | +T: red × 2^T, blue × 2^−T → warmer. ±100 = ±1 stop each way (R/B ratio ±2 stops) |
| Tint | ±100 | +M: red and blue × 2^M relative to green → magenta; − → green |

**WB picker (⌥⌘W)** samples the inverted positive *before* the current tone (so it's absolute,
not relative) and solves for the gains that make that sample neutral:

    a = log2(G/R),  b = log2(G/B)      (wanted red and blue gains, in stops)
    T = (a − b)/2,  M = (a + b)/2

**Match WB to Reference** uses grey-world on *midtone, near-neutral* pixels of both frames
(after gain, luminance 0.03…0.6, (max−min)/max < 0.35): `gain_new = gain_ref · mean_ref / mean_cur`.

---

## 6. Paper (Print on paper)

A print curve on the scene-linear image, same on R, G and B. In natural-log units
(`X = ln(lin/0.18)`, `Y = ln(reflectance)`):

    straight line   Y  = grade · X + ln 0.18                     mid-grey stays 18 %
    shoulder        Y₁ = −s · softplus(−Y / s)                    ≈ min(Y, 0), smoothed  → paper white
    toe             Y₂ = Yb + t · softplus((Y₁ − Yb) / t)         ≈ max(Y₁, Yb), smoothed → paper black
    Yb = −blackDensity · ln 10,     softplus(z) = ln(1 + e^z)
    lin' = e^Y₂

| Slider | Range | Meaning |
|---|---|---|
| Contrast (grade) | 0.6…2.4 (Soft 1.0, Normal 1.2, Hard 1.5) | log–log slope through mid-grey: a stop in → `grade` stops out |
| Paper black | D 1.2…2.4 (glossy 2.05, satin 1.85, matte 1.6) | deepest black = 10^−D: 0.9 % glossy, 1.4 % satin, 2.5 % matte |
| Highlight roll-off (s) | 0.05…0.8 | shoulder softness: where the line would hit white, output is `e^(−s·ln2)` (s = 0.25 → 84 %) |
| Shadow roll-off (t) | 0.1…1.5 | toe softness: larger = more open shadows near black |

Defaults (grade 1.2, D 2.05, s 0.25, t 0.5), linear in → out:

| in | 0.001 | 0.01 | 0.05 | 0.18 | 0.5 | 1.0 | 2.0 | 4.0 |
|---|---|---|---|---|---|---|---|---|
| out | 0.009 | 0.011 | 0.040 | 0.180 | 0.594 | 0.945 | 0.998 | 1.000 |

So values above 1.0 that would have clipped **roll smoothly into paper white**, deep shadows
roll into the paper's black instead of hard 0. Because the same curve is used for R, G and B,
neutrals stay neutral; very saturated highlights desaturate a bit as they approach white — like
a real print. Brightness = Exposure *before* the curve (= print exposure time).

---

## 7. Levels (per channel, then RGB/master)

On γ 2.2-encoded values `e = lin^(1/2.2)`:

    e₁ = ((e − black_c) / (white_c − black_c)) ^ (1 / mid_c)        per channel
    e₂ = ((e₁ − black_m) / (white_m − black_m)) ^ (1 / mid_m)       master
    lin' = e₂^2.2

| Slider | Range | Meaning |
|---|---|---|
| Black | −0.2…0.6 | encoded value that becomes 0 (negative = lift blacks) |
| Midtone | 0.3…3.0 | gamma; > 1 brightens mids (Photoshop convention) |
| White | 0.4…1.5 | encoded value that becomes 1 (> 1 = pull highlights down) |

Nothing is clamped: values outside 0…1 continue (the clipping overlay shows what will clip).

---

## 8. Curves (RGB / R / G / B)

Also on γ 2.2 values. Points → **monotone cubic Hermite spline** (Fritsch–Carlson tangent
limiting, so the curve never overshoots or reverses between points). The four curves are baked
into a **1024-entry LUT** holding `master(channel(x))`, linearly interpolated on the GPU;
outside 0…1 the end-segment slope is extrapolated (an identity curve stays identity for
extended values).

---

## 9. Colour Mixer

Per-band HSL-style edits on HSV of γ 2.2 values. 8 bands, centred at
Red 0°, Orange 30°, Yellow 60°, Green 120°, Aqua 180°, Blue 225°, Purple 270°, Magenta 315°.
A pixel between two band centres gets a **linear blend** of the two bands' settings (no seams).

    w   = smoothstep(0.03, 0.25, S)               protects neutrals (low saturation ⇒ ~no change)
    H' = H + Δhue · w                              Δhue: ±30°
    S' = clamp(S · (1 + Δsat · w), 0, 1)           Δsat: ±100 ⇒ ×0 … ×2
    V' = V · (1 + 0.5 · Δlum · w)                  Δlum: ±100 ⇒ ±50 % brightness

It runs **before** Presence, so with Saturation −100 (B&W) the mixer's luminance still sees the
original colours → it works as a **B&W channel mixer / colour filter** (darken blue = red-filter sky).

---

## 10. Presence (Vibrance, Saturation) — OkLab

Converted to OkLab (`L` lightness, `a,b` colour). Only chroma `(a, b)` is scaled, `L` is untouched,
so brightness doesn't shift (unlike HSV saturation, where yellows glow and blues darken).

    C = |(a, b)|                                   chroma
    w = 1 − smoothstep(0, 0.20, C)                 vibrance weight: high for dull colours
    if vibrance > 0:  w *= 1 − 0.6 · exp(−(h − 55°)² / (2·20²)) · smoothstep(0.02, 0.06, C)   skin protection
    k = max(0, (1 + saturation) · (1 + vibrance · w))
    (a, b) ← k · (a, b)

| Slider | Range | Meaning |
|---|---|---|
| Saturation | ±100 | chroma × (1 + s): −100 = B&W at unchanged lightness, +100 = ×2 |
| Vibrance | ±100 | same but weighted to muted colours and away from skin hues (OkLab h ≈ 55°) |

---

## 11. Sharpen (last)

Luminance-only unsharp mask on γ 2.2 values (even halos, unlike linear):

    Y  = 0.2126 R + 0.7152 G + 0.0722 B          (of γ-encoded colour)
    d  = Y − GaussianBlur(Y, σ = radius)
    w  = smoothstep(t/2, 3t/2, |d|),  t = threshold / 255
    e' = e + amount · w · d                       same offset on R, G, B ⇒ no colour fringes

| Slider | Range | Meaning |
|---|---|---|
| Amount | 0…300 % | strength (0 = off) |
| Radius | 0.3…3 px | σ in **full-resolution** scan pixels (preview scales it, so judge at 1:1) |
| Threshold | 0…20 levels | soft knee: differences below ~t are left alone (grain, skies, skin) |

---

## 12. Before, clipping, output

- **Before (hold `\`)**: the plain inversion — crop, spots, base and points kept; tone, paper,
  levels, curves, mixer, presence, sharpening reset.
- **Clipping overlay (J)**: the working-space colour is converted to the export primaries
  (linear sRGB → Adobe RGB matrix for TIFF, identity for sRGB JPEG) and compared with the values
  that *encode* to 0.5/255 and 254.5/255. Any channel ≥ white → red, ≤ black → blue, both
  (out of gamut on both sides) → magenta.
- **Export**: full-resolution fresh decode, rendered in **32-bit float** (log/exp density maths
  amplifies half-float error in deep shadows; preview uses half float), then
  TIFF 16-bit Adobe RGB (1998) or JPEG 8-bit sRGB.

---

## Cheat sheet

| Control | Space | Operation |
|---|---|---|
| RAW Temperature/Tint/Exposure | camera → linear | decoder gains — cancel after base division; headroom only |
| Film base | linear | `T = raw / base` |
| Density Black/White | log10 (density) | per-channel black/white points of the inversion |
| Range | log10 | contrast of the inversion (`10^R` : 1 between white and black) |
| Exposure | linear | × 2^EV |
| Temperature / Tint | linear (log2 gains) | R × 2^(T+M), B × 2^(−T+M) |
| Paper grade / black / roll-offs | ln–ln | straight line through 0.18 + soft shoulder & toe |
| Levels | γ 2.2 | `((e − b)/(w − b))^(1/mid)` |
| Curves | γ 2.2 | monotone cubic spline LUT |
| Colour mixer | HSV on γ 2.2 | per-band hue / sat / value, neutrals protected |
| Vibrance / Saturation | OkLab | scale chroma, keep lightness |
| Sharpen | luma on γ 2.2 | unsharp mask with soft threshold |
