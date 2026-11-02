# tvOS Player Features Implementation Plan (Milestone 4)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the Apple TV player to the iOS player's features and to Infuse's standard for scrubbing: scrubbing and scanning with trickplay, the swipe-down tabs, audio and subtitle choice, libass subtitles, Skip Intro/Credits, the compact Next Up card and the playback stats panel.

**Architecture:**
- A pure reducer, `TVPlayerInputModel.reduce(_:_:context:now:)`, owns what every remote press means. It reads a snapshot of the player (`TVPlayerContext`), mutates the player's UI state (`TVPlayerInputState`) and returns commands (`TVPlayerCommand`). Time is a parameter, so holds, scans, fades and timeouts are unit-tested without waiting.
- `TVPlayerHostController` keeps its AVKit binding. Its recognizers turn presses and touch-surface swipes into `TVRemoteInput`s for a small `@Observable` controller (`TVPlayerInput`), which ticks the reducer at 10 Hz and hands commands to `TVPlayerCommandRunner`, the only code that touches `PlayerViewModel`.
- The SwiftUI overlay (`TVPlayerOverlay`) takes no interaction and draws everything, focus highlight included, from `TVPlayerInputState`. The tvOS focus engine is not used inside the player.
- Shared iOS code is reused rather than rewritten: `SubtitleOverlayView` (with TV metrics), `PlayerViewModel`'s segments, Next Up countdown, chapters, trickplay and track memory, and a `PlaybackStatsReport` extracted from iOS's stats overlay.

**Tech Stack:** Swift 6, SwiftUI and UIKit (tvOS 26), AVKit (`AVPlayerViewController`), AetherEngine 7.27.2, swift-ass-renderer, XcodeGen, XCTest/XCUITest (`XCUIRemote`).

**Spec:** `docs/superpowers/specs/2026-10-06-tvos-player-features-design.md`. Parent spec: `docs/superpowers/specs/2026-09-29-tvos-app-design.md`. Prototype: https://claude.ai/artifact/Wjp3J4eh4VGqMmmR7ntAKL, boards `Player`, `PlayerTabs`, `PlayerSkip`, `PlayerNextUp`; sizes quoted below come from those boards.

## Global Constraints

- **Deployment target** `tvOS 26.0` for every tvOS target; iOS stays `18.0`.
- **The tvOS focus engine is not used inside the player.** No `.focusable`, `@FocusState` or `.defaultFocus` in any player view. The overlay's `UIHostingController` view keeps `isUserInteractionEnabled = false`.
- **The three host rules in CLAUDE.md still hold:** presented with UIKit `present`, never `fullScreenCover`; `AetherPlayerView` hidden whenever `currentAVPlayer` is non-nil; the engine made with `ownsNowPlayingSession: false`.
- **Exact values from the spec:** press/hold threshold 0.4s; skip and step 10s; transport fade 4s; panel timeout 10s; scan 8× stepping every 2s held to 16×, 32×, 64×; a full-width swipe covers 0.25 of the title; swipe axis commit 40pt, scrub commit 200pt/s; trickplay preview 400×225; chapter tile 380×214; Next Up thumb 420×236.
- **Stats:** a toggle on its icon only, never a tab, never modal. "Show Playback Stats Button" keeps iOS's shared default on tvOS: **on in debug, off in release** (Benjamin, 2026-10-07). Named as on iOS: the icon reads "Show playback stats" / "Hide playback stats", never "Stats for Nerds".
- **HDR chip:** shown only while `PlayerViewModel.videoFormatDescription` is non-nil (AetherEngine's presented `videoFormat`, `nil` for SDR).
- **The iOS app must behave identically.** Shared-code changes are moves, extractions and additive members only. iOS `UnitTests` and `UITests-Smoke` stay green on every PR that touches a shared file.
- **`DOWNLOADS` is defined only on `DionysusPlayer` and `DionysusPlayerTests`.** Shared code that names a Downloads type stays inside `#if DOWNLOADS`.
- **A11y identifiers:** never select on a label, never put an identifier on a screen-root container. New identifiers go in `DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift` under `A11yID.TV.Player`. Focus inside the player is observed through the test-only marker `A11yID.TV.Player.focus` (Task 4), whose label is a fixed, unlocalized id.
- **The Xcode project is generated:** edit `project.yml`, run `xcodegen generate`, never commit `.xcodeproj`.
- **Localization:** `Text("…")` literals in views, `String(localized:)` elsewhere. Sync `Localizable.xcstrings` in Xcode (Cmd+B) in the same PR (memory `automate-xcstrings-catalog-sync`). Times and "S1:E3" labels stay unwrapped.
- **Simulator first.** The Bedroom Apple TV is asked for only in Task 11.
- **Workflow:** Benjamin signs off every commit and every push. Branch from `develop` in the main checkout, one PR per group below, merged with `--merge` once checks pass. CLAUDE.md and TESTING.md change in the commit that changes what they describe. During review rounds run only the new tests; after sign-off run the suites one after another, never concurrently: tvOS unit, tvOS UI, then iOS unit and iOS smoke where a shared file changed.
- **Commit trailer:** `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never include a Claude session URL.
- **`Config/Version.xcconfig` and `DionysusPlayer/Shared/AppVersion.swift` stay uncommitted.** Never `git add -A`.

**Test commands** (or `.superpowers/run.sh <log> <tv|ios> <plan> [args]`, which also stops xcodebuild's post-test hang):

```bash
# tvOS unit
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusTV \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation),OS=27.0' -testPlan TVUnitTests
# tvOS UI
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusTV \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation),OS=27.0' -testPlan TVUITests
# iOS unit
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer \
  -destination 'platform=iOS Simulator,name=iPhone 17' -testPlan UnitTests
# iOS smoke
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer \
  -destination 'platform=iOS Simulator,name=iPhone 17' -testPlan UITests-Smoke
```

One class: append `-only-testing:DionysusTVTests/<Class>` (or `DionysusTVUITests/<Class>`, `DionysusPlayerTests/<Class>`).

**A note on the code below.** It was written against the code as read on 2026-10-06. Where a memberwise initialiser or a parameter list differs from what a snippet assumes, follow the repository and keep the snippet's behaviour.

## Review Focus

The inputs the spec implies but no feature test would naturally meet, most likely first. Each has a test in the task named.

1. **A press before the duration is known** (still loading, or a live-like source reporting 0): Left/Right must not seek to 0, a swipe or hold must not pause into a scrub with nowhere to go, and Menu must still close. (M1's deferred minor: `skip(by:)` before the duration seeked to 0.) Tests in Tasks 1 and 2.
2. **Next Up's countdown reaching zero while a scrub is open**: it must not advance under the person's thumb; it advances once the scrub resolves, and only once. Test in Task 8.
3. **The track list changing under an open panel** (an audio switch re-emits the list; sidecars register late): the focused row must stay in range and a stale index must never select the wrong track. Test in Task 6.
4. **Moving to the next item while the panel, a scrub or a hidden Skip is open**: the new item starts clean (transport up, nothing open), while Stats stays as the person left it. Test in Task 9.
5. **A focused icon disappearing** (a sidecar track list emptying, a reload dropping to one audio track): focus falls back to the scrubber instead of pointing at nothing. Test in Task 1.

## Delivery order

| PR | Branch | Tasks |
|---|---|---|
| 1 | `feature/tvos-player-transport` | 1–4: input model, scrubbing and scanning, host wiring, transport v2 |
| 2 | `feature/tvos-player-subtitles` | 5 |
| 3 | `feature/tvos-player-panel` | 6–7 |
| 4 | `feature/tvos-player-skip-nextup` | 8–9 |
| 5 | `feature/tvos-player-stats` | 10–11 |

The spec and this plan are committed with PR 1's first commit, as M3's were.

## File structure

New TV-only files, under `DionysusTV/Player/`:

| File | Responsibility |
|---|---|
| `TVPlayerInputModel.swift` | Inputs, commands, context, state, timing, and the reducer's entry, transport and tick |
| `TVPlayerInputModel+Scrub.swift` | Scrubbing and scanning |
| `TVPlayerInputModel+Panel.swift` | The swipe-down panel |
| `TVPlayerInputModel+Overlays.swift` | Skip and Next Up |
| `TVSwipeGate.swift` | Turns a touch-surface pan into swipe, step or vertical inputs |
| `TVPlayerContext+ViewModel.swift` | Builds a context from `PlayerViewModel` and the settings |
| `TVPlayerInput.swift` | `@Observable` controller: clock, 10 Hz tick, send |
| `TVPlayerCommandRunner.swift` | Carries out commands on `PlayerViewModel` |
| `TVPlayerFocusID.swift` | The focused item as a fixed id (drawing and the test marker) |
| `TVPlayerOverlay.swift` | The overlay's layers |
| `TVTransportLayout.swift` | Pure transport geometry and text |
| `TVPlayerIconButton.swift` | One transport icon |
| `TVScrubPreview.swift`, `TVScrubThumbnailLoader.swift` | The trickplay bubble and its throttled loader |
| `TVPlayerPanelView.swift` | Tabs row and the four tabs |
| `TVPlayerInfoArt.swift` | The Info tab's artwork rule |
| `TVSkipButton.swift`, `TVNextUpCard.swift` | The bottom-right overlays |
| `TVStatsPanel.swift` | The playback stats panel |

Removed: `DionysusTV/Player/TVTransportChrome.swift` and `DionysusTVTests/TVTransportChromeTests.swift` (the reducer owns the fade).

Shared files touched: `PlayerViewModel.swift` (`play()`, `pause()`), `SubtitleOverlayView.swift` (metrics), `PlayerControlsOverlay.swift` (`BottomChromeTopKey` moved out), new `BottomChromeTopKey.swift`, `PlayerPreferenceKeys.swift` (tvOS stats default), new `PlaybackStatsReport.swift`, `PlaybackStatsOverlay.swift` (renders from the report), `JellyfinModels.swift` + `MediaItem.swift` (series thumb), `UITestConfiguration.swift` + `UITestStubURLProtocol.swift` (two scenarios), `AccessibilityIdentifiers.swift`, `project.yml`.

---

## PR 1: `feature/tvos-player-transport`

### Task 1: The input model's core

**Files:**
- Create: `DionysusTV/Player/TVPlayerInputModel.swift`
- Test: `DionysusTVTests/TVPlayerInputModelHarness.swift`, `DionysusTVTests/TVPlayerInputModelTests.swift`

**Interfaces:**
- Produces: `TVRemoteInput`, `TVPlayerCommand`, `TVPlayerContext`, `TVPlayerInputState`, `TVPlayerIcon`, `TVPanelTab`, `TVDirection`, `TVNextUpButton`, `TVPlayerTiming`, `TVPlayerInputModel.reduce(_:_:context:now:) -> [TVPlayerCommand]`, `TVPlayerInputModel.Intent`, `TVPlayerInputModel.dispatch(_:_:context:now:)`, `TVPlayerInputModel.reduceTransport(_:_:context:now:)`, `TVPlayerInputModel.tick(_:context:now:)`, `TVPlayerInputModel.clamp(_:_:)`; the test-side `TVPlayerInputModelHarness` every model test file conforms to.

- [ ] **Step 1: Branch**

```bash
git switch develop && git pull && git switch -c feature/tvos-player-transport
```

- [ ] **Step 2: Write the shared test driver**

`DionysusTVTests/TVPlayerInputModelHarness.swift`:

```swift
import XCTest
@testable import Dionysus

/// The shared driver for the input model's test files: `state`, `context`
/// and `now`, plus press and tick helpers. `now` advances 0.1s per input
/// unless a test says otherwise, the way the host's 10 Hz tick does.
protocol TVPlayerInputModelHarness: AnyObject {
    var state: TVPlayerInputState { get set }
    var context: TVPlayerContext { get set }
    var now: TimeInterval { get set }
}

extension TVPlayerInputModelHarness {
    /// A 90-minute title playing at 1:40, four chapters, two audio tracks and
    /// three subtitle tracks: the shape of the UI-test fixture movie.
    static var standardContext: TVPlayerContext {
        TVPlayerContext(
            playback: .playing, currentTime: 100, duration: 5400,
            chapterStarts: [0, 1350, 2700, 4050],
            audioTrackIDs: [0, 1], selectedAudioIndex: 0,
            subtitleTrackIDs: [0, 1, 2]
        )
    }

    @discardableResult
    func send(_ input: TVRemoteInput, after seconds: TimeInterval = 0.1) -> [TVPlayerCommand] {
        now += seconds
        return TVPlayerInputModel.reduce(&state, input, context: context, now: now)
    }

    /// Down and up within the hold threshold: a press.
    @discardableResult
    func press(_ direction: TVDirection) -> [TVPlayerCommand] {
        send(.arrowDown(direction))
        return send(.arrowUp(direction))
    }

    /// Ticks at 10 Hz for `seconds`, returning every command they produced.
    @discardableResult
    func tick(for seconds: TimeInterval) -> [TVPlayerCommand] {
        var commands: [TVPlayerCommand] = []
        let end = now + seconds
        while now < end - 0.0001 { commands += send(.tick) }
        return commands
    }
}
```

Every model test file declares the three stored properties and conforms; none subclasses another.

- [ ] **Step 3: Write the failing tests**

`DionysusTVTests/TVPlayerInputModelTests.swift`:

```swift
import XCTest
@testable import Dionysus

/// The player's remote as a table: a state, an input, and the commands and
/// state that come out.
final class TVPlayerInputModelTests: XCTestCase, TVPlayerInputModelHarness {
    var state = TVPlayerInputState()
    var context = TVPlayerInputModelTests.standardContext
    var now: TimeInterval = 1000

    func test_select_whilePlaying_togglesPlayPause_andShowsTheTransport() {
        state.chrome = .hidden
        XCTAssertEqual(send(.select), [.togglePlayPause])
        XCTAssertEqual(state.chrome, .transport)
    }

    func test_playPause_togglesFromAnyFocus() {
        send(.up)
        XCTAssertEqual(send(.playPause), [.togglePlayPause])
    }

    /// Review Focus 1: nothing to act on while loading or failed, except
    /// Menu, which closes.
    func test_loadingOrFailed_onlyMenuActs_andItCloses() {
        for playback in [TVPlayerContext.Playback.loading, .failed] {
            context.playback = playback
            XCTAssertEqual(send(.select), [])
            XCTAssertEqual(press(.right), [])
            XCTAssertEqual(send(.menu), [.close])
        }
    }

    func test_up_focusesTheFirstIcon_onlyOnceTheTransportIsUp() {
        state.chrome = .hidden
        send(.up)
        XCTAssertEqual(state.transportFocus, .scrubber, "From hidden, Up only shows the transport")
        send(.up)
        XCTAssertEqual(state.transportFocus, .icon(.chapters))
    }

    func test_icons_areOnlyThoseWithSomethingToDo() {
        XCTAssertEqual(context.availableIcons, [.chapters, .audio, .subtitles])
        context.audioTrackIDs = [0]
        context.chapterStarts = []
        context.statsButtonEnabled = true
        XCTAssertEqual(context.availableIcons, [.subtitles, .stats])
        context.subtitleTrackIDs = []
        XCTAssertEqual(context.availableIcons, [.stats])
    }

    func test_leftRight_moveAlongTheIcons_andStopAtTheEnds() {
        send(.up)
        press(.right)
        XCTAssertEqual(state.transportFocus, .icon(.audio))
        press(.right)
        press(.right)
        XCTAssertEqual(state.transportFocus, .icon(.subtitles), "No wrap past the last icon")
        press(.left)
        press(.left)
        press(.left)
        XCTAssertEqual(state.transportFocus, .icon(.chapters))
    }

    func test_down_fromAnIcon_returnsToTheScrubber() {
        send(.up)
        send(.down)
        XCTAssertEqual(state.transportFocus, .scrubber)
    }

    func test_selectStats_togglesThePanel() {
        context.statsButtonEnabled = true
        context.chapterStarts = []
        context.audioTrackIDs = [0]
        context.subtitleTrackIDs = []
        send(.up)
        XCTAssertEqual(state.transportFocus, .icon(.stats))
        XCTAssertEqual(send(.select), [])
        XCTAssertTrue(state.isStatsOn)
        send(.select)
        XCTAssertFalse(state.isStatsOn)
    }

    func test_menu_fromAnIcon_returnsToTheScrubber_thenCloses() {
        send(.up)
        XCTAssertEqual(send(.menu), [])
        XCTAssertEqual(state.transportFocus, .scrubber)
        XCTAssertEqual(send(.menu), [.close])
    }

    func test_pressWhilePlaying_skipsTenSeconds_clampedToTheTitle() {
        XCTAssertEqual(press(.right), [.seek(110)])
        context.currentTime = 4
        XCTAssertEqual(press(.left), [.seek(0)])
        context.currentTime = 5395
        XCTAssertEqual(press(.right), [.seek(5400)])
    }

    /// Review Focus 1: with no duration yet a press seeks nowhere.
    func test_press_withNoDuration_seeksNothing() {
        context.duration = 0
        XCTAssertEqual(press(.right), [])
        XCTAssertEqual(state.chrome, .transport, "…but still shows the transport")
    }

    func test_transport_fadesFourSecondsAfterTheLastPress_andFocusReturnsToTheScrubber() {
        send(.up)
        tick(for: 3.8)
        XCTAssertEqual(state.chrome, .transport)
        tick(for: 0.4)
        XCTAssertEqual(state.chrome, .hidden)
        XCTAssertEqual(state.transportFocus, .scrubber)
    }

    func test_transport_neverFadesWhilePausedOrLoading_andItsFadeStartsWithPlayback() {
        state.chrome = .hidden
        context.playback = .paused
        tick(for: 10)
        XCTAssertEqual(state.chrome, .transport, "Pausing shows the transport, and it stays")
        context.playback = .loading
        tick(for: 10)
        XCTAssertEqual(state.chrome, .transport)
        context.playback = .playing
        tick(for: 3.8)
        XCTAssertEqual(state.chrome, .transport, "The fade is timed from playback starting")
        tick(for: 0.4)
        XCTAssertEqual(state.chrome, .hidden)
    }

    func test_autoHideDisabled_keepsTheTransportUp() {
        context.autoHideDisabled = true
        tick(for: 10)
        XCTAssertEqual(state.chrome, .transport)
    }

    func test_endedPlayback_closesWhenNothingFollows_once() {
        context.playback = .ended
        XCTAssertEqual(tick(for: 1), [.close])
        context.closesWhenPlaybackEnds = false
        state.hasRequestedClose = false
        XCTAssertEqual(tick(for: 1), [], "Next Up takes over instead")
    }

    /// Review Focus 5.
    func test_focusedIconThatDisappears_fallsBackToTheScrubber() {
        send(.up)
        press(.right)
        XCTAssertEqual(state.transportFocus, .icon(.audio))
        context.audioTrackIDs = [0]
        tick(for: 0.1)
        XCTAssertEqual(state.transportFocus, .scrubber)
    }
}
```

- [ ] **Step 4: Run them to verify they fail**

Run: `xcodegen generate`, then tvOS unit with `-only-testing:DionysusTVTests/TVPlayerInputModelTests`.
Expected: build failure, "cannot find type 'TVPlayerInputState' in scope".

- [ ] **Step 5: Write the model**

`DionysusTV/Player/TVPlayerInputModel.swift`:

```swift
import Foundation

/// The transport's icons, left to right.
enum TVPlayerIcon: CaseIterable, Equatable {
    case chapters, audio, subtitles, stats

    /// Fixed, unlocalized: identifiers and the focus marker use it.
    var id: String {
        switch self {
        case .chapters: "chapters"
        case .audio: "audio"
        case .subtitles: "subtitles"
        case .stats: "stats"
        }
    }
}

/// The swipe-down panel's tabs, left to right. Stats is not one: it is a
/// toggle on its icon (Benjamin, 2026-10-06).
enum TVPanelTab: CaseIterable, Equatable {
    case info, chapters, audio, subtitles

    var id: String {
        switch self {
        case .info: "info"
        case .chapters: "chapters"
        case .audio: "audio"
        case .subtitles: "subtitles"
        }
    }
}

enum TVDirection: Equatable {
    case left, right

    var sign: Double { self == .left ? -1 : 1 }
}

enum TVNextUpButton: Equatable {
    case playNow, close
}

/// What the remote did, as the host reports it.
enum TVRemoteInput: Equatable {
    case select, playPause, menu, up, down
    /// Left or Right going down and coming up. The model tells a press
    /// (released within `TVPlayerTiming.holdThreshold`) from a hold.
    case arrowDown(TVDirection), arrowUp(TVDirection)
    /// A horizontal swipe `TVSwipeGate` committed to scrubbing: began, the
    /// travel since it began as a fraction of the surface's width, ended.
    case swipeBegan, swipeMoved(fraction: Double), swipeEnded
    /// The model's clock. Holds, scans, fades and timeouts advance on it.
    case tick
}

/// What the host must do to the player (`TVPlayerCommandRunner`).
enum TVPlayerCommand: Equatable {
    case play, pause, togglePlayPause
    case seek(TimeInterval)
    case skipSegment(id: String)
    case playNext, dismissNextUp
    case selectAudio(id: Int), selectSubtitle(id: Int?)
    case close
}

/// The facts the model reads but never sets, snapshotted from
/// `PlayerViewModel` and the settings on every input
/// (`TVPlayerContext.init(viewModel:defaults:)`).
struct TVPlayerContext: Equatable {
    enum Playback: Equatable {
        case loading, playing, paused, ended, failed

        /// Nothing to act on while a title loads or after it failed: only
        /// Menu does anything then, and it closes the player.
        var acceptsInput: Bool { self != .loading && self != .failed }
    }

    struct SkipSegment: Equatable {
        var id: String
        var endSeconds: TimeInterval
    }

    var playback: Playback = .playing
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var chapterStarts: [TimeInterval] = []
    var audioTrackIDs: [Int] = []
    var selectedAudioIndex: Int?
    var subtitleTrackIDs: [Int] = []
    /// `nil` while subtitles are off.
    var selectedSubtitleIndex: Int?
    var statsButtonEnabled = false
    var chaptersInScrubber = true
    var skipSegment: SkipSegment?
    var nextUpSecondsRemaining: Int?
    var closesWhenPlaybackEnds = true
    /// The UI-test harness's `-UITestDisableControlAutoHide`.
    var autoHideDisabled = false

    /// The icons with something to do, so none is a dead stop.
    var availableIcons: [TVPlayerIcon] {
        TVPlayerIcon.allCases.filter { icon in
            switch icon {
            case .chapters: !chapterStarts.isEmpty
            case .audio: audioTrackIDs.count > 1
            case .subtitles: !subtitleTrackIDs.isEmpty
            case .stats: statsButtonEnabled
            }
        }
    }
}

/// Everything the player's UI is doing. The overlay draws from it; only the
/// reducer changes it.
struct TVPlayerInputState: Equatable {
    enum Chrome: Equatable { case hidden, transport }
    enum TransportFocus: Equatable { case scrubber, icon(TVPlayerIcon) }

    struct HeldArrow: Equatable {
        var direction: TVDirection
        var pressedAt: TimeInterval
        var isHold = false
    }

    var chrome: Chrome = .transport
    var transportFocus: TransportFocus = .scrubber
    var lastInputAt: TimeInterval = 0
    var heldArrow: HeldArrow?
    var isStatsOn = false
    var hasRequestedClose = false
}

/// The spec's timings (Benjamin, 2026-10-06). Tuned on the Bedroom Apple TV
/// in Task 11.
enum TVPlayerTiming {
    static let chromeFade: TimeInterval = 4
    static let holdThreshold: TimeInterval = 0.4
    static let skipInterval: TimeInterval = 10
}

/// The player's remote as a pure reducer: a state, an input and a snapshot
/// of the player in; the new state and the commands for the host out.
///
/// The tvOS focus engine is not used in the player (Sodalite's approach):
/// the host's recognizers take every press and this decides what it means,
/// so a press can never land somewhere the focus engine chose instead.
enum TVPlayerInputModel {
    /// What an input means once a press has been told from a hold.
    enum Intent: Equatable {
        case select, playPause, menu, up, down
        case arrow(TVDirection)
        case holdBegan(TVDirection), holdEnded
        case swipeBegan, swipeMoved(Double), swipeEnded
    }

