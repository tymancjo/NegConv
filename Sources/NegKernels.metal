// Core Image Metal kernels for NegConv.
// Compiled and linked with -fcikernel (MTL_COMPILER_FLAGS / MTLLINKER_FLAGS).

#include <CoreImage/CoreImage.h>
using namespace metal;

/// Sign-preserving power, so extended-range (negative) values pass through instead of NaN.
static inline float3 spow(float3 x, float3 p) {
    return sign(x) * pow(abs(x), p);
}

/// HSV conversions (branch-free), hue in 0…1.
static inline float3 rgb2hsv(float3 c) {
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

static inline float3 hsv2rgb(float3 c) {
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

/// Core Image hands kernels PREMULTIPLIED colour. Our maths (log/density, gamma, OkLab) needs
/// the real colour, so every kernel unpremultiplies first and premultiplies its result.
/// Fully transparent pixels (outside the frame, straighten corners) stay transparent black —
/// otherwise "no light through the film" would invert to a huge value and bleed into the
/// background and frame edges as white.
static inline float3 unpremul(coreimage::sample_t s) { return s.rgb / max(s.a, 1.0e-6); }
static inline float4 premul(float3 c, float a) { return a > 0.0 ? float4(c * a, a) : float4(0.0); }

/// Numerically stable softplus: ln(1 + e^z) without overflow.
static inline float3 softplus(float3 z) {
    return max(z, float3(0.0)) + log(1.0 + exp(-abs(z)));
}

/// Linear sRGB ↔ OkLab (Björn Ottosson, 2020). Sign-preserving cube root keeps
/// extended-range (negative) values finite.
static inline float3 linearSRGBToOklab(float3 c) {
    float l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b;
    float m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b;
    float s = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b;
    float3 q = spow(float3(l, m, s), float3(1.0 / 3.0));
    return float3(0.2104542553 * q.x + 0.7936177850 * q.y - 0.0040720468 * q.z,
                  1.9779984951 * q.x - 2.4285922050 * q.y + 0.4505937099 * q.z,
                  0.0259040371 * q.x + 0.7827717662 * q.y - 0.8086757660 * q.z);
}

static inline float3 oklabToLinearSRGB(float3 lab) {
    float l = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z;
    float m = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z;
    float s = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z;
    l = l * l * l; m = m * m * m; s = s * s * s;
    return float3( 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                  -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                  -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s);
}

extern "C" {
namespace coreimage {

/// Density inversion of a linear, camera-scanned colour negative.
///
///   T  = raw / base            transmittance relative to the film base (orange mask removed)
///   D  = −log10(T)             density above base, ≥ 0 for image areas
///   L  = 10^(slope·(D − dWhite)) back to scene-linear; dWhite maps to 1.0
///   L' = (L − lbp)/(1 − lbp)   linear black point; dBlack maps to 0.0
///
/// slope = range / (dWhite − dBlack) per channel equalises the three dye layers' contrast,
/// which is what removes most of the colour crossover. lbp = 10^(−range).
float4 negInvert(sample_t s, float3 base, float3 dWhite, float3 slope, float lbp) {
    float3 t = max(unpremul(s) / base, float3(1.0e-6));
    float3 d = -log10(t);
    float3 L = exp10(slope * (d - dWhite));
    float3 o = (L - lbp) / (1.0 - lbp);
    return premul(o, s.a);
}

/// Positive adjustments.
///   1. gain: exposure (2^EV) × white-balance channel gains — physically correct in LINEAR light.
///   2. levels: done on a perceptual (γ 2.2) encoding, where black/white/midtone sliders behave
///      the way photographers expect; per channel first, then master. Back to linear after.
///   2. paper (optional): print curve in log-log space — straight line of slope `grade` through
///      mid-grey (0.18 stays 0.18), soft shoulder into paper white (1.0), soft toe into paper black.
///   3. levels (as above).
/// No clamping anywhere: values outside 0…1 survive to the output stage (paper maps into 0…1).
/// paper: x = on (0/1), y = grade, z = ln(paper black), w = unused; soft: x = shoulder, y = toe.
float4 negTone(sample_t s, float3 gain,
               float3 cBlack, float3 cWhite, float3 cGamma,
               float3 master /* x = black, y = white, z = gamma */,
               float4 paper, float2 soft) {
    float3 lin = unpremul(s) * gain;
    if (paper.x > 0.5) {
        float3 x = log(max(lin, float3(1.0e-6)) / 0.18);
        float3 y = paper.y * x + log(0.18);
        float3 y1 = -soft.x * softplus(-y / soft.x);                      // shoulder → paper white
        float3 yo = paper.z + soft.y * softplus((y1 - paper.z) / soft.y); // toe → paper black
        lin = exp(yo);
    }
    float3 e = spow(lin, float3(1.0 / 2.2));
    e = (e - cBlack) / max(cWhite - cBlack, float3(1.0e-4));
    e = spow(e, 1.0 / cGamma);
    e = (e - master.x) / max(master.y - master.x, 1.0e-4);
    e = spow(e, float3(1.0 / master.z));
    return premul(spow(e, float3(2.2)), s.a);
}


/// Colour mixer: per-band hue / saturation / luminance on γ 2.2-encoded HSV.
/// Band centres (degrees): red 0, orange 30, yellow 60, green 120, aqua 180, blue 225,
/// purple 270, magenta 315. Each pixel's adjustment is linearly interpolated between the two
/// bands its hue falls between, so there are no seams. Low-saturation pixels are protected
/// (neutral greys and whites don't shift).
/// Arguments: hue shift in degrees, saturation and luminance in −1…1; bands 0–3 in *A, 4–7 in *B.
float4 negColorMix(sample_t s, float4 hueA, float4 hueB, float4 satA, float4 satB,
                   float4 lumA, float4 lumB) {
    float3 e = spow(unpremul(s), float3(1.0 / 2.2));
    float3 hsv = rgb2hsv(max(e, float3(0.0)));

    float centres[9] = { 0.0, 30.0, 60.0, 120.0, 180.0, 225.0, 270.0, 315.0, 360.0 };
    float H[8] = { hueA.x, hueA.y, hueA.z, hueA.w, hueB.x, hueB.y, hueB.z, hueB.w };
    float S[8] = { satA.x, satA.y, satA.z, satA.w, satB.x, satB.y, satB.z, satB.w };
    float L[8] = { lumA.x, lumA.y, lumA.z, lumA.w, lumB.x, lumB.y, lumB.z, lumB.w };

    float h = hsv.x * 360.0;
    int i = 0;
    for (int k = 0; k < 8; k++) { if (h >= centres[k]) { i = k; } }
    int j = (i + 1) % 8;
    float t = (h - centres[i]) / (centres[i + 1] - centres[i]);

    float w = smoothstep(0.03, 0.25, hsv.y);           // protect neutrals
    float dh = mix(H[i], H[j], t) * w;
    float ds = mix(S[i], S[j], t) * w;
    float dl = mix(L[i], L[j], t) * w;

    hsv.x = fract(hsv.x + dh / 360.0 + 1.0);
    hsv.y = clamp(hsv.y * (1.0 + ds), 0.0, 1.0);
    hsv.z = hsv.z * (1.0 + 0.5 * dl);

    float3 rgb = hsv2rgb(hsv);
    return premul(spow(rgb, float3(2.2)), s.a);
}

/// Global saturation and vibrance in OkLab: only chroma (a, b) is scaled, lightness L is
/// untouched, so brightness doesn't shift the way HSV saturation does (yellows glowing,
/// blues darkening).
/// Vibrance is weighted towards dull colours (low chroma) and away from skin tones
/// (OkLab hue ≈ 55°), so it lifts muted areas without overcooking faces or saturated objects.
float4 negPresence(sample_t s, float sat, float vib) {
    float3 lab = linearSRGBToOklab(unpremul(s));
    float C = length(lab.yz);
    float w = 1.0 - smoothstep(0.0, 0.20, C);
    if (vib > 0.0) {
        float h = atan2(lab.z, lab.y) * 57.29578;           // degrees
        float dh = h - 55.0;
        w *= 1.0 - 0.6 * exp(-(dh * dh) / (2.0 * 20.0 * 20.0)) * smoothstep(0.02, 0.06, C);
    }
    float k = max(0.0, (1.0 + sat) * (1.0 + vib * w));
    lab.yz *= k;
    return premul(oklabToLinearSRGB(lab), s.a);
}


/// One channel of the curves LUT (1024 × 1, entry i = curve(i / (n − 1))), linearly
/// interpolated; beyond 0…1 extrapolated with the end-segment slope, so extended-range
/// values keep a sensible mapping (identity curves stay identity).
static inline float lutAt(coreimage::sampler lut, float v, float n, int ch) {
    float4 s = lut.sample(lut.transform(float2(v * (n - 1.0) + 0.5, 0.5)));
    return s[ch];
}

static inline float curve1(coreimage::sampler lut, float x, float n, int ch) {
    float h = 1.0 / (n - 1.0);
    if (x > 1.0) {
        float y1 = lutAt(lut, 1.0, n, ch), y0 = lutAt(lut, 1.0 - h, n, ch);
        return y1 + (x - 1.0) * (y1 - y0) / h;
    }
    if (x < 0.0) {
        float y0 = lutAt(lut, 0.0, n, ch), y1 = lutAt(lut, h, n, ch);
        return y0 + x * (y1 - y0) / h;
    }
    return lutAt(lut, x, n, ch);
}

/// Tone curves on γ 2.2 values (the LUT already holds master ∘ channel).
float4 negCurves(coreimage::sampler src, coreimage::sampler lut, float n) {
    float4 s = src.sample(src.coord());
    if (s.a <= 0.0) return float4(0.0);
    float3 g = spow(s.rgb / s.a, float3(1.0 / 2.2));
    float3 o = float3(curve1(lut, g.r, n, 0), curve1(lut, g.g, n, 1), curve1(lut, g.b, n, 2));
    return premul(spow(o, float3(2.2)), s.a);
}


/// Output clipping overlay. m0…m2: rows of the working (linear sRGB) → output-primaries matrix;
/// lim.x / lim.y: linear values the output encoding shows as pure black / pure white.
/// Highlights (any channel ≥ white) → red, shadows (any channel ≤ black) → blue, both (a colour
/// outside the output gamut on both sides) → magenta. Everything else passes through.
float4 negClip(coreimage::sample_t s, float3 m0, float3 m1, float3 m2, float2 lim) {
    if (s.a <= 0.0) return s;
    float3 c = unpremul(s);
    float3 o = float3(dot(m0, c), dot(m1, c), dot(m2, c));
    bool hi = any(o >= float3(lim.y));
    bool lo = any(o <= float3(lim.x));
    if (!hi && !lo) return s;
    float3 k = (hi && lo) ? float3(1.0, 0.0, 1.0) : (hi ? float3(1.0, 0.0, 0.0) : float3(0.0, 0.25, 1.0));
    return premul(k, s.a);
}


/// Sharpening, step 1: luma of the γ 2.2-encoded colour (Rec. 709 weights) as an opaque grey
/// image, which Swift then blurs. Encoded, not linear: an unsharp mask on linear values makes
/// lopsided halos (strong bright rims, weak dark ones); on γ values they look even.
float4 negSharpLuma(coreimage::sample_t s) {
    float3 e = spow(unpremul(s), float3(1.0 / 2.2));
    float y = dot(e, float3(0.2126, 0.7152, 0.0722));
    return float4(y, y, y, 1.0);
}

/// Sharpening, step 2: luminance-only unsharp mask.
///   d = Y − blur(Y)                          detail at the chosen radius (γ-encoded luma)
///   w = smoothstep(t/2, 3t/2, |d|)           soft threshold: small differences (grain, noise,
///                                             smooth tones) are left alone, real edges pass
///   e' = e + amount · w · d                   same offset on R, G and B → only brightness
///                                             changes, so no colour fringes and no boosted
///                                             chroma noise in the dye clouds.
float4 negSharpen(coreimage::sample_t s, coreimage::sample_t blurred, float amount, float threshold) {
    if (s.a <= 0.0) return s;
    float3 e = spow(unpremul(s), float3(1.0 / 2.2));
    float y = dot(e, float3(0.2126, 0.7152, 0.0722));
    float d = y - blurred.r;
    float w = threshold > 0.0 ? smoothstep(0.5 * threshold, 1.5 * threshold, abs(d)) : 1.0;
    e += amount * w * d;
    return premul(spow(e, float3(2.2)), s.a);
}

}
}
