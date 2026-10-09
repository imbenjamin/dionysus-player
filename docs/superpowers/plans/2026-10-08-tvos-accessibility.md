# tvOS Milestone 5: Accessibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the Apple TV app usable with VoiceOver end to end (sign in, browse, search, open, play, control playback, leave), with an accessibility pass over every page.

**Architecture:** The player gets an *accessible transport mode*: while VoiceOver or Switch Control runs (or a UI-test flag forces it), the host's recognizers stand down except Menu and Play/Pause, the overlay becomes interactive, and its controls become real focusable SwiftUI buttons that send explicit `TVRemoteInput.control(_:)` inputs to the same pure reducer, so `PlayerViewModel` and the engine don't change. The rest of the app is reviewed page by page with `apple-design-skill`'s HIG accessibility audit and a manual VoiceOver walk, fixed, and pinned with journeys and the structural audit.

**Tech Stack:** Swift 6, SwiftUI + UIKit on tvOS 26, XCTest / XCUITest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-08-tvos-accessibility-design.md`

## Global Constraints

- Deployment floor tvOS 26.0; verify on the **tvOS 26.5 Simulator** (`640A2CA1-…`), which behaves differently from 27.
- Never select on an accessibility *label* in a UI test; select by `A11yID`. Never put an identifier on a screen-root container.
- User-facing strings: `Text("…")` literals in views, `String(localized:)` elsewhere; sync `Localizable.xcstrings` with an Xcode.app Cmd+B in the same PR (memory: automate-xcstrings-catalog-sync).
- `xcodegen generate` whenever a source file is added.
- Shared code that names a Downloads type stays inside `#if DOWNLOADS`.
- Sign-off from Benjamin before every commit; screenshots of any visual change before running tests; ask before deploying to the Bedroom Apple TV.
- Before every hand-back, re-point the Simulators at SavareseHillFlix as Ben (UI tests sign them in to the stub).
- No `Claude-Session:` trailer in commits or PRs; keep `Co-Authored-By`.
- Base branch `develop`; merge with `--merge`, after checks pass and Benjamin signs off.
- The spec and this plan are uncommitted; they ride in PR 1's first commit.

## Review Focus

1. **VoiceOver turned on or off mid-playback**: the player switches modes live, keeps playing, and focus lands on Play/Pause (on) or the model's scrubber (off) — pinned by `TVPlayerInputTests.test_accessibleTransport_toggledLive_…` (Task 3) and a manual step (Task 6).
2. **A panel row chosen after the list shrank** (an audio switch rebuilding the session): the row index is re-checked, so a stale index never selects the wrong track — pinned in Task 2 (`test_control_panelRow_outOfRange_doesNothing`).
3. **Controls pressed while loading or failed**: only Menu acts (closes), nothing seeks or toggles — Task 2 (`test_control_whileLoading_doesNothing`).
4. **Next Up reaching zero while VoiceOver is reading the card**: it still advances once, never twice — Task 2 (`test_accessibleTransport_nextUpAtZero_advancesOnce`).
5. **The transport never fades and the panel never times out** in this mode, however long the person takes — Task 2 (`test_accessibleTransport_neverFades_andThePanelNeverTimesOut`).

---

# PR 1: The player's accessible transport

Branch: `feature/tvos-accessible-transport` off `develop`.

### Task 1: Measure VoiceOver in the player (spike, nothing kept)

**Files:**
- Modify: `docs/superpowers/specs/2026-10-08-tvos-accessibility-design.md` (record findings under "How it's built")

- [ ] **Step 1: Branch and build onto the tvOS 26.5 Simulator**

```bash
git switch -c feature/tvos-accessible-transport
xcodegen generate
xcodebuild build -project DionysusPlayer.xcodeproj -scheme DionysusTV \
  -destination 'platform=tvOS Simulator,id=640A2CA1-<rest of udid from `xcrun simctl list devices | grep 26.5`>'
```

- [ ] **Step 2: Turn VoiceOver on in that Simulator**

```bash
xcrun simctl spawn <udid> defaults write com.apple.Accessibility VoiceOverTouchEnabled -bool true
```
If that doesn't take on tvOS, use Settings ▸ Accessibility ▸ VoiceOver in the Simulator (driven with `idb ui key` per memory simulator-automation).

- [ ] **Step 3: Probe throwaway (do not commit)**

In `TVPlayerHostController.viewDidLoad`, temporarily log every recognizer firing and every `pressesBegan` type with `print("[a11y-probe] …")`, and add one temporary `Button("Probe") { print("[a11y-probe] button") }` to `TVPlayerOverlay` with `overlay.view.isUserInteractionEnabled = true`. Play the fixture movie against the LAN server; press Select, Play/Pause, Menu, Up/Down/Left/Right and swipe; capture the console.

- [ ] **Step 4: Record the answers in the spec** (then revert the probe with `git checkout -- DionysusTV/`)

1. Which presses reach our recognizers with VoiceOver on (expect: Menu yes; Play/Pause ?; Select and arrows taken by VoiceOver).
2. Does a focusable SwiftUI button inside the overlay host take VoiceOver focus inside `AVPlayerViewController`?
3. Does `.accessibilityAdjustableAction` fire on swipe up/down for a focused `.focusable()` element?

**Gate:** if (2) is "no", stop and tell Benjamin before Task 4: the fallback is presenting the accessible transport as a sibling `UIHostingController` above the `AVPlayerViewController`'s view rather than inside its overlay host. If Play/Pause doesn't reach us, Task 4 leaves only the Menu recognizer enabled and the spec says the remote's Play/Pause is VoiceOver's under it.

### Task 2: The reducer's accessible mode

**Files:**
- Modify: `DionysusTV/Player/TVPlayerInput.swift` (add `TVPlayerControl`, `TVRemoteInput.control`, context fields)
- Modify: `DionysusTV/Player/TVPlayerInputModel.swift` (`reduce`, `tick`, `chromeMayFade`)
- Create: `DionysusTV/Player/TVPlayerInputModel+Accessible.swift`
- Test: `DionysusTVTests/TVPlayerAccessibleTransportTests.swift`

**Interfaces:**
- Produces: `enum TVPlayerControl { playPause, skip(TVDirection), openPanel(TVPanelTab), toggleStats, panelRow(Int), skipSegment, nextUp(TVNextUpButton) }`; `TVRemoteInput.control(TVPlayerControl)`; `TVPlayerContext.accessibleTransport: Bool`, `.audioTrackTitles: [String]`, `.subtitleTrackTitles: [String]`; `TVPlayerInputModel.reduceControl(_:_:context:now:) -> [TVPlayerCommand]`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Dionysus

/// The accessible transport (M5): the focus engine moves and selects, so
/// the reducer ignores raw arrows and Select and takes explicit controls.
final class TVPlayerAccessibleTransportTests: XCTestCase, TVPlayerInputModelHarness {
    var state = TVPlayerInputState()
    var context: TVPlayerContext = {
        var context = TVPlayerAccessibleTransportTests.standardContext
        context.accessibleTransport = true
        return context
    }()
    var now: TimeInterval = 1000

    func test_rawArrowsSelectAndSwipes_doNothing() {
        XCTAssertEqual(send(.select), [])
        XCTAssertEqual(press(.right), [])
        XCTAssertEqual(send(.up), [])
        XCTAssertEqual(send(.down), [])
        XCTAssertEqual(send(.swipeBegan), [])
        XCTAssertEqual(send(.swipeStep(.right)), [])
        XCTAssertNil(state.scrub)
        XCTAssertNil(state.panel)
        XCTAssertEqual(state.transportFocus, .scrubber)
    }