    static func reduce(
        _ state: inout TVPlayerInputState, _ input: TVRemoteInput, context: TVPlayerContext, now: TimeInterval
    ) -> [TVPlayerCommand] {
        if input == .tick { return tick(&state, context: context, now: now) }
        guard context.playback.acceptsInput else {
            state.heldArrow = nil
            return input == .menu ? [.close] : []
        }
        state.lastInputAt = now
        let intent: Intent
        switch input {
        case .select: intent = .select
        case .playPause: intent = .playPause
        case .menu: intent = .menu
        case .up: intent = .up
        case .down: intent = .down
        case .arrowDown(let direction):
            state.heldArrow = .init(direction: direction, pressedAt: now)
            return []
        case .arrowUp(let direction):
            guard let held = state.heldArrow, held.direction == direction else { return [] }
            state.heldArrow = nil
            intent = .arrow(direction)
        case .swipeBegan: intent = .swipeBegan
        case .swipeMoved(let fraction): intent = .swipeMoved(fraction)
        case .swipeEnded: intent = .swipeEnded
        case .tick: return []
        }
        return dispatch(intent, &state, context: context, now: now)
    }

    /// Each concern in turn; the first that handles the intent wins.
    static func dispatch(
        _ intent: Intent, _ state: inout TVPlayerInputState, context: TVPlayerContext, now: TimeInterval
    ) -> [TVPlayerCommand] {
        reduceTransport(intent, &state, context: context, now: now)
    }

    // MARK: - Transport

    static func reduceTransport(
        _ intent: Intent, _ state: inout TVPlayerInputState, context: TVPlayerContext, now: TimeInterval
    ) -> [TVPlayerCommand] {
        let wasHidden = state.chrome == .hidden
        state.chrome = .transport
        switch intent {
        case .select:
            if case .icon(let icon) = state.transportFocus { return activate(icon, &state, context: context, now: now) }
            return context.playback == .ended ? [] : [.togglePlayPause]
        case .playPause:
            return context.playback == .ended ? [] : [.togglePlayPause]
        case .menu:
            if case .icon = state.transportFocus {
                state.transportFocus = .scrubber
                return []
            }
            return [.close]
        case .up:
            if !wasHidden, state.transportFocus == .scrubber, let first = context.availableIcons.first {
                state.transportFocus = .icon(first)
            }
            return []
        case .down:
            if case .icon = state.transportFocus { state.transportFocus = .scrubber }
            return []
        case .arrow(let direction):
            if case .icon(let icon) = state.transportFocus {
                state.transportFocus = .icon(neighbour(of: icon, direction, in: context.availableIcons))
                return []
            }
            return skip(direction, context: context)
        case .holdBegan, .holdEnded, .swipeBegan, .swipeMoved, .swipeEnded:
            return []
        }
    }

    static func activate(
        _ icon: TVPlayerIcon, _ state: inout TVPlayerInputState, context: TVPlayerContext, now: TimeInterval
    ) -> [TVPlayerCommand] {
        switch icon {
        case .stats: state.isStatsOn.toggle()
        case .chapters, .audio, .subtitles: break
        }
        return []
    }

    static func neighbour(of icon: TVPlayerIcon, _ direction: TVDirection, in icons: [TVPlayerIcon]) -> TVPlayerIcon {
        guard let index = icons.firstIndex(of: icon) else { return icons.first ?? icon }
        let next = index + (direction == .left ? -1 : 1)
        return icons.indices.contains(next) ? icons[next] : icon
    }

    /// Review Focus 1: no duration, no seek. M1's `skip(by:)` seeked to 0.
    static func skip(_ direction: TVDirection, context: TVPlayerContext) -> [TVPlayerCommand] {
        guard context.duration > 0 else { return [] }
        return [.seek(clamp(context.currentTime + direction.sign * TVPlayerTiming.skipInterval, context))]
    }

    static func clamp(_ time: TimeInterval, _ context: TVPlayerContext) -> TimeInterval {
        min(max(time, 0), context.duration)
    }

    // MARK: - Clock

    static func tick(_ state: inout TVPlayerInputState, context: TVPlayerContext, now: TimeInterval) -> [TVPlayerCommand] {
        var commands: [TVPlayerCommand] = []
        if case .icon(let icon) = state.transportFocus, !context.availableIcons.contains(icon) {
            state.transportFocus = .scrubber
        }
        switch context.playback {
        case .loading, .paused, .failed:
            // The transport stays up, and its fade waits for playback, so a
            // slow load doesn't use up the title's time on screen.
            state.chrome = .transport
            state.lastInputAt = now
        case .playing, .ended:
            break
        }
        if state.chrome == .transport, chromeMayFade(state, context: context),
           now - state.lastInputAt >= TVPlayerTiming.chromeFade {
            state.chrome = .hidden
            state.transportFocus = .scrubber
        }
        if context.playback == .ended, context.closesWhenPlaybackEnds, !state.hasRequestedClose {
            state.hasRequestedClose = true
            commands.append(.close)
        }
        return commands
    }

