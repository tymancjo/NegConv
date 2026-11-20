import CoreImage
import Metal

/// Shared GPU and Core Image state. One device, one preview context for the whole app.
///
/// Color-space policy (set once, never implicit):
/// - Working space: linear, extended range, sRGB/Rec.709 primaries. All pipeline math
///   (base division, density, exposure, levels) happens here. "Extended" means values
///   below 0 or above 1 survive between stages instead of being clamped.
/// - Preview drawable: extended sRGB (gamma-encoded). Core Image converts working → display
///   exactly once, at the very end of the preview render.
/// - Export: Adobe RGB (1998), 16-bit (milestone 5).
enum RenderEngine {
    static let device: MTLDevice = {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("NegConv requires Metal.")
        }
        return device
    }()

    static let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static let displaySpace = CGColorSpace(name: CGColorSpace.extendedSRGB)!
    static let exportSpace = CGColorSpace(name: CGColorSpace.adobeRGB1998)!

    /// Half-float is enough for interactive preview. Export will use a separate RGBAf context,
    /// because log/exp density math amplifies half-float quantisation in deep shadows.
    static let previewContext = CIContext(mtlDevice: device, options: [
        .workingColorSpace: workingSpace,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false
    ])
}
