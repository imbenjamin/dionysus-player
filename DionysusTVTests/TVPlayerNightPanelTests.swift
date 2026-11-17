import XCTest
@testable import Dionysus

/// The panel's Night tab: four rows (Night Mode, Night Audio, Volume Limit,
/// Brightness). Each level row holds four controls, 0%, −, + and 100%,
/// which Left and Right move between; Select presses the focused one, and
/// holding Select on − or + repeats (Benjamin, 2026-11-16).
final class TVPlayerNightPanelTests: XCTestCase, TVPlayerInputModelHarness {
    var state = TVPlayerInputState()
    var context = TVPlayerNightPanelTests.standardContext
    var now: TimeInterval = 1000

    private func index(_ row: TVNightPanelRow) -> Int {
        TVNightPanelRow.all.firstIndex(of: row)!
    }

    private var focusedRow: TVNightPanelRow? {
        guard state.panel?.tab == .night, case .content(let index) = state.panel?.focus else { return nil }
        return TVPlayerInputModel.nightRow(at: index)
    }

    /// Down opens Info's tabs; Right moves along to Night, the last tab.
    private func openNightTab() {
        send(.down)
        press(.right, count: TVPlayerInputModel.availableTabs(context).count - 1)
        XCTAssertEqual(state.panel?.tab, .night)
        XCTAssertEqual(state.panel?.focus, .tabs)
    }

    private func focus(_ row: TVNightPanelRow) {
        state.panel = .init(tab: .night, focus: .content(index(row)), lastInputAt: now)
    }

    // MARK: The model

    func test_nightIsTheLastTab_afterSubtitles_andIsAList() {
        XCTAssertEqual(TVPanelTab.allCases.last, .night)
        XCTAssertEqual(TVPanelTab.night.id, "night")
        XCTAssertTrue(TVPanelTab.night.isList)
        XCTAssertEqual(TVPlayerInputModel.availableTabs(context), [.info, .chapters, .audio, .subtitles, .night])
    }

    func test_rows_areTheTwoSwitches_thenFourControlsALevel() {
        XCTAssertEqual(TVNightPanelRow.all, [
            .nightMode, .nightAudio,
            .level(.volume, .min), .level(.volume, .decrease), .level(.volume, .increase), .level(.volume, .max),
            .level(.brightness, .min), .level(.brightness, .decrease), .level(.brightness, .increase), .level(.brightness, .max)
        ])
        for (position, row) in TVNightPanelRow.all.enumerated() {
            XCTAssertEqual(TVPlayerInputModel.nightRow(at: position), row)
        }
        XCTAssertNil(TVPlayerInputModel.nightRow(at: TVNightPanelRow.all.count))
        XCTAssertNil(TVPlayerInputModel.nightRow(at: -1))
    }

    // MARK: Switches

    func test_down_fromTheNightTab_landsOnNightMode_andSelectTurnsItOn() {
        openNightTab()
        send(.down)
        XCTAssertEqual(focusedRow, .nightMode)
        XCTAssertEqual(send(.select), [.setNightMode(true)])
        XCTAssertNotNil(state.panel, "A switch keeps the panel open")
        context.night.isOn = true
        XCTAssertEqual(send(.select), [.setNightMode(false)], "Select flips it back")
    }

    func test_select_onNightAudio_flipsIt() {
        focus(.nightAudio)
        XCTAssertEqual(send(.select), [.setNightAudio(false)])
        context.night.nightAudio = false
        XCTAssertEqual(send(.select), [.setNightAudio(true)])
    }

    func test_leftRight_onTheSwitches_doNothing() {
        for row in [TVNightPanelRow.nightMode, .nightAudio] {
            focus(row)
            XCTAssertEqual(press(.left), [])
            XCTAssertEqual(press(.right), [])
            XCTAssertEqual(focusedRow, row)
        }
    }

    // MARK: Moving

    /// Into a level from above lands on −: both levels start at 100%, where
    /// + and 100% do nothing.
    func test_down_walksTheRows_andEntersALevelOnMinus() {
        openNightTab()
        send(.down)
        send(.down)
        XCTAssertEqual(focusedRow, .nightAudio)
        send(.down)
        XCTAssertEqual(focusedRow, .level(.volume, .decrease))
        send(.down)
        XCTAssertEqual(focusedRow, .level(.brightness, .decrease))
        send(.down)
        XCTAssertEqual(focusedRow, .level(.brightness, .decrease), "No wrap past the last row")
    }

    func test_upDown_betweenLevels_keepTheControl() {
        for control in TVNightLevelControl.allCases {
            focus(.level(.volume, control))
            send(.down)
            XCTAssertEqual(focusedRow, .level(.brightness, control))
            send(.up)
            XCTAssertEqual(focusedRow, .level(.volume, control))
        }
    }

