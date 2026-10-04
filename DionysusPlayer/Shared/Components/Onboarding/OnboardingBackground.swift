import SwiftUI

/// The brand surface behind the whole pre-sign-in journey — splash, welcome,
/// server setup and sign-in — so moving between them never cuts away from it.
///
/// A slowly drifting mesh of the palette's magenta and burgundy with a warm
/// ember, a vignette that settles the edges so the centre (where the content
/// is) glows, and — on the sign-in screen, once a server says it has one —
/// that server's own login splashscreen, blurred, on top.
///
/// Motion stops under Reduce Motion, and under the UI-test harness, where a
/// continuously redrawing view keeps the accessibility tree in motion under
/// every assertion.
struct OnboardingBackground: View {
    /// The server's `/Branding/Splashscreen`, when there is one to show.
    var backdropURL: URL?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.onboardingLayout) private var layout
    @State private var backdrop: UIImage?

    private var isMotionAllowed: Bool { OnboardingMotion.isAllowed(reduceMotion: reduceMotion) }

    var body: some View {
        ZStack {
            animatedMesh

            if let backdrop, !reduceTransparency {
                // Filled inside a screen-sized box and clipped: a bare
                // `scaledToFill` grows whatever contains it to the image's
                // aspect, which pushed the landscape panes off screen.
                Color.clear
                    .overlay {
                        Image(uiImage: backdrop)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
                    // Less blur on iPad, where the collage is large enough to
                    // read as the library it is.
                    .blur(radius: layout.isRegular ? 6 : 10)
                    .saturation(1.2)
                    .overlay { Color.dionysusMagenta.opacity(0.35).blendMode(.overlay) }
                    .overlay(Color.black.opacity(0.45))
                    .transition(.opacity)
            }

            RadialGradient(
                colors: [.clear, .black.opacity(layout.isRegular ? 0.4 : 0.2)],
                center: .center,
                startRadius: 200,
                endRadius: layout.isRegular ? 900 : 600
            )

            // Keeps whatever sits at the bottom legible, whatever the mesh or
            // the backdrop is doing there.
            LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .task(id: backdropURL) { await loadBackdrop() }
    }

    @ViewBuilder
    private var animatedMesh: some View {
        if isMotionAllowed {
            TimelineView(.animation) { context in
                // Slower on the big screen, where the same drift covers
                // several times the distance and reads as busy.
                Self.mesh(time: context.date.timeIntervalSinceReferenceDate * (layout.isRegular ? 0.7 : 1))
            }
        } else {
            Self.mesh(time: 0)
        }
    }

    private func loadBackdrop() async {
        guard let backdropURL else {
            withAnimation(.easeInOut(duration: 0.5)) { backdrop = nil }
            return
        }
        guard let image = try? await RemoteImageLoader.shared.image(for: backdropURL) else { return }
        // Shown blurred, so full resolution buys nothing but memory: the
        // splashscreen route ignores `maxWidth` and serves the admin's
        // original, which decoded to tens of megabytes.
        let scale = min(1, Self.backdropMaxDimension / max(image.size.width, image.size.height, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let thumbnail = await image.byPreparingThumbnail(ofSize: size) ?? image
        withAnimation(.easeInOut(duration: 0.8)) { backdrop = thumbnail }
    }

    private static let backdropMaxDimension: CGFloat = 1000

    /// Nine control points drifting on slow, out-of-phase sine waves. The
    /// lightest point is plain `dionysusMagenta`, which white text clears at
    /// ~5.1:1.
    static func mesh(time: Double) -> some View {
        let a = Float(sin(time * 0.31)) * 0.14
        let b = Float(cos(time * 0.23)) * 0.14
        let c = Float(sin(time * 0.19 + 1.3)) * 0.10
        let ember = Color(red: 0.62, green: 0.16, blue: 0.10)
        let deepMagenta = Color(red: 0.55, green: 0.02, blue: 0.26)
        let night = Color(red: 0.07, green: 0.00, blue: 0.04)
        return MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0, 0], [0.5 + a, 0], [1, 0],
                [0, 0.42 + b], [0.5 + c, 0.48 + a], [1, 0.55 - c],
                [0, 1], [0.5 - b, 1], [1, 1]
            ],
            colors: [
                .dionysusMagenta, deepMagenta, .dionysusBurgundy,
                ember, .dionysusMagenta, deepMagenta,
                .dionysusBurgundy, night, night
            ]
        )
    }
}

/// Whether the journey's ambient motion — the drifting background and the
/// scan radar — may run.
enum OnboardingMotion {
    static func isAllowed(reduceMotion: Bool) -> Bool {
        #if DEBUG
        if UITestHarness.freezesAmbientMotion { return false }
        #endif
        return !reduceMotion
    }
}