    func test_playPauseControl_andRemotePlayPause_toggle() {
        XCTAssertEqual(send(.control(.playPause)), [.togglePlayPause])
        XCTAssertEqual(state.flash?.kind, .pause)
        XCTAssertEqual(send(.playPause), [.togglePlayPause])
    }

    func test_skipControls_seek10s_andFlash() {
        XCTAssertEqual(send(.control(.skip(.right))), [.seek(110)])
        XCTAssertEqual(state.flash?.kind, .skipForward)
        XCTAssertEqual(send(.control(.skip(.left))), [.seek(90)])
        XCTAssertEqual(state.flash?.kind, .skipBack)
    }

    func test_openPanel_switchTab_chooseRow_menuCloses() {
        send(.control(.openPanel(.audio)))
        XCTAssertEqual(state.panel?.tab, .audio)
        XCTAssertEqual(send(.control(.panelRow(1))), [.selectAudio(id: 1)])
        XCTAssertEqual(state.panel?.tab, .audio, "A track switch keeps the panel open")
        send(.control(.openPanel(.subtitles)))
        XCTAssertEqual(state.panel?.tab, .subtitles)
        XCTAssertEqual(send(.control(.panelRow(0))), [.selectSubtitle(id: nil)])
        XCTAssertEqual(send(.menu), [])
        XCTAssertNil(state.panel)
        XCTAssertEqual(send(.menu), [.close])
    }

    func test_chapterRow_seeksPlaysAndCloses() {
        send(.control(.openPanel(.chapters)))
        XCTAssertEqual(send(.control(.panelRow(2))), [.seek(2700), .play])
        XCTAssertNil(state.panel)
    }

    func test_openPanel_forAMissingTab_doesNothing() {
        context.chapterStarts = []
        send(.control(.openPanel(.chapters)))
        XCTAssertNil(state.panel)
    }

    func test_control_panelRow_outOfRange_doesNothing() {
        send(.control(.openPanel(.audio)))
        context.audioTrackIDs = [0]
        XCTAssertEqual(send(.control(.panelRow(1))), [])
    }

    func test_toggleStats_onlyWithItsSetting() {
        send(.control(.toggleStats))
        XCTAssertFalse(state.isStatsOn)
        context.statsButtonEnabled = true
        send(.control(.toggleStats))
        XCTAssertTrue(state.isStatsOn)
    }

    func test_skipSegment_andNextUp() {
        XCTAssertEqual(send(.control(.skipSegment)), [], "Nothing to skip")
        context.skipSegment = .init(id: "intro", endSeconds: 120)
        XCTAssertEqual(send(.control(.skipSegment)), [.skipSegment(id: "intro")])
        context.skipSegment = nil
        XCTAssertEqual(send(.control(.nextUp(.playNow))), [], "No card")
        context.nextUpSecondsRemaining = 8
        XCTAssertEqual(send(.control(.nextUp(.close))), [.dismissNextUp])
        XCTAssertEqual(send(.control(.nextUp(.playNow))), [.playNext])
        XCTAssertEqual(send(.control(.nextUp(.playNow))), [], "Once only")
    }

    func test_accessibleTransport_nextUpAtZero_advancesOnce() {
        context.nextUpSecondsRemaining = 0
        XCTAssertEqual(tick(for: 1), [.playNext])
        XCTAssertEqual(send(.control(.nextUp(.playNow))), [])
    }

    func test_control_whileLoading_doesNothing() {
        context.playback = .loading
        XCTAssertEqual(send(.control(.playPause)), [])
        XCTAssertEqual(send(.control(.skip(.right))), [])
        XCTAssertEqual(send(.menu), [.close])
    }

    func test_accessibleTransport_neverFades_andThePanelNeverTimesOut() {
        tick(for: TVPlayerTiming.chromeFade + 30)
        XCTAssertEqual(state.chrome, .transport)
        send(.control(.openPanel(.info)))
        tick(for: TVPlayerTiming.panelTimeout + 30)
        XCTAssertEqual(state.panel?.tab, .info)
    }

    func test_turnedOnWhileHidden_bringsTheTransportBack_onTheNextTick() {
        context.accessibleTransport = false
        tick(for: TVPlayerTiming.chromeFade + 1)
        XCTAssertEqual(state.chrome, .hidden)
        context.accessibleTransport = true
        tick(for: 0.1)
        XCTAssertEqual(state.chrome, .transport)
        XCTAssertEqual(state.transportFocus, .scrubber)
    }

    func test_controlsOutsideTheMode_doNothing() {
        context.accessibleTransport = false
        XCTAssertEqual(send(.control(.playPause)), [])
    }
}
```

- [ ] **Step 2: Run them to see them fail**

```bash
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusTV -testPlan TVUnitTests \
  -destination 'platform=tvOS Simulator,id=<26.5 udid>' -only-testing:DionysusTVTests/TVPlayerAccessibleTransportTests
```
Expected: compile failure (`control` / `accessibleTransport` unknown).

- [ ] **Step 3: Add the types** to `TVPlayerInput.swift`

```swift
/// What one of the accessible transport's focusable controls asked for
/// (M5). The focus engine has already moved and selected, so these say
/// what to do, not which press happened.
enum TVPlayerControl: Equatable {
    case playPause
    case skip(TVDirection)
    /// Opens the panel on this tab, or switches to it while open.
    case openPanel(TVPanelTab)
    case toggleStats
    /// A row of the open panel's tab: Restart, a chapter, a track.
    case panelRow(Int)
    case skipSegment
    case nextUp(TVNextUpButton)
}
```
In `TVRemoteInput`, after `swipeStep`:
```swift
    /// A control of the accessible transport (`TVPlayerControl`).
    case control(TVPlayerControl)
```
In `TVPlayerContext`, after `autoHideDisabled`:
```swift
    /// VoiceOver or Switch Control is running, or the UI-test harness
    /// forces it: the focus engine drives the player (M5).
    var accessibleTransport = false
    /// The tracks' titles, for the accessible transport's announcements.
    var audioTrackTitles: [String] = []
    var subtitleTrackTitles: [String] = []
```
In `TVPlayerContext+ViewModel.swift`, after `subtitleTrackIDs = …`:
```swift
        audioTrackTitles = audio.map(\.title)
        subtitleTrackTitles = subtitles.map(\.title)
```

- [ ] **Step 4: Route inputs in `reduce`** (`TVPlayerInputModel.swift`), right after `state.panel?.lastInputAt = now`:

```swift
        if context.accessibleTransport {
            switch input {
            case .control(let control):
                return reduceControl(control, &state, context: context, now: now)
            case .menu, .playPause:
                break
            default:
                // The focus engine moves and selects in this mode.
                return []
            }
        }
```
and in the `switch input` below it add `case .control: return []` beside `case .tick: return []`.

- [ ] **Step 5: Create `TVPlayerInputModel+Accessible.swift`**

```swift
import Foundation