    func test_up_fromVolume_goesToNightAudio_thenNightMode_thenTheTabs() {
        focus(.level(.volume, .max))
        send(.up)
        XCTAssertEqual(focusedRow, .nightAudio)
        send(.up)
        XCTAssertEqual(focusedRow, .nightMode)
        send(.up)
        XCTAssertEqual(state.panel?.focus, .tabs)
    }

    /// The value between − and + isn't a stop.
    func test_leftRight_moveAlongALevelsControls_withoutWrapping() {
        focus(.level(.brightness, .min))
        XCTAssertEqual(press(.left), [])
        XCTAssertEqual(focusedRow, .level(.brightness, .min))
        for expected in [TVNightLevelControl.decrease, .increase, .max] {
            XCTAssertEqual(press(.right), [], "Moving never changes the level")
            XCTAssertEqual(focusedRow, .level(.brightness, expected))
        }
        press(.right)
        XCTAssertEqual(focusedRow, .level(.brightness, .max))
        press(.left)
        XCTAssertEqual(focusedRow, .level(.brightness, .increase))
    }

    // MARK: Pressing

    func test_select_onEachControl() {
        context.night.volumePercent = 60
        context.night.brightnessPercent = 40
        focus(.level(.volume, .min))
        XCTAssertEqual(send(.select), [.setVolume(0)])
        focus(.level(.volume, .decrease))
        XCTAssertEqual(send(.select), [.stepVolume(-5)])
        focus(.level(.volume, .increase))
        XCTAssertEqual(send(.select), [.stepVolume(5)])
        focus(.level(.volume, .max))
        XCTAssertEqual(send(.select), [.setVolume(100)])
        focus(.level(.brightness, .min))
        XCTAssertEqual(send(.select), [.setBrightness(0)])
        focus(.level(.brightness, .decrease))
        XCTAssertEqual(send(.select), [.stepBrightness(-5)])
        focus(.level(.brightness, .increase))
        XCTAssertEqual(send(.select), [.stepBrightness(5)])
        focus(.level(.brightness, .max))
        XCTAssertEqual(send(.select), [.setBrightness(100)])
        XCTAssertNotNil(state.panel, "Nothing on the tab closes the panel")
    }

    /// A control that would do nothing stays a focus stop but is inert, so
    /// focus never jumps when a level reaches its end.
    func test_controls_atTheirEnd_areInert_butKeepFocus() {
        context.night.volumePercent = 100
        for control in [TVNightLevelControl.increase, .max] {
            focus(.level(.volume, control))
            XCTAssertEqual(send(.select), [], "\(control)")
            XCTAssertEqual(focusedRow, .level(.volume, control))
        }
        context.night.brightnessPercent = 0
        for control in [TVNightLevelControl.decrease, .min] {
            focus(.level(.brightness, control))
            XCTAssertEqual(send(.select), [], "\(control)")
        }
        XCTAssertTrue(TVPlayerInputModel.nightControlIsInert(.increase, percent: 100))
        XCTAssertTrue(TVPlayerInputModel.nightControlIsInert(.max, percent: 100))
        XCTAssertTrue(TVPlayerInputModel.nightControlIsInert(.decrease, percent: 0))
        XCTAssertTrue(TVPlayerInputModel.nightControlIsInert(.min, percent: 0))
        XCTAssertFalse(TVPlayerInputModel.nightControlIsInert(.min, percent: 5))
        XCTAssertFalse(TVPlayerInputModel.nightControlIsInert(.max, percent: 95))
    }

    /// Levels can be set ahead while Night Mode is off (spec: "to set up
    /// ahead"); they apply as soon as it's on.
    func test_levels_changeWhileNightModeIsOff() {
        context.night.isOn = false
        focus(.level(.volume, .decrease))
        XCTAssertEqual(send(.select), [.stepVolume(-5)])
        focus(.level(.brightness, .min))
        XCTAssertEqual(send(.select), [.setBrightness(0)])
    }

    // MARK: Holding Select

    func test_holdingSelect_onMinus_repeatsEveryTenthOfASecond() {
        context.night.brightnessPercent = 60
        focus(.level(.brightness, .decrease))
        XCTAssertEqual(send(.selectHoldBegan), [.stepBrightness(-5)], "The hold's first step")
        let repeats = tick(for: 0.5)
        XCTAssertEqual(repeats.count, 5, "\(repeats)")
        XCTAssertTrue(repeats.allSatisfy { $0 == .stepBrightness(-5) })
        XCTAssertEqual(send(.selectHoldEnded), [])
        XCTAssertEqual(send(.select), [], "The press that ends a hold adds no step")
        XCTAssertEqual(tick(for: 1), [], "Released, nothing repeats")
        XCTAssertEqual(send(.select), [.stepBrightness(-5)], "The next press is a press")
    }