    static func chromeMayFade(_ state: TVPlayerInputState, context: TVPlayerContext) -> Bool {
        context.playback == .playing && !context.autoHideDisabled
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: tvOS unit, `-only-testing:DionysusTVTests/TVPlayerInputModelTests`. Expected: all pass.

(No commit yet: PR 1 is committed once after Task 4, with Benjamin's sign-off.)

---

### Task 2: Scrubbing, scanning and the swipe gate

**Files:**
- Create: `DionysusTV/Player/TVPlayerInputModel+Scrub.swift`, `DionysusTV/Player/TVSwipeGate.swift`
- Modify: `DionysusTV/Player/TVPlayerInputModel.swift` (state, timing, `reduce`'s `.arrowUp`, `dispatch`, `tick`, `chromeMayFade`)
- Test: `DionysusTVTests/TVPlayerScrubTests.swift`, `DionysusTVTests/TVSwipeGateTests.swift`

**Interfaces:**
- Consumes: Task 1's types.
- Produces: `TVPlayerInputState.Scrub { previewTime, resumesOnCancel, swipeAnchor, scan }`, `TVPlayerInputState.Scan { direction, startedAt, lastTickAt }`, `TVPlayerInputState.scrub`, `TVScrubMetrics`, `TVPlayerInputModel.reduceScrub(_:_:context:now:) -> [TVPlayerCommand]?`, `TVPlayerInputModel.scrubCanOpen(_:context:) -> Bool`, `TVPlayerInputModel.swipeScrubs(_:context:) -> Bool`, `TVPlayerInputModel.scanRate(heldFor:) -> Double`, `TVPlayerInputModel.snapped(_:context:)`, `TVSwipeGate` with `began()`, `changed(translation:velocity:width:scrubs:) -> [TVRemoteInput]`, `ended() -> [TVRemoteInput]`.

- [ ] **Step 1: Write the failing scrub tests**

`DionysusTVTests/TVPlayerScrubTests.swift`:

```swift
import XCTest
@testable import Dionysus

final class TVPlayerScrubTests: XCTestCase, TVPlayerInputModelHarness {
    var state = TVPlayerInputState()
    var context = TVPlayerScrubTests.standardContext
    var now: TimeInterval = 1000

    func test_pressWhilePaused_opensAScrubTenSecondsOn_withoutPlaying() {
        context.playback = .paused
        XCTAssertEqual(press(.right), [])
        XCTAssertEqual(state.scrub?.previewTime, 110)
        XCTAssertEqual(state.scrub?.resumesOnCancel, false)
    }

    func test_scrubPresses_step_andSelectSeeksThereAndPlays() {
        context.playback = .paused
        press(.right)
        press(.right)
        press(.right)
        XCTAssertEqual(state.scrub?.previewTime, 130)
        XCTAssertEqual(send(.select), [.seek(130), .play])
        XCTAssertNil(state.scrub)
    }

    func test_playPause_commitsAScrubToo() {
        context.playback = .paused
        press(.left)
        XCTAssertEqual(send(.playPause), [.seek(90), .play])
    }

    func test_menu_cancels_andStaysPausedWhenTheScrubStartedPaused() {
        context.playback = .paused
        press(.right)
        XCTAssertEqual(send(.menu), [])
        XCTAssertNil(state.scrub)
    }

    func test_swipeWhilePlaying_pauses_andMenuResumes() {
        XCTAssertEqual(send(.swipeBegan), [.pause])
        context.playback = .paused
        XCTAssertEqual(state.scrub?.resumesOnCancel, true)
        XCTAssertEqual(send(.menu), [.play])
    }

    func test_aFullWidthSwipe_coversAQuarterOfTheTitle() {
        context.chaptersInScrubber = false
        send(.swipeBegan)
        send(.swipeMoved(fraction: 1))
        XCTAssertEqual(state.scrub?.previewTime ?? 0, 100 + 1350, accuracy: 0.001)
        send(.swipeMoved(fraction: -0.1))
        XCTAssertEqual(state.scrub?.previewTime ?? 0, 0, accuracy: 0.001, "Clamped at the start")
    }

    func test_swipe_snapsToANearbyChapter_onlyWithChaptersInScrubber() {
        // 0.8% of 5400s is 43.2s either side of a chapter start.
        send(.swipeBegan)
        send(.swipeMoved(fraction: (1320 - 100) / 1350))
        XCTAssertEqual(state.scrub?.previewTime ?? 0, 1350, accuracy: 0.001)
        context.chaptersInScrubber = false
        send(.swipeMoved(fraction: (1320 - 100) / 1350))
        XCTAssertEqual(state.scrub?.previewTime ?? 0, 1320, accuracy: 0.001)
    }

    func test_holdWhilePlaying_pausesAndScansAt8x() {
        send(.arrowDown(.right))
        XCTAssertEqual(tick(for: 0.3), [])
        XCTAssertEqual(tick(for: 0.2), [.pause], "Past 0.4s the press is a hold")
        context.playback = .paused
        let start = state.scrub?.previewTime ?? 0
        tick(for: 1)
        XCTAssertEqual((state.scrub?.previewTime ?? 0) - start, 8, accuracy: 1.7, "8x for the first two seconds")
    }

    func test_scanRate_stepsEveryTwoSeconds_to64x() {
        XCTAssertEqual(TVPlayerInputModel.scanRate(heldFor: 0), 8)
        XCTAssertEqual(TVPlayerInputModel.scanRate(heldFor: 1.9), 8)
        XCTAssertEqual(TVPlayerInputModel.scanRate(heldFor: 2), 16)
        XCTAssertEqual(TVPlayerInputModel.scanRate(heldFor: 4.5), 32)
        XCTAssertEqual(TVPlayerInputModel.scanRate(heldFor: 6), 64)
        XCTAssertEqual(TVPlayerInputModel.scanRate(heldFor: 60), 64, "64x is the ceiling")
    }

    func test_releasingAHold_keepsTheScrubOpenAtThePreview() {
        send(.arrowDown(.left))
        tick(for: 1)
        context.playback = .paused
        let preview = state.scrub?.previewTime
        XCTAssertEqual(send(.arrowUp(.left)), [])
        XCTAssertNotNil(state.scrub)
        XCTAssertNil(state.scrub?.scan)
        XCTAssertEqual(state.scrub?.previewTime, preview)
    }

    func test_aShortPress_isNeverAHold() {
        send(.arrowDown(.right))
        tick(for: 0.3)
        XCTAssertEqual(send(.arrowUp(.right)), [.seek(110)], "Still a 10s skip while playing")
        XCTAssertNil(state.scrub)
    }

    func test_holdOnAnIcon_actsAsOnePressOnRelease() {
        send(.up)
        send(.arrowDown(.right))
        XCTAssertEqual(tick(for: 1), [], "No scrub opens from an icon")
        XCTAssertNil(state.scrub)
        send(.arrowUp(.right))
        XCTAssertEqual(state.transportFocus, .icon(.audio))
    }

    /// Review Focus 1.
    func test_noDuration_noScrubOpens() {
        context.duration = 0
        XCTAssertEqual(send(.swipeBegan), [])
        send(.arrowDown(.right))
        XCTAssertEqual(tick(for: 1), [])
        XCTAssertNil(state.scrub)
    }

    func test_theTransportStaysUpWhileScrubbing() {
        context.playback = .paused
        press(.right)
        context.playback = .playing   // e.g. resumed by a headphone button
        tick(for: 10)
        XCTAssertEqual(state.chrome, .transport)
    }
}
```

- [ ] **Step 2: Write the failing swipe gate tests**

`DionysusTVTests/TVSwipeGateTests.swift`:

```swift
import XCTest
@testable import Dionysus

final class TVSwipeGateTests: XCTestCase {
    private var gate = TVSwipeGate()
    private let width: CGFloat = 1920

    private func move(_ x: CGFloat, _ y: CGFloat = 0, vx: CGFloat = 1000, vy: CGFloat = 0, scrubs: Bool = true) -> [TVRemoteInput] {
        gate.changed(translation: CGPoint(x: x, y: y), velocity: CGPoint(x: vx, y: vy), width: width, scrubs: scrubs)
    }

    func test_belowTheAxisDistance_nothingHappens() {
        gate.began()
        XCTAssertEqual(move(30), [])
    }

    func test_aFastHorizontalSwipe_beginsAScrub_measuredFromWhereItCommitted() {
        gate.began()
        XCTAssertEqual(move(50), [.swipeBegan])
        XCTAssertEqual(move(50 + 192), [.swipeMoved(fraction: 0.1)])
        XCTAssertEqual(gate.ended(), [.swipeEnded])
    }

    /// A resting thumb drifts slowly; it must never pause playback.
    func test_aSlowDrift_neverBeginsAScrub() {
        gate.began()
        XCTAssertEqual(move(60, vx: 100), [])
        XCTAssertEqual(move(90, vx: 150), [])
        XCTAssertEqual(gate.ended(), [])
    }

    func test_whereNoScrubCanOpen_aSwipeIsOneArrowPress() {
        gate.began()
        XCTAssertEqual(move(100, scrubs: false), [], "Under the step distance")
        XCTAssertEqual(move(-160, vx: -800, scrubs: false), [], "The axis is horizontal; direction reads at the step")
        gate.began()
        XCTAssertEqual(move(160, vx: 800, scrubs: false), [.arrowDown(.right), .arrowUp(.right)])
        XCTAssertEqual(move(400, vx: 800, scrubs: false), [], "Once per swipe")
    }

    func test_aVerticalSwipe_isOneUpOrDown() {
        gate.began()
        XCTAssertEqual(move(0, 160, vx: 0, vy: 900), [.down])
        XCTAssertEqual(move(0, 400, vx: 0, vy: 900), [])
        gate.began()
        XCTAssertEqual(move(0, -160, vx: 0, vy: -900), [.up])
    }
}
```

- [ ] **Step 3: Run them to verify they fail**

Expected: build failure, "value of type 'TVPlayerInputState' has no member 'scrub'" and "cannot find 'TVSwipeGate'".

- [ ] **Step 4: Add the scrub state and timing**

In `TVPlayerInputModel.swift`, inside `TVPlayerInputState`, after `HeldArrow`:

```swift
    struct Scan: Equatable {
        var direction: TVDirection
        var startedAt: TimeInterval
        var lastTickAt: TimeInterval
    }

    /// A scrub moves a preview, never playback, until it is committed.
    struct Scrub: Equatable {
        var previewTime: TimeInterval
        /// Whether the scrub paused playback, so cancelling resumes it.
        var resumesOnCancel: Bool
        /// The preview when the current swipe began.
        var swipeAnchor: TimeInterval?
        var scan: Scan?
    }
```

and the stored property `var scrub: Scrub?` after `heldArrow`.

In `TVPlayerTiming` add:

```swift
    static let scanSpeeds: [Double] = [8, 16, 32, 64]
    static let scanStepInterval: TimeInterval = 2
```

and below it:

```swift
/// How a swipe maps onto the title (tuned in Task 11).
enum TVScrubMetrics {
    /// A swipe across the whole surface covers this fraction of the title.
    static let fullSwipeFractionOfDuration = 0.25
    /// A swipe's preview snaps to a chapter start this close, as a fraction
    /// of the title (43s of a 90-minute film).
    static let snapFractionOfDuration = 0.008
}
```

- [ ] **Step 5: Route holds and scrubs**

In `reduce`, replace the `.arrowUp` case with:

```swift
        case .arrowUp(let direction):
            guard let held = state.heldArrow, held.direction == direction else { return [] }
            state.heldArrow = nil
            // A hold that started a scan ends it; one that didn't (an icon,
            // the panel) counts as a single press on release.
            intent = held.isHold && state.scrub?.scan != nil ? .holdEnded : .arrow(direction)
```

Replace `dispatch`'s body with:

```swift
        if let commands = reduceScrub(intent, &state, context: context, now: now) { return commands }
        return reduceTransport(intent, &state, context: context, now: now)
```

In `tick`, before the `switch context.playback`:

```swift
        if var held = state.heldArrow, !held.isHold, context.playback.acceptsInput,
           now - held.pressedAt >= TVPlayerTiming.holdThreshold {
            held.isHold = true
            state.heldArrow = held
            commands += dispatch(.holdBegan(held.direction), &state, context: context, now: now)
        }
        if var scrub = state.scrub, var scan = scrub.scan {
            let rate = scanRate(heldFor: now - scan.startedAt)
            scrub.previewTime = clamp(scrub.previewTime + scan.direction.sign * rate * (now - scan.lastTickAt), context)
            scan.lastTickAt = now
            scrub.scan = scan
            state.scrub = scrub
        }
```

and change `chromeMayFade` to:

```swift
        context.playback == .playing && !context.autoHideDisabled && state.scrub == nil
```

- [ ] **Step 6: Write the scrub reducer**

`DionysusTV/Player/TVPlayerInputModel+Scrub.swift`:

```swift
import Foundation

extension TVPlayerInputModel {
    /// Scrubbing and scanning (Benjamin, 2026-10-06): a swipe or a hold
    /// pauses and opens a scrub; a press of Left/Right while paused opens one
    /// 10s away. `nil` when the intent isn't a scrub's.
    static func reduceScrub(
        _ intent: Intent, _ state: inout TVPlayerInputState, context: TVPlayerContext, now: TimeInterval
    ) -> [TVPlayerCommand]? {
        if let scrub = state.scrub {
            return continueScrub(scrub, intent, &state, context: context, now: now)
        }
        guard scrubCanOpen(state, context: context) else {
            switch intent {
            case .swipeBegan, .swipeMoved, .swipeEnded, .holdBegan, .holdEnded: return []
            default: return nil
            }
        }
        let playing = context.playback == .playing
        switch intent {
        case .holdBegan(let direction):
            state.chrome = .transport
            state.scrub = .init(
                previewTime: context.currentTime, resumesOnCancel: playing,
                scan: .init(direction: direction, startedAt: now, lastTickAt: now)
            )
            return playing ? [.pause] : []
        case .swipeBegan:
            state.chrome = .transport
            state.scrub = .init(previewTime: context.currentTime, resumesOnCancel: playing, swipeAnchor: context.currentTime)
            return playing ? [.pause] : []
        case .arrow(let direction) where context.playback == .paused:
            state.chrome = .transport
            state.scrub = .init(
                previewTime: clamp(context.currentTime + direction.sign * TVPlayerTiming.skipInterval, context),
                resumesOnCancel: false
            )
            return []
        case .swipeMoved, .swipeEnded, .holdEnded:
            return []
        default:
            return nil
        }
    }

    /// Where a scrub may open: a title with a duration, focus on the
    /// scrubber (always so with the transport hidden).
    static func scrubCanOpen(_ state: TVPlayerInputState, context: TVPlayerContext) -> Bool {
        context.duration > 0 && state.transportFocus == .scrubber
    }

    /// Whether a horizontal swipe scrubs (`TVSwipeGate`), or steps instead.
    static func swipeScrubs(_ state: TVPlayerInputState, context: TVPlayerContext) -> Bool {
        state.scrub != nil || scrubCanOpen(state, context: context)
    }

    static func continueScrub(
        _ scrub: TVPlayerInputState.Scrub, _ intent: Intent, _ state: inout TVPlayerInputState,
        context: TVPlayerContext, now: TimeInterval
    ) -> [TVPlayerCommand] {
        var scrub = scrub
        switch intent {
        case .select, .playPause:
            state.scrub = nil
            return [.seek(scrub.previewTime), .play]
        case .menu:
            state.scrub = nil
            return scrub.resumesOnCancel ? [.play] : []
        case .arrow(let direction):
            scrub.scan = nil
            scrub.swipeAnchor = nil
            scrub.previewTime = clamp(scrub.previewTime + direction.sign * TVPlayerTiming.skipInterval, context)
        case .holdBegan(let direction):
            scrub.swipeAnchor = nil
            scrub.scan = .init(direction: direction, startedAt: now, lastTickAt: now)
        case .holdEnded:
            scrub.scan = nil
        case .swipeBegan:
            scrub.scan = nil
            scrub.swipeAnchor = scrub.previewTime
        case .swipeMoved(let fraction):
            if let anchor = scrub.swipeAnchor {
                let travel = fraction * context.duration * TVScrubMetrics.fullSwipeFractionOfDuration
                scrub.previewTime = snapped(clamp(anchor + travel, context), context: context)
            }
        case .swipeEnded:
            scrub.swipeAnchor = nil
        case .up, .down:
            break
        }
        state.scrub = scrub
        return []
    }

    /// 8x, stepping up every 2s held to 64x.
    static func scanRate(heldFor seconds: TimeInterval) -> Double {
        let step = Int(max(seconds, 0) / TVPlayerTiming.scanStepInterval)
        return TVPlayerTiming.scanSpeeds[min(step, TVPlayerTiming.scanSpeeds.count - 1)]
    }

    /// Chapters in Scrubber's snap, as iOS's scrubber has it.
    static func snapped(_ time: TimeInterval, context: TVPlayerContext) -> TimeInterval {
        guard context.chaptersInScrubber, context.duration > 0 else { return time }
        let radius = context.duration * TVScrubMetrics.snapFractionOfDuration
        guard let nearest = context.chapterStarts.min(by: { abs($0 - time) < abs($1 - time) }),
              abs(nearest - time) <= radius else { return time }
        return nearest
    }
}
```

- [ ] **Step 7: Write the swipe gate**

`DionysusTV/Player/TVSwipeGate.swift`:

```swift
import CoreGraphics

/// Turns one touch-surface pan into what it means to the player.
///
/// Horizontal, where a scrub can open: a scrub, once the swipe has moved
/// 40pt and is going at least 200pt/s, so a resting thumb's drift never
/// pauses playback. Horizontal elsewhere, or vertical: one arrow press per
/// swipe after 150pt at 400pt/s. Sodalite's measured thresholds
/// (`PlayerHostController.handlePan`); indirect touches over-report
/// translation, so these are larger than they look.
struct TVSwipeGate {
    static let axisCommitDistance: CGFloat = 40
    static let scrubCommitVelocity: CGFloat = 200
    static let stepDistance: CGFloat = 150
    static let stepVelocity: CGFloat = 400

    private enum Phase { case undecided, horizontal, vertical, scrubbing, done }
    private var phase: Phase = .undecided
    private var scrubOriginX: CGFloat = 0

    mutating func began() {
        phase = .undecided
    }

    mutating func changed(translation t: CGPoint, velocity v: CGPoint, width: CGFloat, scrubs: Bool) -> [TVRemoteInput] {
        if phase == .undecided {
            guard max(abs(t.x), abs(t.y)) >= Self.axisCommitDistance else { return [] }
            phase = abs(t.x) > abs(t.y) ? .horizontal : .vertical
        }
        switch phase {
        case .horizontal where scrubs:
            guard abs(v.x) >= Self.scrubCommitVelocity else { return [] }
            phase = .scrubbing
            scrubOriginX = t.x
            return [.swipeBegan]
        case .horizontal:
            guard abs(t.x) >= Self.stepDistance, abs(v.x) >= Self.stepVelocity else { return [] }
            phase = .done
            let direction: TVDirection = t.x < 0 ? .left : .right
            return [.arrowDown(direction), .arrowUp(direction)]
        case .vertical:
            guard abs(t.y) >= Self.stepDistance, abs(v.y) >= Self.stepVelocity else { return [] }
            phase = .done
            return [t.y < 0 ? .up : .down]
        case .scrubbing:
            return [.swipeMoved(fraction: Double((t.x - scrubOriginX) / max(width, 1)))]
        case .undecided, .done:
            return []
        }
    }

    mutating func ended() -> [TVRemoteInput] {
        defer { phase = .undecided }
        return phase == .scrubbing ? [.swipeEnded] : []
    }
}
```

- [ ] **Step 8: Run the model and gate tests**

Run: tvOS unit, `-only-testing:DionysusTVTests/TVPlayerInputModelTests -only-testing:DionysusTVTests/TVPlayerScrubTests -only-testing:DionysusTVTests/TVSwipeGateTests`. Expected: all pass. If `test_holdWhilePlaying_pausesAndScans_rampingEveryTwoSeconds` is off by one tick, the 10 Hz step makes the ramp boundary land a tick late; widen nothing else, the accuracies already allow for it.

---

### Task 3: Wiring the host to the model

**Files:**
- Create: `DionysusTV/Player/TVPlayerContext+ViewModel.swift`, `DionysusTV/Player/TVPlayerInput.swift`, `DionysusTV/Player/TVPlayerCommandRunner.swift`, `DionysusTV/Player/TVPlayerOverlay.swift`
- Modify: `DionysusTV/Player/TVPlayerHostController.swift`, `DionysusTV/Player/TVPlayerPresenter.swift`, `DionysusTV/Player/TVTransportOverlay.swift`, `DionysusPlayer/Features/Player/PlayerViewModel.swift`
- Delete: `DionysusTV/Player/TVTransportChrome.swift`, `DionysusTVTests/TVTransportChromeTests.swift`
- Test: `DionysusTVTests/TVPlayerContextTests.swift`, `DionysusTVTests/TVPlayerInputTests.swift`, `DionysusTVTests/TVPlayerCommandRunnerTests.swift`

**Interfaces:**
- Consumes: Tasks 1–2.
- Produces: `TVPlayerContext.init(viewModel:defaults:)`, `TVPlayerContext.playback(_:) -> Playback`, `TVPlayerInput` (`state`, `context`, `perform`, `send(_:)`, `swipeScrubs`, `start()`, `stop()`, `reset()`), `TVPlayerCommandRunner(viewModel:close:playNext:)` with `run(_:)`, `TVPlayerOverlay(viewModel:input:)`, `PlayerViewModel.play()`, `PlayerViewModel.pause()`, `TVPlayerHostController(viewModel:)`.

- [ ] **Step 1: Write the failing tests**

`DionysusTVTests/TVPlayerContextTests.swift`:

```swift
import XCTest
@testable import Dionysus

@MainActor
final class TVPlayerContextTests: XCTestCase {
    private let suiteName = "com.dionysusplayer.tests.TVPlayerContextTests"
    private lazy var defaults = UserDefaults(suiteName: suiteName)!

    override func tearDown() async throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    func test_playbackStates_mapToWhatThePlayerAcceptsInputIn() {
        XCTAssertEqual(TVPlayerContext.playback(.idle), .loading)
        XCTAssertEqual(TVPlayerContext.playback(.loading), .loading)
        XCTAssertEqual(TVPlayerContext.playback(.playing), .playing)
        XCTAssertEqual(TVPlayerContext.playback(.buffering), .playing)
        XCTAssertEqual(TVPlayerContext.playback(.seeking), .playing)
        XCTAssertEqual(TVPlayerContext.playback(.reconnecting), .playing)
        XCTAssertEqual(TVPlayerContext.playback(.paused), .paused)
        XCTAssertEqual(TVPlayerContext.playback(.ended), .ended)
    }

    func test_tracksAndSettings_comeFromTheViewModelAndDefaults() {
        let engine = FakePlaybackEngine()
        engine.audioTracks = [
            PlaybackTrack(id: 4, kind: .audio, title: "English", metadata: nil, isSelected: false),
            PlaybackTrack(id: 7, kind: .audio, title: "Commentary", metadata: nil, isSelected: true)
        ]
        engine.subtitleTracks = [PlaybackTrack(id: 2, kind: .subtitle, title: "English", metadata: nil, isSelected: false)]
        let viewModel = PlayerViewModel(
            client: JellyfinAPIClient(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok", session: MockURLProtocol.makeSession()),
            userID: "user-1", itemID: "item-1", engine: engine,
            trackPreferenceStore: TrackPreferenceStore(defaults: defaults),
            nextUpPreferenceStore: NextUpPreferenceStore(defaults: defaults),
            streamPreferenceStore: StreamPreferenceStore(defaults: defaults)
        )
        defaults.set(true, forKey: showPlaybackStatsButtonEnabledStorageKey)
        defaults.set(false, forKey: chaptersInScrubberEnabledStorageKey)

        let context = TVPlayerContext(viewModel: viewModel, defaults: defaults)

        XCTAssertEqual(context.audioTrackIDs, [4, 7])
        XCTAssertEqual(context.selectedAudioIndex, 1)
        XCTAssertEqual(context.subtitleTrackIDs, [2])
        XCTAssertNil(context.selectedSubtitleIndex)
        XCTAssertTrue(context.statsButtonEnabled)
        XCTAssertFalse(context.chaptersInScrubber)
    }
}
```

`DionysusTVTests/TVPlayerInputTests.swift`:

```swift
import XCTest
@testable import Dionysus

@MainActor
final class TVPlayerInputTests: XCTestCase {
    func test_send_reducesAndHandsTheCommandsOver() {
        var now: TimeInterval = 50
        let input = TVPlayerInput(clock: { now })
        input.context = { TVPlayerContext(playback: .playing, currentTime: 20, duration: 600) }
        var performed: [TVPlayerCommand] = []
        input.perform = { performed += $0 }

        input.send(.arrowDown(.right))
        now += 0.1
        input.send(.arrowUp(.right))

        XCTAssertEqual(performed, [.seek(30)])
    }

    func test_start_timesTheFirstFadeFromNow_notFromZero() {
        var now: TimeInterval = 50
        let input = TVPlayerInput(clock: { now })
        input.context = { TVPlayerContext(playback: .playing, duration: 600) }
        input.start()
        input.stop()
        now += 1
        input.send(.tick)
        XCTAssertEqual(input.state.chrome, .transport, "One second in, the transport is still up")
    }

    func test_reset_keepsOnlyStats() {
        let input = TVPlayerInput(clock: { 0 })
        input.context = { TVPlayerContext(playback: .playing, duration: 600, statsButtonEnabled: true) }
        input.send(.up)
        input.send(.select)
        XCTAssertTrue(input.state.isStatsOn)
        input.reset()
        XCTAssertTrue(input.state.isStatsOn)
        XCTAssertEqual(input.state.transportFocus, .scrubber)
    }
}
```

`DionysusTVTests/TVPlayerCommandRunnerTests.swift`:

```swift
import XCTest
@testable import Dionysus

@MainActor
final class TVPlayerCommandRunnerTests: XCTestCase {
    private let suiteName = "com.dionysusplayer.tests.TVPlayerCommandRunnerTests"

    override func tearDown() async throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    func test_commands_reachTheEngineThroughTheViewModel() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let engine = FakePlaybackEngine()
        let viewModel = PlayerViewModel(
            client: JellyfinAPIClient(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok", session: MockURLProtocol.makeSession()),
            userID: "user-1", itemID: "item-1", engine: engine,
            trackPreferenceStore: TrackPreferenceStore(defaults: defaults),
            nextUpPreferenceStore: NextUpPreferenceStore(defaults: defaults),
            streamPreferenceStore: StreamPreferenceStore(defaults: defaults)
        )
        var closed = 0
        var advanced = 0
        let runner = TVPlayerCommandRunner(viewModel: viewModel, close: { closed += 1 }, playNext: { advanced += 1 })

        runner.run([.pause, .play, .togglePlayPause, .seek(42), .selectAudio(id: 3), .selectSubtitle(id: nil), .playNext, .close])
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(engine.pauseCallCount, 1)
        XCTAssertEqual(engine.playCallCount, 1)
        XCTAssertEqual(engine.togglePlayPauseCallCount, 1)
        XCTAssertEqual(engine.seekedTimes, [42])
        XCTAssertEqual(engine.selectedAudioTrackIDs, [3])
        XCTAssertEqual(engine.selectedSubtitleTrackIDs, [nil])
        XCTAssertEqual(advanced, 1)
        XCTAssertEqual(closed, 1)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Expected: build failure, "cannot find 'TVPlayerInput' in scope".

- [ ] **Step 3: Add `play()` and `pause()` to the shared view model**

In `DionysusPlayer/Features/Player/PlayerViewModel.swift`, after `togglePlayPause()`:

```swift
    /// Explicit, for the Apple TV's scrub: a swipe or hold pauses, and a
    /// commit plays, whatever the state was. iOS only toggles.
    func play() {
        engine.play()
    }

    func pause() {
        engine.pause()
    }
```

- [ ] **Step 4: Write the context builder, controller and runner**

`DionysusTV/Player/TVPlayerContext+ViewModel.swift`:

```swift
import Foundation

extension TVPlayerContext {
    /// A snapshot of the player and the settings, taken on every input.
    @MainActor
    init(viewModel: PlayerViewModel, defaults: UserDefaults = .standard) {
        self.init()
        playback = Self.playback(viewModel.state)
        currentTime = viewModel.currentTime
        duration = viewModel.duration
        chapterStarts = viewModel.chapters.map(\.startSeconds)
        let audio = viewModel.audioTracks
        audioTrackIDs = audio.map(\.id)
        selectedAudioIndex = audio.firstIndex(where: \.isSelected)
        let subtitles = viewModel.subtitleTracks
        subtitleTrackIDs = subtitles.map(\.id)
        selectedSubtitleIndex = subtitles.firstIndex(where: \.isSelected)
        statsButtonEnabled = Self.flag(showPlaybackStatsButtonEnabledStorageKey, default: showPlaybackStatsButtonEnabledDefault, in: defaults)
        chaptersInScrubber = Self.flag(chaptersInScrubberEnabledStorageKey, default: chaptersInScrubberEnabledDefault, in: defaults)
        skipSegment = viewModel.currentSkipSegment.map { SkipSegment(id: $0.id, endSeconds: $0.endSeconds) }
        nextUpSecondsRemaining = viewModel.nextUpSecondsRemaining
        closesWhenPlaybackEnds = viewModel.closesWhenPlaybackEnds
        #if DEBUG
        autoHideDisabled = UITestConfiguration.disablesControlAutoHide
        #endif
    }

    /// `object(forKey:)` before `bool(forKey:)`, as
    /// `PlayerViewModel.isStyledASSEnabled` does: `bool` reads an unwritten
    /// key as `false`, and a launch argument ("-key YES") arrives as a
    /// string that only `bool` understands.
    static func flag(_ key: String, default fallback: Bool, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    static func playback(_ state: PlaybackState) -> Playback {
        switch state {
        case .idle, .loading: .loading
        case .playing, .seeking, .buffering, .reconnecting: .playing
        case .paused: .paused
        case .ended: .ended
        case .failed: .failed
        }
    }
}
```

`DionysusTV/Player/TVPlayerInput.swift`:

```swift
import Foundation
import Observation

/// Runs `TVPlayerInputModel` for the host: a clock, a 10 Hz tick while the
/// player is up, and the state the overlay draws from.
@Observable
@MainActor
final class TVPlayerInput {
    private(set) var state = TVPlayerInputState()
    @ObservationIgnored var context: () -> TVPlayerContext = { TVPlayerContext() }
    @ObservationIgnored var perform: ([TVPlayerCommand]) -> Void = { _ in }
    @ObservationIgnored private let clock: () -> TimeInterval
    @ObservationIgnored private var ticker: Task<Void, Never>?

    static let tickInterval: Duration = .milliseconds(100)

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    func send(_ input: TVRemoteInput) {
        var next = state
        let commands = TVPlayerInputModel.reduce(&next, input, context: context(), now: clock())
        // Assigned only on change: every tick would otherwise invalidate the
        // overlay ten times a second.
        if next != state { state = next }
        if !commands.isEmpty { perform(commands) }
    }

    var swipeScrubs: Bool { TVPlayerInputModel.swipeScrubs(state, context: context()) }

    func start() {
        guard ticker == nil else { return }
        state.lastInputAt = clock()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                self?.send(.tick)
            }
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
    }

    /// A new item in the same player: everything starts over but Stats,
    /// which stays as the person left it (Review Focus 4).
    func reset() {
        state = TVPlayerInputState(lastInputAt: clock(), isStatsOn: state.isStatsOn)
    }
}
```

`DionysusTV/Player/TVPlayerCommandRunner.swift`:

```swift
import Foundation

/// The only code that acts on `PlayerViewModel` for a press.
@MainActor
struct TVPlayerCommandRunner {
    let viewModel: PlayerViewModel
    let close: () -> Void
    let playNext: () -> Void

    func run(_ commands: [TVPlayerCommand]) {
        for command in commands {
            switch command {
            case .play: viewModel.play()
            case .pause: viewModel.pause()
            case .togglePlayPause: viewModel.togglePlayPause()
            case .seek(let time): viewModel.seek(to: time)
            case .skipSegment(let id):
                if let segment = viewModel.mediaSegments.first(where: { $0.id == id }) {
                    viewModel.skipSegment(segment)
                }
            case .playNext: playNext()
            case .dismissNextUp: viewModel.dismissNextUp()
            case .selectAudio(let id): viewModel.selectAudioTrack(id: id)
            case .selectSubtitle(let id): viewModel.selectSubtitleTrack(id: id)
            case .close: close()
            }
        }
    }
}
```

- [ ] **Step 5: Rewire the host**

In `DionysusTV/Player/TVPlayerHostController.swift`:

1. Replace the stored properties and `init` with:

```swift
    private var session: TVPlaybackSession
    private var viewModel: PlayerViewModel { session.viewModel }
    private var engine: PlaybackEngine { viewModel.engine }
    private let input = TVPlayerInput()
    private var swipeGate = TVSwipeGate()

    private var aetherView: AetherPlayerView?
    private var isAetherViewBound = false
    private var fakeSurface: UIHostingController<AnyView>?
    private var overlayHost: UIHostingController<TVPlayerOverlay>?
    private var ourRecognizers: [UIGestureRecognizer] = []
    private var cancellables: Set<AnyCancellable> = []

    init(viewModel: PlayerViewModel) {
        session = TVPlaybackSession(viewModel: viewModel)
        super.init(nibName: nil, bundle: nil)
        input.context = { [weak self] in
            guard let self else { return TVPlayerContext() }
            return TVPlayerContext(viewModel: self.viewModel)
        }
        input.perform = { [weak self] commands in self?.run(commands) }
    }
```

2. In `viewDidLoad`, replace the surface branch with `bindSurface()`, build the overlay as `TVPlayerOverlay(viewModel: viewModel, input: input)`, and replace the five `addPress` lines with:

```swift
        addTap(.select) { [weak self] in self?.input.send(.select) }
        addTap(.playPause) { [weak self] in self?.input.send(.playPause) }
        addTap(.menu) { [weak self] in self?.input.send(.menu) }
        addTap(.upArrow) { [weak self] in self?.input.send(.up) }
        addTap(.downArrow) { [weak self] in self?.input.send(.down) }
        addArrow(.leftArrow, .left)
        addArrow(.rightArrow, .right)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        view.addGestureRecognizer(pan)
        ourRecognizers.append(pan)
```

3. In `pressesEnded`, replace `case .playPause: togglePlayPause()` with `case .playPause: input.send(.playPause)`.

4. In `viewDidAppear`, after `session.begin()` add `input.start()`.

5. Rename `bindToAVKit`'s call site into a pair, and keep the fake surface for removal:

```swift
    private func bindSurface() {
        if let aether = engine as? AetherPlaybackEngine {
            bindToAVKit(aether)
        } else {
            showFakeSurface()
        }
    }
```

In `showFakeSurface()`, assign the hosting controller to `fakeSurface` and make its type `UIHostingController<AnyView>` (`UIHostingController(rootView: engine.makeSurface())` already is).

6. Replace the `// MARK: - Remote` section's `togglePlayPause()` and `skip(by:)` with:

```swift
    private func run(_ commands: [TVPlayerCommand]) {
        TVPlayerCommandRunner(viewModel: viewModel, close: { [weak self] in self?.close() }, playNext: {}).run(commands)
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            swipeGate.began()
        case .changed:
            let inputs = swipeGate.changed(
                translation: pan.translation(in: view), velocity: pan.velocity(in: view),
                width: view.bounds.width, scrubs: input.swipeScrubs
            )
            inputs.forEach(input.send)
        case .ended, .cancelled, .failed:
            swipeGate.ended().forEach(input.send)
        default:
            break
        }
    }
```

7. In `close()`, add `input.stop()` as its first line.

8. Rename `addPress` to `addTap` (same body), and add:

```swift
    /// Left and Right report down and up, so the model can tell a press from
    /// a hold. A long-press recognizer with no minimum is UIKit's way to get
    /// both edges of a remote press.
    private func addArrow(_ type: UIPress.PressType, _ direction: TVDirection) {
        let recognizer = UILongPressGestureRecognizer(target: nil, action: nil)
        recognizer.minimumPressDuration = 0
        recognizer.allowedPressTypes = [NSNumber(value: type.rawValue)]
        recognizer.addTarget(self, action: direction == .left ? #selector(leftArrowChanged(_:)) : #selector(rightArrowChanged(_:)))
        view.addGestureRecognizer(recognizer)
        ourRecognizers.append(recognizer)
    }

    @objc private func leftArrowChanged(_ recognizer: UILongPressGestureRecognizer) { arrowChanged(recognizer, .left) }
    @objc private func rightArrowChanged(_ recognizer: UILongPressGestureRecognizer) { arrowChanged(recognizer, .right) }

    private func arrowChanged(_ recognizer: UILongPressGestureRecognizer, _ direction: TVDirection) {
        switch recognizer.state {
        case .began: input.send(.arrowDown(direction))
        case .ended, .cancelled, .failed: input.send(.arrowUp(direction))
        default: break
        }
    }
```

9. Delete `private let chrome = TVTransportChrome()` and every `chrome.` use.

In `TVPlayerPresenter.present`, construct the host with `TVPlayerHostController(viewModel: viewModel)`.

- [ ] **Step 6: Give the overlay the input state**

`DionysusTV/Player/TVPlayerOverlay.swift`:

```swift
import SwiftUI

/// Everything drawn over the video, bottom to top. Takes no interaction:
/// the host's recognizers take every press (`TVPlayerInputModel`).
struct TVPlayerOverlay: View {
    let viewModel: PlayerViewModel
    let input: TVPlayerInput

    var body: some View {
        ZStack {
            TVTransportOverlay(viewModel: viewModel, input: input)
        }
    }
}
```

In `TVTransportOverlay.swift`: replace `let chrome: TVTransportChrome` with `let input: TVPlayerInput`; replace `showsChrome` with `input.state.chrome == .transport`; delete the `.onChange(of: viewModel.state)` modifier.

Delete `DionysusTV/Player/TVTransportChrome.swift` and `DionysusTVTests/TVTransportChromeTests.swift`, then `xcodegen generate`.

- [ ] **Step 7: Run the unit tests and the existing player journeys**

Run: tvOS unit (whole `TVUnitTests` plan), then tvOS UI `-only-testing:DionysusTVUITests/PlayerJourneyTests -only-testing:DionysusTVUITests/PlayerReturnJourneyTests`. Expected: all pass. `test_openPlayer_skipForward_menuDismisses` now goes through `arrowDown`/`arrowUp`: XCUIRemote's press is well under 0.4s, so it stays a skip.

---

### Task 4: Transport v2

**Files:**
- Create: `DionysusTV/Player/TVTransportLayout.swift`, `TVPlayerIconButton.swift`, `TVScrubPreview.swift`, `TVScrubThumbnailLoader.swift`, `TVPlayerFocusID.swift`, `DionysusTVUITests/Support/TVPlayerJourney.swift`
- Modify: `DionysusTV/Player/TVTransportOverlay.swift`, `TVPlayerOverlay.swift`, `DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift`, `DionysusTVUITests/PlayerJourneyTests.swift`, `DionysusTVUITests/AccessibilityAuditTests.swift`, `CLAUDE.md`
- Test: `DionysusTVTests/TVTransportLayoutTests.swift`, `DionysusTVTests/TVScrubThumbnailLoaderTests.swift`, `DionysusTVTests/TVPlayerFocusIDTests.swift`, `DionysusTVUITests/PlayerScrubJourneyTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: `TVTransportLayout.fraction(_:duration:)`, `.bufferedFraction(currentTime:bufferedSeconds:duration:)`, `.previewCenterX(fraction:trackWidth:previewWidth:)`, `.previewCaption(time:chapterName:)`, `.formatChipText(_:)`; `TVPlayerIcon.systemImage`, `.label`; `TVScrubThumbnailLoader(clock:fetch:)` with `image`, `request(_:)`, `reset()`; `TVPlayerFocusID.describe(_:context:) -> String`; `A11yID.TV.Player.icon(_:)`, `.scrubPreview`, `.remaining`, `.bufferedRange`, `.focus`; journey helpers `openPlayer(scenario:extraArguments:)`, `playerFocus(_:)`, `waitForPlayerFocus(_:_:timeout:)`, `elapsedSeconds(_:)`, `Self.seconds(_:)`.

- [ ] **Step 1: Write the failing unit tests**

`DionysusTVTests/TVTransportLayoutTests.swift`:

```swift
import XCTest
@testable import Dionysus

final class TVTransportLayoutTests: XCTestCase {
    func test_fraction_isClampedAndSafeWithoutADuration() {
        XCTAssertEqual(TVTransportLayout.fraction(2700, duration: 5400), 0.5)
        XCTAssertEqual(TVTransportLayout.fraction(6000, duration: 5400), 1)
        XCTAssertEqual(TVTransportLayout.fraction(10, duration: 0), 0)
    }

    func test_bufferedFraction_runsFromThePlayheadOn_andIsAbsentWithoutAReading() {
        XCTAssertEqual(TVTransportLayout.bufferedFraction(currentTime: 2700, bufferedSeconds: 540, duration: 5400) ?? 0, 0.6, accuracy: 0.0001)
        XCTAssertEqual(TVTransportLayout.bufferedFraction(currentTime: 5300, bufferedSeconds: 540, duration: 5400), 1)
        XCTAssertNil(TVTransportLayout.bufferedFraction(currentTime: 2700, bufferedSeconds: nil, duration: 5400))
        XCTAssertNil(TVTransportLayout.bufferedFraction(currentTime: 2700, bufferedSeconds: 30, duration: 0))
    }

    func test_previewCenter_staysOnTheTrack() {
        XCTAssertEqual(TVTransportLayout.previewCenterX(fraction: 0.5, trackWidth: 1760, previewWidth: 400), 880)
        XCTAssertEqual(TVTransportLayout.previewCenterX(fraction: 0, trackWidth: 1760, previewWidth: 400), 200)
        XCTAssertEqual(TVTransportLayout.previewCenterX(fraction: 1, trackWidth: 1760, previewWidth: 400), 1560)
    }

    func test_previewCaption_namesTheChapterWhenThereIsOne() {
        XCTAssertEqual(TVTransportLayout.previewCaption(time: 3135, chapterName: "The Radio Broadcast"), "52:15 · The Radio Broadcast")
        XCTAssertEqual(TVTransportLayout.previewCaption(time: 3135, chapterName: nil), "52:15")
    }

    /// The chip shows only what the engine reports as presented, and nothing
    /// for SDR, whose description is nil (Benjamin, 2026-10-06).
    func test_formatChip_onlyWhileTheEngineReportsHDR() {
        XCTAssertEqual(TVTransportLayout.formatChipText("Dolby Vision"), "DOLBY VISION")
        XCTAssertNil(TVTransportLayout.formatChipText(nil))
    }
}
```

`DionysusTVTests/TVScrubThumbnailLoaderTests.swift`:

```swift
import XCTest
@testable import Dionysus

@MainActor
final class TVScrubThumbnailLoaderTests: XCTestCase {
    func test_requests_areThrottled_andTheLastOneAlwaysFetches() async throws {
        var now: TimeInterval = 0
        var fetched: [Double] = []
        let loader = TVScrubThumbnailLoader(clock: { now }, fetch: { seconds in
            fetched.append(seconds)
            return nil
        })
        loader.request(10)
        now += 0.05
        loader.request(20)
        now += 0.02
        loader.request(30)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fetched, [10, 30], "The first at once, then the latest once the window passes")
    }
}
```

`DionysusTVTests/TVPlayerFocusIDTests.swift`:

```swift
import XCTest
@testable import Dionysus

final class TVPlayerFocusIDTests: XCTestCase {
    func test_describesTheScrubberAnIconOrNothing() {
        var state = TVPlayerInputState()
        let context = TVPlayerContext(duration: 600, chapterStarts: [0, 300])
        XCTAssertEqual(TVPlayerFocusID.describe(state, context: context), "scrubber")
        state.transportFocus = .icon(.chapters)
        XCTAssertEqual(TVPlayerFocusID.describe(state, context: context), "icon.chapters")
        state.chrome = .hidden
        state.transportFocus = .scrubber
        XCTAssertEqual(TVPlayerFocusID.describe(state, context: context), "none")
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Expected: build failure, "cannot find 'TVTransportLayout'".

- [ ] **Step 3: Write the pure helpers**

`DionysusTV/Player/TVTransportLayout.swift`:

```swift
import CoreGraphics
import Foundation

/// The transport's geometry and text, kept out of the view to be tested.
enum TVTransportLayout {
    static func fraction(_ time: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, time / duration))
    }

    /// The end of what is buffered, as a fraction of the title. `nil` where
    /// the route reports nothing (`PlaybackStats.bufferedSeconds` is
    /// native-route only), so no fill is drawn rather than a wrong one.
    static func bufferedFraction(currentTime: TimeInterval, bufferedSeconds: Double?, duration: TimeInterval) -> Double? {
        guard let bufferedSeconds, duration > 0 else { return nil }
        return fraction(currentTime + bufferedSeconds, duration: duration)
    }

    /// The preview's centre over the scrub head, kept on the track.
    static func previewCenterX(fraction: Double, trackWidth: CGFloat, previewWidth: CGFloat) -> CGFloat {
        let half = previewWidth / 2
        return min(max(trackWidth * fraction, half), max(trackWidth - half, half))
    }

    /// "52:15 · The Radio Broadcast" (prototype screen 12).
    static func previewCaption(time: TimeInterval, chapterName: String?) -> String {
        let clock = TVPlaybackTimeFormat.string(time)
        guard let chapterName else { return clock }
        return "\(clock) · \(chapterName)"
    }

    /// `PlayerViewModel.videoFormatDescription` is AetherEngine's presented
    /// format and `nil` for SDR, so the chip shows only while the engine has
    /// evidence the picture is HDR (Benjamin, 2026-10-06; CLAUDE.md, HDR).
    static func formatChipText(_ description: String?) -> String? {
        description?.uppercased()
    }
}
```

`DionysusTV/Player/TVPlayerFocusID.swift`:

```swift
/// The focused item as a fixed id. The overlay draws focus from the state
/// directly; this exists for the UI tests, which can't see focus in a
/// player that doesn't use the focus engine (`A11yID.TV.Player.focus`).
enum TVPlayerFocusID {
    static func describe(_ state: TVPlayerInputState, context: TVPlayerContext) -> String {
        if state.chrome == .transport, case .icon(let icon) = state.transportFocus { return "icon.\(icon.id)" }
        return state.chrome == .transport ? "scrubber" : "none"
    }
}
```

`DionysusTV/Player/TVScrubThumbnailLoader.swift`:

```swift
import CoreGraphics
import Foundation
import Observation

/// The scrub preview's trickplay still, fetched at most every 0.12s while
/// the preview moves, the throttle iOS's scrubber uses
/// (`PlayerControlsOverlay.scrubThumbnailThrottleInterval`). A throttle, not
/// a debounce: a long scan would otherwise never fetch until it stopped.
@Observable
@MainActor
final class TVScrubThumbnailLoader {
    static let throttle: TimeInterval = 0.12

    private(set) var image: CGImage?
    @ObservationIgnored private let clock: () -> TimeInterval
    @ObservationIgnored private let fetch: @MainActor (Double) async -> CGImage?
    @ObservationIgnored private var lastFetchAt: TimeInterval = -.infinity
    @ObservationIgnored private var pending: Double?
    @ObservationIgnored private var trailing: Task<Void, Never>?

    init(
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        fetch: @escaping @MainActor (Double) async -> CGImage?
    ) {
        self.clock = clock
        self.fetch = fetch
    }

    func request(_ seconds: Double) {
        pending = seconds
        if clock() - lastFetchAt >= Self.throttle {
            fire()
        } else if trailing == nil {
            trailing = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.throttle))
                guard let self, !Task.isCancelled else { return }
                self.trailing = nil
                self.fire()
            }
        }
    }

    func reset() {
        trailing?.cancel()
        trailing = nil
        pending = nil
        image = nil
    }

    private func fire() {
        guard let seconds = pending else { return }
        pending = nil
        lastFetchAt = clock()
        Task { [weak self, fetch] in
            if let image = await fetch(seconds) { self?.image = image }
        }
    }
}
```

Run the three unit test classes. Expected: pass. The fetch closure is `@MainActor`, so the test's closure can append to a local array; if Swift 6 still reports a data race on that capture, collect into a `@MainActor final class Box { var values: [Double] = [] }` instead.

- [ ] **Step 4: Add the identifiers**

In `AccessibilityIdentifiers.swift`, extend `A11yID.TV.Player`:

```swift
        enum Player {
            static let transport = "tv.player.transport"
            static let titleBlock = "tv.player.title"
            static let elapsed = "tv.player.elapsed"
            static let remaining = "tv.player.remaining"
            static let formatLabel = "tv.player.format"
            static let scrubPreview = "tv.player.scrubPreview"
            static let bufferedRange = "tv.player.buffered"
            /// Test-only: a 1pt element whose label is `TVPlayerFocusID`'s
            /// id for what has focus, since the player doesn't use the focus
            /// engine XCUITest's `hasFocus` reads.
            static let focus = "tv.player.focus"
            static func icon(_ id: String) -> String { "tv.player.icon.\(id)" }
        }
```

- [ ] **Step 5: Write the icon button and the preview**

`DionysusTV/Player/TVPlayerIconButton.swift`:

```swift
import SwiftUI

extension TVPlayerIcon {
    var systemImage: String {
        switch self {
        case .chapters: "list.bullet"
        case .audio: "waveform"
        case .subtitles: "captions.bubble"
        case .stats: "chart.bar.xaxis"
        }
    }

    var label: String {
        switch self {
        case .chapters: String(localized: "Chapters")
        case .audio: String(localized: "Audio")
        case .subtitles: String(localized: "Subtitles")
        case .stats: String(localized: "Stats for Nerds")
        }
    }
}

/// One of the transport's icons (prototype screen 12). Drawn focused from
/// the model's state: the player doesn't use the focus engine.
struct TVPlayerIconButton: View {
    let icon: TVPlayerIcon
    let isFocused: Bool
    /// Stats' panel is showing.
    var isOn = false

    var body: some View {
        Image(systemName: icon.systemImage)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(isFocused ? Color.black : Color.white)
            .frame(width: 84, height: 84)
            .background(Circle().fill(isFocused ? Color.white : Color.white.opacity(isOn ? 0.4 : 0.18)))
            .scaleEffect(isFocused ? 1.1 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 16, y: 8)
            .animation(.easeOut(duration: 0.15), value: isFocused)
            .accessibilityElement()
            .accessibilityLabel(icon.label)
            .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier(A11yID.TV.Player.icon(icon.id))
    }
}
```

`DionysusTV/Player/TVScrubPreview.swift`:

```swift
import SwiftUI

/// The trickplay still above the scrub head, with "52:15 · Chapter" under
/// it (prototype screen 12). Without trickplay only the caption shows.
struct TVScrubPreview: View {
    let image: CGImage?
    let showsFrame: Bool
    let caption: String

    static let size = CGSize(width: 400, height: 225)

    var body: some View {
        VStack(spacing: 12) {
            if showsFrame {
                ZStack {
                    RoundedRectangle(cornerRadius: 18).fill(Color.black)
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                }
                .frame(width: Self.size.width, height: Self.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white, lineWidth: 3))
                .shadow(color: .black.opacity(0.6), radius: 25, y: 20)
            }
            Text(caption)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.55), in: Capsule())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
        .accessibilityIdentifier(A11yID.TV.Player.scrubPreview)
    }
}
```

- [ ] **Step 6: Rewrite the transport's chrome**

In `TVTransportOverlay.swift`:

1. Delete `static let showsFormatChip` and its doc comment.
2. Add state and settings:

```swift
    @AppStorage(chaptersInScrubberEnabledStorageKey) private var chaptersInScrubber = chaptersInScrubberEnabledDefault
    @State private var bufferedSeconds: Double?
    @State private var thumbnails: TVScrubThumbnailLoader

    init(viewModel: PlayerViewModel, input: TVPlayerInput) {
        self.viewModel = viewModel
        self.input = input
        _thumbnails = State(initialValue: TVScrubThumbnailLoader(fetch: { [viewModel] seconds in
            await viewModel.scrubThumbnail(atSeconds: seconds)
        }))
    }

    private var state: TVPlayerInputState { input.state }
    private var showsChrome: Bool { state.chrome == .transport }
    /// The preview's time while scrubbing, else the playhead.
    private var shownTime: TimeInterval { state.scrub?.previewTime ?? viewModel.currentTime }
```

3. On `body`'s outer `ZStack`, after `.animation(...)`:

```swift
        // `PlaybackStats.bufferedSeconds` is polled, not pushed; once a
        // second is plenty for a fill nobody reads to the second.
        .task(id: showsChrome) {
            while showsChrome, !Task.isCancelled {
                bufferedSeconds = viewModel.stats.bufferedSeconds
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: state.scrub?.previewTime) { _, time in
            if let time { thumbnails.request(time) } else { thumbnails.reset() }
        }
```

4. Replace `bottomBar` and `scrubber` with:

```swift
    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 18) {
            iconRow
            scrubber
            HStack {
                Text(TVPlaybackTimeFormat.string(shownTime))
                    .monospacedDigit()
                    .accessibilityIdentifier(A11yID.TV.Player.elapsed)
                Spacer()
                if let chip = TVTransportLayout.formatChipText(viewModel.videoFormatDescription) {
                    Text(chip)
                        .font(.caption.bold())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.35), in: .capsule)
                        .accessibilityIdentifier(A11yID.TV.Player.formatLabel)
                }
                Spacer()
                Text("\u{2212}" + TVPlaybackTimeFormat.string(max(0, viewModel.duration - shownTime)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(A11yID.TV.Player.remaining)
            }
            .font(.callout.weight(.semibold))
        }
    }

    private var iconRow: some View {
        HStack(spacing: 18) {
            Spacer()
            ForEach(input.context().availableIcons, id: \.self) { icon in
                TVPlayerIconButton(
                    icon: icon,
                    isFocused: state.transportFocus == .icon(icon),
                    isOn: icon == .stats && state.isStatsOn
                )
            }
        }
        .frame(height: 96)
    }

    private var scrubber: some View {
        GeometryReader { geo in
            let duration = viewModel.duration
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                if let buffered = TVTransportLayout.bufferedFraction(
                    currentTime: viewModel.currentTime, bufferedSeconds: bufferedSeconds, duration: duration
                ) {
                    Capsule().fill(.white.opacity(0.45))
                        .frame(width: width * buffered)
                        .accessibilityElement()
                        .accessibilityLabel(Text("Buffered"))
                        .accessibilityIdentifier(A11yID.TV.Player.bufferedRange)
                }
                Capsule().fill(.white)
                    .frame(width: width * TVTransportLayout.fraction(viewModel.currentTime, duration: duration))
                if chaptersInScrubber, duration > 0 {
                    ForEach(viewModel.chapters.filter { $0.startSeconds > 0 }) { chapter in
                        Rectangle()
                            .fill(.black.opacity(0.75))
                            .frame(width: 5)
                            .offset(x: width * chapter.startSeconds / duration)
                    }
                }
                if let scrub = state.scrub {
                    let fraction = TVTransportLayout.fraction(scrub.previewTime, duration: duration)
                    Circle()
                        .fill(.white)
                        .frame(width: 28, height: 28)
                        .shadow(color: .black.opacity(0.5), radius: 8)
                        .offset(x: width * fraction - 14)
                    TVScrubPreview(
                        image: thumbnails.image,
                        showsFrame: viewModel.supportsScrubThumbnails,
                        caption: TVTransportLayout.previewCaption(
                            time: scrub.previewTime, chapterName: viewModel.chapters.chapter(at: scrub.previewTime)?.name
                        )
                    )
                    .fixedSize()
                    .position(
                        x: TVTransportLayout.previewCenterX(fraction: fraction, trackWidth: width, previewWidth: TVScrubPreview.size.width),
                        y: -(TVScrubPreview.size.height / 2 + 150)
                    )
                }
            }
        }
        .frame(height: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Playback position"))
        .accessibilityValue(Text(TVPlaybackTimeFormat.string(shownTime)))
        .accessibilityIdentifier(A11yID.TV.Player.transport)
    }
```

(`.contain`, not `.ignore`: the preview and the buffered fill are found inside it.)

5. Add the test marker to `TVPlayerOverlay`'s `ZStack`, last:

```swift
            #if DEBUG
            if UITestConfiguration.isActive {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel(TVPlayerFocusID.describe(input.state, context: input.context()))
                    .accessibilityIdentifier(A11yID.TV.Player.focus)
            }
            #endif
```

and to `AccessibilityAuditTests.isKnownAcceptable`, before the final `return false`:

```swift
        // The player's test-only focus marker (`A11yID.TV.Player.focus`):
        // its label is a fixed id, not prose, and it exists only under the
        // harness.
        if element.identifier == A11yID.TV.Player.focus {
            return true
        }
```

- [ ] **Step 7: Move the journey helpers and write the journeys**

`DionysusTVUITests/Support/TVPlayerJourney.swift`:

```swift
import XCTest

extension TVUITestCase {
    /// Launches signed in, opens the focused first tile's detail page (the
    /// part-watched movie, resuming at 20:00) and plays it.
    @discardableResult
    func openPlayer(scenario: String = "standard", extraArguments: [String]) -> XCUIApplication {
        let app = launch(scenario: scenario, seedSession: true, extraArguments: extraArguments)
        waitForHomeThenFirstTile(app)
        openDetailFromFocusedTile(app)
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10))
        return app
    }

    /// `TVPlayerFocusID`'s id for what has focus in the player.
    func playerFocus(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any)[A11yID.TV.Player.focus].label
    }

    func waitForPlayerFocus(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 5) -> Bool {
        let focused = poll(timeout: timeout) { playerFocus(app) == id }
        if !focused { attachTree() }
        return focused
    }

    func elapsedSeconds(_ app: XCUIApplication) -> Double? {
        Self.seconds(app.staticTexts[A11yID.TV.Player.elapsed].label)
    }

    /// "1:02:03" or "12:34" in seconds.
    nonisolated static func seconds(_ label: String) -> Double? {
        let parts = label.split(separator: ":").compactMap { Double($0) }
        guard parts.count >= 2 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}
```

In `PlayerJourneyTests.swift`, delete its private `openPlayer` and `seconds` (now shared) and replace `test_transport_showsTitleAndTimes_withoutFormatChip` with:

```swift
    /// The title block sits top-left, and the scrubber and times are on
    /// screen. The fake engine reports a Dolby Vision picture, so the HDR
    /// chip shows (it shows only while the engine reports HDR).
    func test_transport_showsTitleTimesAndTheHDRChip() {
        let app = openPlayer(extraArguments: ["-UITestDisableControlAutoHide", "YES"])
        let title = app.descendants(matching: .any)[A11yID.TV.Player.titleBlock]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(title.frame.minY, 70, "The title block sits at the top of the safe area")
        XCTAssertLessThanOrEqual(title.frame.minX, 90, "…and at its left edge")
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.remaining].exists)
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.transport].exists)
        let chip = app.staticTexts[A11yID.TV.Player.formatLabel]
        XCTAssertTrue(chip.exists)
        XCTAssertTrue(chip.label.hasPrefix("DOLBY VISION"))
    }
```

`DionysusTVUITests/PlayerScrubJourneyTests.swift`:

```swift
import XCTest

final class PlayerScrubJourneyTests: TVUITestCase {
    private let keepTransportUp = ["-UITestDisableControlAutoHide", "YES"]

    /// The fixture movie has chapters and the fake engine two audio and three
    /// subtitle tracks, so three icons show; Stats waits for its setting.
    func test_icons_matchTheTitle_andUpLeftRightMenuMoveAmongThem() {
        let app = openPlayer(extraArguments: keepTransportUp)
        for id in ["chapters", "audio", "subtitles"] {
            XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.icon(id)].exists, "\(id) icon")
        }
        XCTAssertTrue(waitForPlayerFocus(app, "scrubber"))
        press(.up)
        XCTAssertTrue(waitForPlayerFocus(app, "icon.chapters"))
        press(.right)
        XCTAssertTrue(waitForPlayerFocus(app, "icon.audio"))
        press(.menu)
        XCTAssertTrue(waitForPlayerFocus(app, "scrubber"), "Menu takes focus back to the scrubber")
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].exists, "…without closing the player")
    }

    func test_pausedRightThrice_previewsThirtySecondsOn_andSelectGoesThere() throws {
        let app = openPlayer(extraArguments: keepTransportUp)
        press(.playPause)
        Thread.sleep(forTimeInterval: 1)
        let pausedAt = try XCTUnwrap(elapsedSeconds(app))
        press(.right, times: 3)
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.scrubPreview].waitForExistence(timeout: 3))
        XCTAssertTrue(poll(timeout: 3) { abs((self.elapsedSeconds(app) ?? 0) - (pausedAt + 30)) <= 1 }, "The preview reads 30s on, still paused")
        press(.select)
        XCTAssertTrue(poll(timeout: 3) { !app.descendants(matching: .any)[A11yID.TV.Player.scrubPreview].exists })
        XCTAssertTrue(poll(timeout: 5) { (self.elapsedSeconds(app) ?? 0) >= pausedAt + 31 }, "Select seeks there and plays")
    }

    func test_holdingRight_pausesAndScans_andMenuReturnsToWherePlaybackWas() throws {
        let app = openPlayer(extraArguments: keepTransportUp)
        let before = try XCTUnwrap(elapsedSeconds(app))
        XCUIRemote.shared.press(.right, forDuration: 3)
        // 0.4s to become a hold, then 8x: at least 15s on by release.
        XCTAssertGreaterThan(elapsedSeconds(app) ?? 0, before + 15)
        let preview = app.descendants(matching: .any)[A11yID.TV.Player.scrubPreview]
        XCTAssertTrue(preview.exists, "Releasing keeps the scrub open")
        press(.menu)
        XCTAssertTrue(poll(timeout: 3) { !preview.exists })
        let resumed = try XCTUnwrap(elapsedSeconds(app))
        XCTAssertLessThan(abs(resumed - before), 6, "Back where playback was")
        XCTAssertTrue(poll(timeout: 5) { (self.elapsedSeconds(app) ?? 0) > resumed + 1 }, "…and playing again")
    }
}
```

Add one audit to `AccessibilityAuditTests`:

```swift
    func test_playerTransport() throws {
        let app = openPlayer(extraArguments: ["-UITestDisableControlAutoHide", "YES"])
        try audit(app)
    }
```

- [ ] **Step 8: Run the new journeys and the audit**

Run: tvOS UI `-only-testing:DionysusTVUITests/PlayerScrubJourneyTests -only-testing:DionysusTVUITests/PlayerJourneyTests -only-testing:DionysusTVUITests/AccessibilityAuditTests/test_playerTransport`. Expected: pass. If the audit flags the icon buttons as unlabeled, check each has `.accessibilityElement()` before its label.

- [ ] **Step 9: Check it in the Simulator**

Build and run `DionysusTV` on the booted Apple TV Simulator (re-point it to the LAN server as Ben first; memory `simulator-automation`). Play a movie from the LAN server and check, with idb HID keys (up 82, down 81, left 80, right 79, Select 40, Menu 41): the icon row sits right-aligned above the scrubber; Up focuses Chapters with a white circle; holding Right (`idb ui key --duration 3 <udid> 79`) pauses and the preview runs with a trickplay still (titles on the LAN server have trickplay); Menu resumes; the chapter ticks show and go with Profile → Chapters in Scrubber off. Screenshot each for Benjamin.

- [ ] **Step 10: Update CLAUDE.md**

In CLAUDE.md's tvOS section, replace the sentences from "AVKit's chrome is hidden and the transport is ours" to "used up the title's time on screen." with:

```markdown
AVKit's chrome is hidden and the transport is ours (`TVTransportOverlay`),
inset by the safe area alone. **The player doesn't use the focus engine**
(Benjamin, 2026-10-06, as Sodalite does): the host's recognizers take every
press and touch-surface swipe and hand them to `TVPlayerInputModel`, a pure
reducer over `TVPlayerInputState` that returns commands for
`TVPlayerCommandRunner`, the only code that acts on `PlayerViewModel`. The
overlay takes no interaction and draws focus from the state, so XCUITest
reads it from a test-only marker (`A11yID.TV.Player.focus`), not `hasFocus`.
What isn't guessable:
- **Left/Right report down and up** (a long-press recognizer with no
  minimum), so the model tells a press (a 10s skip, acted on release) from a
  hold past 0.4s (pause and scan). A swipe pauses and scrubs once
  `TVSwipeGate` has seen 40pt at 200pt/s; a resting thumb never pauses.
- **A scrub moves a preview, never playback**, until Select or Play/Pause
  commits; Menu cancels and resumes if the scrub paused. A scan runs the
  preview at 8×, stepping every 2s held to 64×, rather than AVPlayer
  fast-forward, which AetherEngine offers on the native route only.
- **The transport fades 4s after the last press**, never while paused,
  loading or scrubbing; the fade is timed in the reducer from playback
  starting, so a slow load doesn't use up the title's time on screen.
- **The HDR chip shows only while the engine reports HDR**
  (`videoFormatDescription`, nil for SDR); see the HDR paragraph above.
```

Also in the HDR paragraph, delete the sentence "For the same reason the player's format chip stays hidden on tvOS (`TVTransportOverlay.showsFormatChip`)." and replace it with "The player's format chip therefore shows only while the engine reports HDR, and says nothing rather than SDR."

- [ ] **Step 11: Run the suites, sync strings, get sign-off, commit and open PR 1**

Open the project in Xcode and build once (Cmd+B) to extract "Chapters", "Audio", "Subtitles", "Stats for Nerds", "Buffered". Run tvOS unit, tvOS UI, iOS unit, iOS smoke (one after another; `PlayerViewModel.swift` changed). Show Benjamin the diff and the screenshots; after his sign-off:

```bash
git add docs/superpowers/specs/2026-10-06-tvos-player-features-design.md \
  docs/superpowers/specs/2026-09-29-tvos-app-design.md \
  docs/superpowers/plans/2026-10-06-tvos-player-features.md \
  DionysusTV/Player DionysusTVTests DionysusTVUITests \
  DionysusPlayer/Features/Player/PlayerViewModel.swift \
  DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift \
  DionysusPlayer/Resources/Localizable.xcstrings CLAUDE.md
git status --short   # the two version files must still show as unstaged
git commit -m "Drive the Apple TV player from its own input model, with scrubbing, scanning and the transport's icons

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -u origin feature/tvos-player-transport
gh pr create --base develop --title "tvOS M4 PR 1: input model, scrubbing and scanning, transport v2" \
  --body-file "$SCRATCH/pr1-body.md"
```

Write `pr1-body.md` in the session's scratchpad (`$SCRATCH`) first: a short summary of what changed, the unit and UI tests added, a note that the M4 spec and plan ride along, and the "🤖 Generated with [Claude Code](https://claude.com/claude-code)" line last. No session URL. Merge with `gh pr merge --merge` once checks pass and Benjamin says so.

---

## PR 2: `feature/tvos-player-subtitles`

### Task 5: Subtitles on the Apple TV

**Files:**
- Create: `DionysusPlayer/Features/Player/BottomChromeTopKey.swift`, `DionysusPlayerTests/Features/Player/SubtitleOverlayLayoutTests.swift`
- Modify: `DionysusPlayer/Features/Player/SubtitleOverlayView.swift`, `DionysusPlayer/Features/Player/PlayerControlsOverlay.swift` (delete `BottomChromeTopKey`), `DionysusTV/Player/TVPlayerOverlay.swift`, `DionysusTV/Player/TVTransportOverlay.swift`, `project.yml`, `CLAUDE.md`

**Interfaces:**
- Consumes: Task 4's overlay.
- Produces: `SubtitleOverlayMetrics` (`.phone`, `.tv`), `SubtitleOverlayView(viewModel:zoomMode:controlsVisible:controlsTop:metrics:)`, `SubtitleOverlayView.bottomInset(controlsVisible:controlsTop:overlayMaxY:metrics:)`, `BottomChromeTopKey` in a shared file.

- [ ] **Step 1: Branch**

```bash
git switch develop && git pull && git switch -c feature/tvos-player-subtitles
```

- [ ] **Step 2: Write the failing test**

`DionysusPlayerTests/Features/Player/SubtitleOverlayLayoutTests.swift`:

```swift
import XCTest
@testable import Dionysus

final class SubtitleOverlayLayoutTests: XCTestCase {
    /// The phone's values are the ones the overlay always had.
    func test_phoneMetrics_areUnchanged() {
        let phone = SubtitleOverlayMetrics.phone
        XCTAssertEqual(phone.fontSize, 20)
        XCTAssertEqual(phone.horizontalInset, 24)
        XCTAssertEqual(phone.restingBottomInset, 28)
        XCTAssertEqual(phone.controlsGap, 8)
    }

    func test_bottomInset_clearsTheChrome_andRestsWithoutIt() {
        let tv = SubtitleOverlayMetrics.tv
        XCTAssertEqual(
            SubtitleOverlayView.bottomInset(controlsVisible: true, controlsTop: 860, overlayMaxY: 1080, metrics: tv),
            1080 - 860 + tv.controlsGap
        )
        XCTAssertEqual(
            SubtitleOverlayView.bottomInset(controlsVisible: false, controlsTop: 860, overlayMaxY: 1080, metrics: tv),
            tv.restingBottomInset
        )
        XCTAssertEqual(
            SubtitleOverlayView.bottomInset(controlsVisible: true, controlsTop: .infinity, overlayMaxY: 1080, metrics: tv),
            tv.restingBottomInset, "No chrome reported, nothing to clear"
        )
    }
}
```

Add `"Features/Player/SubtitleOverlayLayoutTests.swift"` to `DionysusTVTests`' includes in `project.yml`, and to `DionysusTV`'s Features includes add `"Player/SubtitleOverlayView.swift"` and `"Player/BottomChromeTopKey.swift"`. Run `xcodegen generate`. Run the class on iOS unit. Expected: build failure, "cannot find 'SubtitleOverlayMetrics'".

- [ ] **Step 3: Move `BottomChromeTopKey`**

Cut `BottomChromeTopKey` and its doc comment from the end of `PlayerControlsOverlay.swift` into `DionysusPlayer/Features/Player/BottomChromeTopKey.swift` (add `import SwiftUI`), unchanged. Its doc comment's "the scrubber row plus the chapter/format row beneath it" gains: "On the Apple TV, the transport's bottom bar, or the raised scrubber while the panel is open."

- [ ] **Step 4: Give the overlay metrics**

In `SubtitleOverlayView.swift`, add above the struct:

```swift
/// The sizes that differ between a phone at arm's length and a TV across the
/// room. `.phone` is what this overlay always drew.
struct SubtitleOverlayMetrics {
    var fontSize: CGFloat
    var horizontalInset: CGFloat
    /// Bottom clearance once the chrome has gone.
    var restingBottomInset: CGFloat
    /// Breathing room between a subtitle and the chrome it clears.
    var controlsGap: CGFloat
    var horizontalPadding: CGFloat
    var verticalPadding: CGFloat
    var cornerRadius: CGFloat

    static let phone = SubtitleOverlayMetrics(
        fontSize: 20, horizontalInset: 24, restingBottomInset: 28, controlsGap: 8,
        horizontalPadding: 10, verticalPadding: 5, cornerRadius: 6
    )

    /// Sized for a 1920×1080pt screen viewed from a sofa; the font size is
    /// set against Infuse on the same title in Task 11. The resting inset
    /// keeps a cue inside the title-safe area.
    static let tv = SubtitleOverlayMetrics(
        fontSize: 46, horizontalInset: 80, restingBottomInset: 60, controlsGap: 20,
        horizontalPadding: 22, verticalPadding: 10, cornerRadius: 12
    )
}
```

In the struct: add `var metrics: SubtitleOverlayMetrics = .phone` after `controlsTop`; delete the static `controlsGap`, `restingBottomInset` and `horizontalInset`; replace every `Self.horizontalInset` with `metrics.horizontalInset`; in `textCueContent` use `metrics.fontSize`, `metrics.horizontalPadding`, `metrics.verticalPadding` and `metrics.cornerRadius` in place of 20, 10, 5 and 6. Replace the instance `bottomInset(overlayMaxY:)` with a static the call site passes its values to:

```swift
    /// Clearance at the bottom of the overlay, given where this overlay's
    /// own bottom edge sits globally. (The doc comment that was here stays,
    /// unchanged, above this.)
    static func bottomInset(
        controlsVisible: Bool, controlsTop: CGFloat, overlayMaxY: CGFloat, metrics: SubtitleOverlayMetrics
    ) -> CGFloat {
        guard controlsVisible, controlsTop.isFinite else { return metrics.restingBottomInset }
        return max(overlayMaxY - controlsTop + metrics.controlsGap, metrics.restingBottomInset)
    }
```

and in `body`: `let bottomInset = Self.bottomInset(controlsVisible: controlsVisible, controlsTop: controlsTop, overlayMaxY: proxy.frame(in: .global).maxY, metrics: metrics)`.

Run the class on iOS unit and tvOS unit. Expected: pass.

- [ ] **Step 5: Draw subtitles on the Apple TV**

`TVPlayerOverlay.swift` becomes:

```swift
struct TVPlayerOverlay: View {
    let viewModel: PlayerViewModel
    let input: TVPlayerInput

    /// The top of whatever bottom chrome is up (`BottomChromeTopKey`), so
    /// cues sit above it: the transport, or the raised scrubber while the
    /// panel is open.
    @State private var chromeTop: CGFloat = .infinity

    var body: some View {
        ZStack {
            // Ignores the safe area to lie over the full-bleed picture; libass
            // reads the window's insets itself (CLAUDE.md, Subtitles).
            SubtitleOverlayView(
                viewModel: viewModel, zoomMode: .fit,
                controlsVisible: input.state.chrome == .transport,
                controlsTop: chromeTop, metrics: .tv
            )
            .ignoresSafeArea()

            TVTransportOverlay(viewModel: viewModel, input: input)

            // (the DEBUG focus marker from Task 4 stays here, last)
        }
        .onPreferenceChange(BottomChromeTopKey.self) { top in
            MainActor.assumeIsolated { chromeTop = top }
        }
    }
}
```

In `TVTransportOverlay.bottomBar`, after its `VStack`, report its top:

```swift
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: BottomChromeTopKey.self, value: proxy.frame(in: .global).minY)
            }
        )
```

The bar is only built while the chrome shows, so with the chrome gone the key falls back to `.infinity` and cues rest.

- [ ] **Step 6: Check in the Simulator for AVKit drawing its own copy, and for fonts**

The UI-test fake has no AVPlayer, so this needs real playback. On the booted Apple TV Simulator, signed in to the LAN server as Ben, play a title with a default SubRip track and one with an authored ASS track (memory `track-selection-test-assets`: Deadpool has embedded ASS fonts). Pick the track by setting it on iOS or the web client first, since the panel arrives in PR 3, or by leaving a default track on. Check:

1. Each SubRip line appears **once**, in our style (dark rounded box, semibold white). A second, differently styled copy is AVKit drawing the rendition. If it appears: add to `TVPlayerHostController.apply(avPlayer:hostEngine:)`, after `player = avPlayer`, the line `(engine as? AetherPlaybackEngine)?.setNativeSubtitleRendering(false)`, rerun, and note it in CLAUDE.md's player paragraph ("AVKit draws a selected rendition itself under `AVPlayerViewController`, so the host switches native rendering off on every new `AVPlayer`").
2. Deadpool's styled lines render in their embedded font (compare with iOS on the same scene). If they fall back to a system font, read the console for `CTFontManagerRegisterFontsForURL` errors and report to Benjamin before going further.
3. With the transport up, cues sit above it; when it fades, they settle near the bottom.

Screenshot each.

- [ ] **Step 7: Update CLAUDE.md**

Add to the tvOS player paragraph:

```markdown
**Subtitles are iOS's `SubtitleOverlayView`, compiled into the TV target**
with `SubtitleOverlayMetrics.tv` (46pt text, title-safe resting inset), the
whole overlay including libass. Cues clear whatever bottom chrome is up
through `BottomChromeTopKey`, which the TV transport reports too.
```

- [ ] **Step 8: Suites, sign-off, commit, PR 2**

Run tvOS unit, tvOS UI, iOS unit, iOS smoke. After Benjamin's sign-off, commit `project.yml`, the two new files, the two changed shared files, the TV overlay files and CLAUDE.md (never the version files), push, open "tvOS M4 PR 2: subtitles on the Apple TV" and merge with `--merge` when checks pass.

---

## PR 3: `feature/tvos-player-panel`

### Task 6: The panel in the input model

**Files:**
- Create: `DionysusTV/Player/TVPlayerInputModel+Panel.swift`
- Modify: `DionysusTV/Player/TVPlayerInputModel.swift`, `DionysusTV/Player/TVPlayerInputModel+Scrub.swift`, `DionysusTV/Player/TVPlayerFocusID.swift`
- Test: `DionysusTVTests/TVPlayerPanelTests.swift`

**Interfaces:**
- Consumes: Tasks 1–2.
- Produces: `TVPlayerInputState.Panel { tab, focus, lastInputAt }` with `Focus.tabs` / `.content(Int)`, `TVPlayerInputState.panel`, `TVPlayerTiming.panelTimeout`, `TVPanelTab.isList`, `TVPlayerInputModel.reducePanel(_:_:context:)`, `.availableTabs(_:)`, `.contentCount(_:_:)`, `.defaultIndex(_:_:)`, `.openPanel(_:focus:_:now:)`.

- [ ] **Step 1: Branch**

```bash
git switch develop && git pull && git switch -c feature/tvos-player-panel
```

- [ ] **Step 2: Write the failing tests**

`DionysusTVTests/TVPlayerPanelTests.swift`:

```swift
import XCTest
@testable import Dionysus

final class TVPlayerPanelTests: XCTestCase, TVPlayerInputModelHarness {
    var state = TVPlayerInputState()
    var context = TVPlayerPanelTests.standardContext
    var now: TimeInterval = 1000

    func test_down_opensInfoOnTheTabs_andDownAgainLandsOnRestart() {
        send(.down)
        XCTAssertEqual(state.panel?.tab, .info)
        XCTAssertEqual(state.panel?.focus, .tabs)
        send(.down)
        XCTAssertEqual(state.panel?.focus, .content(0))
        XCTAssertEqual(send(.select), [.seek(0), .play], "Restart")
        XCTAssertNil(state.panel)
    }

    func test_down_fromHidden_opensThePanelToo() {
        state.chrome = .hidden
        send(.down)
        XCTAssertEqual(state.panel?.tab, .info)
        XCTAssertEqual(state.chrome, .transport)
    }

    func test_tabsFollowFocus_withoutWrapping() {
        send(.down)
        press(.right)
        XCTAssertEqual(state.panel?.tab, .chapters)
        press(.right)
        press(.right)
        press(.right)
        XCTAssertEqual(state.panel?.tab, .subtitles)
        press(.left)
        XCTAssertEqual(state.panel?.tab, .audio)
    }

    func test_chaptersTab_isAbsentWithoutChapters() {
        context.chapterStarts = []
        XCTAssertEqual(TVPlayerInputModel.availableTabs(context), [.info, .audio, .subtitles])
        send(.down)
        press(.right)
        XCTAssertEqual(state.panel?.tab, .audio)
    }

    func test_anIcon_opensItsTab_onTheChosenRow() {
        context.selectedSubtitleIndex = 1
        send(.up)
        press(.right)
        press(.right)
        send(.select)
        XCTAssertEqual(state.panel?.tab, .subtitles)
        XCTAssertEqual(state.panel?.focus, .content(2), "Off is row 0, so the second track is row 2")
    }

    func test_chapters_landOnTheCurrentChapter_moveSideways_andSelectJumpsAndPlays() {
        context.currentTime = 3000
        send(.up)
        send(.select)
        XCTAssertEqual(state.panel?.focus, .content(2))
        press(.right)
        press(.right)
        XCTAssertEqual(state.panel?.focus, .content(3), "Stops at the last")
        XCTAssertEqual(send(.select), [.seek(4050), .play])
        XCTAssertNil(state.panel)
    }

    func test_audio_selectKeepsThePanelOpen() {
        send(.up)
        press(.right)
        send(.select)
        send(.down)
        XCTAssertEqual(state.panel?.focus, .content(1))
        XCTAssertEqual(send(.select), [.selectAudio(id: 1)])
        XCTAssertNotNil(state.panel)
    }

    func test_subtitles_rowZeroIsOff() {
        send(.down)
        press(.right)
        press(.right)
        press(.right)
        send(.down)
        XCTAssertEqual(send(.select), [.selectSubtitle(id: nil)])
        send(.down)
        XCTAssertEqual(send(.select), [.selectSubtitle(id: 0)])
    }

    func test_up_fromTheFirstRow_goesToTheTabs_andUpAgainCloses() {
        send(.down)
        press(.right)
        press(.right)
        send(.down)
        send(.up)
        XCTAssertEqual(state.panel?.focus, .tabs)
        send(.up)
        XCTAssertNil(state.panel)
        XCTAssertEqual(state.transportFocus, .scrubber)
    }

    func test_menu_closesFromAnywhere() {
        send(.down)
        send(.down)
        XCTAssertEqual(send(.menu), [])
        XCTAssertNil(state.panel)
        XCTAssertEqual(send(.menu), [.close], "A second Menu closes the player")
    }

    func test_panel_closesAfterTenQuietSeconds_andTheTransportFadesLater() {
        send(.down)
        tick(for: 9.8)
        XCTAssertNotNil(state.panel)
        tick(for: 0.4)
        XCTAssertNil(state.panel)
        XCTAssertEqual(state.chrome, .transport)
        tick(for: 4.2)
        XCTAssertEqual(state.chrome, .hidden)
    }

    func test_swipesAndHoldsInThePanel_neverScrubBehindIt() {
        send(.down)
        XCTAssertEqual(send(.swipeBegan), [])
        send(.arrowDown(.right))
        XCTAssertEqual(tick(for: 1), [])
        XCTAssertNil(state.scrub)
        XCTAssertEqual(TVPlayerInputModel.swipeScrubs(state, context: context), false)
    }

    func test_playPause_stillWorksWithThePanelOpen() {
        send(.down)
        XCTAssertEqual(send(.playPause), [.togglePlayPause])
        XCTAssertNotNil(state.panel)
    }

    /// Review Focus 3: a list that shrinks under the panel never leaves
    /// focus past its end, so a stale row can't pick the wrong track.
    func test_aShrinkingTrackList_clampsTheFocusedRow() {
        context.subtitleTrackIDs = [0, 1, 2]
        send(.down)
        press(.right)
        press(.right)
        press(.right)
        send(.down)
        send(.down)
        send(.down)
        send(.down)
        XCTAssertEqual(state.panel?.focus, .content(3))
        context.subtitleTrackIDs = [5]
        tick(for: 0.1)
        XCTAssertEqual(state.panel?.focus, .content(1))
        XCTAssertEqual(send(.select), [.selectSubtitle(id: 5)])
    }
}
```

Run. Expected: build failure, "value of type 'TVPlayerInputState' has no member 'panel'".

- [ ] **Step 3: Add the panel to the state and the clock**

In `TVPlayerInputState`, add after `Scrub`:

```swift
    struct Panel: Equatable {
        enum Focus: Equatable { case tabs, content(Int) }
        var tab: TVPanelTab
        var focus: Focus
        var lastInputAt: TimeInterval
    }
```

and `var panel: Panel?` after `scrub`. In `TVPlayerTiming` add `static let panelTimeout: TimeInterval = 10`. Add to `TVPanelTab`:

```swift
    /// Audio and Subtitles are vertical lists; Chapters is a rail.
    var isList: Bool { self == .audio || self == .subtitles }
```

In `reduce`, after `state.lastInputAt = now`, add `state.panel?.lastInputAt = now`.

`dispatch` becomes:

```swift
        if let commands = reduceScrub(intent, &state, context: context, now: now) { return commands }
        if let commands = reducePanel(intent, &state, context: context) { return commands }
        return reduceTransport(intent, &state, context: context, now: now)
```

In `reduceTransport`, `.down` becomes:

```swift
        case .down:
            if case .icon = state.transportFocus {
                state.transportFocus = .scrubber
            } else {
                openPanel(.info, focus: .tabs, &state, now: now)
            }
            return []
```

and `activate`'s `case .chapters, .audio, .subtitles: break` becomes:

```swift
        case .chapters: openPanel(.chapters, focus: .content(defaultIndex(.chapters, context)), &state, now: now)
        case .audio: openPanel(.audio, focus: .content(defaultIndex(.audio, context)), &state, now: now)
        case .subtitles: openPanel(.subtitles, focus: .content(defaultIndex(.subtitles, context)), &state, now: now)
```

In `tick`, after the icon fallback:

```swift
        if var panel = state.panel {
            if now - panel.lastInputAt >= TVPlayerTiming.panelTimeout {
                state.panel = nil
                state.lastInputAt = now
            } else if case .content(let index) = panel.focus {
                let count = contentCount(panel.tab, context)
                panel.focus = count == 0 ? .tabs : .content(min(index, count - 1))
                state.panel = panel
            }
        }
```

`chromeMayFade` becomes `context.playback == .playing && !context.autoHideDisabled && state.scrub == nil && state.panel == nil`.

In `+Scrub.swift`, `scrubCanOpen` becomes:

```swift
        context.duration > 0 && state.transportFocus == .scrubber && state.panel == nil
```

- [ ] **Step 4: Write the panel reducer**

`DionysusTV/Player/TVPlayerInputModel+Panel.swift`:

```swift
import Foundation

extension TVPlayerInputModel {
    /// The swipe-down panel. `nil` when it isn't open, or for Play/Pause,
    /// which the transport handles with the panel up.
    static func reducePanel(
        _ intent: Intent, _ state: inout TVPlayerInputState, context: TVPlayerContext
    ) -> [TVPlayerCommand]? {
        guard var panel = state.panel else { return nil }
        let count = contentCount(panel.tab, context)
        switch (intent, panel.focus) {
        case (.menu, _):
            state.panel = nil
            return []
        case (.playPause, _):
            return nil
        case (.up, .tabs):
            state.panel = nil
            state.transportFocus = .scrubber
            return []
        case (.down, .tabs), (.select, .tabs):
            if count > 0 { panel.focus = .content(defaultIndex(panel.tab, context)) }
        case (.arrow(let direction), .tabs):
            panel.tab = neighbour(of: panel.tab, direction, in: availableTabs(context))
        case (.up, .content(let index)):
            panel.focus = panel.tab.isList && index > 0 ? .content(index - 1) : .tabs
        case (.down, .content(let index)):
            if panel.tab.isList, index + 1 < count { panel.focus = .content(index + 1) }
        case (.arrow(let direction), .content(let index)):
            if panel.tab == .chapters, count > 0 {
                panel.focus = .content(min(max(index + (direction == .left ? -1 : 1), 0), count - 1))
            }
        case (.select, .content(let index)):
            let (commands, closes) = activateRow(panel.tab, index, context)
            state.panel = closes ? nil : panel
            return commands
        case (.holdBegan, _), (.holdEnded, _), (.swipeBegan, _), (.swipeMoved, _), (.swipeEnded, _):
            break
        }
        state.panel = panel
        return []
    }

    static func openPanel(
        _ tab: TVPanelTab, focus: TVPlayerInputState.Panel.Focus, _ state: inout TVPlayerInputState, now: TimeInterval
    ) {
        state.chrome = .transport
        state.transportFocus = .scrubber
        state.panel = .init(tab: tab, focus: focus, lastInputAt: now)
    }

    /// Chapters only when the title has them.
    static func availableTabs(_ context: TVPlayerContext) -> [TVPanelTab] {
        TVPanelTab.allCases.filter { $0 != .chapters || !context.chapterStarts.isEmpty }
    }

    static func neighbour(of tab: TVPanelTab, _ direction: TVDirection, in tabs: [TVPanelTab]) -> TVPanelTab {
        guard let index = tabs.firstIndex(of: tab) else { return tabs.first ?? tab }
        let next = index + (direction == .left ? -1 : 1)
        return tabs.indices.contains(next) ? tabs[next] : tab
    }

    static func contentCount(_ tab: TVPanelTab, _ context: TVPlayerContext) -> Int {
        switch tab {
        case .info: 1
        case .chapters: context.chapterStarts.count
        case .audio: context.audioTrackIDs.count
        case .subtitles: context.subtitleTrackIDs.count + 1
        }
    }

    /// Where Down lands: Restart, the current chapter, the chosen track (Off
    /// is Subtitles' row 0).
    static func defaultIndex(_ tab: TVPanelTab, _ context: TVPlayerContext) -> Int {
        switch tab {
        case .info: 0
        case .chapters: context.chapterStarts.lastIndex { $0 <= context.currentTime } ?? 0
        case .audio: context.selectedAudioIndex ?? 0
        case .subtitles: context.selectedSubtitleIndex.map { $0 + 1 } ?? 0
        }
    }

    /// A row's action, and whether it closes the panel: Restart and a
    /// chapter play from there and close; a track switch stays, so the
    /// change can be seen or heard.
    static func activateRow(
        _ tab: TVPanelTab, _ index: Int, _ context: TVPlayerContext
    ) -> (commands: [TVPlayerCommand], closesPanel: Bool) {
        switch tab {
        case .info:
            return ([.seek(0), .play], true)
        case .chapters:
            guard context.chapterStarts.indices.contains(index) else { return ([], false) }
            return ([.seek(context.chapterStarts[index]), .play], true)
        case .audio:
            guard context.audioTrackIDs.indices.contains(index) else { return ([], false) }
            return ([.selectAudio(id: context.audioTrackIDs[index])], false)
        case .subtitles:
            if index == 0 { return ([.selectSubtitle(id: nil)], false) }
            guard context.subtitleTrackIDs.indices.contains(index - 1) else { return ([], false) }
            return ([.selectSubtitle(id: context.subtitleTrackIDs[index - 1])], false)
        }
    }
}
```

`TVPlayerFocusID.describe` gains, first:

```swift
        if let panel = state.panel {
            switch panel.focus {
            case .tabs: return "tab.\(panel.tab.id)"
            case .content(let index): return "content.\(panel.tab.id).\(index)"
            }
        }
```

- [ ] **Step 5: Run every model test**

Run: tvOS unit `-only-testing:DionysusTVTests/TVPlayerInputModelTests -only-testing:DionysusTVTests/TVPlayerScrubTests -only-testing:DionysusTVTests/TVPlayerPanelTests -only-testing:DionysusTVTests/TVPlayerFocusIDTests`. Expected: pass. Task 1's `test_down_fromAnIcon_returnsToTheScrubber` still passes (an icon's Down returns to the scrubber, it doesn't open the panel).

---

### Task 7: The panel's views

**Files:**
- Create: `DionysusTV/Player/TVPlayerPanelView.swift`, `DionysusTV/Player/TVPlayerInfoArt.swift`, `DionysusTVUITests/PlayerPanelJourneyTests.swift`
- Modify: `DionysusPlayer/Core/Networking/JellyfinModels.swift` (`BaseItemDto.seriesThumbImageTag`), `DionysusPlayer/Core/Models/MediaItem.swift` (`seriesThumbImageURL`), `DionysusTV/Player/TVTransportOverlay.swift`, `AccessibilityIdentifiers.swift`, `DionysusTVUITests/AccessibilityAuditTests.swift`, `CLAUDE.md`
- Test: `DionysusTVTests/TVPlayerInfoArtTests.swift`

**Interfaces:**
- Consumes: Task 6's state; `TVDetailFormat.metadata(for:)`; `AsyncRemoteImage(url:placeholderSystemImage:retryPatience:)`; `PlaybackTrack.title`/`.metadata`; `Chapter`.
- Produces: `TVPlayerInfoArt(item:)` (`url`, `shape`), `MediaItem.seriesThumbImageURL`, `TVPlayerPanelView(viewModel:panel:tabs:)`, `A11yID.TV.Player.panelTab(_:)`, `.panelRow(_:_:)`, `.restart`, `.infoArt`.

- [ ] **Step 1: Write the failing art test**

`DionysusTVTests/TVPlayerInfoArtTests.swift`:

```swift
import XCTest
@testable import Dionysus

final class TVPlayerInfoArtTests: XCTestCase {
    private let images = ImageURLBuilder(baseURL: URL(string: "https://jf.example")!, accessToken: nil)

    private func item(_ kind: BaseItemKind, tags: [String: String] = [:], seriesThumb: String? = nil) -> MediaItem {
        var dto = BaseItemDto(id: "item", name: "Name", type: kind)
        dto.imageTags = tags
        dto.seriesId = "series"
        dto.seriesThumbImageTag = seriesThumb
        return MediaItem(dto: dto, images: images)
    }

    func test_aMovie_showsItsPoster() {
        let art = TVPlayerInfoArt(item: item(.movie, tags: ["Primary": "p"]))
        XCTAssertEqual(art.shape, .poster)
        XCTAssertTrue(art.url?.absoluteString.contains("/Items/item/Images/Primary") ?? false)
    }

    func test_anEpisode_showsItsThumb_thenItsStill_thenTheShowsThumb() {
        XCTAssertTrue(TVPlayerInfoArt(item: item(.episode, tags: ["Thumb": "t", "Primary": "p"])).url?.absoluteString.contains("Images/Thumb") ?? false)
        let still = TVPlayerInfoArt(item: item(.episode, tags: ["Primary": "p"]))
        XCTAssertEqual(still.shape, .landscape)
        XCTAssertTrue(still.url?.absoluteString.contains("/Items/item/Images/Primary") ?? false)
        let show = TVPlayerInfoArt(item: item(.episode, seriesThumb: "s"))
        XCTAssertTrue(show.url?.absoluteString.contains("/Items/series/Images/Thumb") ?? false)
        XCTAssertNil(TVPlayerInfoArt(item: item(.episode)).url, "Nothing to show: the glyph stands in")
    }
}
```

Run. Expected: build failure, "value of type 'BaseItemDto' has no member 'seriesThumbImageTag'".

- [ ] **Step 2: Add the series thumb**

In `BaseItemDto` (`JellyfinModels.swift`), after `seasonName`:

```swift
    /// The series' Thumb tag, which Jellyfin sends on an episode by default
    /// (`SeriesThumbImageTag`). The player's Info tab falls back to it.
    var seriesThumbImageTag: String?
```

In `MediaItem.swift`, after `thumbImageURL`:

```swift
    /// An episode's series Thumb, `nil` when the series has none.
    var seriesThumbImageURL: URL? {
        guard let seriesID = dto.seriesId, let tag = dto.seriesThumbImageTag else { return nil }
        return images.url(itemID: seriesID, imageType: "Thumb", tag: tag, maxWidth: 800)
    }
```

Check it on the LAN server with an episode of a series that has a Thumb: `curl -s "http://192.168.0.222:8096/flix/Users/<user id>/Items/<episode id>" -H "Authorization: MediaBrowser Token=<token>" | python3 -m json.tool | grep SeriesThumb` (memory `jellyfin-test-server` says how to get a token). `SeriesThumbImageTag` isn't gated by `Fields`, so if it's missing, that series has no Thumb; try another before concluding anything.

`DionysusTV/Player/TVPlayerInfoArt.swift`:

```swift
import Foundation

/// The Info tab's artwork (Benjamin, 2026-10-06): a movie's portrait
/// poster; an episode's landscape thumb (its Thumb, else its still, which is
/// its Primary), falling back to the show's Thumb.
struct TVPlayerInfoArt: Equatable {
    enum Shape: Equatable {
        case poster, landscape

        var size: CGSize {
            switch self {
            case .poster: CGSize(width: 220, height: 330)
            case .landscape: CGSize(width: 480, height: 270)
            }
        }
    }

    let url: URL?
    let shape: Shape

    init(item: MediaItem) {
        if item.kind == .episode {
            shape = .landscape
            let still = item.dto.imageTags?["Primary"] != nil ? item.imageURL(type: "Primary", maxWidth: 960) : nil
            url = item.thumbImageURL ?? still ?? item.seriesThumbImageURL
        } else {
            shape = .poster
            url = item.dto.imageTags?["Primary"] != nil ? item.imageURL(type: "Primary", maxWidth: 440) : nil
        }
    }
}
```

Run the test. Expected: pass.

- [ ] **Step 3: Add the identifiers**

In `A11yID.TV.Player`:

```swift
            static let panel = "tv.player.panel"
            static let restart = "tv.player.restart"
            static let infoArt = "tv.player.infoArt"
            static func panelTab(_ id: String) -> String { "tv.player.tab.\(id)" }
            static func panelRow(_ tab: String, _ index: Int) -> String { "tv.player.row.\(tab).\(index)" }
```

- [ ] **Step 4: Write the panel view**

`DionysusTV/Player/TVPlayerPanelView.swift`:

```swift
import SwiftUI

extension TVPanelTab {
    var title: String {
        switch self {
        case .info: String(localized: "Info")
        case .chapters: String(localized: "Chapters")
        case .audio: String(localized: "Audio")
        case .subtitles: String(localized: "Subtitles")
        }
    }
}

/// The swipe-down panel (prototype screen 13, without its Stats tab): the
/// tabs, then the tab's content. Drawn from the model's state; it takes no
/// focus of its own.
struct TVPlayerPanelView: View {
    let viewModel: PlayerViewModel
    let panel: TVPlayerInputState.Panel
    let tabs: [TVPanelTab]

    private func isFocused(_ index: Int) -> Bool { panel.focus == .content(index) }

    var body: some View {
        VStack(alignment: .leading, spacing: 34) {
            HStack(spacing: 12) {
                ForEach(tabs, id: \.self) { tab in
                    let focused = panel.focus == .tabs && tab == panel.tab
                    Text(tab.title)
                        .font(.headline)
                        .foregroundStyle(focused ? Color.black : Color.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .background(
                            Capsule().fill(focused ? Color.white : Color.white.opacity(tab == panel.tab ? 0.2 : 0))
                        )
                        .accessibilityAddTraits(tab == panel.tab ? [.isButton, .isSelected] : .isButton)
                        .accessibilityIdentifier(A11yID.TV.Player.panelTab(tab.id))
                }
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.TV.Player.panel)
    }

    @ViewBuilder
    private var content: some View {
        switch panel.tab {
        case .info: info
        case .chapters: chapters
        case .audio: trackList(rows: viewModel.audioTracks.map { ($0.title, $0.metadata, $0.isSelected) })
        case .subtitles:
            trackList(rows: [(String(localized: "Off"), nil, !viewModel.subtitleTracks.contains(where: \.isSelected))]
                + viewModel.subtitleTracks.map { ($0.title, $0.metadata, $0.isSelected) })
        }
    }

    // MARK: Info

    @ViewBuilder
    private var info: some View {
        if let item = viewModel.item {
            let art = TVPlayerInfoArt(item: item)
            HStack(alignment: .top, spacing: 40) {
                AsyncRemoteImage(url: art.url, placeholderSystemImage: item.kind.placeholderSystemImage)
                    .frame(width: art.shape.size.width, height: art.shape.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .accessibilityElement()
                    .accessibilityLabel(String(localized: "Artwork"))
                    .accessibilityIdentifier(A11yID.TV.Player.infoArt)
                VStack(alignment: .leading, spacing: 14) {
                    Text(item.kind == .episode ? (item.dto.seriesName ?? item.railTitle) : item.railTitle)
                        .font(.title3.bold())
                    if item.kind == .episode {
                        Text(item.numberedEpisodeName).font(.headline).foregroundStyle(.secondary)
                    }
                    Text(TVDetailFormat.metadata(for: item).joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary)
                    if let overview = item.dto.overview {
                        Text(overview).font(.callout).lineLimit(4).frame(maxWidth: 900, alignment: .leading)
                    }
                    Label("Restart", systemImage: "arrow.counterclockwise")
                        .font(.headline)
                        .foregroundStyle(isFocused(0) ? Color.black : Color.white)
                        .padding(.horizontal, 30)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(isFocused(0) ? Color.white : Color.white.opacity(0.18)))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier(A11yID.TV.Player.restart)
                }
            }
        }
    }

    // MARK: Chapters

    private var chapters: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(Array(viewModel.chapters.enumerated()), id: \.element.id) { index, chapter in
                        chapterTile(chapter, index: index).id(index)
                    }
                }
            }
            .scrollClipDisabled()
            .onChange(of: panel.focus, initial: true) { _, focus in
                if case .content(let index) = focus { withAnimation { proxy.scrollTo(index, anchor: .center) } }
            }
        }
    }

    private func chapterTile(_ chapter: Chapter, index: Int) -> some View {
        let current = viewModel.currentChapter?.id == chapter.id
        let focused = isFocused(index)
        return VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomLeading) {
                if let url = chapter.imageURL {
                    AsyncRemoteImage(url: url, placeholderSystemImage: "film")
                } else {
                    TVChapterTrickplayFrame(viewModel: viewModel, seconds: chapter.startSeconds)
                }
                if current {
                    Color.black.opacity(0.25)
                    GeometryReader { geo in
                        Rectangle().fill(Color.dionysusAmber)
                            .frame(width: geo.size.width * chapterProgress(index), height: 8)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            .frame(width: 380, height: 214)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white, lineWidth: focused ? 4 : 0))
            .scaleEffect(focused ? 1.06 : 1)
            .animation(.easeOut(duration: 0.15), value: focused)
            HStack(spacing: 12) {
                Text(chapter.name).font(.callout.weight(.semibold)).lineLimit(1)
                if current {
                    Text("NOW")
                        .font(.caption.bold())
                        .foregroundStyle(Color(red: 0.08, green: 0.03, blue: 0.06))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color.dionysusAmber, in: Capsule())
                }
            }
            Text(TVPlaybackTimeFormat.string(chapter.startSeconds)).font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 380, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chapter.name)
        .accessibilityValue(TVPlaybackTimeFormat.string(chapter.startSeconds))
        .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(A11yID.TV.Player.panelRow(TVPanelTab.chapters.id, index))
    }

    /// How far the playhead is through chapter `index`.
    private func chapterProgress(_ index: Int) -> Double {
        let chapters = viewModel.chapters
        let start = chapters[index].startSeconds
        let end = index + 1 < chapters.count ? chapters[index + 1].startSeconds : viewModel.duration
        guard end > start else { return 0 }
        return min(1, max(0, (viewModel.currentTime - start) / (end - start)))
    }

    // MARK: Tracks

    /// iOS's picker text, two lines a track: the title, then the metadata
    /// line (`PlaybackTrack.metadata`), with a tick on the chosen one.
    private func trackList(rows: [(title: String, metadata: String?, isChosen: Bool)]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        let focused = isFocused(index)
                        HStack(spacing: 20) {
                            Image(systemName: "checkmark")
                                .font(.headline)
                                .opacity(row.isChosen ? 1 : 0)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.title).font(.headline)
                                if let metadata = row.metadata {
                                    Text(metadata).font(.subheadline).opacity(0.7)
                                }
                            }
                        }
                        .foregroundStyle(focused ? Color.black : Color.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                        .frame(width: 760, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 20).fill(focused ? Color.white : Color.clear))
                        .id(index)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(row.isChosen ? [.isButton, .isSelected] : .isButton)
                        .accessibilityIdentifier(A11yID.TV.Player.panelRow(panel.tab.id, index))
                    }
                }
            }
            .frame(height: 330)
            .onChange(of: panel.focus, initial: true) { _, focus in
                if case .content(let index) = focus { withAnimation { proxy.scrollTo(index, anchor: .center) } }
            }
        }
    }
}

/// A chapter with no image of its own: the trickplay frame at its start.
private struct TVChapterTrickplayFrame: View {
    let viewModel: PlayerViewModel
    let seconds: Double
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            MediaPlaceholderBox(systemImage: "film", isSettled: !viewModel.supportsScrubThumbnails)
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .task(id: seconds) {
            guard viewModel.supportsScrubThumbnails else { return }
            image = await viewModel.scrubThumbnail(atSeconds: seconds)
        }
    }
}
```

`MediaPlaceholderBox`'s initialiser may name its parameters differently; follow the repository (its doc comment in CLAUDE.md, "Image loading & placeholders"). `item.kind.placeholderSystemImage` is `BaseItemKind.placeholderSystemImage`.

- [ ] **Step 5: Raise the transport when the panel is open**

In `TVTransportOverlay`, the chrome layer branches on the panel. Replace `chromeLayer`'s inner `VStack` with:

```swift
            if let panel = state.panel {
                VStack(alignment: .leading, spacing: 0) {
                    titleBlock
                    Spacer(minLength: 40)
                    // The raised scrubber reports `BottomChromeTopKey`, so a
                    // subtitle just chosen shows above it.
                    VStack(alignment: .leading, spacing: 18) {
                        scrubber
                        timesRow
                    }
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: BottomChromeTopKey.self, value: proxy.frame(in: .global).minY)
                        }
                    )
                    TVPlayerPanelView(viewModel: viewModel, panel: panel, tabs: TVPlayerInputModel.availableTabs(input.context()))
                        .frame(height: 430, alignment: .top)
                        .padding(.top, 50)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    titleBlock
                    Spacer()
                    bottomBar
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
```

Move the times `HStack` out of `bottomBar` into a `timesRow` property both branches use. With the panel open, the gradient behind deepens: in `chromeLayer`'s gradient `VStack`, give the bottom gradient `.frame(height: state.panel == nil ? 420 : 780)` and stops `[.clear, .black.opacity(0.75), .black.opacity(0.92)]` while the panel is open (prototype `PlayerTabs`).

- [ ] **Step 6: Write the journeys**

`DionysusTVUITests/PlayerPanelJourneyTests.swift`:

```swift
import XCTest

final class PlayerPanelJourneyTests: TVUITestCase {
    private let keepTransportUp = ["-UITestDisableControlAutoHide", "YES"]

    func test_down_opensInfo_andRestartGoesBackToTheStart() {
        let app = openPlayer(extraArguments: keepTransportUp)
        press(.down)
        XCTAssertTrue(waitForPlayerFocus(app, "tab.info"))
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.infoArt].exists)
        press(.down)
        XCTAssertTrue(waitForPlayerFocus(app, "content.info.0"))
        press(.select)
        XCTAssertTrue(poll(timeout: 3) { !app.descendants(matching: .any)[A11yID.TV.Player.panel].exists })
        XCTAssertTrue(poll(timeout: 3) { (self.elapsedSeconds(app) ?? 999) < 10 }, "Restart plays from 0:00")
    }

    func test_chapters_iconOpensOnTheCurrentChapter_andSelectJumpsThere() throws {
        let app = openPlayer(extraArguments: keepTransportUp)
        press(.up)
        XCTAssertTrue(waitForPlayerFocus(app, "icon.chapters"))
        press(.select)
        // The movie resumes at 20:00, inside its first chapter (0:00–23:45).
        XCTAssertTrue(waitForPlayerFocus(app, "content.chapters.0"))
        press(.right)
        XCTAssertTrue(waitForPlayerFocus(app, "content.chapters.1"))
        let tile = app.descendants(matching: .any)[A11yID.TV.Player.panelRow("chapters", 1)]
        let start = try XCTUnwrap(Self.seconds(tile.value as? String ?? ""))
        press(.select)
        XCTAssertTrue(poll(timeout: 3) { abs((self.elapsedSeconds(app) ?? 0) - start) < 3 }, "Playback jumps to the chapter")
    }

    func test_audio_selectMovesTheTick_andTheChoiceIsRememberedNextTime() {
        let app = openPlayer(extraArguments: keepTransportUp)
        press(.up)
        press(.right)
        XCTAssertTrue(waitForPlayerFocus(app, "icon.audio"))
        press(.select)
        XCTAssertTrue(waitForPlayerFocus(app, "content.audio.0"))
        press(.down)
        press(.select)
        let second = app.descendants(matching: .any)[A11yID.TV.Player.panelRow("audio", 1)]
        XCTAssertTrue(poll(timeout: 3) { second.isSelected }, "The tick moves to the chosen track")
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.panel].exists, "The panel stays open")

        // Close the player and play the same title again.
        press(.menu)
        press(.menu)
        let play = app.buttons[A11yID.TV.Detail.play]
        XCTAssertTrue(waitForFocus(play))
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10))
        press(.up)
        press(.right)
        press(.select)
        XCTAssertTrue(poll(timeout: 3) { app.descendants(matching: .any)[A11yID.TV.Player.panelRow("audio", 1)].isSelected })
    }

    func test_choosingASubtitle_showsItAboveTheRaisedScrubber() {
        let app = openPlayer(extraArguments: keepTransportUp)
        press(.up)
        press(.right)
        press(.right)
        XCTAssertTrue(waitForPlayerFocus(app, "icon.subtitles"))
        press(.select)
        XCTAssertTrue(waitForPlayerFocus(app, "content.subtitles.0"), "Off is chosen, so focus lands on it")
        press(.down)
        press(.select)
        let cue = app.descendants(matching: .any)[A11yID.Player.plainSubtitle].firstMatch
        XCTAssertTrue(cue.waitForExistence(timeout: 5))
        let scrubber = app.descendants(matching: .any)[A11yID.TV.Player.transport]
        XCTAssertLessThanOrEqual(cue.frame.maxY, scrubber.frame.minY, "The cue sits above the raised scrubber")
    }

    func test_choosingTheStyledTrack_rendersItThroughLibass() {
        let app = openPlayer(extraArguments: keepTransportUp)
        press(.up)
        press(.right)
        press(.right)
        press(.select)
        press(.down, times: 3)
        XCTAssertTrue(waitForPlayerFocus(app, "content.subtitles.3"))
        press(.select)
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.Player.styledSubtitle].waitForExistence(timeout: 10))
    }

    func test_menu_closesThePanel_andASecondMenuClosesThePlayer() {
        let app = openPlayer(extraArguments: keepTransportUp)
        press(.down)
        XCTAssertTrue(waitForPlayerFocus(app, "tab.info"))
        press(.menu)
        XCTAssertTrue(poll(timeout: 3) { !app.descendants(matching: .any)[A11yID.TV.Player.panel].exists })
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].exists)
        press(.menu)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Detail.play]))
    }
}
```

Add to `AccessibilityAuditTests`:

```swift
    func test_playerPanel() throws {
        let app = openPlayer(extraArguments: ["-UITestDisableControlAutoHide", "YES"])
        press(.down)
        XCTAssertTrue(waitForPlayerFocus(app, "tab.info"))
        try audit(app)
    }
```

- [ ] **Step 7: Run the journeys**

Run: tvOS UI `-only-testing:DionysusTVUITests/PlayerPanelJourneyTests -only-testing:DionysusTVUITests/AccessibilityAuditTests/test_playerPanel`. Expected: pass. If `test_choosingASubtitle_showsItAboveTheRaisedScrubber` fails on position, check the raised scrubber reports `BottomChromeTopKey` (the transport's `GeometryReader` must be on the scrubber block, not the panel).

- [ ] **Step 8: Simulator check**

On the LAN server: swipe down on the Simulator's remote (or press Down) for Info. Check a movie shows its poster and an episode its still, with the show's thumb for an episode without one. Check chapter images, then a title without chapter images, which should show trickplay frames. Check the audio and subtitle lists against iOS's picker text for the same title. Screenshot each tab for Benjamin.

- [ ] **Step 9: CLAUDE.md, suites, sign-off, commit, PR 3**

Add to the tvOS player paragraph:

```markdown
**The swipe-down panel** (Info, Chapters, Audio, Subtitles; no Stats tab)
opens with Down or an icon, and lifts the scrubber to mid-screen. Its tabs
follow focus. Restart and a chapter play from there and close it; a track
switch keeps it open so the change shows. It closes on Menu, Up from the
tabs, or 10s without a press. Info's art is a movie's poster, else an
episode's thumb or still, else the show's thumb
(`BaseItemDto.seriesThumbImageTag`).
```

Sync strings ("Info", "Off", "Restart", "NOW", "Artwork" reuse). Run tvOS unit, tvOS UI, iOS unit, iOS smoke (`JellyfinModels.swift` and `MediaItem.swift` changed). After sign-off commit, push, open "tvOS M4 PR 3: the swipe-down panel", merge with `--merge` when checks pass.

---

## PR 4: `feature/tvos-player-skip-nextup`

### Task 8: Skip and Next Up in the input model, and their fixtures

**Files:**
- Create: `DionysusTV/Player/TVPlayerInputModel+Overlays.swift`
- Modify: `DionysusTV/Player/TVPlayerInputModel.swift`, `TVPlayerInputModel+Scrub.swift`, `TVPlayerFocusID.swift`, `DionysusPlayer/Core/UITestSupport/UITestConfiguration.swift`, `DionysusPlayer/Core/UITestSupport/UITestStubURLProtocol.swift`, `TESTING.md`
- Test: `DionysusTVTests/TVPlayerOverlaysTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 2, 6.
- Produces: `TVPlayerInputState.hiddenSkipSegmentID`, `.nextUpFocus`, `.hasRequestedAdvance`; `TVPlayerInputModel.reduceOverlays(_:_:context:)`, `.nextUpHasFocus(_:context:)`, `.skipButtonVisible(_:context:)`, `.selectSkips(_:context:)`, `.playNext(_:)`; scenarios `skipIntro` and `earlyCredits`.

- [ ] **Step 1: Branch**

```bash
git switch develop && git pull && git switch -c feature/tvos-player-skip-nextup
```

- [ ] **Step 2: Write the failing tests**

`DionysusTVTests/TVPlayerOverlaysTests.swift`:

```swift
import XCTest
@testable import Dionysus

final class TVPlayerOverlaysTests: XCTestCase, TVPlayerInputModelHarness {
    var state = TVPlayerInputState()
    var context = TVPlayerOverlaysTests.standardContext
    var now: TimeInterval = 1000
    let intro = TVPlayerContext.SkipSegment(id: "intro", endSeconds: 120)

    func test_select_skips_whileTheButtonShows() {
        context.skipSegment = intro
        XCTAssertEqual(send(.select), [.skipSegment(id: "intro")])
        state.chrome = .hidden
        XCTAssertEqual(send(.select), [.skipSegment(id: "intro")])
        XCTAssertEqual(send(.playPause), [.togglePlayPause], "Play/Pause still pauses")
    }

    func test_select_onAnIcon_isTheIcons_notASkip() {
        context.skipSegment = intro
        context.statsButtonEnabled = true
        send(.up)
        press(.right)
        press(.right)
        press(.right)
        XCTAssertEqual(state.transportFocus, .icon(.stats))
        XCTAssertEqual(send(.select), [])
        XCTAssertTrue(state.isStatsOn)
    }

    func test_menu_hidesTheButtonWhileNothingElseIsUp_andASecondMenuCloses() {
        context.skipSegment = intro
        state.chrome = .hidden
        XCTAssertEqual(send(.menu), [])
        XCTAssertEqual(state.hiddenSkipSegmentID, "intro")
        XCTAssertFalse(TVPlayerInputModel.skipButtonVisible(state, context: context))
        state.chrome = .hidden
        XCTAssertEqual(send(.menu), [.close])
    }

    func test_aHiddenButton_returnsWithTheTransport_andSelectStillSkips() {
        context.skipSegment = intro
        state.chrome = .hidden
        send(.menu)
        send(.up)
        XCTAssertTrue(TVPlayerInputModel.skipButtonVisible(state, context: context))
        XCTAssertEqual(send(.select), [.skipSegment(id: "intro")])
    }

    func test_menuWithTheTransportUp_closes_evenWithTheButtonShowing() {
        context.skipSegment = intro
        XCTAssertEqual(send(.menu), [.close])
    }

    func test_nextUp_hasFocusWhileTheTransportIsHidden() {
        context.nextUpSecondsRemaining = 8
        state.chrome = .hidden
        XCTAssertTrue(TVPlayerInputModel.nextUpHasFocus(state, context: context))
        XCTAssertEqual(press(.right), [], "Moves to Close instead of skipping")
        XCTAssertEqual(state.nextUpFocus, .close)
        XCTAssertEqual(state.chrome, .hidden)
        XCTAssertEqual(send(.select), [.dismissNextUp])
        press(.left)
        XCTAssertEqual(send(.select), [.playNext])
    }

    func test_nextUp_menuMeansClose() {
        context.nextUpSecondsRemaining = 8
        state.chrome = .hidden
        XCTAssertEqual(send(.menu), [.dismissNextUp])
    }

    func test_nextUp_upShowsTheTransport_andTheCardLosesFocusUntilItFades() {
        context.nextUpSecondsRemaining = 8
        state.chrome = .hidden
        send(.up)
        XCTAssertFalse(TVPlayerInputModel.nextUpHasFocus(state, context: context))
        XCTAssertEqual(press(.right), [.seek(110)], "With the transport up, Right skips again")
        tick(for: 4.2)
        XCTAssertTrue(TVPlayerInputModel.nextUpHasFocus(state, context: context))
    }

    func test_nextUp_pausedArrowsMoveTheCard_notAScrub() {
        context.nextUpSecondsRemaining = 8
        context.playback = .paused
        state.chrome = .hidden
        // Pausing shows the transport on the next tick, so press before it.
        XCTAssertEqual(press(.right), [])
        XCTAssertNil(state.scrub)
    }

    func test_countdownReachingZero_playsNext_once() {
        context.nextUpSecondsRemaining = 0
        XCTAssertEqual(tick(for: 1), [.playNext])
    }

    /// Review Focus 2.
    func test_countdownReachingZeroDuringAScrub_waitsForTheScrubToResolve() {
        context.nextUpSecondsRemaining = 3
        send(.swipeBegan)
        context.playback = .paused
        context.nextUpSecondsRemaining = 0
        XCTAssertEqual(tick(for: 1), [])
        send(.menu)
        context.playback = .playing
        XCTAssertEqual(tick(for: 1), [.playNext])
    }

    func test_theCardsFocus_resetsWhenItGoes() {
        context.nextUpSecondsRemaining = 8
        state.chrome = .hidden
        press(.right)
        context.nextUpSecondsRemaining = nil
        tick(for: 0.1)
        XCTAssertEqual(state.nextUpFocus, .playNow)
    }
}
```

Run. Expected: build failure, "has no member 'hiddenSkipSegmentID'".

- [ ] **Step 3: Add the state and route the overlays**

In `TVPlayerInputState`, after `isStatsOn`:

```swift
    /// A skip button Menu hid while nothing else was up. It shows again with
    /// the transport (Benjamin, 2026-10-06).
    var hiddenSkipSegmentID: String?
    var nextUpFocus: TVNextUpButton = .playNow
    var hasRequestedAdvance = false
```

`dispatch` becomes:

```swift
        if let commands = reduceScrub(intent, &state, context: context, now: now) { return commands }
        if let commands = reducePanel(intent, &state, context: context) { return commands }
        if let commands = reduceOverlays(intent, &state, context: context) { return commands }
        return reduceTransport(intent, &state, context: context, now: now)
```

In `tick`, before `return commands`:

```swift
        if context.nextUpSecondsRemaining == nil { state.nextUpFocus = .playNow }
        // Review Focus 2: never under a scrub; once it resolves, once only.
        if context.nextUpSecondsRemaining == 0, state.scrub == nil {
            commands += playNext(&state)
        }
```

In `+Scrub.swift`, the paused-arrow case becomes:

```swift
        case .arrow(let direction) where context.playback == .paused && !nextUpHasFocus(state, context: context):
```

`DionysusTV/Player/TVPlayerInputModel+Overlays.swift`:

```swift
import Foundation

extension TVPlayerInputModel {
    /// Skip Intro/Credits and the Next Up card. `nil` for intents they
    /// leave to the transport.
    static func reduceOverlays(
        _ intent: Intent, _ state: inout TVPlayerInputState, context: TVPlayerContext
    ) -> [TVPlayerCommand]? {
        if nextUpHasFocus(state, context: context) {
            switch intent {
            case .select:
                return state.nextUpFocus == .playNow ? playNext(&state) : [.dismissNextUp]
            case .arrow(let direction):
                state.nextUpFocus = direction == .left ? .playNow : .close
                return []
            case .menu:
                return [.dismissNextUp]
            default:
                return nil
            }
        }
        if let segment = context.skipSegment, selectSkips(state, context: context) {
            switch intent {
            case .select:
                return [.skipSegment(id: segment.id)]
            case .menu where state.chrome == .hidden:
                state.hiddenSkipSegmentID = segment.id
                return []
            default:
                return nil
            }
        }
        return nil
    }

    /// The card has focus while the transport is hidden and nothing else is
    /// open; with the transport up it stays on screen without focus.
    static func nextUpHasFocus(_ state: TVPlayerInputState, context: TVPlayerContext) -> Bool {
        context.nextUpSecondsRemaining != nil && state.chrome == .hidden && state.panel == nil && state.scrub == nil
    }

    /// Always with the transport up; with it hidden, until Menu hides it.
    static func skipButtonVisible(_ state: TVPlayerInputState, context: TVPlayerContext) -> Bool {
        guard let segment = context.skipSegment else { return false }
        return state.chrome == .transport || state.hiddenSkipSegmentID != segment.id
    }

    /// Whether Select means Skip: the button shows and focus isn't on an
    /// icon, in the panel or in a scrub. The button is drawn focused then.
    static func selectSkips(_ state: TVPlayerInputState, context: TVPlayerContext) -> Bool {
        skipButtonVisible(state, context: context) && state.panel == nil && state.scrub == nil
            && state.transportFocus == .scrubber
    }

    static func playNext(_ state: inout TVPlayerInputState) -> [TVPlayerCommand] {
        guard !state.hasRequestedAdvance else { return [] }
        state.hasRequestedAdvance = true
        return [.playNext]
    }
}
```

`TVPlayerFocusID.describe` becomes:

```swift
    static func describe(_ state: TVPlayerInputState, context: TVPlayerContext) -> String {
        if let panel = state.panel {
            switch panel.focus {
            case .tabs: return "tab.\(panel.tab.id)"
            case .content(let index): return "content.\(panel.tab.id).\(index)"
            }
        }
        if TVPlayerInputModel.nextUpHasFocus(state, context: context) {
            return state.nextUpFocus == .playNow ? "nextUp.playNow" : "nextUp.close"
        }
        if state.chrome == .transport, case .icon(let icon) = state.transportFocus { return "icon.\(icon.id)" }
        if TVPlayerInputModel.selectSkips(state, context: context) { return "skip" }
        return state.chrome == .transport ? "scrubber" : "none"
    }
```

Run every model test class. Expected: pass.

- [ ] **Step 4: Add the two scenarios**

In `UITestScenario`, after `thinDynamicRails`:

```swift
    /// Every item has an intro from 0:00 to 83:20, long enough that a
    /// resumed title starts inside it: Skip Intro shows at once.
    case skipIntro
    /// Every episode's credits start at 0:05, so Next Up shows as soon as an
    /// episode plays and counts down 10s.
    case earlyCredits
```

In `UITestStubURLProtocol`, replace the `/MediaSegments` case's body with:

```swift
            let itemID = path.components(separatedBy: "/MediaSegments/").last ?? ""
            let segments = mediaSegments(forItem: itemID)
            return try encode(MediaSegmentDtoQueryResult(items: segments, totalRecordCount: segments.count))
```

and add beside the other private helpers:

```swift
    /// Segments for the two player scenarios; none otherwise.
    private func mediaSegments(forItem itemID: String) -> [MediaSegmentDto] {
        let ticksPerSecond: Int64 = 10_000_000
        switch UITestConfiguration.scenario {
        case .skipIntro:
            return [MediaSegmentDto(id: "intro-\(itemID)", itemId: itemID, type: .intro, startTicks: 0, endTicks: 5000 * ticksPerSecond)]
        case .earlyCredits where library.allItems[itemID]?.type == .episode:
            return [MediaSegmentDto(id: "outro-\(itemID)", itemId: itemID, type: .outro, startTicks: 5 * ticksPerSecond, endTicks: 2880 * ticksPerSecond)]
        default:
            return []
        }
    }
```

Add both to the list of scenarios the stub accepts if it keeps one (the `case .slowLogoImage, .slowSubtitleFonts, …` line near 544 lists scenarios sharing the standard catalogue: add `.skipIntro, .earlyCredits` there).

In TESTING.md's scenario table, add the two rows with the descriptions above.

---

### Task 9: Skip and Next Up on screen, and the next item in place

**Files:**
- Create: `DionysusTV/Player/TVSkipButton.swift`, `DionysusTV/Player/TVNextUpCard.swift`, `DionysusTVUITests/PlayerSegmentJourneyTests.swift`
- Modify: `DionysusTV/Player/TVPlayerOverlay.swift`, `DionysusTV/Player/TVPlayerHostController.swift`, `DionysusTV/Player/TVPlayerPresenter.swift`, `AccessibilityIdentifiers.swift`, `DionysusTVUITests/AccessibilityAuditTests.swift`, `CLAUDE.md`
- Test: `DionysusTVTests/TVPlayerHostAdvanceTests.swift`

**Interfaces:**
- Consumes: Task 8; `PlaybackSegment.Kind.skipButtonTitle`; `PlayerViewModel.nextEpisode`, `.nextUpSecondsRemaining`, `.nextUpTotalCountdownSeconds`, `.currentSkipSegment`.
- Produces: `TVSkipButton(title:isFocused:)`, `TVNextUpCard(episode:secondsRemaining:totalSeconds:focus:)`, `TVPlayerHostController.makeViewModel: ((String) -> PlayerViewModel?)?`, `A11yID.TV.Player.skipButton`, `.nextUpCard`, `.nextUpPlayNow`, `.nextUpClose`.

- [ ] **Step 1: Add the identifiers**

```swift
            static let skipButton = "tv.player.skip"
            static let nextUpCard = "tv.player.nextUp"
            static let nextUpPlayNow = "tv.player.nextUp.playNow"
            static let nextUpClose = "tv.player.nextUp.close"
```

- [ ] **Step 2: Write the two views**

`DionysusTV/Player/TVSkipButton.swift`:

```swift
import SwiftUI

/// "Skip Intro" and the like, bottom-right (prototype screen 14). Focused
/// whenever Select would skip (`TVPlayerInputModel.selectSkips`).
struct TVSkipButton: View {
    let title: String
    let isFocused: Bool

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
            Image(systemName: "forward.fill").accessibilityHidden(true)
        }
        .font(.headline)
        .foregroundStyle(isFocused ? Color.black : Color.white)
        .padding(.horizontal, 34)
        .padding(.vertical, 18)
        .background(Capsule().fill(isFocused ? Color.white : Color.black.opacity(0.45)))
        .overlay(Capsule().stroke(Color.white.opacity(isFocused ? 0 : 0.4), lineWidth: 2))
        .scaleEffect(isFocused ? 1.05 : 1)
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(A11yID.TV.Player.skipButton)
    }
}
```

`DionysusTV/Player/TVNextUpCard.swift`:

```swift
import SwiftUI

/// The compact Next Up card (prototype screen 15; Benjamin's settled call):
/// the thumb with a seconds chip and a countdown bar, "S1:E4 · Title", then
/// Play Now and Close. Nothing else.
struct TVNextUpCard: View {
    let episode: MediaItem
    let secondsRemaining: Int
    let totalSeconds: Int
    /// `nil` while the transport is up and the card has no focus.
    let focus: TVNextUpButton?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack(alignment: .topTrailing) {
                AsyncRemoteImage(url: episode.thumbImageURL ?? episode.primaryImageURL, placeholderSystemImage: "tv")
                    .frame(width: 420, height: 236)
                    .accessibilityHidden(true)
                Text("\(secondsRemaining)s")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.6), in: Capsule())
                    .padding(12)
                GeometryReader { geo in
                    let fraction = totalSeconds > 0 ? Double(secondsRemaining) / Double(totalSeconds) : 0
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.25))
                        Rectangle().fill(Color.dionysusAmber).frame(width: geo.size.width * fraction)
                    }
                    .frame(height: 8)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .frame(width: 420, height: 236)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            Text(episode.kind == .episode ? episode.numberedEpisodeName : episode.railTitle)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 4)
            HStack(spacing: 14) {
                button("Play Now", systemImage: "play.fill", isFocused: focus == .playNow, id: A11yID.TV.Player.nextUpPlayNow)
                    .frame(maxWidth: .infinity)
                button("Close", systemImage: nil, isFocused: focus == .close, id: A11yID.TV.Player.nextUpClose)
            }
        }
        .padding(20)
        .frame(width: 460)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.TV.Player.nextUpCard)
    }

    private func button(_ title: LocalizedStringKey, systemImage: String?, isFocused: Bool, id: String) -> some View {
        HStack(spacing: 10) {
            if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
            Text(title)
        }
        .font(.headline)
        .foregroundStyle(isFocused ? Color.black : Color.white)
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
        .frame(maxWidth: systemImage == nil ? nil : .infinity)
        .background(Capsule().fill(isFocused ? Color.white : Color.white.opacity(0.18)))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(id)
    }
}
```

- [ ] **Step 3: Lay them over the video**

In `TVPlayerOverlay`, between the transport and the DEBUG marker:

```swift
            bottomTrailing
