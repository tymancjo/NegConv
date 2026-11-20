import SwiftUI

/// Click on something that should be neutral grey to set the white balance.
struct WhiteBalanceOverlay: View {
    let imageSize: CGSize
    var message = "Click a neutral grey or white area (asphalt, concrete, white paint)"
    /// Called with the clicked point, normalised y-up in the displayed (cropped) image.
    let onPick: (CGPoint) -> Void

    var body: some View {
        GeometryReader { geo in
            let fit = FitLayout.fitRect(content: imageSize, in: geo.size)
            ZStack {
                Color.white.opacity(0.001)
                    .onTapGesture(coordinateSpace: .local) { p in
                        guard fit.contains(p) else { return }
                        onPick(CGPoint(x: (p.x - fit.minX) / fit.width,
                                       y: 1 - (p.y - fit.minY) / fit.height))
                    }
                    .onHover { inside in
                        if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
                    }
                Text(message)
                    .font(.callout)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .position(x: geo.size.width / 2, y: 22)
                    .allowsHitTesting(false)
            }
        }
    }
}
