import XCTest

/// The cues `SubtitleOverlayView` places where the source asked, rather than
/// stacking them bottom centre: text with an ASS `\an` alignment or `\pos`
/// anchor (WebVTT's line and position settings arrive the same way), and
/// bitmap cues (PGS, VobSub, DVB), whose rect is normalized against a canvas
/// that may be taller than the picture.
///
/// `PreviewPlaybackEngine`'s Signs and PGS tracks publish them, at the places
/// `UITestFixtureIdentity` names. Each frame is checked against the picture
/// rect the overlay works from (`A11yID.Player.subtitlePicture`, a test-only
/// marker), so the journey holds on any device and pose: the fixture's
/// 2.4:1 picture is letterboxed in an iPhone held tall and sits above the
/// fold in tabletop. `SubtitleAppearanceJourneyTests` and
/// `StyledSubtitleJourneyTests` cover the default-placed and libass paths.
final class PlacedSubtitleJourneyTests: UITestCase {
    private let signsTrackID = 3
    private let pgsTrackID = 4
    /// A rounding allowance: SwiftUI lays out on the pixel grid.
    private let tolerance: CGFloat = 1.5

    private func playTrack(_ id: Int, scenario: String = "standard") -> PlayerScreen {
        launch(scenario: scenario)
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.primaryMovieID)
        AssetDetailScreen(app: app).play()
        let player = PlayerScreen(app: app)
        player.awaitControls()
        player.tracksButton.tap()
        player.trackNavigationRow("subtitle").awaitExistence("the Subtitles navigation row")
        player.trackNavigationRow("subtitle").tap()
        let option = player.trackOption("subtitle", id)
        option.awaitExistence("subtitle track \(id)'s row")
        option.tap()
        option.awaitDisappearance("the track picker after selecting track \(id)")
        return player
    }

    /// The picture rect, checked to have the fixture's 2.4:1 shape, so a
    /// wrong `videoRect` can't pass by moving the cues with it.
    private func picture(file: StaticString = #filePath, line: UInt = #line) -> CGRect {
        let marker = app.descendants(matching: .any)[A11yID.Player.subtitlePicture]
        marker.awaitExistence("the overlay's picture rect", file: file, line: line)
        let rect = marker.frame
        XCTAssertEqual(rect.width / rect.height, 3840.0 / 1600.0, accuracy: 0.02,
                       "The picture rect should keep the video's 2.4:1 shape (\(rect))", file: file, line: line)
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.insetBy(dx: -tolerance, dy: -tolerance).contains(rect),
                      "The picture rect \(rect) should fit inside the window \(window)", file: file, line: line)
        return rect
    }

    private func textCue(_ text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: A11yID.Player.plainSubtitle)
            .matching(NSPredicate(format: "label == %@", text))
            .firstMatch
    }

    private func assertCentre(
        of element: XCUIElement, at expected: CGPoint, _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let frame = element.frame
        XCTAssertEqual(frame.midX, expected.x, accuracy: tolerance,
                       "\(what) should be centred on x \(expected.x), not at \(frame)", file: file, line: line)
        XCTAssertEqual(frame.midY, expected.y, accuracy: tolerance,
                       "\(what) should be centred on y \(expected.y), not at \(frame)", file: file, line: line)
    }

    /// `\an8` alone puts a sign at the top centre of the picture, not of the
    /// screen; `\pos` puts it at its anchor, normalized against the picture.
    /// Neither joins the bottom-centre stack.
    func testPlacedTextCues_landWhereTheSourcePutsThem() {
        _ = playTrack(signsTrackID)
        let aligned = textCue(UITestFixtureIdentity.alignedSubtitleCueText)
        let positioned = textCue(UITestFixtureIdentity.positionedSubtitleCueText)
        aligned.awaitExistence("the \\an8 sign")
        positioned.awaitExistence("the \\pos sign")
        let video = picture()

        // `SubtitleOverlayView.alignmentPoint`: row 7–9 sits 8% down the picture.
        assertCentre(of: aligned, at: CGPoint(x: video.midX, y: video.minY + 0.08 * video.height),
                     "The \\an8 sign")
        let anchor = UITestFixtureIdentity.positionedSubtitleCueAnchor
        assertCentre(of: positioned,
                     at: CGPoint(x: video.minX + anchor.x * video.width, y: video.minY + anchor.y * video.height),
                     "The \\pos sign")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Placed text cues"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A bitmap cue's 16:9 canvas is taller than the 2.4:1 picture: it maps
    /// width-aligned and centred on the picture, so the cue keeps the
    /// canvas's proportions and may reach past the picture's own edges.
    func testImageCue_isDrawnAtItsRectOnTheCanvas() {
        _ = playTrack(pgsTrackID)
        let cue = app.descendants(matching: .any)[A11yID.Player.imageSubtitle]
        cue.awaitExistence("the PGS cue")
        let video = picture()

        let canvas = UITestFixtureIdentity.imageSubtitleCanvasSize
        let rect = UITestFixtureIdentity.imageSubtitleCueRect
        let canvasHeight = video.width * canvas.height / canvas.width
        let canvasTop = video.midY - canvasHeight / 2
        let expected = CGRect(
            x: video.minX + rect.minX * video.width, y: canvasTop + rect.minY * canvasHeight,
            width: rect.width * video.width, height: rect.height * canvasHeight
        )
        let frame = cue.frame
        XCTAssertEqual(frame.minX, expected.minX, accuracy: tolerance, "PGS cue at \(frame), expected \(expected)")
        XCTAssertEqual(frame.minY, expected.minY, accuracy: tolerance, "PGS cue at \(frame), expected \(expected)")
        XCTAssertEqual(frame.width, expected.width, accuracy: tolerance, "PGS cue at \(frame), expected \(expected)")
        XCTAssertEqual(frame.height, expected.height, accuracy: tolerance, "PGS cue at \(frame), expected \(expected)")
        XCTAssertFalse(textCue(UITestFixtureIdentity.plainSubtitleCueText).exists,
                       "A bitmap track draws its picture, not a text cue")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Image cue"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Anamorphic video (720×576 coded, shown at 16:9) whose PGS canvas is
    /// the coded frame, as AetherEngine reports a DVB or DVD plane. The
    /// picture rect takes the displayed 16:9 shape, and the canvas covers it
    /// exactly: mapped width-aligned onto the displayed picture, it was 1.42
    /// times too tall and the cue sat low.
    func testImageCue_onAnamorphicVideo_isPlacedOnTheDisplayedPicture() {
        _ = playTrack(pgsTrackID, scenario: "anamorphicVideo")
        let cue = app.descendants(matching: .any)[A11yID.Player.imageSubtitle]
        cue.awaitExistence("the PGS cue")
        let marker = app.descendants(matching: .any)[A11yID.Player.subtitlePicture]
        marker.awaitExistence("the overlay's picture rect")
        let video = marker.frame
        XCTAssertEqual(video.width / video.height, 16.0 / 9.0, accuracy: 0.02,
                       "The picture rect should take the displayed 16:9 shape, not the coded 5:4 (\(video))")

        let rect = UITestFixtureIdentity.imageSubtitleCueRect
        let expected = CGRect(
            x: video.minX + rect.minX * video.width, y: video.minY + rect.minY * video.height,
            width: rect.width * video.width, height: rect.height * video.height
        )
        let frame = cue.frame
        XCTAssertEqual(frame.minX, expected.minX, accuracy: tolerance, "PGS cue at \(frame), expected \(expected)")
        XCTAssertEqual(frame.minY, expected.minY, accuracy: tolerance, "PGS cue at \(frame), expected \(expected)")
        XCTAssertEqual(frame.width, expected.width, accuracy: tolerance, "PGS cue at \(frame), expected \(expected)")
        XCTAssertEqual(frame.height, expected.height, accuracy: tolerance, "PGS cue at \(frame), expected \(expected)")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Anamorphic image cue"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
