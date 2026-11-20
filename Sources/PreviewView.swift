import CoreImage
import MetalKit
import SwiftUI

/// A magnified view request: either a circular loupe at the cursor or a full-window 1:1 view.
struct DetailRequest {
    enum Kind {
        /// `viewPoint` in SwiftUI points (y-down), `radius` in points.
        case loupe(viewPoint: CGPoint, radius: CGFloat)
        case actual
    }
    var kind: Kind
    /// Processed image to magnify (full-res when available, else the preview).
    var image: CIImage
    /// Centre of the magnified area, normalised y-up in `image`.
    var center: CGPoint
    /// Device pixels per image pixel (1 = 100 % on a full-res source).
    var pixelZoom: CGFloat
    /// True when `image` is the full-resolution decode (enables nearest-neighbour above 100 %).
    var isFullRes: Bool
}

/// Metal-backed preview. Draws on demand (not every frame) with the shared preview CIContext.
/// Layout comes from `FitLayout`, the same function SwiftUI overlays use.
struct PreviewView: NSViewRepresentable {
    var image: CIImage?
    var detail: DetailRequest?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: RenderEngine.device)
        view.delegate = context.coordinator
        view.framebufferOnly = false              // Core Image writes into the drawable texture
        view.colorPixelFormat = .rgba16Float      // no 8-bit banding in smooth gradients
        view.colorspace = RenderEngine.displaySpace
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.autoResizeDrawable = true
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.image = image
        context.coordinator.detail = detail
        view.needsDisplay = true
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var image: CIImage?
        var detail: DetailRequest?

        private let queue: MTLCommandQueue = RenderEngine.device.makeCommandQueue()!
        /// Neutral dark surround (≈ #1C1C1C, explicit sRGB) — dark so the print is judged against a
    /// neutral, unlit surround rather than the window's light chrome.
    private let backgroundColor = CIColor(red: 0.11, green: 0.11, blue: 0.11,
                                          colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
        private lazy var background = CIImage(color: backgroundColor)

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            view.needsDisplay = true
        }

        func draw(in view: MTKView) {
            let size = view.drawableSize
            guard size.width > 0, size.height > 0,
                  let drawable = view.currentDrawable,
                  let commandBuffer = queue.makeCommandBuffer() else { return }

            let bounds = CGRect(origin: .zero, size: size)
            let scale = size.width / max(view.bounds.width, 1)        // points → pixels
            var output = background.cropped(to: bounds)

            if let detail, case .actual = detail.kind {
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                output = magnified(detail, at: centre).composited(over: output)
            } else {
                if let image {
                    output = place(image, viewPoints: view.bounds.size, scale: scale)
                        .composited(over: output)
                }
                if let detail, case let .loupe(p, radius) = detail.kind {
                    // SwiftUI y-down points → Core Image y-up pixels.
                    let centre = CGPoint(x: p.x * scale, y: (view.bounds.height - p.y) * scale)
                    output = loupe(detail, at: centre, radius: radius * scale, over: output)
                }
            }

            let destination = CIRenderDestination(
                width: Int(size.width), height: Int(size.height),
                pixelFormat: view.colorPixelFormat,
                commandBuffer: commandBuffer,
                mtlTextureProvider: { drawable.texture })
            destination.colorSpace = RenderEngine.displaySpace

            do {
                _ = try RenderEngine.previewContext.startTask(toRender: output, from: bounds,
                                                              to: destination, at: .zero)
            } catch {
                print("Preview render failed: \(error)")
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        // MARK: - Fit view

        /// Scale into the fit rect (computed in points, converted to pixels). The fit rect is
        /// centred, so it is the same in y-up (Core Image) and y-down (SwiftUI) coordinates.
        private func place(_ image: CIImage, viewPoints: CGSize, scale: CGFloat) -> CIImage {
            let e = image.extent
            guard e.width > 0, e.height > 0 else { return image }
            let fitPt = FitLayout.fitRect(content: e.size, in: viewPoints)
            let fit = CGRect(x: fitPt.minX * scale, y: fitPt.minY * scale,
                             width: fitPt.width * scale, height: fitPt.height * scale)
            let s = fit.width / e.width

            // Clamp first so the resampler sees repeated edge pixels instead of transparency
            // (no faded / semi-transparent fringe), then crop back to the exact scaled frame.
            var img = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                .clampedToExtent()
            if s < 1 {
                // Lanczos: sharper and less aliased than bilinear when downscaling.
                img = img.applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: s, kCIInputAspectRatioKey: 1.0])
            } else {
                img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
            }
            let scaled = CGRect(x: 0, y: 0, width: e.width * s, height: e.height * s).integral
            return img.cropped(to: scaled)
                .transformed(by: CGAffineTransform(translationX: fit.minX.rounded(), y: fit.minY.rounded()))
        }

        // MARK: - Magnification

        /// The detail image scaled by `pixelZoom` so that its `center` lands on `point` (pixels).
        /// At exactly 100 % the translation is whole pixels, so there is no resampling at all;
        /// above 100 % on full-res data, nearest-neighbour shows real pixels instead of blur.
        private func magnified(_ d: DetailRequest, at point: CGPoint) -> CIImage {
            var src = d.image
            let e = src.extent
            if d.isFullRes && d.pixelZoom > 1.01 { src = src.samplingNearest() }
            let c = CGPoint(x: e.minX + d.center.x * e.width, y: e.minY + d.center.y * e.height)
            let tx = (point.x - c.x * d.pixelZoom).rounded()
            let ty = (point.y - c.y * d.pixelZoom).rounded()
            var img = src
            if abs(d.pixelZoom - 1) > 0.001 {
                img = img.transformed(by: CGAffineTransform(scaleX: d.pixelZoom, y: d.pixelZoom))
            }
            return img.transformed(by: CGAffineTransform(translationX: tx, y: ty))
        }

        private func loupe(_ d: DetailRequest, at p: CGPoint, radius r: CGFloat,
                           over output: CIImage) -> CIImage {
            let square = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            let content = magnified(d, at: p)
                .composited(over: background)
                .cropped(to: square)
            // Generator filter (no input image), so build it with CIFilter rather than applyingFilter.
            let gradient = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: p.x, y: p.y),
                "inputRadius0": max(r - 1.5, 0),
                "inputRadius1": r,
                "inputColor0": CIColor.white,
                "inputColor1": CIColor.clear
            ])?.outputImage ?? CIImage(color: .white)
            let mask = gradient.cropped(to: square)
            return content.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: output,
                kCIInputMaskImageKey: mask
            ])
        }
    }
}