```

with:

```swift
    /// Skip and Next Up share the bottom-right slot; the view model makes
    /// them exclusive. With the transport up they sit above it; with the
    /// panel open they wait, since the panel fills the lower half.
    @ViewBuilder
    private var bottomTrailing: some View {
        if input.state.panel == nil {
            bottomTrailingSlot
        }
    }

    private var bottomTrailingSlot: some View {
        GeometryReader { proxy in
            let context = input.context()
            let lift = chromeTop.isFinite ? max(0, proxy.frame(in: .global).maxY - chromeTop + 30) : 0
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    if let episode = viewModel.nextEpisode, let seconds = viewModel.nextUpSecondsRemaining {
                        TVNextUpCard(
                            episode: episode, secondsRemaining: seconds,
                            totalSeconds: viewModel.nextUpTotalCountdownSeconds ?? seconds,
                            focus: TVPlayerInputModel.nextUpHasFocus(input.state, context: context) ? input.state.nextUpFocus : nil
                        )
                    } else if let segment = viewModel.currentSkipSegment,
                              TVPlayerInputModel.skipButtonVisible(input.state, context: context) {
                        TVSkipButton(
                            title: segment.kind.skipButtonTitle,
                            isFocused: TVPlayerInputModel.selectSkips(input.state, context: context)
                        )
                    }
                }
            }
            .padding(.bottom, lift)
        }
        .animation(.easeInOut(duration: 0.25), value: chromeTop)
    }
