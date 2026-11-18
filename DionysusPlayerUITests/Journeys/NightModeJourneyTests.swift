import XCTest

/// The player's Night panel (Night Mode spec, "iOS player"), against the
/// fake engine. The dimming layer is hidden from accessibility and has no
/// identifier, so what it and the volume ceiling are given is read from
/// Playback Stats' "Night Mode" row, opened by the play link's `stats=1`.
final class NightModeJourneyTests: UITestCase {
    private func link(_ string: String) -> URL { URL(string: "dionysus://" + string)! }

    /// Opens `url` in the running app, accepting the system's "Open in
    /// Dionysus?" prompt if it asks (as `DeepLinkJourneyTests` does).
    private func openLink(_ url: URL) {
        XCUIDevice.shared.system.open(url)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 2) { open.tap() }
    }

    /// The fixture movie playing, its controls pinned and Playback Stats
    /// open.
    private func openPlayerWithStats(scenario: String = "standard", extraArguments: [String] = []) -> PlayerScreen {
        launch(scenario: scenario, extraArguments: extraArguments)
        HomeScreen(app: app).awaitLoaded()
        openLink(link("play/\(UITestFixtureIdentity.primaryMovieID)?stats=1"))
        let player = PlayerScreen(app: app)
        player.awaitControls()
        return player
    }

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

    /// Taps the panel's empty backdrop, closing it.
    private func closePanel(_ player: PlayerScreen) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.9)).tap()
        player.nightToggle.awaitDisappearance("the Night panel, closed")
    }

    /// `value` can't be read through an `NSPredicate` reliably, so it's
    /// polled.
    private func poll(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return false
    }

    /// On, Brightness down twice and Volume once, read back by Playback
    /// Stats; Brightness's 0% shortcut; and the settings outlast the player.
    func test_nightPanel_appliesLevels() {
        let player = openPlayerWithStats()
        let statsRow = player.statsValue("Night Mode")
        player.statsPageIndicator.awaitExistence("Playback Stats, opened by the link")
        XCTAssertFalse(statsRow.exists, "Off, Night Mode has no row")
        XCTAssertEqual(player.nightButton.value as? String, "Off")

        player.nightButton.tap()
        player.nightToggle.awaitExistence("the Night panel")
        XCTAssertEqual(player.nightVolume.value as? String, "100%")
        XCTAssertFalse(player.nightControl("volume", "increase").isEnabled, "+ does nothing at 100%")
        XCTAssertFalse(player.nightControl("volume", "max").isEnabled, "100% does nothing at 100%")
        player.nightToggle.switches.firstMatch.tap()
        XCTAssertTrue(poll { (player.nightButton.value as? String) == "On" }, "The moon shows Night Mode on")

        player.nightControl("brightness", "decrease").tap()
        player.nightControl("brightness", "decrease").tap()
        player.nightControl("volume", "decrease").tap()
        XCTAssertTrue(poll { (player.nightBrightness.value as? String) == "90%" })
        XCTAssertEqual(player.nightVolume.value as? String, "95%")
        XCTAssertTrue(poll { statsRow.label == "Night Audio · Volume 95% · Brightness 90%" },
                      "Stats read \(statsRow.label)")

        player.nightControl("brightness", "min").tap()
        XCTAssertTrue(poll { (player.nightBrightness.value as? String) == "0%" })
        XCTAssertFalse(player.nightControl("brightness", "decrease").isEnabled, "− does nothing at 0%")
        XCTAssertFalse(player.nightControl("brightness", "min").isEnabled, "0% does nothing at 0%")
        XCTAssertTrue(poll { statsRow.label == "Night Audio · Volume 95% · Brightness 0%" })

        // Closed and played again: still on, the same levels.
        closePanel(player)
        player.close()
        player.closeButton.awaitDisappearance("the player, closed")
        AssetDetailScreen(app: app).play()
        player.awaitControls()
        XCTAssertEqual(player.nightButton.value as? String, "On")
        player.nightButton.tap()
        player.nightToggle.awaitExistence("the Night panel, in the next session")
        XCTAssertEqual(player.nightVolume.value as? String, "95%")
        XCTAssertEqual(player.nightBrightness.value as? String, "0%")
    }

    /// A server transcode can't carry Night Audio: the note says so, in
    /// place of its usual copy.
    func test_nightPanel_transcodeSaysUnavailable() {
        let player = openPlayer(scenario: "transcode")
        player.nightButton.tap()
        player.nightToggle.awaitExistence("the Night panel")
        let usual = "Limits dynamic range. Turns off Atmos and passthrough while on."
        XCTAssertTrue(player.nightAudioToggle.label.contains(usual), player.nightAudioToggle.label)

        player.nightToggle.switches.firstMatch.tap()
        XCTAssertTrue(poll { player.nightAudioToggle.label.contains("Not available when transcoding") },
                      player.nightAudioToggle.label)
    }

    /// The schedule switching Night Mode mid-play says so over the picture,
    /// and the switch applies (read from Playback Stats; the fade and the
    /// ramp are unit-tested). The harness stands in for the boundary
    /// (`-UITestNightModeScheduledSwitchAfter`), since a journey can't wait
    /// for a time of day.
    func test_scheduledSwitch_saysSo_andApplies() {
        let player = openPlayerWithStats(extraArguments: [
            "-nightMode.volumePercent", "60",
            "-nightMode.brightnessPercent", "40",
            "-UITestNightModeScheduledSwitchAfter", "4"
        ])
        let statsRow = player.statsValue("Night Mode")
        player.statsPageIndicator.awaitExistence("Playback Stats, opened by the link")
        XCTAssertFalse(player.nightModeNotice.exists, "Nothing to say before the switch")

        player.nightModeNotice.awaitExistence("the scheduled switch's notice", timeout: 15)
        XCTAssertEqual(player.nightModeNotice.label, "Night Mode starting as scheduled")
        XCTAssertTrue(poll { statsRow.label == "Night Audio · Volume 60% · Brightness 40%" },
                      "Stats read \(statsRow.label)")
        XCTAssertEqual(player.nightButton.value as? String, "On")
        player.nightModeNotice.awaitDisappearance("the notice, gone on its own")
    }

    /// The schedule is a one-line summary in the player, edited in
    /// Profile. Turned on through `UserDefaults`' argument domain, where
    /// "YES" arrives as a string (`NightModeStore` reads it as a Bool). With
    /// a 24-hour locale so the times read as the spec writes them.
    func test_nightPanel_scheduleSummary() {
        let player = openPlayer(extraArguments: [
            "-nightMode.schedule.enabled", "YES",
            "-AppleLocale", "en_GB"
        ])
        player.nightButton.tap()
        player.nightScheduleSummary.awaitExistence("the schedule's summary")
        XCTAssertEqual(player.nightScheduleSummary.label, "Schedule: 22:00–07:00")
    }

    func test_nightPanel_scheduleSummaryReadsOffByDefault() {
        let player = openPlayer()
        player.nightButton.tap()
        player.nightScheduleSummary.awaitExistence("the schedule's summary")
        XCTAssertEqual(player.nightScheduleSummary.label, "Schedule: Off")
    }
}