extension TVPlayerInputModel {
    /// The accessible transport's controls (M5). Each reuses what the
    /// remote's own path does, so both modes act the same.
    static func reduceControl(
        _ control: TVPlayerControl, _ state: inout TVPlayerInputState, context: TVPlayerContext, now: TimeInterval
    ) -> [TVPlayerCommand] {
        state.chrome = .transport
        switch control {
        case .playPause:
            return togglePlayPause(&state, context: context)
        case .skip(let direction):
            let commands = skip(direction, context: context)
            if !commands.isEmpty { flash(direction == .left ? .skipBack : .skipForward, &state) }
            return commands
        case .openPanel(let tab):
            guard availableTabs(context).contains(tab) else { return [] }
            openPanel(tab, focus: .tabs, &state, now: now)
            return []
        case .toggleStats:
            if context.statsButtonEnabled { state.isStatsOn.toggle() }
            return []
        case .panelRow(let index):
            guard let panel = state.panel else { return [] }
            let (commands, closes) = activateRow(panel.tab, index, context)
            if closes { state.panel = nil }
            return commands
        case .skipSegment:
            return context.skipSegment.map { [.skipSegment(id: $0.id)] } ?? []
        case .nextUp(let button):
            guard context.nextUpSecondsRemaining != nil else { return [] }
            return button == .playNow ? playNext(&state) : [.dismissNextUp]
        }
    }
}
```

- [ ] **Step 6: Never fade, never time out, come back if hidden** — in `tick`:
  - change `if now - panel.lastInputAt >= TVPlayerTiming.panelTimeout {` to `if !context.accessibleTransport, now - panel.lastInputAt >= TVPlayerTiming.panelTimeout {`
  - before the `switch context.playback` add:
```swift
        if context.accessibleTransport {
            // Turned on mid-playback with the transport faded (Review Focus 1).
            state.chrome = .transport
            state.transportFocus = .scrubber
        }
```
  - `chromeMayFade`: append `&& !context.accessibleTransport`.

- [ ] **Step 7: `xcodegen generate`, run the new tests and the whole input-model suite**

Run the Step 2 command, then again without `-only-testing` filter for `TVPlayerInputModelTests`, `TVPlayerOverlaysTests`, `TVPlayerPanelTests`, `TVPlayerScrubTests`. Expected: all PASS.

- [ ] **Step 8: Commit** (after Benjamin's sign-off; first commit also adds the spec and this plan)

```bash
git add docs/superpowers/specs/2026-10-08-tvos-accessibility-design.md docs/superpowers/plans/2026-10-08-tvos-accessibility.md \
  DionysusTV/Player/TVPlayerInput.swift DionysusTV/Player/TVPlayerInputModel.swift \
  DionysusTV/Player/TVPlayerInputModel+Accessible.swift DionysusTV/Player/TVPlayerContext+ViewModel.swift \
  DionysusTVTests/TVPlayerAccessibleTransportTests.swift
git commit -m "tvOS: the player's input model gains an accessible transport mode"
```

### Task 3: Turning the mode on, and announcements

**Files:**
- Create: `DionysusTV/Player/TVAccessibleTransport.swift`
- Modify: `DionysusTV/Player/TVPlayerInput.swift` (observable `accessibleTransport`, `snapshot()`, `announce`)
- Modify: `DionysusPlayer/Core/UITestSupport/UITestConfiguration.swift` (flag)
- Modify: `DionysusTV/Player/TVPlaybackTimeFormat.swift` (spoken form)
- Test: `DionysusTVTests/TVAccessibleTransportTests.swift`, `DionysusTVTests/TVPlayerInputTests.swift`, `DionysusTVTests/TVPlaybackTimeFormatTests.swift`

**Interfaces:**
- Consumes: Task 2's `TVPlayerControl`, `TVPlayerContext.accessibleTransport/…TrackTitles`.
- Produces: `TVAccessibleTransport.isOn(voiceOver:switchControl:forced:) -> Bool`; `TVPlayerAnnouncement.text(for: Flash.Kind) -> String`, `.trackChosen(_ commands: [TVPlayerCommand], context:) -> String?`, `.skipAvailable(_ title: String) -> String`, `.nextUp(_ title: String) -> String`; `TVPlayerInput.accessibleTransport: Bool` (observed), `TVPlayerInput.snapshot() -> TVPlayerContext`, `TVPlayerInput.announce: (String) -> Void`; `TVPlaybackTimeFormat.spoken(_:) -> String`, `.spokenPosition(_:of:) -> String`; `UITestConfiguration.forcesAccessibleTransport`.

- [ ] **Step 1: Failing tests** — `DionysusTVTests/TVAccessibleTransportTests.swift`:

```swift
import XCTest
@testable import Dionysus

final class TVAccessibleTransportTests: XCTestCase {
    func test_onWithVoiceOverSwitchControlOrTheHarness() {
        XCTAssertFalse(TVAccessibleTransport.isOn(voiceOver: false, switchControl: false, forced: false))
        XCTAssertTrue(TVAccessibleTransport.isOn(voiceOver: true, switchControl: false, forced: false))
        XCTAssertTrue(TVAccessibleTransport.isOn(voiceOver: false, switchControl: true, forced: false))
        XCTAssertTrue(TVAccessibleTransport.isOn(voiceOver: false, switchControl: false, forced: true))
    }

    func test_announcements() {
        XCTAssertEqual(TVPlayerAnnouncement.text(for: .pause), String(localized: "Paused"))
        XCTAssertEqual(TVPlayerAnnouncement.text(for: .play), String(localized: "Playing"))
        XCTAssertEqual(TVPlayerAnnouncement.text(for: .skipForward), String(localized: "Forward 10 seconds"))
        XCTAssertEqual(TVPlayerAnnouncement.text(for: .skipBack), String(localized: "Back 10 seconds"))
        var context = TVPlayerContext()
        context.audioTrackIDs = [3, 4]
        context.audioTrackTitles = ["English", "French"]
        context.subtitleTrackIDs = [7]
        context.subtitleTrackTitles = ["English SDH"]
        XCTAssertEqual(TVPlayerAnnouncement.trackChosen([.selectAudio(id: 4)], context: context), String(localized: "Audio, French"))
        XCTAssertEqual(TVPlayerAnnouncement.trackChosen([.selectSubtitle(id: 7)], context: context), String(localized: "Subtitles, English SDH"))
        XCTAssertEqual(TVPlayerAnnouncement.trackChosen([.selectSubtitle(id: nil)], context: context), String(localized: "Subtitles, Off"))
        XCTAssertNil(TVPlayerAnnouncement.trackChosen([.seek(0)], context: context))
    }
}
```
Append to `TVPlayerInputTests.swift`:
```swift
    func test_accessibleTransport_announcesFlashesAndTracks_onlyInTheMode() {
        let input = TVPlayerInput(clock: { 1000 })
        var context = TVPlayerContext(playback: .playing, currentTime: 100, duration: 5400, audioTrackIDs: [0, 1], selectedAudioIndex: 0)
        context.audioTrackTitles = ["English", "French"]
        input.context = { context }
        var spoken: [String] = []
        input.announce = { spoken.append($0) }
        input.send(.playPause)
        XCTAssertEqual(spoken, [], "Nothing is announced outside the mode")
        input.accessibleTransport = true
        input.send(.control(.playPause))
        input.send(.control(.openPanel(.audio)))
        input.send(.control(.panelRow(1)))
        XCTAssertEqual(spoken, [String(localized: "Paused"), String(localized: "Audio, French")])
    }

    func test_accessibleTransport_toggledLive_reachesTheReducer() {
        let input = TVPlayerInput(clock: { 1000 })
        input.context = { TVPlayerContext(playback: .playing, currentTime: 100, duration: 5400) }
        input.accessibleTransport = true
        XCTAssertTrue(input.snapshot().accessibleTransport)
        input.send(.select)
        XCTAssertNil(input.state.flash, "Select is the focus engine's in the mode")
        input.accessibleTransport = false
        input.send(.select)
        XCTAssertEqual(input.state.flash?.kind, .pause)
    }
```
Append to `TVPlaybackTimeFormatTests.swift`:
```swift
    func test_spoken() {
        XCTAssertEqual(TVPlaybackTimeFormat.spoken(750), "12 minutes, 30 seconds")
        XCTAssertEqual(TVPlaybackTimeFormat.spoken(0), String(localized: "0 seconds"))
        XCTAssertEqual(TVPlaybackTimeFormat.spokenPosition(750, of: 6720),
                       String(localized: "12 minutes, 30 seconds of 1 hour, 52 minutes"))
    }
```
(The English expectations assume the test runs in `en`; the existing format tests already do.)

- [ ] **Step 2: Run, expect compile failure.** Same command as Task 2 Step 2 with the three test classes.

- [ ] **Step 3: Implement `TVAccessibleTransport.swift`**

```swift
import Foundation

/// When the player uses the accessible transport (M5): whenever VoiceOver
/// or Switch Control runs, both of which need focusable controls, or the
/// UI-test harness forces it (XCUITest can't run VoiceOver).
enum TVAccessibleTransport {
    static func isOn(voiceOver: Bool, switchControl: Bool, forced: Bool) -> Bool {
        voiceOver || switchControl || forced
    }
}

/// What the accessible transport says aloud. One short phrase per action;
/// the mid-screen flashes stay as they are.
enum TVPlayerAnnouncement {
    static func text(for kind: TVPlayerInputState.Flash.Kind) -> String {
        switch kind {
        case .play: String(localized: "Playing")
        case .pause: String(localized: "Paused")
        case .skipBack: String(localized: "Back 10 seconds")
        case .skipForward: String(localized: "Forward 10 seconds")
        }
    }

    /// "Audio, French" for a track switch among `commands`, else `nil`.
    static func trackChosen(_ commands: [TVPlayerCommand], context: TVPlayerContext) -> String? {
        for command in commands {
            switch command {
            case .selectAudio(let id):
                guard let index = context.audioTrackIDs.firstIndex(of: id),
                      context.audioTrackTitles.indices.contains(index) else { continue }
                return String(localized: "Audio, \(context.audioTrackTitles[index])")
            case .selectSubtitle(nil):
                return String(localized: "Subtitles, Off")
            case .selectSubtitle(let id?):
                guard let index = context.subtitleTrackIDs.firstIndex(of: id),
                      context.subtitleTrackTitles.indices.contains(index) else { continue }
                return String(localized: "Subtitles, \(context.subtitleTrackTitles[index])")
            default:
                continue
            }
        }
        return nil
    }

    static func skipAvailable(_ title: String) -> String { String(localized: "\(title) available") }
    static func nextUp(_ title: String) -> String { String(localized: "Up next: \(title)") }
}
```

- [ ] **Step 4: `TVPlayerInput`** — add below `perform`:

```swift
    /// The accessible transport is on (`TVAccessibleTransport`). Observed,
    /// so the overlay redraws when VoiceOver is turned on or off.
    var accessibleTransport = false
    /// Posts a VoiceOver announcement; the host sets it.
    @ObservationIgnored var announce: (String) -> Void = { _ in }

    /// `context()` with the mode applied: what the reducer and the overlay read.
    func snapshot() -> TVPlayerContext {
        var snapshot = context()
        snapshot.accessibleTransport = accessibleTransport
        return snapshot
    }
```
Replace `send(_:)`'s body with:
```swift
        let context = snapshot()
        var next = state
        let commands = TVPlayerInputModel.reduce(&next, input, context: context, now: clock())
        if context.accessibleTransport {
            if next.flash != state.flash, let kind = next.flash?.kind { announce(TVPlayerAnnouncement.text(for: kind)) }
            if let track = TVPlayerAnnouncement.trackChosen(commands, context: context) { announce(track) }
        }
        // Assigned only on change: every tick would otherwise invalidate the
        // overlay ten times a second.
        if next != state { state = next }
        if !commands.isEmpty { perform(commands) }
```
and `swipeScrubs` to `TVPlayerInputModel.swipeScrubs(state, context: snapshot())`. Replace every `input.context()` in `DionysusTV/Player/*.swift` (5 sites) with `input.snapshot()`.

- [ ] **Step 5: Spoken time** in `TVPlaybackTimeFormat.swift`:

```swift
    /// `string`'s spoken form, "12 minutes, 30 seconds", as iOS's scrubber
    /// reads it (`PlayerControlsOverlay.spokenTime`).
    static func spoken(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return String(localized: "0 seconds") }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = .dropAll
        guard let text = formatter.string(from: seconds.rounded(.down)), !text.isEmpty else {
            return String(localized: "0 seconds")
        }
        return text
    }

    /// The scrubber's accessibility value: "12 minutes, 30 seconds of 1 hour, 52 minutes".
    static func spokenPosition(_ seconds: TimeInterval, of duration: TimeInterval) -> String {
        String(localized: "\(spoken(seconds)) of \(spoken(duration))")
    }
```

- [ ] **Step 6: The UI-test flag** in `UITestConfiguration.swift`, beside `disablesControlAutoHide`:

```swift
    /// The tvOS player's accessible transport, which otherwise needs
    /// VoiceOver or Switch Control running; XCUITest can run neither.
    static var forcesAccessibleTransport: Bool { flag("UITestAccessibleTransport") }
```

- [ ] **Step 7: Run the tests, expect PASS.** Then **commit** (after sign-off): `tvOS: when the accessible transport is on, and what it announces`.

### Task 4: The host switches modes

**Files:**
- Modify: `DionysusTV/Player/TVPlayerHostController.swift`

**Interfaces:**
- Consumes: `TVAccessibleTransport.isOn`, `TVPlayerInput.accessibleTransport`, `.announce`, `UITestConfiguration.forcesAccessibleTransport`.
- Produces: the overlay host is interactive and preferred for focus while the mode is on.

- [ ] **Step 1: Keep the always-on recognizers apart.** Add a property `private var modeIndependentRecognizers: Set<ObjectIdentifier> = []` and change `addTap` so Menu and Play/Pause register there:

```swift
    private func addTap(_ type: UIPress.PressType, _ action: @escaping () -> Void) {
        let recognizer = PressRecognizer(action: action)
        // …existing setup lines unchanged…
        if type == .menu || type == .playPause { modeIndependentRecognizers.insert(ObjectIdentifier(recognizer)) }
    }
```
(If Task 1 found Play/Pause doesn't reach us under VoiceOver, keep `.playPause` in the set anyway: it still serves Switch Control and the harness.)

- [ ] **Step 2: Apply the mode.**

```swift
    /// VoiceOver or Switch Control, read now and on every change (M5).
    private func applyAccessibleTransport() {
        var forced = false
        #if DEBUG
        forced = UITestConfiguration.isActive && UITestConfiguration.forcesAccessibleTransport
        #endif
        let on = TVAccessibleTransport.isOn(
            voiceOver: UIAccessibility.isVoiceOverRunning,
            switchControl: UIAccessibility.isSwitchControlRunning,
            forced: forced
        )
        guard on != input.accessibleTransport || !isAccessibleTransportApplied else { return }
        isAccessibleTransportApplied = true
        input.accessibleTransport = on
        for recognizer in ourRecognizers where !modeIndependentRecognizers.contains(ObjectIdentifier(recognizer)) {
            recognizer.isEnabled = !on
        }
        overlayHost?.view.isUserInteractionEnabled = on
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }
    private var isAccessibleTransportApplied = false

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if input.accessibleTransport, let overlay = overlayHost?.view { return [overlay] }
        return super.preferredFocusEnvironments
    }
```
Make sure `addTap` and `addArrow` append to `ourRecognizers` (the pan already does); add the append if they don't.

- [ ] **Step 3: Wire it.** At the end of `viewDidLoad`:

```swift
        input.announce = { text in AccessibilityNotification.Announcement(text).post() }
        applyAccessibleTransport()
        for name in [UIAccessibility.voiceOverStatusDidChangeNotification, UIAccessibility.switchControlStatusDidChangeNotification] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.applyAccessibleTransport() }
                .store(in: &cancellables)
        }
```

- [ ] **Step 4: Build** (`xcodebuild build … -scheme DionysusTV`); expected success. No commit yet: Task 5's views make it testable; commit both together.

### Task 5: The accessible transport's views

**Files:**
- Create: `DionysusTV/Player/TVPlayerControlButton.swift`
- Modify: `DionysusTV/Player/TVTransportOverlay.swift`, `TVPlayerPanelView.swift`, `TVPlayerOverlay.swift`, `TVNextUpCard.swift`, `TVSkipButton.swift`
- Modify: `DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift` (`A11yID.TV.Player`)
- Modify: `DionysusTVUITests/Support/TVPlayerJourney.swift` (move `openEpisodeOne` here, add helpers)
- Create: `DionysusTVUITests/PlayerAccessibleTransportJourneyTests.swift`
- Modify: `DionysusTVUITests/AccessibilityAuditTests.swift`

**Interfaces:**
- Consumes: `TVPlayerControl`, `TVPlayerInput.accessibleTransport/snapshot()`, `TVPlaybackTimeFormat.spokenPosition`, `TVPlayerAnnouncement.skipAvailable/nextUp`.
- Produces: `A11yID.TV.Player.control(_ id: String)`, `A11yID.TV.Player.scrubber`; `TVPlayerControlButton`.

- [ ] **Step 1: Write the failing journeys** — `PlayerAccessibleTransportJourneyTests.swift`:

```swift
import XCTest

/// The accessible transport (M5), forced on: XCUITest can't run VoiceOver,
/// but the mode is the same, so the focus engine drives real buttons.
final class PlayerAccessibleTransportJourneyTests: TVUITestCase {
    private let accessible = ["-UITestAccessibleTransport", "YES"]

    private func control(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.buttons[A11yID.TV.Player.control(id)]
    }

    func test_opensOnPlayPause_pauses_andTheTransportNeverFades() {
        let app = openPlayer(extraArguments: accessible)
        let playPause = control(app, "playPause")
        XCTAssertTrue(waitForFocus(playPause), "Play/Pause takes focus as the player opens")
        let playingLabel = playPause.label
        press(.select)
        // Compared with each other, never with a localized literal.
        XCTAssertTrue(poll(timeout: 3) { playPause.label != playingLabel }, "Pausing relabels the button")
        press(.select)
        XCTAssertTrue(poll(timeout: 3) { playPause.label == playingLabel })
        // Playing again, and past the fade the remote's mode would apply.
        sleep(UInt32(5))
        XCTAssertTrue(playPause.exists, "The transport stays up while playing")
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].exists)
    }

    func test_skipButtons_move10s() {
        let app = openPlayer(extraArguments: accessible)
        XCTAssertTrue(waitForFocus(control(app, "playPause")))
        guard let before = elapsedSeconds(app) else { return XCTFail("No elapsed") }
        press(.right)
        XCTAssertTrue(waitForFocus(control(app, "forward")))
        press(.select)
        XCTAssertTrue(poll(timeout: 5) { (self.elapsedSeconds(app) ?? 0) >= before + 9 }, "Forward skips 10s")
    }

    func test_scrubber_isAdjustable_andRightSkips() {
        let app = openPlayer(extraArguments: accessible)
        XCTAssertTrue(waitForFocus(control(app, "playPause")))
        press(.down)
        let scrubber = app.descendants(matching: .any)[A11yID.TV.Player.scrubber]
        XCTAssertTrue(waitForFocus(scrubber))
        XCTAssertTrue(scrubber.traits.contains(.adjustable))
        guard let before = elapsedSeconds(app) else { return XCTFail("No elapsed") }
        press(.right)
        XCTAssertTrue(poll(timeout: 5) { (self.elapsedSeconds(app) ?? 0) >= before + 9 })
    }

    func test_audio_opensThePanel_choosesATrack_menuClosesThenLeaves() {
        let app = openPlayer(extraArguments: accessible)
        XCTAssertTrue(waitForFocus(control(app, "playPause")))
        let audio = app.buttons[A11yID.TV.Player.icon("audio")]
        XCTAssertTrue(moveFocus(to: audio, pressing: .right, limit: 8))
        press(.select)
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.panel].waitForExistence(timeout: 5))
        let second = app.buttons[A11yID.TV.Player.panelRow("audio", 1)]
        XCTAssertTrue(moveFocus(to: second, pressing: .down, limit: 4))
        press(.select)
        XCTAssertTrue(poll(timeout: 5) { second.isSelected }, "The chosen track is marked selected")
        press(.menu)
        XCTAssertFalse(app.descendants(matching: .any)[A11yID.TV.Player.panel].waitForExistence(timeout: 2))
        press(.menu)
        XCTAssertFalse(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 3))
    }

    func test_skipIntro_isAButton() {
        let app = openPlayer(scenario: "skipIntro", extraArguments: accessible)
        let skip = app.buttons[A11yID.TV.Player.skipButton]
        XCTAssertTrue(skip.waitForExistence(timeout: 10))
        XCTAssertTrue(moveFocus(to: skip, pressing: .up, limit: 3) || moveFocus(to: skip, pressing: .right, limit: 8))
        guard let before = elapsedSeconds(app) else { return XCTFail("No elapsed") }
        press(.select)
        XCTAssertTrue(poll(timeout: 5) { (self.elapsedSeconds(app) ?? 0) > before + 15 }, "Skip jumps to the intro's end")
    }

    func test_nextUp_closeAndPlayNow_areButtons() {
        let app = openEpisodeOne(scenario: "earlyCredits", extraArguments: accessible)
        let close = app.buttons[A11yID.TV.Player.nextUpClose]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons[A11yID.TV.Player.nextUpPlayNow].exists)
        XCTAssertTrue(moveFocus(to: close, pressing: .up, limit: 3) || moveFocus(to: close, pressing: .right, limit: 10))
        press(.select)
        XCTAssertFalse(app.descendants(matching: .any)[A11yID.TV.Player.nextUpCard].waitForExistence(timeout: 2))
    }
}
```
Add to `TVPlayerJourney.swift` (and delete the private copy in `PlayerSegmentJourneyTests.swift`):
```swift
    /// Launches signed in and plays S1:E1 from Home's second tile.
    @discardableResult
    func openEpisodeOne(scenario: String, extraArguments: [String] = []) -> XCUIApplication {
        let app = launch(scenario: scenario, seedSession: true, extraArguments: extraArguments)
        waitForHomeThenFirstTile(app)
        press(.right)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.episodeID(season: 1, episode: 1))]))
        openDetailFromFocusedTile(app)
        press(.select)
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.focus].waitForExistence(timeout: 10))
        return app
    }

    /// Presses `direction` until `element` has focus, at most `limit` times.
    func moveFocus(to element: XCUIElement, pressing direction: XCUIRemote.Button, limit: Int) -> Bool {
        for _ in 0..<limit {
            if element.hasFocus { return true }
            press(direction)
        }
        return element.hasFocus
    }
```

- [ ] **Step 2: Run them; expect failure** (identifiers missing).

```bash
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusTV -testPlan TVUITests \
  -destination 'platform=tvOS Simulator,id=<26.5 udid>' -only-testing:DionysusTVUITests/PlayerAccessibleTransportJourneyTests
```

- [ ] **Step 3: Identifiers** in `A11yID.TV.Player`:

```swift
            /// The accessible transport's own buttons: back, playPause, forward, info.
            static func control(_ id: String) -> String { "tv.player.control.\(id)" }
            /// The scrubber as one adjustable element (accessible transport).
            static let scrubber = "tv.player.scrubber"
```

- [ ] **Step 4: The focusable button** — `TVPlayerControlButton.swift`:

```swift
import SwiftUI

/// A player control the focus engine can reach, for the accessible
/// transport (M5). Drawn by `label` from the focus engine's own focus,
/// read the way `TVSidebarRowStyle` reads it, so it looks exactly like the
/// model-drawn control it stands in for.
struct TVPlayerControlButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: (_ isFocused: Bool) -> Label

    var body: some View {
        Button(action: action) { EmptyView() }
            .buttonStyle(Style(label: label))
    }

    private struct Style: ButtonStyle {
        let label: (Bool) -> Label
        func makeBody(configuration: Configuration) -> some View { Body(label: label) }
    }

    private struct Body: View {
        let label: (Bool) -> Label
        @Environment(\.isFocused) private var isFocused
        var body: some View { label(isFocused) }
    }
}

/// The accessible transport's extra buttons (M5), left to right before the
/// icons: back 10s, Play/Pause, forward 10s, Info.
enum TVAccessibleTransportButton: CaseIterable {
    case back, playPause, forward, info

    var id: String {
        switch self {
        case .back: "back"
        case .playPause: "playPause"
        case .forward: "forward"
        case .info: "info"
        }
    }

    func systemImage(isPlaying: Bool) -> String {
        switch self {
        case .back: "gobackward.10"
        case .playPause: isPlaying ? "pause.fill" : "play.fill"
        case .forward: "goforward.10"
        case .info: "info.circle"
        }
    }

    /// Worded by what a press does, as iOS's controls are.
    func label(isPlaying: Bool) -> String {
        switch self {
        case .back: String(localized: "Back 10 seconds")
        case .playPause: isPlaying ? String(localized: "Pause") : String(localized: "Play")
        case .forward: String(localized: "Forward 10 seconds")
        case .info: String(localized: "Info")
        }
    }

    var control: TVPlayerControl {
        switch self {
        case .back: .skip(.left)
        case .playPause: .playPause
        case .forward: .skip(.right)
        case .info: .openPanel(.info)
        }
    }
}
```

- [ ] **Step 5: `TVPlayerIconButton`** — split its drawing so both modes share it. Keep the struct, and add a sibling used in the mode:

```swift
/// The icon's look for a given focus; shared by the remote's mode (focus
/// from the model) and the accessible transport (focus from the engine).
struct TVPlayerIconFace: View {
    let systemImage: String
    let isFocused: Bool
    var isOn = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(isFocused ? Color.black : Color.white)
            .frame(width: 84, height: 84)
            .background(Circle().fill(isFocused ? Color.white : Color.white.opacity(isOn ? 0.4 : 0.18)))
            .scaleEffect(isFocused ? 1.1 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 16, y: 8)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}
```
and make `TVPlayerIconButton.body` `TVPlayerIconFace(systemImage: icon.systemImage, isFocused: isFocused, isOn: isOn)` followed by its existing four accessibility modifiers.

- [ ] **Step 6: `TVTransportOverlay`** — read the mode and draw focusable controls in it.

Add:
```swift
    private var accessible: Bool { input.accessibleTransport }
    @FocusState private var focusedControl: String?
    private func send(_ control: TVPlayerControl) { input.send(.control(control)) }
```
Replace `iconRow` with:
```swift
    private var iconRow: some View {
        HStack(spacing: 18) {
            if accessible {
                ForEach(TVAccessibleTransportButton.allCases.filter { $0 != .info }, id: \.id) { button in
                    accessibleButton(button)
                }
            }
            Spacer()
            if accessible { accessibleButton(.info) }
            ForEach(input.snapshot().availableIcons, id: \.self) { icon in
                if accessible {
                    TVPlayerControlButton(action: { send(icon == .stats ? .toggleStats : .openPanel(icon.panelTab)) }) { focused in
                        TVPlayerIconFace(systemImage: icon.systemImage, isFocused: focused, isOn: icon == .stats && state.isStatsOn)
                    }
                    .accessibilityLabel(icon.label(isOn: state.isStatsOn))
                    .accessibilityAddTraits(icon == .stats && state.isStatsOn ? .isSelected : [])
                    .accessibilityIdentifier(A11yID.TV.Player.icon(icon.id))
                } else {
                    TVPlayerIconButton(icon: icon, isFocused: state.transportFocus == .icon(icon), isOn: icon == .stats && state.isStatsOn)
                }
            }
        }
        .frame(height: 96)
        .focusSection()
    }

    private func accessibleButton(_ button: TVAccessibleTransportButton) -> some View {
        let isPlaying = viewModel.state == .playing
        return TVPlayerControlButton(action: { send(button.control) }) { focused in
            TVPlayerIconFace(systemImage: button.systemImage(isPlaying: isPlaying), isFocused: focused)
        }
        .focused($focusedControl, equals: button.id)
        .accessibilityLabel(button.label(isPlaying: isPlaying))
        .accessibilityIdentifier(A11yID.TV.Player.control(button.id))
    }
```
with, in `TVPlayerIconButton.swift`:
```swift
extension TVPlayerIcon {
    /// The panel tab an icon opens; Stats opens none.
    var panelTab: TVPanelTab {
        switch self {
        case .chapters: .chapters
        case .audio: .audio
        case .subtitles: .subtitles
        case .stats: .info
        }
    }
}
```
On the chrome layer's root `ZStack` add `.defaultFocus($focusedControl, TVAccessibleTransportButton.playPause.id)`.

Scrubber: wrap the existing `scrubber` in the mode:
```swift
    @ViewBuilder
    private var scrubberStop: some View {
        if accessible {
            scrubber
                .focusable()
                .focused($isScrubberFocused)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(viewModel.item?.railTitle ?? String(localized: "Playback position"))
                .accessibilityValue(TVPlaybackTimeFormat.spokenPosition(viewModel.currentTime, of: viewModel.duration))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: send(.skip(.right))
                    case .decrement: send(.skip(.left))
                    @unknown default: break
                    }
                }
                .onMoveCommand { direction in
                    if direction == .left { send(.skip(.left)) }
                    if direction == .right { send(.skip(.right)) }
                }
                .accessibilityIdentifier(A11yID.TV.Player.scrubber)
        } else {
            scrubber
        }
    }
    @FocusState private var isScrubberFocused: Bool
```
use `scrubberStop` where `scrubber` sits in the bottom `VStack`, and in `scrubber`'s knob branch change `TVPlayerInputModel.scrubberHasFocus(state)` to `(accessible ? isScrubberFocused : TVPlayerInputModel.scrubberHasFocus(state))`. In the mode the icon row stays up with the panel open (it carries the tab buttons' way back): change `if state.panel == nil { iconRow… }` to `if state.panel == nil || accessible`.

- [ ] **Step 7: Panel tabs and rows** in `TVPlayerPanelView`: add `var accessible = false` and `var send: (TVPlayerControl) -> Void = { _ in }`, passed from `TVTransportOverlay` (`accessible: accessible, send: send`). Wrap each tab:
```swift
                    if accessible {
                        TVPlayerControlButton(action: { send(.openPanel(tab)) }) { focused in
                            tabFace(tab, focused: focused)
                        }
                        .accessibilityLabel(tab.title)
                        .accessibilityAddTraits(tab == panel.tab ? .isSelected : [])
                        .accessibilityIdentifier(A11yID.TV.Player.panelTab(tab.id))
                    } else {
                        tabFace(tab, focused: panel.focus == .tabs && tab == panel.tab)
                            .accessibilityAddTraits(tab == panel.tab ? [.isButton, .isSelected] : .isButton)
                            .accessibilityIdentifier(A11yID.TV.Player.panelTab(tab.id))
                    }
```
where `tabFace(_:focused:)` is the existing `Text(tab.title)…background(…)` chain moved into a function. Do the same for each track row (`rowFace(row, focused:)`, action `send(.panelRow(index))`, `.accessibilityElement(children: .combine)`, `.isSelected` when chosen), each chapter tile (action `send(.panelRow(index))`), and Restart (action `send(.panelRow(0))`). In the mode, `isFocused(_:)` is not used; the `ScrollViewReader`'s `onChange(of: panel.focus)` stays (it never changes in the mode, and the focus engine scrolls a focused row into view itself). Add `.focusSection()` to the tabs `HStack` and to the content.

- [ ] **Step 8: Skip and Next Up** — in `TVPlayerOverlay.bottomTrailingSlot`, when `input.accessibleTransport`:
```swift
TVPlayerControlButton(action: { input.send(.control(.skipSegment)) }) { focused in
    TVSkipButton(title: segment.kind.skipButtonTitle, isFocused: focused)
}
```
(the identifier and label stay on `TVSkipButton`; check in `attachTree()` output that the Button carries `tv.player.skip` with the button trait; if the identifier sits on a child, move `.accessibilityIdentifier` onto the `TVPlayerControlButton`). In `TVNextUpCard` add `var send: ((TVNextUpButton) -> Void)?`; when non-nil, wrap each `button(…)` in `TVPlayerControlButton(action: { send(.playNow / .close) })` drawing `isFocused` from the engine. Show both regardless of `nextUpHasFocus` in the mode (`skipButtonVisible` is already true with the transport up). Announce arrivals in `TVPlayerOverlay`:
```swift
        .onChange(of: viewModel.currentSkipSegment?.id) { _, id in
            guard input.accessibleTransport, id != nil, let segment = viewModel.currentSkipSegment else { return }
            AccessibilityNotification.Announcement(TVPlayerAnnouncement.skipAvailable(segment.kind.skipButtonTitle)).post()
        }
        .onChange(of: viewModel.nextEpisode?.id) { _, id in
            guard input.accessibleTransport, id != nil, let episode = viewModel.nextEpisode else { return }
            AccessibilityNotification.Announcement(TVPlayerAnnouncement.nextUp(episode.railTitle)).post()
        }
```
The countdown is never announced per second (Next Up's label must not contain the seconds).

- [ ] **Step 9: Screenshot first.** Build, launch with `-UITestMode YES -UITestScenario standard -UITestSeedSession YES -UITestAccessibleTransport YES` on the 26.5 Simulator, open the player, screenshot the transport, the open Audio panel and Skip; send them to Benjamin and wait for his OK before running tests.

- [ ] **Step 10: Run the new journeys, then every Player journey and the whole `TVUnitTests` plan.** Expected PASS. Fix anything the remote's mode lost (the model-drawn path must be untouched).

- [ ] **Step 11: Audit** — add to `AccessibilityAuditTests.swift`:
```swift
    func test_playerAccessibleTransport() throws {
        let app = openPlayer(extraArguments: ["-UITestAccessibleTransport", "YES"])
        try audit(app)
    }

    func test_playerAccessibleTransportPanel() throws {
        let app = openPlayer(extraArguments: ["-UITestAccessibleTransport", "YES"])
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Player.control("playPause")]))
        let info = app.buttons[A11yID.TV.Player.control("info")]
        XCTAssertTrue(moveFocus(to: info, pressing: .right, limit: 6))
        press(.select)
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.panel].waitForExistence(timeout: 5))
        try audit(app)
    }
```
(`audit(_:)` is the file's existing private helper, line 134.) Run; expected PASS.

- [ ] **Step 12: Commit** (after sign-off) Tasks 4–5: `tvOS: an accessible transport in the player for VoiceOver and Switch Control`.

### Task 6: Manual VoiceOver run, docs, PR 1

- [ ] **Step 1: VoiceOver walk on the 26.5 Simulator** (VoiceOver on, real LAN server): open a movie, Play/Pause, back/forward, adjust the scrubber with swipe up/down, open Audio and change track, Subtitles Off, Info ▸ Restart, Menu closes the panel then the player. Then an episode with an intro and Next Up. Turn VoiceOver off mid-playback and on again (Review Focus 1). Note everything read wrongly; fix before continuing.
- [ ] **Step 2: Docs.** CLAUDE.md's tvOS player section: a paragraph "**The accessible transport** (M5)…" covering when it's on, recognizers standing down except Menu and Play/Pause, controls sending `TVPlayerControl`, never fading, the test flag, and Task 1's measured facts. TESTING.md: the new unit and journey files and the two audit screens. Spec: Status line "PR 1 done".
- [ ] **Step 3: Run the four suites** (tvOS unit, tvOS UI full, iOS unit, iOS smoke — never two at once), sync `Localizable.xcstrings` via Xcode Cmd+B, re-point the Simulators at SavareseHillFlix, and ask Benjamin to sign off.
- [ ] **Step 4: Commit, push, open PR** "tvOS M5 PR 1: accessible transport" (concise body, the "Generated with Claude Code" line, no session URL). Merge after checks and his sign-off.

---

# PRs 2–5: the page passes

Each page pass follows one task shape. The **known fixes** listed carry their code; anything else the review finds is written into this plan under that PR's "Findings" heading (finding, fix, test) and shown to Benjamin before it's fixed, so the plan stays the record.

**The per-page procedure (Steps A–F), used by Tasks 7–10:**

- **A. HIG review:** invoke `apple-design-skill` on the page with screenshots from the 26.5 Simulator (normal, and focused states), asking for its accessibility audit specifically against tvOS focus.
- **B. VoiceOver walk:** VoiceOver on in the Simulator; walk every focusable element in order with `idb ui key` arrows; record what is spoken (the Simulator's VoiceOver caption panel: Settings ▸ Accessibility ▸ VoiceOver ▸ Caption Panel). Watch specifically for repeated or jumping announcements from `tvClaimsFocus`, `tvPageClaimingFocus`, `tvMenuReturnsToLanding` and the shell's 3-second fallback.
- **C. Write findings** into this plan under the PR, each with its fix and test; show Benjamin.
- **D. Fix test-first:** a journey asserting the label/value/trait/order (by `A11yID`, comparing labels to each other or to fixture data, never to a localized literal), failing first.
- **E. Audit:** add the page's states to `AccessibilityAuditTests` where missing.
- **F. Re-walk with VoiceOver**, screenshot any visual change to Benjamin, run the four suites, docs (CLAUDE.md where a fact isn't guessable, TESTING.md), commit after sign-off, PR, merge.

### Task 7 (PR 2): Shell and Home

Pages: sidebar (collapsed, open, Libraries group), Home (hero, rails, See All tiles, the load-more spinner).

**Known fix 1: the hero's timer stops under VoiceOver.**

- [ ] Failing test in `TVHeroPagerTests.test_timerRuns_onlyWhenEverythingAllowsIt`: give the `runs` helper a `voiceOver: Bool = false` parameter, pass it as `voiceOver:`, and add `XCTAssertFalse(runs(voiceOver: true), "VoiceOver needs to read one item fully, as on iOS")`.
- [ ] Implement in `TVHeroPager.timerRuns`: add parameter `voiceOver: Bool` and `&& !voiceOver`. In `TVHomeView` add `@Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled` and pass `voiceOver: voiceOverEnabled`.

**Known fix 2: the paging guard isn't a VoiceOver stop; the hero has a Next action.**

- [ ] In `TVHeroView.pageGuard`, `.focusable(enabled)` → `.focusable(enabled && !voiceOverEnabled)` with `@Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled`.
- [ ] On the hero's button `HStack`, add:
```swift
            .accessibilityAction(named: Text("Next Item")) {
                guard pager.canGoForward else { return }
                withAnimation(.easeInOut(duration: 0.35)) { pager.forward() }
            }
```
- [ ] XCUITest can't list or perform a named custom action on tvOS, and the guard's `focusable` depends on VoiceOver being on, so neither is reachable by a journey. `TVHeroPagerTests` already pins `forward()` wrapping; check the action and the guard by hand in Step B, and record both as manual-only in TESTING.md.

**Known fix 3: rail headings carry the header trait.**

- [ ] Journey in `HomeJourneyTests`: `XCTAssertTrue(app.staticTexts[A11yID.TV.Main.railTitle(<first rail title from fixtures>)].traits.contains(.header))` — find the rail heading's identifier in `A11yID.TV.Main`; if it has none, add `static func railTitle(_ title: String) -> String { "tv.main.rail.\(title)" }` and set it on the heading `Text`.
- [ ] Add `.accessibilityAddTraits(.isHeader)` to the rail heading in `TVHomeView` (and the "Recent Searches" and results headings in Search, Task 9).

**Known fix 4: the sidebar announces itself.**

- [ ] In `TVSidebar`, on the rail container: `.accessibilityElement(children: .contain)` and `.accessibilityLabel(Text("Sidebar"))`; each library row's `accessibilityHint` `Text("Opens \(library.name)")` only where the row's label alone doesn't say it (check in Step B first; skip if the label already reads as the page).

- [ ] Steps A–F for the sidebar and Home.

### Task 8 (PR 3): Detail pages and the library grid

Pages: movie, show (season tabs, episodes, an episode chosen), box set, playlist, Full Details, cast rail, library grid with each pill open, See All.

**Known fix 1: cast tiles aren't buttons.** In `TVCastRail`, the tile keeps focus but drops the button trait: `.accessibilityRemoveTraits(.isButton)`. Journey in `DetailJourneyTests`: the first cast tile's `elementType` is not `.button` (query with `descendants(matching: .any)[A11yID…castTile…]` and assert `!traits.contains(.button)`; add an `A11yID` if missing).

**Known fix 2: the logo reads as the title.** Check `TVDetailHeader`'s logo in Step B; if VoiceOver reads "image", set `.accessibilityLabel(item.railTitle)` on the logo view and hide the fallback text when the logo shows. Journey: the header's title element's label equals the fixture item's name (`UITestFixtureIdentity`), not empty.

**Known fix 3: grid posters read title, year and badges.** In `TVPosterCell` (UIKit), set `accessibilityLabel = item.accessibilityDescription` and `accessibilityValue` to the badges' spoken text (the SwiftUI tiles' value, "Watched", "Favorite"), and `accessibilityTraits = .button`. Journey in `CollectionGridJourneyTests`: the first poster's label equals the fixture movie's `railTitle`-based description; the watched fixture's value is non-empty.

**Known fix 4: pills read their value.** `TVDropdownPill`: `.accessibilityLabel(title)` (the facet) and `.accessibilityValue(selection ?? String(localized: "All"))`. Journey: Genre pill's value changes after choosing a genre (compare before and after).

- [ ] Steps A–F for each page listed.

### Task 9 (PR 4): Search and Profile

**Known fix 1: Search announces results.** In `TVSearchView`, when results land for a query: `AccessibilityNotification.Announcement(String(localized: "\(count) results")).post()` (`count` the total across rails; "No results" when zero), only on a change of the result set, never per keystroke while loading. Unit-test the text in `TVSearchGroupingTests` via a static `TVSearchGrouping.announcement(count:) -> String`.

**Known fix 2: headings.** Recent Searches and each results rail heading: `.isHeader` (as Task 7, fix 3), journey asserting the trait.

**Profile:** Step B confirms each row reads label, value, and the chevron rows say they open a page (a hint `Text("Opens a list")` only if needed); confirmations read Cancel first.

- [ ] Steps A–F for Search (empty, typing, results, Recent Searches, Clear) and Profile (each section, each picker, each cover).

### Task 10 (PR 5): Onboarding

**Known fix 1: the Quick Connect code is read digit by digit.** Where the code `Text` is drawn on tvOS, add `.accessibilityLabel(code.map(String.init).joined(separator: " "))`. Unit test: a `static func spokenCode(_ code: String) -> String` beside it (`"123456"` → `"1 2 3 4 5 6"`).

**Known fix 2: discovery announces a found server.** In Find Your Server, when the list goes from empty to non-empty: `AccessibilityNotification.Announcement(String(localized: "Found \(count) servers")).post()`.

- [ ] Steps A–F for Welcome, Find Your Server (scanning, found, address field, Rescan), sign-in (user list, password, Quick Connect), Who's Watching? (lockups, Forget This Account).

# PR 6: display settings, device pass, closing

### Task 11: Reduce Motion, Reduce Transparency, Increase Contrast, Bold Text

- [ ] **Step 1:** Grep for unguarded motion: `rg -n "withAnimation|\.animation\(|\.transition\(" DionysusTV` and list each that runs without a `reduceMotion` check and moves (not fades) something; the hero dot fill, the Next Up bar (already guarded), crossfades in `TVHeldImage`. For each moving one, guard with `@Environment(\.accessibilityReduceMotion)`: no animation, or a plain opacity.
- [ ] **Step 2:** Reduce Transparency: `rg -n "glassEffect|Material" DionysusTV`; for each, add `@Environment(\.accessibilityReduceTransparency)` and substitute an opaque fill (`Color(white: 0.12)` for glass, matching the plum where the sidebar is plum) when it's on.
- [ ] **Step 3:** Increase Contrast: secondary text over artwork (`.foregroundStyle(.secondary)` and `.white.opacity(<0.9)` over images) uses full white when `@Environment(\.colorSchemeContrast) == .increased`.
- [ ] **Step 4:** Bold Text: screenshot every page with it on; fix any clipping (pill max width 260pt, sidebar rows, tile captions).
- [ ] **Step 5:** Screenshots of each setting on the 26.5 Simulator to Benjamin before tests (`xcrun simctl spawn <udid> defaults write com.apple.Accessibility ReduceMotionEnabled -bool true` and the equivalents, or Settings ▸ Accessibility).
- [ ] **Step 6:** Unit tests where a helper decides (e.g. a `TVHeldImage` transition chooser); otherwise record each in TESTING.md as checked by screenshot.

### Task 12: Device pass and closing docs

- [ ] **Step 1:** Ask Benjamin before deploying to Bedroom. VoiceOver on the Apple TV; walk the success journey end to end: sign in, Home, Search a title and open it, play, pause, skip, scrub, change audio and subtitles, skip an intro, Next Up, leave. Fix what the device shows that the Simulator didn't.
- [ ] **Step 2:** Docs: CLAUDE.md (accessible transport, anything learned about VoiceOver and the focus claims), TESTING.md, parent spec's M5 line "done", memory `tvos-app-direction`.
- [ ] **Step 3:** Four suites, catalog sync, Simulators re-pointed, sign-off, PR "tvOS M5 PR 6: display settings and device pass", merge.
- [ ] **Step 4:** Final whole-milestone review (`superpowers:requesting-code-review`), fixes in a follow-up PR as M4's #317 was.