```

The `GeometryReader` sits inside the safe area, so the slot keeps the HIG's 80pt and 60pt insets.

- [ ] **Step 4: Write the failing advance test**

`DionysusTVTests/TVPlayerHostAdvanceTests.swift`:

```swift
import XCTest
@testable import Dionysus

@MainActor
final class TVPlayerHostAdvanceTests: XCTestCase {
    /// Review Focus 4: a new item starts clean but keeps Stats.
    func test_reset_forANewItem_clearsThePanelScrubAndHiddenSkip_butKeepsStats() {
        var now: TimeInterval = 0
        let input = TVPlayerInput(clock: { now })
        var context = TVPlayerContext(
            playback: .playing, currentTime: 100, duration: 600, chapterStarts: [0, 300],
            statsButtonEnabled: true, skipSegment: .init(id: "intro", endSeconds: 120)
        )
        input.context = { context }
        input.send(.up)
        now += 0.1
        input.send(.arrowDown(.right))
        now += 0.1
        input.send(.arrowUp(.right))
        input.send(.select)
        XCTAssertTrue(input.state.isStatsOn)
        input.send(.down)
        input.send(.down)
        XCTAssertNotNil(input.state.panel)
        context.playback = .paused

        input.reset()

        XCTAssertNil(input.state.panel)
        XCTAssertNil(input.state.scrub)
        XCTAssertNil(input.state.hiddenSkipSegmentID)
        XCTAssertFalse(input.state.hasRequestedAdvance)
        XCTAssertEqual(input.state.chrome, .transport)
        XCTAssertTrue(input.state.isStatsOn)
    }
}
```

With no audio or subtitle tracks in this context the icons are Chapters and Stats, so one Right reaches Stats; the first Down returns focus from the icon to the scrubber and the second opens the panel. Run. Expected: pass already (Task 3's `reset()`); the test pins the behaviour before the host starts relying on it.

- [ ] **Step 5: Move to the next item in place**

In `TVPlayerHostController`:

1. Add the factory the presenter sets:

```swift
    /// Builds the player for another item, for Next Up. Set by
    /// `TVPlayerPresenter`, which holds the client, user and queue.
    var makeViewModel: ((String) -> PlayerViewModel?)?
