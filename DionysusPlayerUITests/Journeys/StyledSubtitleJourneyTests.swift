import XCTest

/// Covers the authored-ASS subtitle path end to end through the real app:
/// selecting an ASS track, resolving it to a Jellyfin stream, fetching the
/// script, handing it to libass, and painting what comes back.
///
/// This is the one part of the subtitle stack a journey can prove. libass
/// composites a whole frame into a single bitmap, so there is no `Text` to
/// read — but the overlay carries the cue text as its accessibility label
/// (which is also what a VoiceOver user gets), so the label doubles as the
/// assertion. Everything upstream of the paint has to have worked for that
/// element to exist at all: the track-change announcement, the ordinal
/// mapping from engine track to `MediaStream`, the fetch, and libass parsing
/// a real script.
///
/// Runs against `PreviewPlaybackEngine` (`PlaybackEngineFactory`) and the
/// stubbed server, but libass itself is the real thing — the script comes from
/// `UITestStubURLProtocol.assScript` and is genuinely parsed and rendered.
final class StyledSubtitleJourneyTests: UITestCase {
    /// `PreviewPlaybackEngine`'s ASS track. Its id deliberately does NOT match
    /// the fixture's `MediaStream.index` (6) — the app pairs them by ordinal,
    /// and a fixture where the two happened to agree would pass even if that
    /// mapping were wrong.
    private let assTrackID = 2

    private func openPlayer(scenario: String = "standard", extraArguments: [String] = []) -> PlayerScreen {
        launch(scenario: scenario, extraArguments: extraArguments)
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.primaryMovieID)
        AssetDetailScreen(app: app).play()
        let player = PlayerScreen(app: app)
        player.awaitControls()
        return player
    }

    private func selectASSTrack(_ player: PlayerScreen) {
        player.tracksButton.tap()
        player.trackNavigationRow("subtitle").awaitExistence("the Subtitles navigation row")
        player.trackNavigationRow("subtitle").tap()
        let assOption = player.trackOption("subtitle", assTrackID)
        assOption.awaitExistence("the authored-ASS subtitle row")
        assOption.tap()
        assOption.awaitDisappearance("the track picker after selecting the ASS track")
    }

    /// The whole chain in one: selecting the track eventually paints a libass
    /// frame carrying the fixture's cue text.
    func testSelectingAnASSTrackRendersAStyledSubtitle() {
        let player = openPlayer()
        selectASSTrack(player)

        player.styledSubtitle.awaitExistence("the libass-rendered subtitle")
        XCTAssertTrue(
            player.styledSubtitle.label.contains(UITestFixtureIdentity.styledSubtitleCueText),
            """
            The styled subtitle should carry the fixture cue's text as its \
            accessibility label, got: \(player.styledSubtitle.label)
            """
        )
    }

    /// Turning subtitles off tears the renderer down rather than leaving the
    /// last frame on screen — the failure mode that would show the previous
    /// track's lines over content they don't belong to.
    func testTurningSubtitlesOffRemovesTheStyledSubtitle() {
        let player = openPlayer()
        selectASSTrack(player)
        player.styledSubtitle.awaitExistence("the libass-rendered subtitle")

        player.tracksButton.tap()
        player.trackNavigationRow("subtitle").awaitExistence("the Subtitles navigation row")
        player.trackNavigationRow("subtitle").tap()
        player.subtitleOffOption.awaitExistence("the subtitle leaf's Off row")
        player.subtitleOffOption.tap()

        player.styledSubtitle.awaitDisappearance("the styled subtitle after turning subtitles off")
    }

    /// A plain-text track must not reach libass. Nothing else asserts the
    /// negative, and the cost of getting it wrong is that every SubRip and
    /// WebVTT track in the app starts depending on a script fetch that has no
    /// script to return.
    func testSelectingAPlainTextTrackDoesNotRenderAStyledSubtitle() {
        let player = openPlayer()

        player.tracksButton.tap()
        player.trackNavigationRow("subtitle").awaitExistence("the Subtitles navigation row")
        player.trackNavigationRow("subtitle").tap()
        let subripOption = player.trackOption("subtitle", 0)
        subripOption.awaitExistence("the first (SubRip) subtitle row")
        subripOption.tap()
        subripOption.awaitDisappearance("the track picker after selecting a SubRip track")

        XCTAssertFalse(
            // A short wait on purpose: this asserts an absence, and the full
            // timeout would add 15s to the suite for a result that is settled
            // as soon as the selection has been handled.
            player.styledSubtitle.waitForExistence(timeout: 3),
            "A SubRip track should render through the app's own overlay, not libass."
        )
        player.plainSubtitle.awaitExistence("the SubRip cue on the app's own overlay")
    }
}