    /// The tap's Select can arrive before the hold's end; either order adds
    /// nothing.
    func test_holdingSelect_releaseBeforeTheHoldsEnd_addsNoStep() {
        context.night.volumePercent = 50
        focus(.level(.volume, .increase))
        XCTAssertEqual(send(.selectHoldBegan), [.stepVolume(5)])
        XCTAssertEqual(send(.select), [])
        XCTAssertEqual(send(.selectHoldEnded), [])
        XCTAssertEqual(tick(for: 0.5), [])
        XCTAssertEqual(send(.select), [.stepVolume(5)])
    }

    /// A hold whose release sends no tap at all leaves nothing behind to
    /// swallow a later press.
    func test_aHoldWithNoTap_doesntSwallowTheNextPress() {
        context.night.volumePercent = 50
        focus(.level(.volume, .increase))
        send(.selectHoldBegan)
        send(.selectHoldEnded)
        tick(for: 1)
        XCTAssertEqual(send(.select), [.stepVolume(5)])
    }

    /// A hold the tick ends (the panel closed under it) leaves its release
    /// tap to come; that tap mustn't act on the transport.
    func test_aHoldEndedByTheTick_swallowsTheReleaseTap() {
        context.night.volumePercent = 50
        focus(.level(.volume, .increase))
        send(.selectHoldBegan)
        state.panel = nil
        tick(for: 0.1)
        XCTAssertNil(state.selectHold)
        XCTAssertEqual(send(.select), [], "The release tap")
        XCTAssertEqual(send(.select), [.togglePlayPause], "The next press is a press")
    }

    /// The user may keep holding long after the tick ended the hold; the
    /// release then comes past any fixed window.
    func test_aHoldEndedByTheTick_swallowsALateRelease_andOnlyThat() {
        context.night.volumePercent = 50
        focus(.level(.volume, .increase))
        send(.selectHoldBegan)
        state.panel = nil
        tick(for: 0.1)
        tick(for: 2)
        XCTAssertEqual(send(.selectHoldEnded), [])
        XCTAssertEqual(send(.select), [], "The release tap, 2 s on")
        XCTAssertEqual(send(.select), [.togglePlayPause], "A genuine press is a press")
    }

    func test_aHoldEndedByTheTick_flagDoesntOutliveTheRelease() {
        context.night.volumePercent = 50
        focus(.level(.volume, .increase))
        send(.selectHoldBegan)
        state.panel = nil
        tick(for: 0.1)
        send(.select)
        send(.selectHoldEnded)
        tick(for: 1)
        XCTAssertEqual(send(.select), [.togglePlayPause])
    }

    func test_holdingSelect_elsewhere_doesNothingOfItsOwn() {
        for row in [TVNightPanelRow.nightMode, .level(.volume, .min), .level(.brightness, .max)] {
            focus(row)
            XCTAssertEqual(send(.selectHoldBegan), [], "\(row)")
            XCTAssertEqual(tick(for: 0.5), [])
            send(.selectHoldEnded)
        }
        state.panel = nil
        XCTAssertEqual(send(.selectHoldBegan), [], "Nor outside the panel")
        XCTAssertEqual(send(.selectHoldEnded), [])
        XCTAssertEqual(send(.select), [.togglePlayPause], "And the tap still acts there")
    }

    func test_aHold_stopsAtTheLevelsEnd_andKeepsThePanelOpen() {
        context.night.volumePercent = 10
        focus(.level(.volume, .decrease))
        send(.selectHoldBegan)
        context.night.volumePercent = 0
        XCTAssertEqual(tick(for: 0.5), [], "Refused at 0%")
        tick(for: 12)
        XCTAssertNotNil(state.panel, "A held button counts as pressing, so the panel stays")
        send(.selectHoldEnded)
    }

    // MARK: Copy

    /// Night Audio's note (Benjamin, 2026-11-16), or why it can't apply.
    func test_nightAudioNote() {
        let note = "Limits dynamic range. Turns off Atmos and passthrough while on."
        XCTAssertEqual(TVPlayerPanelView.nightAudioNote(.off), note)
        XCTAssertEqual(TVPlayerPanelView.nightAudioNote(.applied), note)
        XCTAssertEqual(TVPlayerPanelView.nightAudioNote(.unavailable), "Not available when transcoding")
    }

    // MARK: Timeout

    func test_nightTab_closesAfterTenQuietSeconds() {
        openNightTab()
        send(.down)
        tick(for: 9.8)
        XCTAssertNotNil(state.panel)
        tick(for: 0.4)
        XCTAssertNil(state.panel)
    }

    func test_aPress_keepsThePanelOpenPastItsTimeout() {
        context.night.volumePercent = 60
        focus(.level(.volume, .decrease))
        tick(for: 8)
        send(.select)
        tick(for: 8)
        XCTAssertNotNil(state.panel, "Each press restarts the timeout")
    }
}

private extension TVPlayerInputModelHarness {
    func press(_ direction: TVDirection, count: Int) {
        for _ in 0..<count { press(direction) }
    }
}