```

2. Replace `run(_:)`'s `playNext: {}` with `playNext: { [weak self] in self?.advanceToNextItem() }`.

3. Add:

```swift
    /// Play Now, or the countdown reaching zero: the next item plays in this
    /// player, without dismissing (spec, The host). The finished item is
    /// reported as iOS reports it, so Home and the page beneath are current.
    private func advanceToNextItem() {
        guard let next = viewModel.nextEpisode, let nextViewModel = makeViewModel?(next.id) else { return close() }
        // Before `end()`, as iOS's `tearDown` does: a late time update during
        // the stop could otherwise reach zero again and advance twice.
        viewModel.dismissNextUp()
        if let outcome = session.end() {
            pendingOutcome = outcome
            RecentPlaybackBroadcaster.shared.record(outcome)
        }
        unbindSurface()
        session = TVPlaybackSession(viewModel: nextViewModel)
        input.reset()
        bindSurface()
        overlayHost?.rootView = TVPlayerOverlay(viewModel: nextViewModel, input: input)
        session.begin()
    }

    private func unbindSurface() {
        cancellables.removeAll()
        if let aetherView {
            if isAetherViewBound, let aether = engine as? AetherPlaybackEngine {
                aether.hostEngine.unbind(view: aetherView)
            }
            aetherView.removeFromSuperview()
        }
        aetherView = nil
        isAetherViewBound = false
        player = nil
        if let fakeSurface {
            fakeSurface.willMove(toParent: nil)
            fakeSurface.view.removeFromSuperview()
            fakeSurface.removeFromParent()
        }
        fakeSurface = nil
    }
