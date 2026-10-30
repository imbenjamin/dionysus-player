import XCTest

/// Profile → Playback → Subtitle Style, through the player. The
/// Simulator's caption settings can't be changed from a test, so
/// `-UITestCustomCaptionStyle` stands in `SystemCaptionStyle.uiTestStyle`
/// (twice the size, yellow, a window) for them; the cue's height is what
/// tells the two looks apart. `SystemCaptionStyleTests` covers the mapping.
final class SubtitleAppearanceJourneyTests: UITestCase {
    private let customSystemStyle = ["-UITestCustomCaptionStyle", "YES"]

    /// Plays the movie with its SubRip track and returns the cue's height.
    private func subRipCueHeight(extraArguments: [String], screenshot name: String) -> CGFloat {
        launch(extraArguments: extraArguments)
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.primaryMovieID)
        AssetDetailScreen(app: app).play()
        let player = PlayerScreen(app: app)
        player.awaitControls()
        player.tracksButton.tap()
        player.trackNavigationRow("subtitle").awaitExistence("the Subtitles navigation row")
        player.trackNavigationRow("subtitle").tap()
        let subripOption = player.trackOption("subtitle", 0)
        subripOption.awaitExistence("the first (SubRip) subtitle row")
        subripOption.tap()
        subripOption.awaitDisappearance("the track picker after selecting a SubRip track")
        player.plainSubtitle.awaitExistence("the SubRip cue on the app's own overlay")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return player.plainSubtitle.frame.height
    }

    /// System, the default, draws what Settings asks for; Dionysus
    /// ignores it and draws the app's own look.
    func testMatchSystemFollowsTheSystemStyle_andDionysusDoesNot() {
        let system = subRipCueHeight(extraArguments: customSystemStyle, screenshot: "System")
        app.terminate()
        let dionysus = subRipCueHeight(
            extraArguments: customSystemStyle + ["-subtitleAppearance", "dionysus"], screenshot: "Dionysus"
        )
        XCTAssertGreaterThan(
            system, dionysus * 1.5,
            "At twice the size the system style's cue should be far taller (\(system) against \(dionysus))"
        )
    }

    /// The setting is in Playback, defaulting to System.
    func testTheSettingIsInPlayback() {
        launch()
        HomeScreen(app: app).awaitLoaded()
        TabBar(app: app).profile.tap()
        ProfileScreen(app: app).openPlaybackSettings()
        let picker = app.buttons[A11yID.Profile.subtitleAppearance]
        for _ in 0..<6 where !picker.isHittable { app.swipeUp() }
        picker.awaitExistence("the Subtitle Style picker")
    }
}