extension StyledSubtitleJourneyTests {
    /// Profile → Playback → Advanced → Subtitle Styling, off.
    ///
    /// Forced through `UserDefaults`' argument domain rather than by driving
    /// the settings screen: the Advanced screen sits behind an iPhone/iPad
    /// layout fork that `ProfileScreen` deliberately doesn't absorb, and what
    /// this is actually about is the player's behaviour, not how the switch
    /// was flipped. `ASSSubtitleMappingTests` covers the read itself,
    /// including that an unset key means *on*.
    ///
    /// The track must still render — unstyled, through the app's own cue path.
    /// Disabling styling is not disabling subtitles, and a version of this
    /// that only asserted libass' absence would pass just as happily on a bug
    /// that dropped the track entirely.
    func testDisablingSubtitleStylingRendersTheTrackUnstyled() {
        let player = openPlayer(extraArguments: ["-styledASSSubtitlesEnabled", "NO"])
        selectASSTrack(player)

        XCTAssertFalse(
            // Short on purpose, like the SubRip case above: this asserts an
            // absence that is settled as soon as the selection is handled.
            player.styledSubtitle.waitForExistence(timeout: 3),
            "With Subtitle Styling off, an ASS track must not reach libass."
        )
        player.plainSubtitle.awaitExistence(
            "the unstyled subtitle the app's own cue path should still be rendering"
        )
    }

    /// The same journey with the setting left alone, so the pair states the
    /// default as a behaviour rather than only as a constant: the fixture's
    /// ASS track renders styled out of the box.
    func testSubtitleStylingIsOnByDefault() {
        let player = openPlayer()
        selectASSTrack(player)
        player.styledSubtitle.awaitExistence(
            "the libass-rendered subtitle, which styling being on by default should produce"
        )
    }

    /// A script must render while its faces are still downloading.
    ///
    /// The fixture source declares a font attachment and `PreviewPlaybackEngine`
    /// reports none of its own, so every journey in this file already goes
    /// through the font fetch — which is the point: the two routes this serves
    /// in production (a server-side transcode and offline playback) are exactly
    /// the ones where AetherEngine has nothing to offer.
    ///
    /// What only this test can catch is the fetch being made to *gate* the
    /// script. `.slowSubtitleFonts` holds the attachment response for
    /// `UITestStubURLProtocol.slowFontAttachmentDelay` — two minutes, against a
    /// 15s assertion budget — so a build that waited for the fonts before
    /// handing the script to libass cannot pass this by finishing early. It
    /// also stands in for the font fetch failing outright, since inside the
    /// budget the two are the same thing: no faces, and a subtitle regardless.
    func testAScriptRendersWhileItsFontsAreStillDownloading() {
        let player = openPlayer(scenario: "slowSubtitleFonts")
        selectASSTrack(player)

        player.styledSubtitle.awaitExistence(
            "the libass-rendered subtitle, which must not wait on the font attachments"
        )
        XCTAssertTrue(
            player.styledSubtitle.label.contains(UITestFixtureIdentity.styledSubtitleCueText),
            """
            The styled subtitle should carry the fixture cue's text even with no \
            fonts registered — libass falls back to a system face, which is how \
            every authored track behaved before fonts were fetched at all. \
            Got: \(player.styledSubtitle.label)
            """
        )
    }

    /// Top-aligned signs must stay on the picture.
    ///
    /// `ass_set_use_margins` — which is what puts regular dialogue in the bar
    /// below the picture — relocates *every* regular event into the margins,
    /// and a top-aligned event is regular. With a top margin present that sends
    /// an `\an8` sign into the letterbox bar above the picture, which is
    /// precisely where a sign annotating the image must not be. The fixture
    /// script carries one such cue alongside the bottom one, so the composited
    /// bitmap spans both and its top edge is the sign's.
    func testTopAlignedSignStaysOnThePicture() {
        let player = openPlayer()
        selectASSTrack(player)
        player.styledSubtitle.awaitExistence("the libass-rendered subtitle")

        XCTAssertTrue(
            player.styledSubtitle.label.contains(UITestFixtureIdentity.styledSubtitleTopCueText),
            "The fixture's top-aligned cue should be on screen alongside the bottom one."
        )
        XCTAssertGreaterThan(
            player.styledSubtitle.frame.minY,
            UITestFixtureIdentity.styledSubtitleMinimumTopY,
            """
            A top-aligned sign rendered near the top of the SCREEN rather than \
            the top of the picture — the letterbox bar above the video, which \
            means libass was given a top margin to relocate it into.
            """
        )
    }
}