```

`unbindSurface()` runs while `session` still holds the old view model, so `engine` is the old engine.

4. In `close()`, add `viewModel.dismissNextUp()` after `input.stop()`.

5. In `TVPlayerOverlay`, key the whole `ZStack` on the item so per-item view state (the thumbnail loader, `chromeTop`) starts fresh: `.id(viewModel.itemID)` on the `ZStack`.

In `TVPlayerPresenter.present`, after creating the host:

```swift
        host.makeViewModel = { itemID in
            guard let engine = makeEngine() else { return nil }
            return PlayerViewModel(client: client, userID: userID, itemID: itemID, engine: engine, playbackQueue: queue)
        }
```

- [ ] **Step 6: Write the journeys**

`DionysusTVUITests/PlayerSegmentJourneyTests.swift`:

```swift
import XCTest

final class PlayerSegmentJourneyTests: TVUITestCase {
    func test_skipIntro_selectSkipsToTheIntrosEnd() {
        let app = openPlayer(scenario: "skipIntro", extraArguments: ["-UITestDisableControlAutoHide", "YES"])
        let skip = app.descendants(matching: .any)[A11yID.TV.Player.skipButton]
        XCTAssertTrue(skip.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForPlayerFocus(app, "skip"))
        press(.select)
        XCTAssertTrue(poll(timeout: 5) { (self.elapsedSeconds(app) ?? 0) >= 5000 }, "Skips to 83:20")
        XCTAssertTrue(poll(timeout: 3) { !skip.exists })
    }

    func test_skipIntro_menuHidesIt_theTransportBringsItBack_andASecondMenuCloses() {
        let app = openPlayer(scenario: "skipIntro", extraArguments: [])
        let skip = app.descendants(matching: .any)[A11yID.TV.Player.skipButton]
        XCTAssertTrue(skip.waitForExistence(timeout: 10))
        // Let the transport fade (4s after playback starts).
        XCTAssertTrue(poll(timeout: 8) { !app.staticTexts[A11yID.TV.Player.elapsed].exists })
        press(.menu)
        XCTAssertTrue(poll(timeout: 3) { !skip.exists }, "Menu hides the button")
        press(.up)
        XCTAssertTrue(skip.waitForExistence(timeout: 3), "It is back while the transport is up")
        XCTAssertTrue(poll(timeout: 8) { !app.staticTexts[A11yID.TV.Player.elapsed].exists })
        press(.menu)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Detail.play]), "A second Menu closes the player")
    }

    /// The part-watched S1:E1 resumes at 12:00, inside credits that start at
    /// 0:05, so the card shows at once and counts down 10s.
    func test_nextUp_playNowPlaysTheNextEpisodeInThePlayer() {
        let app = openEpisodeOne(scenario: "earlyCredits")
        let card = app.descendants(matching: .any)[A11yID.TV.Player.nextUpCard]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForPlayerFocus(app, "nextUp.playNow", timeout: 8), "Focus is the card's once the transport fades")
        press(.select)
        press(.up)
        let title = app.descendants(matching: .any)[A11yID.TV.Player.titleBlock]
        XCTAssertTrue(poll(timeout: 10) { title.exists && title.label.contains("2") && (self.elapsedSeconds(app) ?? 999) < 20 },
                      "The second episode plays from its start in the same player")
    }

    func test_nextUp_closeHidesTheCard_forTheRestOfTheEpisode() {
        let app = openEpisodeOne(scenario: "earlyCredits")
        let card = app.descendants(matching: .any)[A11yID.TV.Player.nextUpCard]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForPlayerFocus(app, "nextUp.playNow", timeout: 8))
        press(.right)
        XCTAssertTrue(waitForPlayerFocus(app, "nextUp.close"))
        press(.select)
        XCTAssertTrue(poll(timeout: 3) { !card.exists })
        Thread.sleep(forTimeInterval: 12)
        XCTAssertFalse(card.exists, "Past where the countdown would have ended, nothing advanced")
    }

    func test_nextUp_countdownReachingZero_advancesByItself() {
        let app = openEpisodeOne(scenario: "earlyCredits")
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.nextUpCard].waitForExistence(timeout: 10))
        press(.up)
        XCTAssertTrue(poll(timeout: 16) { (self.elapsedSeconds(app) ?? 999) < 20 }, "The next episode starts when the countdown ends")
    }

    /// Home's Continue Watching rail: the movie, then S1:E1.
    private func openEpisodeOne(scenario: String) -> XCUIApplication {
        let app = launch(scenario: scenario, seedSession: true)
        waitForHomeThenFirstTile(app)
        press(.right)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.episodeID(season: 1, episode: 1))]))
        openDetailFromFocusedTile(app)
        press(.select)
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.focus].waitForExistence(timeout: 10))
        return app
    }
}
```

If the title block's label doesn't carry the episode number in a form `contains("2")` can read reliably, compare it against the label read before Play Now instead (`XCTAssertNotEqual`).

Add to `AccessibilityAuditTests`:

```swift
    func test_playerNextUp() throws {
        let app = launch(scenario: "earlyCredits", seedSession: true)
        waitForHomeThenFirstTile(app)
        press(.right)
        openDetailFromFocusedTile(app)
        press(.select)
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.nextUpCard].waitForExistence(timeout: 10))
        try audit(app)
    }
```

- [ ] **Step 7: Run the tests, then check in the Simulator**

Run: tvOS unit (whole plan), tvOS UI `-only-testing:DionysusTVUITests/PlayerSegmentJourneyTests -only-testing:DionysusTVUITests/AccessibilityAuditTests/test_playerNextUp`. Expected: pass.

On the LAN server, play an episode that has intro segments (the server's intro-skipper data) and one near its end. Check Skip Intro's look and position, and that it sits above the transport when that is up. Check the Next Up card against prototype screen 15. Check that the next episode starts in place without the player closing, and that after Menu the show page beneath shows the new episode's progress. Screenshot each.

- [ ] **Step 8: CLAUDE.md, suites, sign-off, commit, PR 4**

Add to the tvOS player paragraph:

```markdown
**Skip and Next Up** share the bottom-right slot and lift above the
transport when it is up. Select skips while the button shows and focus
isn't on an icon or in the panel; Menu with nothing else up hides the
button, which comes back with the transport (Benjamin, 2026-10-06). The
Next Up card has focus while the transport is hidden, and Menu there means
Close. **The next item plays in the same player**
(`TVPlayerHostController.advanceToNextItem()`): the session ends and is
reported, a new view model and engine are bound to AVKit, nothing is
dismissed, and Stats stays as it was. Never under an open scrub.
```

Run tvOS unit, tvOS UI, iOS unit, iOS smoke (the stub and the scenario list are shared). After sign-off commit (including TESTING.md), push, open "tvOS M4 PR 4: Skip Intro/Credits and Next Up", merge with `--merge` when checks pass.

---

## PR 5: `feature/tvos-player-stats`

### Task 10: The playback stats panel

**Files:**
- Create: `DionysusPlayer/Features/Player/PlaybackStatsReport.swift`, `DionysusTV/Player/TVStatsPanel.swift`, `DionysusPlayerTests/Features/Player/PlaybackStatsReportTests.swift`, `DionysusTVUITests/PlayerStatsJourneyTests.swift`
- Modify: `DionysusPlayer/Features/Player/PlaybackStatsOverlay.swift`, `DionysusPlayer/Core/Persistence/PlayerPreferenceKeys.swift`, `DionysusTV/Player/TVPlayerOverlay.swift`, `AccessibilityIdentifiers.swift`, `project.yml`, `CLAUDE.md`

**Interfaces:**
- Consumes: `PlaybackStats`, `PlayerViewModel` (`stats`, `state`, `sourceVideoStream`, `sourceAudioStream`, `serverVersion`, `streamingSession`, `isOfflinePlayback`, `refreshServerVersion()`, `refreshStreamingSession()`).
- Produces: `PlaybackStatsReport` with `Row { label, value, id }`, `Section { title, rows }`, `DeviceReadings` (`current()`), and `video(_:sourceVideoStream:)`, `audio(_:sourceAudioStream:readings:)`, `playback(_:state:zoomMode:)`, `display(_:readings:)`, `streaming(isOffline:serverVersion:session:)`, `build()`; `TVStatsPanel(viewModel:)`; `A11yID.TV.Player.statsPanel`, `.statsValue(_:)`.

- [ ] **Step 1: Branch**

```bash
git switch develop && git pull && git switch -c feature/tvos-player-stats
```

- [ ] **Step 2: Write the failing tests**

`DionysusPlayerTests/Features/Player/PlaybackStatsReportTests.swift`:

```swift
import XCTest
@testable import Dionysus

