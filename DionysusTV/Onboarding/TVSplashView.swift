import SwiftUI

/// Shown while `AppState` restores the session (`isRestoringSession`), as
/// iOS's `SplashView` is. It takes over from `LaunchScreen.storyboard`
/// (`DionysusTV/Resources/`) without a cut: the same burgundy
/// (`LaunchBackground`) and the glyph at the same size and place, with the
/// brand mesh and the glyph's shadow fading in over them. `TVRootView`
/// crossfades it into whatever comes next.
struct TVSplashView: View {
    /// The glyph's artwork size, matching Welcome's. The storyboard's
    /// `LaunchGlyph` frame is 352pt because its artwork fills 1068/1253 of its
    /// viewBox, while `DionysusGlyph` is trimmed to its artwork; the artwork
    /// sits off-centre in `LaunchGlyph`'s viewBox, so the storyboard moves it
    /// 2pt right and 3pt up to land where this one draws it.
    static let glyphSize: CGFloat = 300

    /// Gates the spinner, as on iOS: restoring is usually near-instant.
    @State private var showsSpinner = false
    private static let spinnerDelay: Duration = .seconds(3)
    @State private var showsBrand = false

    var body: some View {
        ZStack {
            Color("LaunchBackground")
                .ignoresSafeArea()
            TVBrandBackground { Color.clear }
                .opacity(showsBrand ? 1 : 0)
            Image("DionysusGlyph")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white)
                .frame(width: Self.glyphSize, height: Self.glyphSize)
                .shadow(color: .black.opacity(showsBrand ? 0.45 : 0), radius: 24, y: 16)
                .accessibilityHidden(true)
        }
        // Below the glyph, clear of its shadow.
        .overlay(alignment: .bottom) {
            if showsSpinner {
                TVWhiteSpinner()
                    .padding(.bottom, 160)
                    .transition(.opacity)
                    .accessibilityIdentifier(A11yID.TV.Onboarding.splashSpinner)
            }
        }
        .animation(.easeInOut, value: showsSpinner)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6)) { showsBrand = true }
        }
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
    TVSplashView()
}
