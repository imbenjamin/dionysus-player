import SwiftUI

/// Branded splash shown while `AppState` restores the session
/// (`AppState.isRestoringSession`) — the first stage of `OnboardingFlowView`,
/// which supplies the background (`OnboardingBackground`). Sharing that
/// background and the glyph with the welcome screen is what lets a first
/// launch run from launch screen to splash to welcome as one scene: the glyph
/// moves, nothing cuts.
///
/// Deliberately mirrors `dionysus.icon` (the Icon Composer source of the app
/// icon): the glyph is `DionysusGlassGlyph`, glass masked to its own
/// silhouette. It no longer tilts with the device — see that type.
struct SplashView: View {
    /// The glyph's frame, matched to `LaunchScreen.storyboard` so the system
    /// launch snapshot hands over without a jump: the storyboard's 157pt frame
    /// holds `LaunchGlyph`, whose artwork fills 1068/1253 of its viewBox —
    /// 134pt — while `DionysusGlyph` is trimmed to its artwork. 134 is also
    /// what this splash measured before: a 179pt frame, projected down to
    /// 0.75x by the tilt effect's out-of-plane pivot, which SwiftUI's
    /// perspective applies even at zero tilt.
    static let glyphSize: CGFloat = 134

    /// Gates the loading spinner — session restore is typically near-instant,
    /// so showing it at once would mostly flash on every launch. Cancelled
    /// with the view if restoring finishes first.
    @State private var showsSpinner = false
    private static let spinnerDelay: Duration = .seconds(3)

    var body: some View {
        DionysusGlassGlyph()
            .onboardingGlyph()
            .frame(width: Self.glyphSize, height: Self.glyphSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Between the glyph and the bottom edge: close enough to belong
            // to this screen, clear of the glyph's shadow. White
            // rather than the usual `dionysusPrimary` spinner tint, because it
            // sits on the brand background, not a system one.
            .overlay(alignment: .bottom) {
                if showsSpinner {
                    ProgressView()
                        .tint(.white)
                        .padding(.bottom, 96)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut, value: showsSpinner)
            .task {
                do {
                    try await Task.sleep(for: Self.spinnerDelay)
                    showsSpinner = true
                } catch {
                    // Restoring finished first; nothing to show a spinner for.
                }
            }
    }
}

#Preview {
    ZStack {
        OnboardingBackground()
        SplashView()
    }
}
