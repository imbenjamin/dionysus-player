import SwiftUI

/// Layout constants shared by the two pre-authentication screens,
/// `ServerSetupView` and `LoginView`.
enum SignInLayout {
    /// Cap for the credentials column — see `signInColumn()`.
    ///
    /// Derived the same way `SettingsLayout.readableFooterWidth` and
    /// `DetailLayout.readableContentWidth` are, from this app's own
    /// measured rendering rather than a round number.
    /// `ServerSetupView`'s 66-character subtitle renders on one line at
    /// a measured 471.5pt of `.body` text, i.e. ~7.14pt per character.
    ///
    /// 500 bounds the column including its own `contentPadding` gutters,
    /// so the text inside gets 452pt, or ~63 characters — inside the
    /// conventional 45-75 optimum, and deliberately at the tighter end
    /// of it. This is the narrowest of the app's three column caps
    /// because these two screens hold the shortest content there is: a
    /// server address and a username, not the paragraphs the other two
    /// were sized around. Taking the same ~75-character target used
    /// there would give a 532pt-wide field for a ten-character
    /// username, which reads as a layout that failed to stop — the very
    /// complaint the cap exists to answer.
    static let credentialsWidth: CGFloat = 500

    /// Inset between the credentials column and the screen edges, and
    /// the horizontal inset of the pinned action footer that lines up
    /// with it.
    static let contentPadding: CGFloat = 24
}

/// Constrains a pre-authentication screen's content to a readable
/// measure and centers it, leaving its contents leading-aligned.
///
/// Unconstrained, both screens ran the full width of the device —
/// measured at 820pt in iPad portrait and 1180pt in landscape on an
/// 11-inch device. That put a 1,132pt text field around a single IP
/// address, and a 1,132pt primary button against HIG's explicit "Avoid
/// full-width buttons". The Use HTTPS toggle was worse than either: its
/// label sat at the leading margin with its switch ~1,050pt away at the
/// trailing one, the same defect the detail pages' `SummaryRow` had
/// before `readableDetailColumn()`.
///
/// Unlike `readableDetailColumn()` and `readableSettingsFooter()`, this
/// is *not* gated on size class. Those cap content that a compact
/// screen already renders at a readable measure, so gating keeps them
/// no-ops on iPhone. Here the cap simply never binds below 500pt, and
/// on an iPhone in landscape (932pt wide) it's just as welcome as it is
/// on an iPad — the same reasoning `ReadableDetailColumn` gives for
/// keying off horizontal size class alone, taken one step further to no
/// gate at all.
///
/// Two `.frame`s for the same reason `ReadableDetailColumn` uses two:
/// the inner one caps the width and keeps contents left-aligned against
/// that cap, the outer one takes the full screen width and centers the
/// capped column within it.
private struct SignInColumn: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: SignInLayout.credentialsWidth, alignment: .leading)
            // Centers the capped column itself. A no-op on a screen
            // narrower than the cap, where the frame above already
            // fills the width.
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

extension View {
    /// See `SignInColumn`. Apply it *outside* the content's own padding,
    /// so the cap bounds the column including its gutters — that's the
    /// relationship `SignInLayout.credentialsWidth` is derived against.
    func signInColumn() -> some View {
        modifier(SignInColumn())
    }
}

/// Fades scrolled content out under the status bar on a pre-authentication
/// screen, which has no navigation bar to do it: without this, text scrolled
/// up runs straight through the clock.
///
/// Solid background across the status bar itself, fading to clear over
/// `fadeHeight` below it. Shown only once the content has scrolled, so the
/// resting layout's top item — flush with the safe area — is never dimmed.
///
/// The inset is measured on the scroll view (`onGeometryChange`), the way
/// `HomeView.topSafeAreaInset` does and for the same reason: a window lookup
/// misses any inset SwiftUI adds itself.
private struct StatusBarScrollFade: ViewModifier {
    static let fadeHeight: CGFloat = 20

    @State private var topInset: CGFloat = 0
    @State private var isScrolled = false

    func body(content: Content) -> some View {
        let background = Color(uiColor: .systemBackground)
        let height = topInset + Self.fadeHeight
        content
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 0.5
            } action: { _, scrolled in
                isScrolled = scrolled
            }
            .overlay(alignment: .top) {
                LinearGradient(
                    stops: [
                        .init(color: background, location: 0),
                        .init(color: background, location: height > 0 ? topInset / height : 0),
                        .init(color: background.opacity(0), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: height)
                .ignoresSafeArea(edges: .top)
                .opacity(isScrolled ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: isScrolled)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

extension View {
    /// See `StatusBarScrollFade`. Apply to the `ScrollView` itself.
    func statusBarScrollFade() -> some View {
        modifier(StatusBarScrollFade())
    }
}
