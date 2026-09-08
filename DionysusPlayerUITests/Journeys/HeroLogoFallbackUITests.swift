import XCTest

/// `LogoImageView`'s delayed fallback-text reveal (see that type's own doc
/// comment) is invisible to VoiceOver by design — `BackdropLogoOverlay`
/// hides its whole visual layer from accessibility, and
/// `PlayerControlsOverlay`'s title row collapses its children the same way
/// via `.accessibilityElement(children: .ignore)` — so neither the fallback
/// text nor the real logo image is independently queryable from a UI test.
/// `heroLogoFallbackVisible` (declared alongside every other test-only
/// signal, gated on `UITestConfiguration.isActive` so it never exists
/// outside the harness) is the one exception, added specifically so this
/// timing has *some* automated coverage instead of none.
///
/// Both tests launch with the `slowLogoImage` scenario, which delays only
/// the `Logo` image response (`UITestStubURLProtocol.slowLogoImageDelay`,
/// 2s) — comfortably past `LogoImageView`'s own 1s reveal delay, so the
/// fallback is guaranteed to appear, and comfortably inside each
/// `waitForExistence`/`awaitDisappearance` budget below.
final class HeroLogoFallbackUITests: UITestCase {
    /// The asset-detail hero header: `BackdropLogoOverlay`'s
    /// `.accessibilityHidden` case.
    func testSlowLogoOnAssetDetailEventuallyShowsThenHidesFallback() {
        launch(scenario: "slowLogoImage")
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.primaryMovieID)

        let detail = AssetDetailScreen(app: app)
        detail.awaitLoaded()

        detail.heroLogoFallbackVisible.awaitExistence(
            "the hero fallback text once the logo has taken longer than its reveal delay"
        )
        // Once the (still-delayed, but finite) logo request resolves,
        // `LogoImageView` hides the fallback again on the spot — same
        // cross-fade-back-to-logo behaviour a fast load exercises from the
        // very first frame, just reached from a state where the fallback
        // was showing first.
        detail.heroLogoFallbackVisible.awaitDisappearance(
            "the hero fallback text once the delayed logo has finished loading"
        )
    }

    /// The player's title row: `PlayerControlsOverlay`'s
    /// `.accessibilityElement(children: .ignore)` case — a structurally
    /// different way of hiding the same content, worth covering
    /// separately rather than assuming one proves the other.
    func testSlowLogoInPlayerEventuallyShowsThenHidesFallback() {
        launch(scenario: "slowLogoImage")
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.primaryMovieID)
        AssetDetailScreen(app: app).play()

        let player = PlayerScreen(app: app)
        player.awaitControls()

        player.heroLogoFallbackVisible.awaitExistence(
            "the player title row's fallback text once the logo has taken longer than its reveal delay"
        )
        player.heroLogoFallbackVisible.awaitDisappearance(
            "the player title row's fallback text once the delayed logo has finished loading"
        )
    }
}