final class PlaybackStatsReportTests: XCTestCase {
    private let stats = PlaybackStats(
        videoSize: "3840×1600", frameRate: "23.976 fps", bitrate: "38.2 Mbps",
        sourceColorFormat: "Dolby Vision (Profile 8)", displayColorFormat: "HDR10",
        videoDecoder: "VideoToolbox HEVC (HW)", audioDecoder: "AVPlayer", audioChannels: "5.1",
        backend: "Native", route: "Loopback", bufferedSeconds: 24, bufferedBytes: 8_400_000,
        currentTime: 0, duration: 5400, videoCodec: "HEVC Main 10", container: "Matroska",
        pixelFormat: "yuv420p10le (10-bit)", colorDescription: "BT.2020 · PQ", audioSampling: "48 kHz",
        liveBitrate: "38.4 Mbps", networkThroughput: "212.0 Mbps", frames: "0 dropped"
    )

    /// The rows and ids iOS's journeys read stay as they were.
    func test_video_keepsIOSsRowsInOrder() {
        let section = PlaybackStatsReport.video(stats, sourceVideoStream: nil)
        XCTAssertEqual(section.rows.prefix(4).map(\.label), ["Resolution", "Frame Rate", "Bitrate", "Codec"])
        XCTAssertEqual(section.rows.first { $0.label == "Codec" }?.value, "HEVC Main 10")
        XCTAssertTrue(section.rows.contains { $0.label == "Enhancement Layer" }, "Shown for a Dolby Vision source")
    }

    func test_audioDecoder_hasItsOwnID() {
        let section = PlaybackStatsReport.audio(stats, sourceAudioStream: nil, readings: .init())
        XCTAssertEqual(section.rows.first?.id, "Audio Decoder")
    }

    func test_playback_omitsZoomWhereThereIsNone() {
        XCTAssertTrue(PlaybackStatsReport.playback(stats, state: .playing, zoomMode: .fit).rows.contains { $0.label == "Zoom" })
        XCTAssertFalse(PlaybackStatsReport.playback(stats, state: .playing, zoomMode: nil).rows.contains { $0.label == "Zoom" })
    }

    func test_build_namesThePlatformsVersion() {
        let labels = PlaybackStatsReport.build().rows.map(\.label)
        #if os(tvOS)
        XCTAssertTrue(labels.contains("tvOS Version"))
        #else
        XCTAssertTrue(labels.contains("iOS Version"))
        #endif
    }

    /// iOS's default on both platforms: on in debug, off in release
    /// (Benjamin, 2026-10-07).
    func test_statsButtonDefault() {
        #if DEBUG
        XCTAssertTrue(showPlaybackStatsButtonEnabledDefault)
        #else
        XCTAssertFalse(showPlaybackStatsButtonEnabledDefault)
        #endif
    }
}
```

Add `"Features/Player/PlaybackStatsReportTests.swift"` to `DionysusTVTests`' includes and `"Player/PlaybackStatsReport.swift"` to `DionysusTV`'s Features includes in `project.yml`; `xcodegen generate`. Run on iOS unit. Expected: build failure, "cannot find 'PlaybackStatsReport'".

- [ ] **Step 3: Name the icon as iOS does; keep iOS's default**

No change to `PlayerPreferenceKeys.swift`: its `#if DEBUG` default is shared, so the Apple TV already gets iOS's on-in-debug, off-in-release (Benjamin, 2026-10-07). In `TVPlayerIconButton`, the stats icon's label becomes iOS's (`PlayerControlsOverlay`'s stats button): "Hide playback stats" while the panel is on, "Show playback stats" while off. Remove the "Stats for Nerds" entry from `Localizable.xcstrings` if nothing else uses it.

- [ ] **Step 4: Extract the report**

`DionysusPlayer/Features/Player/PlaybackStatsReport.swift`:

```swift
import AVFAudio
import SwiftUI
import UIKit

/// The playback stats rows, built once for both apps: iOS's
/// `PlaybackStatsOverlay` pages them, the Apple TV's `TVStatsPanel` shows
/// them on one page. Labels are technical and stay unlocalized, as they
/// were; section titles are localized.
enum PlaybackStatsReport {
    struct Row: Equatable, Identifiable {
        let label: String
        let value: String
        /// Keys the value's accessibility identifier where the label isn't
        /// unique (Video and Audio both have a "Decoder").
        let id: String

        init(_ label: String, _ value: String, id: String? = nil) {
            self.label = label
            self.value = value
            self.id = id ?? label
        }
    }

    struct Section: Equatable, Identifiable {
        let title: String
        let rows: [Row]
        var id: String { title }
    }

    /// The readings that come from UIKit and AVFAudio rather than the engine.
    struct DeviceReadings: Equatable {
        var audioOutputRoute: String?
        var audioOutputChannelCount: Int?
        var thermalState: ProcessInfo.ThermalState = .nominal
        var edrHeadroom: CGFloat = 1

        @MainActor
        static func current() -> DeviceReadings {
            DeviceReadings(
                audioOutputRoute: AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName,
                audioOutputChannelCount: AVAudioSession.sharedInstance().outputNumberOfChannels,
                thermalState: ProcessInfo.processInfo.thermalState,
                edrHeadroom: UIScreen.main.currentEDRHeadroom
            )
        }
    }
}
```

Then move into an `extension PlaybackStatsReport`, from `PlaybackStatsOverlay`, **verbatim and with their doc comments**: `appVersion`, `aetherEngineVersion`, `deviceModelIdentifier`, `screenSize`, `refreshRateHz`, `describeChannelCount`, `describeBuffered`, `formatKB`, `describeEnhancementLayer`, `describePlayMethod`, `formatMbps`, `sourceResolutionText`, `sourceFrameRateText`, `sourceBitrateText`, `sourceChannelsText`, `describe(_ state: PlaybackState)`, `describe(_ thermalState:)`, `formatTime`. Rename `iOSVersion` to:

```swift
    /// "tvOS Version" on the Apple TV, "iOS Version" on iOS (the row's label
    /// is also its accessibility id, which iOS's journeys read).
    static let osVersionLabel: String = {
        #if os(tvOS)
        "tvOS Version"
        #else
        "iOS Version"
        #endif
    }()
    static let osVersion = UIDevice.current.systemVersion
```

Then turn each `@ViewBuilder` section of the overlay into a builder returning `Section`, keeping every row, label, fallback and condition exactly as the overlay has them:

```swift
extension PlaybackStatsReport {
    static func video(_ stats: PlaybackStats, sourceVideoStream stream: MediaStream?) -> Section {
        var rows: [Row] = [
            Row("Resolution", stats.videoSize ?? sourceResolutionText(stream) ?? "—"),
            Row("Frame Rate", stats.frameRate ?? sourceFrameRateText(stream) ?? "—"),
            Row("Bitrate", stats.bitrate ?? sourceBitrateText(stream) ?? "—"),
            Row("Codec", stats.videoCodec ?? StreamFormatDescription.codec(stream) ?? "—"),
            Row("Container", stats.container ?? "—"),
            Row("Pixel Format", stats.pixelFormat ?? StreamFormatDescription.pixelFormat(stream) ?? "—"),
            Row("Color", stats.colorDescription ?? StreamFormatDescription.color(stream) ?? "—"),
            Row("Source Color", stats.sourceColorFormat)
        ]
        if stats.sourceColorFormat.hasPrefix("Dolby Vision") {
            rows.append(Row("Enhancement Layer", describeEnhancementLayer(stream?.videoRangeType)))
        }
        rows.append(Row("Decoder", stats.videoDecoder ?? "—"))
        if let decoded = stats.decodedFormat { rows.append(Row("Decoded", decoded)) }
        rows.append(Row("Backend", stats.backend))
        rows.append(Row("Route", stats.route))
        return Section(title: String(localized: "Video"), rows: rows)
    }

    static func audio(_ stats: PlaybackStats, sourceAudioStream: MediaStream?, readings: DeviceReadings) -> Section {
        let engineKnowsTrack = stats.audioChannels != nil
        let fallback = engineKnowsTrack ? nil : sourceAudioStream
        return Section(title: String(localized: "Audio"), rows: [
            Row("Decoder", stats.audioDecoder ?? "—", id: "Audio Decoder"),
            Row("Source Channels", stats.audioChannels ?? sourceChannelsText(sourceAudioStream) ?? "—"),
            Row("Profile", stats.audioProfile ?? fallback?.profile ?? "—"),
            Row("Sampling", stats.audioSampling ?? StreamFormatDescription.audioSampling(fallback) ?? "—"),
            Row("Output Route", readings.audioOutputRoute ?? "—"),
            Row("Output Channels", describeChannelCount(readings.audioOutputChannelCount))
        ])
    }

    /// `zoomMode` is `nil` on the Apple TV, which has no zoom.
    static func playback(_ stats: PlaybackStats, state: PlaybackState, zoomMode: VideoZoomMode?) -> Section {
        var rows = [
            Row("State", describe(state)),
            Row("Position", "\(formatTime(stats.currentTime)) / \(formatTime(stats.duration))"),
            Row("Buffered", describeBuffered(seconds: stats.bufferedSeconds, bytes: stats.bufferedBytes)),
            Row("Live Bitrate", stats.liveBitrate ?? "—"),
            Row("Throughput", stats.networkThroughput ?? "—"),
            Row("Frames", stats.frames ?? "—")
        ]
        if let zoomMode { rows.append(Row("Zoom", zoomMode == .fill ? "Fill" : "Fit")) }
        return Section(title: String(localized: "Playback"), rows: rows)
    }

    static func display(_ stats: PlaybackStats, readings: DeviceReadings) -> Section {
        Section(title: String(localized: "Display"), rows: [
            Row("Screen", "\(Int(screenSize.width))×\(Int(screenSize.height)) pt"),
            Row("Displayed Color", stats.displayColorFormat),
            Row("Refresh Rate", "\(refreshRateHz) Hz"),
            Row("EDR Headroom", String(format: "%.2fx", readings.edrHeadroom)),
            Row("Thermal State", describe(readings.thermalState))
        ])
    }

    static func streaming(isOffline: Bool, serverVersion: String?, session: SessionInfoDto?) -> Section {
        guard !isOffline else {
            return Section(title: String(localized: "Playback Source"), rows: [Row("Play Method", "Download")])
        }
        var rows = [
            Row("Jellyfin Server", serverVersion ?? "—"),
            Row("Play Method", describePlayMethod(session?.playState?.playMethod))
        ]
        if let transcoding = session?.transcodingInfo {
            rows.append(Row("Transcode Video", transcoding.videoCodec ?? "—"))
            rows.append(Row("Transcode Audio", transcoding.audioCodec ?? "—"))
            rows.append(Row("Transcode Bitrate", transcoding.bitrate.map(formatMbps) ?? "—"))
            if let width = transcoding.width, let height = transcoding.height {
                rows.append(Row("Transcode Size", "\(width)×\(height)"))
            }
            rows.append(Row("Completion", transcoding.completionPercentage.map { String(format: "%.0f%%", $0) } ?? "—"))
            if let reasons = transcoding.transcodeReasons, !reasons.isEmpty {
                rows.append(Row("Reasons", reasons.joined(separator: ", ")))
            }
        }
        return Section(title: String(localized: "Streaming"), rows: rows)
    }

    static func build() -> Section {
        Section(title: String(localized: "Build"), rows: [
            Row("App Version", appVersion),
            Row("AetherEngine Version", aetherEngineVersion),
            Row("Device", deviceModelIdentifier),
            Row(osVersionLabel, osVersion)
        ])
    }
}
```

In `PlaybackStatsOverlay`, replace the four `@State` readings with `@State private var readings = PlaybackStatsReport.DeviceReadings()`, set it in `pollWhileVisible` with `readings = .current()`, delete the moved statics, and render each page from the report:

```swift
    @ViewBuilder
    private func pageContent(_ page: Int, _ stats: PlaybackStats) -> some View {
        let sections: [PlaybackStatsReport.Section] = switch page {
        case 0: [PlaybackStatsReport.video(stats, sourceVideoStream: viewModel.sourceVideoStream)]
        case 1: [
            PlaybackStatsReport.audio(stats, sourceAudioStream: viewModel.sourceAudioStream, readings: readings),
            PlaybackStatsReport.playback(stats, state: viewModel.state, zoomMode: zoomMode)
        ]
        default: [
            PlaybackStatsReport.display(stats, readings: readings),
            PlaybackStatsReport.streaming(isOffline: viewModel.isOfflinePlayback, serverVersion: viewModel.serverVersion, session: viewModel.streamingSession),
            PlaybackStatsReport.build()
        ]
        }
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                Text(section.title).bold().padding(.top, index == 0 ? 0 : 4)
                ForEach(section.rows) { item in row(item.label, item.value, id: item.id) }
            }
        }
    }
```

Delete the six `…Section` view builders. Run `PlaybackStatsReportTests` on iOS unit and tvOS unit, then iOS UI `-only-testing:DionysusPlayerUITests/PlayerJourneyTests` (the stats journey reads "Codec", "Pixel Format", "Sampling", "Frames"). Expected: pass, identical labels and values.

- [ ] **Step 5: Write the TV panel**

Add identifiers:

```swift
            static let statsPanel = "tv.player.stats"
            static func statsValue(_ id: String) -> String { "tv.player.stats.\(id)" }
```

`DionysusTV/Player/TVStatsPanel.swift`:

```swift
import SwiftUI

/// The playback stats panel on the Apple TV: one glass page top-right, every row of
/// iOS's three pages (`PlaybackStatsReport`), refreshed twice a second. A
/// toggle on its icon; it takes no presses (Benjamin, 2026-10-06).
struct TVStatsPanel: View {
    let viewModel: PlayerViewModel

    @State private var stats: PlaybackStats?
    @State private var readings = PlaybackStatsReport.DeviceReadings()

    private static let pollInterval: Duration = .milliseconds(500)
    /// `/Sessions` is a network round-trip; every 5s is plenty.
    private static let streamingPollTicks = 10

    var body: some View {
        Group {
            if let stats {
                HStack(alignment: .top, spacing: 40) {
                    column([
                        PlaybackStatsReport.video(stats, sourceVideoStream: viewModel.sourceVideoStream),
                        PlaybackStatsReport.audio(stats, sourceAudioStream: viewModel.sourceAudioStream, readings: readings)
                    ])
                    column([
                        PlaybackStatsReport.playback(stats, state: viewModel.state, zoomMode: nil),
                        PlaybackStatsReport.display(stats, readings: readings),
                        PlaybackStatsReport.streaming(isOffline: false, serverVersion: viewModel.serverVersion, session: viewModel.streamingSession),
                        PlaybackStatsReport.build()
                    ])
                }
            } else {
                Text("Gathering stats…").font(.callout)
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 28)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 36))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.TV.Player.statsPanel)
        .task { await poll() }
    }

    private func column(_ sections: [PlaybackStatsReport.Section]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                Text(section.title)
                    .font(.headline)
                    .padding(.top, index == 0 ? 0 : 14)
                ForEach(section.rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(row.label)
                            .foregroundStyle(.secondary)
                            .frame(width: 210, alignment: .leading)
                        Text(row.value)
                            .fontWeight(.semibold)
                            .lineLimit(2)
                            .accessibilityIdentifier(A11yID.TV.Player.statsValue(row.id))
                    }
                    .font(.system(size: 21))
                }
            }
        }
        .frame(width: 440, alignment: .leading)
    }

    private func poll() async {
        var tick = 0
        while !Task.isCancelled {
            stats = viewModel.stats
            readings = .current()
            if tick % Self.streamingPollTicks == 0 {
                await viewModel.refreshServerVersion()
                await viewModel.refreshStreamingSession()
            }
            tick += 1
            try? await Task.sleep(for: Self.pollInterval)
        }
    }
}
```

In `TVPlayerOverlay`, between the subtitles and the transport:

```swift
            if input.state.isStatsOn, input.context().statsButtonEnabled {
                TVStatsPanel(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.opacity)
            }
```

(inside the safe area, so it sits at the HIG's insets, top-right, clear of the title block).

- [ ] **Step 6: Write the journeys**

`DionysusTVUITests/PlayerStatsJourneyTests.swift`:

```swift
import XCTest

final class PlayerStatsJourneyTests: TVUITestCase {
    func test_statsIcon_isAbsentWhileTheSettingIsOff() {
        let app = openPlayer(extraArguments: ["-UITestDisableControlAutoHide", "YES", "-showPlaybackStatsButtonEnabled", "NO"])
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.icon("chapters")].exists)
        XCTAssertFalse(app.descendants(matching: .any)[A11yID.TV.Player.icon("stats")].exists)
    }

    /// The icon toggles the panel; Menu and Select don't close it.
    func test_statsIcon_togglesThePanel_whichIgnoresMenuAndSelect() {
        let app = openPlayer(extraArguments: ["-UITestDisableControlAutoHide", "YES", "-showPlaybackStatsButtonEnabled", "YES"])
        press(.up)
        press(.right, times: 3)
        XCTAssertTrue(waitForPlayerFocus(app, "icon.stats"))
        press(.select)
        let panel = app.descendants(matching: .any)[A11yID.TV.Player.statsPanel]
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.statsValue("Codec")].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts[A11yID.TV.Player.statsValue("Codec")].label, "HEVC Main 10")
        press(.menu)
        XCTAssertTrue(waitForPlayerFocus(app, "scrubber"))
        press(.select)
        XCTAssertTrue(panel.exists, "Neither Menu nor Select closes it")
        press(.up)
        press(.right, times: 3)
        XCTAssertTrue(waitForPlayerFocus(app, "icon.stats"))
        press(.select)
        XCTAssertTrue(poll(timeout: 3) { !panel.exists })
    }
}
```

Add to `AccessibilityAuditTests` a `test_playerStats` opening the panel as above and auditing.

- [ ] **Step 7: Run, check, document, commit PR 5's code**

Run tvOS unit, tvOS UI, iOS unit, iOS smoke, and iOS UI `PlayerJourneyTests` (the stats extraction touches iOS). On the Simulator with the LAN server, open Stats on a direct-play title and on a transcode (Profile → Streaming), and screenshot both. Update CLAUDE.md's player paragraph:

```markdown
**Playback stats** is a toggle on its icon, never a tab and never modal:
one glass page top-right with every row of iOS's three pages
(`PlaybackStatsReport`, shared, which iOS's overlay pages). Its setting is
iOS's, shared: on in debug builds, off in release. The icon is labelled as
iOS's button is ("Show playback stats" / "Hide playback stats").
```

and delete the sentence "Next Episode Countdown, Chapters in Scrubber, Subtitle Styling and Show Playback Stats Button are stored but change nothing on tvOS until M4 brings their player features" from the Profile paragraph. After sign-off commit and push; the PR opens after Task 11.

---

### Task 11: The device pass, tuning and the milestone's docs

**Files:**
- Modify (as findings require): `DionysusTV/Player/TVPlayerInputModel.swift` (`TVPlayerTiming`), `TVPlayerInputModel+Scrub.swift` (`TVScrubMetrics`), `DionysusPlayer/Features/Player/SubtitleOverlayView.swift` (`SubtitleOverlayMetrics.tv`) and their tests, `CLAUDE.md`, `docs/superpowers/specs/2026-10-06-tvos-player-features-design.md`, `docs/superpowers/specs/2026-09-29-tvos-app-design.md`, memory `open-issues-and-follow-ups.md`

- [ ] **Step 1: Ask Benjamin for the Bedroom Apple TV**

The only hardware step in M4. Ask him to wake the TV and say when; build and install with the steps in memory `physical-device-cli-deployment` (Debug, the branch build).

- [ ] **Step 2: Gather the HDR evidence (throwaway logging, never committed)**

On a scratch branch from the PR 5 branch, add to `TVPlayerHostController.viewDidAppear` a 1 Hz `Task` that prints, with `print("[HDRProbe] …")`:
- `AVDisplayManager`'s state (`view.window?.avDisplayManager.isDisplayCriteriaMatchingEnabled`, `.isDisplayModeSwitchInProgress`, `.preferredDisplayCriteria`);
- `viewModel.videoFormatDescription`;
- the engine's `sourceVideoFormat` and `videoFormat` (through `AetherPlaybackEngine.hostEngine`);
- for the native route, the current `AVPlayerItem`'s first video track's `CMFormatDescription` transfer function (`kCMFormatDescriptionExtension_TransferFunction`).

Capture the console (memory `physical-device-cli-deployment`, console capture). Play: an HDR10 title on direct play; a DV title; an HDR AV1 or VP9 title (the software route); and the HDR10 title forced to transcode (Profile → Streaming → a low Max Streaming Bitrate). For each, note what the TV's own info banner says and what each reading says, once the switch has settled.

Decide with Benjamin. If a reading tracks the TV's banner where `videoFormat` reads SDR (software route, transcode), draft an AetherEngine issue that proposes it as evidence for `videoFormat`, quoting the measurements. Benjamin files it, or approves filing it. If none does, record that in CLAUDE.md's HDR paragraph. Delete the scratch branch.

- [ ] **Step 3: Tune against Infuse**

On the same titles in Infuse and Dionysus, with Benjamin holding the remote:
- **Swipe ratio:** how far one full swipe moves the preview. Change `TVScrubMetrics.fullSwipeFractionOfDuration` until it feels like Infuse's.
- **Scan steps:** the hold ramp (`TVPlayerTiming.scanSpeeds`, `scanStepInterval`).
- **Subtitle size:** set `SubtitleOverlayMetrics.tv.fontSize` so a line matches Infuse's default size on the same scene, photographed from the sofa.
- **libass cost:** an ASS-heavy scene on a 4K picture plays without dropped frames (Stats' Frames row).
- **Atmos:** switching to an Atmos track in the panel keeps passthrough (Stats' Output Channels and the AVR's display).

Update each changed constant's test (`TVPlayerScrubTests`, `SubtitleOverlayLayoutTests`), rerun those classes, and note each value and its reason in the constant's doc comment ("Matched to Infuse on the Bedroom Apple TV, 2026-10-…").

- [ ] **Step 4: Close the milestone's docs**

- **CLAUDE.md's HDR paragraph:** replace "The HDR label still can't be trusted on its own: … a session that falls back would still read SDR." with:

  "The label is one-sided: AetherEngine claims HDR only on evidence (AE#459, since 6.82.0): AVPlayer still playing an HDR master 500ms after it was served, or EDR headroom above 1.00, which reads a flat 1.00 here. Checked across every 7.x release (2026-10-06): 7.1.0, 7.10.1, 7.22.2 and 7.23.2 each removed a way it read SDR wrongly, and none moved the rule. It can still read SDR on an HDR picture for the first half second, after a fallback to the media playlist, on the software route and on a server transcode."

  Follow it with Step 2's device findings, dated.
- **The M4 spec:** add a "Delivered" line listing PRs 1–5 by number.
- **The tvOS app spec:** the M4 milestone line gains "(done: PRs #…)".
- **Memory:** in `open-issues-and-follow-ups.md`, delete the closed M1 minor ("`skip(by:)` before the duration is known seeks to 0") and "Still to do on Bedroom: scrubbing vs Infuse". Add anything found and left open.

- [ ] **Step 5: Suites, sign-off, commit, PR 5**

Run tvOS unit, tvOS UI, iOS unit, iOS smoke one after another. After Benjamin's sign-off commit, push, open "tvOS M4 PR 5: Playback stats, the device pass and tuning", and merge with `--merge` when checks pass. M4 is then done; M5 (accessibility) starts with brainstorming.
