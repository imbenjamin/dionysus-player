import SwiftUI
import UIKit

/// The onboarding flow's brand ground: the iOS mesh colours, drawn statically,
/// under the prototype's vignette. `photoURL` (the server's login artwork,
/// when it has one) is blended in softly over the mesh, as on Who's Watching?.
struct TVBrandBackground<Content: View>: View {
    var photoURL: URL? = nil
    @ViewBuilder var content: Content

    /// Loaded directly rather than through `AsyncRemoteImage`, whose loading
    /// and failure placeholder would show its glyph through the blend.
    @State private var photo: UIImage?

    var body: some View {
        ZStack {
            MeshGradient(
                width: 3, height: 3,
                points: [[0, 0], [0.55, 0], [1, 0], [0, 0.45], [0.5, 0.5], [1, 0.55], [0, 1], [0.5, 1], [1, 1]],
                colors: [
                    .dionysusMagenta, Color(red: 0.55, green: 0.02, blue: 0.26), .dionysusBurgundy,
                    Color(red: 0.62, green: 0.16, blue: 0.10), .dionysusMagenta, Color(red: 0.55, green: 0.02, blue: 0.26),
                    .dionysusBurgundy, Color(red: 0.07, green: 0, blue: 0.04), Color(red: 0.07, green: 0, blue: 0.04)
                ]
            )
            .ignoresSafeArea()

            if let photo {
                // In an overlay on a clear view, so the filled image takes the
                // screen's size rather than setting it: drawn directly in the
                // ZStack, it grew the stack past the screen and pushed the
                // content off it.
                Color.clear
                    .overlay {
                        Image(uiImage: photo)
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 10)
                            .saturation(1.2)
                    }
                    .clipped()
                    .opacity(0.55)
                    .blendMode(.softLight)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }

            // The prototype's vignette: darker at the edges and towards the bottom.
            ZStack {
                RadialGradient(colors: [.clear, .black.opacity(0.5)], center: UnitPoint(x: 0.5, y: 0.45), startRadius: 400, endRadius: 1100)
                LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: UnitPoint(x: 0.5, y: 0.5), endPoint: .bottom)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            content
        }
        .task(id: photoURL) {
            guard let photoURL else { photo = nil; return }
            photo = try? await RemoteImageLoader.shared.image(for: photoURL)
        }
    }
}
