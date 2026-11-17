# Night Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One Night Mode switch in the player (iOS and Apple TV) over three
saved levels (Night Audio, Volume Limit, Brightness), remembered until turned
off, with an optional on/off schedule in Profile.

**Architecture:** A pure settings and schedule core in `Core/` (store, rules,
an `@Observable` controller) that both apps compile. The player view model
turns the controller's effect into three engine and view inputs: AetherEngine
audio shaping, engine output volume, and a dimming layer's opacity. The UI is
a panel per platform plus a Profile page per platform. A feasibility gate on
the Living Room Apple TV sits between the Apple TV player and everything
after it, because its result decides the Volume Limit row's note.

**Tech Stack:** Swift 6, SwiftUI (UIKit host on tvOS), AetherEngine 7.66.0
(`setAudioShaping`, `AudioShaping.Compressor.night`, `audioShapingState`,
`volume`, `LoadOptions.audioShaping`, all confirmed present at the 7.66.0
tag, 2026-11-16), XCTest and XCUITest.

**Spec:** `docs/superpowers/specs/2026-11-16-night-mode-design.md`

**Issue:** #363 ("[Feature] Night / Sleep mode"). The PR body says `Closes #363`.

## Global Constraints

- Platforms: iOS 18 floor, tvOS 26.0 floor; Xcode 27.1 in CI, 27.2 locally.
- AetherEngine stays pinned at `exact: "7.66.0"`. No engine change is needed.
- Levels: `0...100`, step `5`, both Volume Limit and Brightness.
- Defaults: Night Mode off, Night Audio on, Volume 100%, Brightness 100%,
  schedule off, 22:00 on, 07:00 off.
- Storage is per device, shared by every user: `AudioOffsetStore.platformStorage`
  (UserDefaults on iOS, shared keychain on tvOS), as `SpatialAudioStore`.
- Night Audio = `AudioShaping(compressor: .night)`; off = `AudioShaping()`.
- Brightness dims video **and subtitles**, never controls, panels, Stats,
  Skip, Next Up or the version question. Picture in Picture is not dimmed.
- `PlaybackEngine` changes land in the protocol, `AetherPlaybackEngine`,
  `PreviewPlaybackEngine` and the test `FakePlaybackEngine` together.
- Copy (exact): "Night Mode", "Night Audio", "Volume Limit", "Brightness",
  "Limits dynamic range. Turns off Atmos and passthrough while on." (Benjamin, 2026-11-16, replacing "Turns off Atmos and receiver passthrough while on."), "Not available for
  this stream", "Schedule", "Turn On", "Turn Off", "The schedule never turns
  Night Mode on or off while both times are the same."
- Strings go through `Localizable.xcstrings`, synced by an Xcode.app build in
  the same PR (`CLAUDE.md`, Localization).
- Never select on accessibility labels in UI tests; no identifier on a
  screen-root container; decorative SF Symbols `.accessibilityHidden(true)`.
- Views that change under VoiceOver read `@VoiceOverEnabled`.
- Simulators: iPhone 17 and Apple TV 4K (4th generation); never the Duo
  unless a fold check needs it; boot only when needed, shut down after.
- **Never touch a physical device without asking Benjamin first, per
  command** (the feasibility gate).
- Commit only after Benjamin's sign-off; no Claude session URL in commits.

## Review Focus

1. **Night Audio and Spatial Audio rebuild order.** Night Audio turned off
   mid-film on a TrueHD Atmos title with Spatial Audio on must end in the
   rendered bed, not the DD+ bridge: shaping off first, then
   `correctSpatialAudio`. Test in Task 3.
2. **A boundary passing while the player is open** (22:00 arrives mid-film)
   must dim and compress at once, without the user touching anything. Test
   in Task 2 (controller wake) and Task 3 (view model follows the effect).
3. **Next Up / auto-advance and Restart load a new session**: the new load
   must carry Night Audio and the volume, not reset them. Test in Task 3.
4. **Quick repeated toggles** (Night Audio on/off/on within a second) must
   not queue three rebuilds; AetherEngine folds them, and the view model must
   not await each. Test in Task 3 with the fake recording calls.
5. **A server transcode** (`isRemoteHLS`) with Night Audio on must say "Not
   available for this stream" while volume and brightness still apply. Test
   in Task 3 (state) and Task 6 (journey row).

---

### Task 1: Settings, store and schedule rules

**Files:**
- Create: `DionysusPlayer/Core/NightMode/NightModeSettings.swift`
- Create: `DionysusPlayer/Core/NightMode/NightModeStore.swift`
- Create: `DionysusPlayer/Core/NightMode/NightModeScheduleRules.swift`
- Test: `DionysusPlayerTests/Core/NightMode/NightModeStoreTests.swift`
- Test: `DionysusPlayerTests/Core/NightMode/NightModeScheduleRulesTests.swift`
- Modify: `project.yml` only if `Core/NightMode` isn't picked up by the
  targets' existing `Core/` globs (DionysusTV includes `Core/`; the Top Shelf
  extension must **not** compile it). Then `xcodegen generate`.

**Interfaces:**
- Produces:
  - `struct TimeOfDay: Equatable, Sendable { var hour: Int; var minute: Int; var minutesSinceMidnight: Int }`
  - `struct NightModeSchedule: Equatable, Sendable { var isEnabled: Bool; var turnOn: TimeOfDay; var turnOff: TimeOfDay; var neverTriggers: Bool /* turnOn == turnOff */ }`
  - `struct NightModeSettings: Equatable, Sendable { var isOn: Bool; var nightAudio: Bool; var volumePercent: Int; var brightnessPercent: Int; var schedule: NightModeSchedule; static let defaults: NightModeSettings; var effect: NightModeEffect }`
  - `struct NightModeEffect: Equatable, Sendable { var nightAudio: Bool; var volume: Float; var dimOpacity: Double; static let none: NightModeEffect }` (`effect` is `.none` when `isOn` is false; otherwise `volume = volumePercent / 100`, `dimOpacity = 1 - brightnessPercent / 100`)
  - `enum NightModeLevel { static let range = 0...100; static let step = 5; static func clamped(_ percent: Int) -> Int }` (round to nearest 5, then clamp)
  - `final class NightModeStore { init(storage: AudioOffsetStorage = AudioOffsetStore.platformStorage); var settings: NightModeSettings; var lastBoundaryApplied: Date? }`, keys prefixed `nightMode.`
  - `enum NightModeScheduleRules { static func boundaryToApply(schedule: NightModeSchedule, lastApplied: Date?, now: Date, calendar: Calendar) -> (date: Date, turnsOn: Bool)?; static func nextBoundary(after now: Date, schedule: NightModeSchedule, calendar: Calendar) -> Date? }`

- [ ] **Step 1: Write the failing store tests** in `NightModeStoreTests`
  over an in-memory `AudioOffsetStorage`:
  `test_defaults_whenNothingStored` (asserts `NightModeSettings.defaults`:
  off, nightAudio true, 100, 100, schedule off 22:00/07:00);
  `test_roundTrip_keepsEveryField`;
  `test_levels_clampAndSnapToFive` (`clamped(-5) == 0`, `clamped(103) == 100`,
  `clamped(42) == 40`, `clamped(43) == 45`; a stored 43 reads back 45);
  `test_effect_offIsNone`, `test_effect_onMapsLevels` (60% → `volume == 0.6`,
  40% → `dimOpacity == 0.6`).
- [ ] **Step 2: Write the failing rules tests** in
  `NightModeScheduleRulesTests` with a fixed `Calendar` in `Europe/London`:
  - `test_noBoundary_whenScheduleOff`
  - `test_noBoundary_whenNeverApplied` (lastApplied nil → nil: enabling
    changes nothing until the next boundary)
  - `test_turnsOn_atStart` (22:00 window, lastApplied 21:00, now 22:00 → on)
  - `test_turnsOff_atEnd_acrossMidnight` (22:30→07:00, lastApplied 23:00,
    now 07:05 next day → off)
  - `test_missedBoundaries_collapseToLatest` (lastApplied two days ago at
    20:00, now 23:00 → the 22:00 on, not an earlier off)
  - `test_noBoundary_whenEqualTimes`
  - `test_nextBoundary_isTheNearestEither` (now 06:00, 22:00→07:00 → 07:00
    today; now 08:00 → 22:00 today)
  - `test_dstSpringForward_stillFires` (on time 01:30 on the March change
    day in London resolves to a real instant, not skipped)
- [ ] **Step 3: Run both, expect FAIL** (types not defined):
  `xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DionysusPlayerTests/NightModeStoreTests -only-testing:DionysusPlayerTests/NightModeScheduleRulesTests`
- [ ] **Step 4: Implement the three files.** Boundaries come from
  `calendar.nextDate(after:matching:matchingPolicy: .nextTime)` per time, so
  a DST gap moves the time forward rather than skipping the day.
- [ ] **Step 5: Run, expect PASS**, and the same suite under the TV scheme:
  `xcodebuild test … -scheme DionysusTV -testPlan TVUnitTests -destination 'platform=tvOS Simulator,name=Apple TV 4K (4th generation)' -only-testing:DionysusTVTests/NightModeStoreTests`
  (add the test files to `DionysusTVTests` sources if the shared-test glob
  doesn't already cover `Core/`).
- [ ] **Step 6: Commit** `Add Night Mode settings, store and schedule rules`.

### Task 2: The Night Mode controller

**Files:**
- Create: `DionysusPlayer/Core/NightMode/NightModeController.swift`
- Test: `DionysusPlayerTests/Core/NightMode/NightModeControllerTests.swift`

**Interfaces:**
- Consumes: Task 1's `NightModeStore`, `NightModeSettings`, `NightModeEffect`, `NightModeScheduleRules`.
- Produces:
  - `@Observable @MainActor final class NightModeController`
    - `static let shared: NightModeController`
    - `init(store: NightModeStore = NightModeStore(), now: @escaping () -> Date = Date.init, calendar: Calendar = .current, schedulesWakes: Bool = true)`
    - `private(set) var settings: NightModeSettings`
    - `var effect: NightModeEffect { settings.effect }`
    - `func setOn(_ on: Bool)`, `func setNightAudio(_ on: Bool)`, `func setVolumePercent(_ p: Int)`, `func setBrightnessPercent(_ p: Int)`, `func setSchedule(_ s: NightModeSchedule)`
    - `func evaluate()`: applies `boundaryToApply`, stores `lastBoundaryApplied`, reschedules the wake
    - `func observeEffect(_ handler: @escaping @MainActor (NightModeEffect) -> Void) -> NightModeObservation` (fires on every effect change, not on unchanged writes; `NightModeObservation.cancel()`; cancelled on deinit)

- [ ] **Step 1: Write the failing tests** with an injected clock and
  `schedulesWakes: false`:
  - `test_setOn_persistsAndChangesEffect`
  - `test_setSchedule_enabling_recordsNowAsApplied_andChangesNothing` (on at
    23:00 inside a 22:00 window: `isOn` unchanged)
  - `test_evaluate_afterStart_turnsOn_andNotifiesObserver`
  - `test_manualOff_insideWindow_holdsUntilNextStart` (off by hand at 23:00;
    evaluate at 06:00 → still off; at 22:00 next day → on)
  - `test_scheduleOff_keepsCurrentValue`
  - `test_observer_notCalled_forUnchangedEffect` (level change while off)
  - `test_wake_isAtNextBoundary` (expose `nextWake: Date?` internal for tests)
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** Wake: one `Task` sleeping until `nextWake`,
  replaced on every change. Also `evaluate()` on
  `UIApplication.willEnterForegroundNotification` and
  `UIApplication.significantTimeChangeNotification`. `setSchedule` that
  enables or edits times sets `lastBoundaryApplied = now()`.
- [ ] **Step 4: Run, expect PASS** (iOS and TV unit plans, as Task 1).
- [ ] **Step 5: Commit** `Add the Night Mode controller with its schedule wake`.

### Task 3: Engine protocol and the player view model

**Files:**
- Modify: `DionysusPlayer/Core/Playback/PlaybackEngine.swift` (protocol and its `load` convenience overloads)
- Modify: `DionysusPlayer/Core/Playback/AetherPlaybackEngine.swift` (`makeLoadOptions`, `load`, new members)
- Modify: `DionysusPlayer/Core/Playback/PreviewPlaybackEngine.swift`
- Modify: `DionysusPlayerTests/Support/FakePlaybackEngine.swift`
- Modify: `DionysusPlayer/Core/Playback/PlaybackTypes.swift` (`NightAudioState`)
- Modify: `DionysusPlayer/Features/Player/PlayerViewModel.swift`
- Modify: `DionysusPlayer/Features/Player/PlaybackStatsReport.swift` (a "Night Mode" row in the audio section)
- Test: `DionysusPlayerTests/Core/Playback/AetherPlaybackEngineLoadOptionsTests.swift`
- Test: `DionysusPlayerTests/Features/Player/PlayerViewModelNightModeTests.swift`
- Test: `DionysusPlayerTests/Features/Player/PlaybackStatsReportTests.swift`

**Interfaces:**
- Consumes: Task 2's `NightModeController`, `observeEffect`, `NightModeEffect`.
- Produces:
  - `enum NightAudioState: Equatable { case off, applied, unavailable }` (mapped 1:1 from AetherEngine's `AudioShapingState`)
  - `PlaybackEngine`:
    - `load(url:externalSubtitles:knownAtmosAudioTrackIndices:isRemoteHLS:audioOffset:spatialAudio:nightAudio: Bool)` (the existing overloads pass `false`)
    - `func setNightAudio(_ on: Bool)` (no await: AetherEngine rebuilds on its own task and folds repeats)
    - `var nightAudioState: NightAudioState { get }`, `var onNightAudioStateChange: ((NightAudioState) -> Void)? { get set }`
    - `var outputVolume: Float { get set }` (forwards `AetherEngine.volume`)
  - `AetherPlaybackEngine.makeLoadOptions(…, nightAudio: Bool = false)` sets `options.audioShaping`.
  - `PlayerViewModel`:
    - init param `nightMode: NightModeController = .shared`
    - `private(set) var videoDimOpacity: Double`
    - `private(set) var nightAudioState: NightAudioState`
    - `var nightMode: NightModeController { get }` (the panels bind to it)
  - `FakePlaybackEngine`: `private(set) var nightAudioCalls: [Bool]`, `loadedNightAudio: Bool?`, `outputVolume`, and `.setNightAudio(Bool)` appended to `audioEvents`.
  - `PreviewPlaybackEngine`: records the same and reports `nightAudioState` `.unavailable` for `isRemoteHLS` loads, else `.applied` while on.
  - `PlaybackStats` gains `nightMode: String?`; the report's audio section shows a "Night Mode" row only while it's non-nil: "Night Audio · Volume 60% · Brightness 40%", with "Night Audio unavailable" in place of "Night Audio" when `.unavailable`; parts at their normal value are omitted. UI journeys read this row.

- [ ] **Step 1: Write the failing load-options test**
  `test_nightAudio_setsNightCompressor` (`makeLoadOptions(…, nightAudio: true).audioShaping == AudioShaping(compressor: .night)`;
  false → `AudioShaping()`).
- [ ] **Step 2: Write the failing view-model tests** in
  `PlayerViewModelNightModeTests` (controller over an in-memory store,
  `schedulesWakes: false`, the fake engine):
  - `test_start_loadsWithNightAudioAndVolume_whenOn` (`loadedNightAudio == true`, `outputVolume == 0.6`, `videoDimOpacity == 0.6`)
  - `test_start_loadsPlain_whenOff` (false, 1.0, 0)
  - `test_turningOn_midSession_appliesAll` (one `setNightAudio(true)`)
  - `test_levelChange_appliesVolumeAndDim_withoutRebuild` (no new `nightAudioCalls` entry)
  - `test_nightAudioOff_beforeSpatialCorrection` (Atmos track, Spatial Audio
    on: `audioEvents` ends `[.setNightAudio(false), .setSpatialAudio(.render(...))]`)
  - `test_loadsWithSpatialOff_whileNightAudio` (avoid a wasted bed rebuild)
  - `test_nextItem_keepsNightSettings` (the next view model's load carries them)
  - `test_rapidToggles_callEngineEachTime_withoutAwaiting` (three calls recorded, none awaited)
  - `test_remoteHLS_reportsUnavailable` (state from the fake's callback)
  - `test_boundaryDuringPlayback_applies` (controller `evaluate()` past start
    → view model updates)
- [ ] **Step 3: Write the failing stats-row tests** in
  `PlaybackStatsReportTests`: `test_nightModeRow_listsActiveParts`,
  `test_nightModeRow_saysUnavailable`, `test_noNightModeRow_whenOff`.
- [ ] **Step 4: Run all three, expect FAIL.**
- [ ] **Step 5: Implement.** In `AetherPlaybackEngine` follow
  `engine.$audioShapingState` like `$videoRoute`. In `PlayerViewModel`,
  subscribe with `observeEffect` in init, cancel in `stop()`; on Night Audio
  off with Spatial Audio relevant, call `setNightAudio(false)` then
  `correctSpatialAudio(forEngineTrackID:)`; while Night Audio is in force,
  load with `spatialAudio: .off` and skip `correctSpatialAudio`.
- [ ] **Step 6: Run, expect PASS**; then the full `UnitTests` and
  `TVUnitTests` plans (the protocol change touches every conformer).
- [ ] **Step 7: Commit** `Apply Night Mode to the engine and the player view model`.

### Task 4: Apple TV player: the dimming layer, the Night tab and the moon

**Files:**
- Modify: `DionysusTV/Player/TVPlayerOverlay.swift` (dim layer between `SubtitleOverlayView` and `controls`; in `.accessibleLayer` role it draws nothing, since that layer sits above everything)
- Modify: `DionysusTV/Player/TVPlayerInputModel.swift` (`TVPanelTab.night`, `TVNightPanelRow`)
- Modify: `DionysusTV/Player/TVPlayerInputModel+Panel.swift` (rows, Left/Right steps, Select)
- Modify: `DionysusTV/Player/TVPlayerCommandRunner.swift` (commands to the controller)
- Modify: `DionysusTV/Player/TVPlayerPanelView.swift` (the Night tab's content)
- Modify: `DionysusTV/Player/TVTransportOverlay.swift` (moon by the time)
- Modify: `DionysusTV/Player/TVPlayerContext+ViewModel.swift`
- Modify: `DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift` (`A11yID.TV.Player.night*`)
- Test: `DionysusTVTests/TVPlayerInputModelTests.swift`, `DionysusTVTests/TVPlayerAccessibleTransportTests.swift`
- Test: `DionysusTVUITests/PlayerPanelJourneyTests.swift`, `DionysusTVUITests/AccessibilityAuditTests.swift`

**Interfaces:**
- Consumes: Task 3's `PlayerViewModel.videoDimOpacity`, `nightAudioState`, `nightMode`.
- Produces:
  - `TVPanelTab.night` (id `"night"`, after `.subtitles`, `isList == true`)
  - `enum TVNightPanelRow: Equatable { case nightMode, nightAudio, volume, brightness, brightnessMin, brightnessMax }`
  - `TVPlayerCommand` cases `.setNightMode(Bool)`, `.setNightAudio(Bool)`, `.stepVolume(Int)`, `.stepBrightness(Int)`, `.setBrightness(Int)`
  - Identifiers: `tv.player.night.tab`, `tv.player.night.toggle`, `.nightAudio`, `.volume`, `.brightness`, `.brightnessMin`, `.brightnessMax`, `tv.player.night.indicator`. The dim layer is hidden from accessibility and has no identifier: journeys read its level from the Stats "Night Mode" row

- [ ] **Step 1: Write failing reducer tests**: Down from the Night tab to
  `.nightMode`; Select flips it (`.setNightMode(true)`); Left/Right on
  `.volume` emit `.stepVolume(-5)`/`(+5)`; Select on `.brightnessMin` emits
  `.setBrightness(0)`; Up/Down stay in the one column; the panel's 10 s
  timeout still applies.
- [ ] **Step 2: Write a failing accessible-transport test**: the Volume and
  Brightness rows are adjustable elements stepping 5.
- [ ] **Step 3: Write the failing journey** `test_nightTab_dimsAndShowsInStats`:
  open the panel, move to Night, turn it on, step Brightness down twice and
  Volume down once, assert the indicator exists and the Stats "Night Mode"
  row reads the levels (the session opened by a play link with Playback
  Stats on, `TESTING.md`'s deep-link table); Brightness 0% shortcut.
- [ ] **Step 4: Run, expect FAIL.**
- [ ] **Step 5: Implement.** The Night Audio row's note under it is the
  fixed copy; while `nightAudioState == .unavailable` it reads "Not
  available for this stream". Levels show greyed while Night Mode is off.
- [ ] **Step 6: Run the reducer tests and the journey, expect PASS**; add the
  Night tab to `AccessibilityAuditTests`' panel audit and run it.
- [ ] **Step 7: Commit** `Add the Night tab and dimming to the Apple TV player`.

### Task 5: Feasibility gate on the Living Room Apple TV (Benjamin present)

No code. **Ask Benjamin before every device command** (memory: never touch a
physical device without asking). Build Task 4's branch to the Living Room
Apple TV (`docs`: memory "Physical device CLI deployment").

- [ ] **Step 1: Volume Limit through the receiver.** Play a DD+ title
  (stream-copied, `audioDelivery == .streamCopy`) to the AVR; Night Mode on,
  Night Audio **off**, Volume Limit 20%. Record: does the level drop? Then a
  TrueHD title (bridged to DD+) and a PCM-bed Spatial Audio title. Then the
  TV's own speakers over HDMI (AVR bypassed or off), the same three.
- [ ] **Step 2: Detection.** If any route ignores the limit, log
  `engine.audioDelivery`, the output port type
  (`AVAudioSession.currentRoute.outputs`) and the source codec on each route,
  and decide whether a rule tells those routes apart.
- [ ] **Step 3: Brightness on HDR.** Brightness 40% on an HDR10 title and a
  Dolby Vision title (memory: Living Room per-format picks): even dimming,
  no banding or tone shift, controls at full brightness, subtitles dimmed.
- [ ] **Step 4: Night Audio audibly compresses** on a loud action scene;
  note the hitch on toggle.
- [ ] **Step 5: Record the outcome in the spec** under "Volume Limit and
  passthrough" (which of its three branches holds) and choose Task 5b's
  shape. Commit the spec change after sign-off.

### Task 5b: Volume Limit note (shape set by Task 5)

**Files:**
- Modify: `DionysusPlayer/Features/Player/PlayerViewModel.swift` (`volumeLimitNote: VolumeLimitNote?`)
- Modify: the two panels (Tasks 4 and 6) to show it under the Volume row
- Test: `DionysusPlayerTests/Features/Player/PlayerViewModelNightModeTests.swift`

**Interfaces:**
- Produces: `enum VolumeLimitNote: Equatable { case setOnReceiver, mayNotApplyThroughReceiver }`, with copy "Set on your receiver" / "May not apply when audio goes to a receiver".

- [ ] **Step 1:** If Task 5 found the limit works everywhere, delete this
  task and say so in the spec. Otherwise write the failing test for the rule
  Task 5 chose: detectable route → `.setOnReceiver` on that route only;
  undetectable → `.mayNotApplyThroughReceiver` always on the affected
  platform; never a note while Night Audio is applied.
- [ ] **Step 2: Run, FAIL; implement; run, PASS.**
- [ ] **Step 3: Commit** `Say when Volume Limit can't reach the receiver`.

### Task 6: iOS player: the dimming layer, the moon button and the panel

**Files:**
- Create: `DionysusPlayer/Features/Player/NightModePanel.swift`
- Modify: `DionysusPlayer/Features/Player/PlayerView.swift` (dim layer directly above `SubtitleOverlayView`, sized like it, below `PlaybackStatsOverlay`)
- Modify: `DionysusPlayer/Features/Player/PlayerControlsOverlay.swift` (moon button in `topSection`'s trailing `HStack`, before the tracks button; the panel as a hand-rolled `.overlay`, like the track picker)
- Modify: `DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift` (`A11yID.Player.night*`)
- Test: `DionysusPlayerTests/Features/Player/PlayerControlsOverlayTests.swift`
- Test: `DionysusPlayerUITests/Journeys/PlayerJourneyTests.swift` (or a new `NightModeJourneyTests.swift` beside it), `DionysusPlayerUITests/Journeys/AccessibilityAuditTests.swift`, `DionysusPlayerUITests/Journeys/VoiceOverJourneyTests.swift`

**Interfaces:**
- Consumes: Task 3's view-model members; Task 5b's `volumeLimitNote`.
- Produces: identifiers `player.night.button`, `player.night.toggle`, `.nightAudio`, `.volume`, `.brightness`, `.brightnessMin`, `.brightnessMax`, `.scheduleSummary`, `player.night.panel`.

- [ ] **Step 1: Write the failing overlay test**: the moon shows `moon` off
  and `moon.fill` on the white badge on (the rotation lock's on-state); label
  "Night Mode", value "On"/"Off".
- [ ] **Step 2: Write the failing journey** `test_nightPanel_appliesLevels`:
  tap the moon, turn on, Brightness − twice (90%), Volume − once (95%),
  assert the Stats "Night Mode" row reads them (Playback Stats on through
  the play link's stats parameter); Brightness 0%
  shortcut; close and reopen the player: still on, same levels.
  `test_nightPanel_transcodeSaysUnavailable` with the stub's transcode
  scenario. `test_nightPanel_scheduleSummary` (schedule on through the
  `-nightMode.schedule.enabled YES` launch argument, which UserDefaults'
  argument domain reads on iOS → "22:00–07:00").
- [ ] **Step 3: Write the failing VoiceOver journey**: under
  `-UITestSimulateVoiceOver`, Volume and Brightness are adjustable (swipe up
  +5).
- [ ] **Step 4: Run, expect FAIL.**
- [ ] **Step 5: Implement** the panel per the spec's sketch: −/+ step 5 with
  `.buttonRepeatBehavior(.enabled)`, levels greyed while off, the Night
  Audio note and the unavailable state, the schedule line (summary only).
  The dim layer is `Color.black.opacity(viewModel.videoDimOpacity)`,
  `.allowsHitTesting(false)`, `.accessibilityHidden(true)`, framed to
  `foldLayout.videoHeight` like the subtitles.
- [ ] **Step 6: Show Benjamin a screenshot of the panel (iPhone 17, landscape
  and portrait) and wait** before running the suites (memory: show visual
  changes before tests).
- [ ] **Step 7: Run the journeys and the audit, expect PASS.** Check the Duo
  tabletop by one screenshot: the dim covers only the picture above the fold.
- [ ] **Step 8: Commit** `Add the Night Mode panel and dimming to the iOS player`.

### Task 7: Profile: Night Mode page and schedule (both apps) and its link

**Files:**
- Create: `DionysusPlayer/Features/Profile/NightModeSettingsView.swift`
- Create: `DionysusTV/Shell/Profile/TVNightModePage.swift`
- Modify: `DionysusPlayer/Features/Profile/ProfileView.swift` (`ProfileSubpage.nightMode`; a "Night Mode" `NavigationLink` in `playbackRows` after Audio Offset, value "On"/"Off")
- Modify: `DionysusTV/Shell/Profile/TVProfileView.swift` (a Playback row opening a cover; the footer sentence "Night Mode quiets and dims playback, by hand or on a schedule.")
- Modify: `DionysusPlayer/Core/DeepLinks/DeepLinkProfilePage.swift` (`case nightMode`, path `["playback", "night"]`)
- Modify: each app's linked-Profile handling (iOS split/push, tvOS cover)
- Modify: `TESTING.md` (deep-link table: add `playback/night`; test tables)
- Test: `DionysusPlayerTests/Core/DeepLinks/DeepLinkLibraryTests.swift` (`DeepLinkProfilePageTests`)
- Test: `DionysusPlayerUITests/Journeys/ProfileJourneyTests.swift`, `DeepLinkJourneyTests.swift`, `AccessibilityAuditTests.swift`
- Test: `DionysusTVUITests/ProfileJourneyTests.swift`, `DeepLinkPlacesJourneyTests.swift`, `AccessibilityAuditTests.swift`

**Interfaces:**
- Consumes: Task 2's controller setters and `settings.schedule`.
- Produces: `DeepLink.ProfilePage.nightMode`; identifiers `profile.night.link`, `profile.night.toggle`, `.nightAudio`, `.volume`, `.brightness`, `.schedule`, `.turnOn`, `.turnOff`, `.sameTimesNote`; tvOS `tv.profile.night.*` plus `.turnOnHour`, `.turnOnMinute`, `.turnOffHour`, `.turnOffMinute`.

- [ ] **Step 1: Write the failing parser test**
  `test_playbackNight_isNightMode` (`profile/playback/night` → `.nightMode`;
  `profile/playback/NIGHT` too).
- [ ] **Step 2: Write the failing iOS journeys**: Profile → Night Mode,
  turn the schedule on, set Turn On to 21:30 with the `DatePicker` (wheel
  values by identifier), assert the player panel's summary reads it;
  equal times show the note; `dionysus://profile/playback/night` opens the
  page.
- [ ] **Step 3: Write the failing tvOS journeys**: the row opens the cover;
  the Turn On Hour picker (00–23) and Minute picker (00–55 by 5) set 21:30;
  Menu closes onto the row; the link opens the cover.
- [ ] **Step 4: Run, expect FAIL.**
- [ ] **Step 5: Implement.** iOS: `DatePicker(displayedComponents: .hourAndMinute)`
  per time, shown while Schedule is on, and the same switch and levels as the
  panel (reuse `NightModePanel`'s rows as a shared subview if it fits; it's
  the builder's call). tvOS: `TVSettingsRow`s, the pickers as
  `TVSettingsPicker` pages; the levels as rows stepping with Left/Right
  (the Audio Offset page's hold-to-repeat pattern).
- [ ] **Step 6: Screenshot both pages to Benjamin and wait**, then run the
  journeys and both audits, expect PASS.
- [ ] **Step 7: Commit** `Add the Night Mode page and schedule to Profile`.

### Task 8: Docs, strings and the full suites

**Files:**
- Modify: `DionysusPlayer/Core/Playback/CLAUDE.md` (a "Night Mode" section:
  shaping trades Atmos and passthrough, takes priority over Spatial Audio,
  rebuild order, unavailable on `.remoteBypass`, volume and the gate's
  finding, dim layer placement, PiP not dimmed)
- Modify: `DionysusTV/CLAUDE.md` (panel tabs list adds Night; Profile's
  Playback rows add Night Mode; the moon)
- Modify: `CLAUDE.md` root only if a rule emerged that binds other work
- Modify: `DionysusPlayer/Resources/Localizable.xcstrings` (Xcode.app build,
  memory "Automate Xcode string catalog sync")
- Check: `PRIVACY.md` and the privacy manifests need nothing (no new
  identifier, permission or destination; UserDefaults already declared).

- [ ] **Step 1: Sync the catalog** with an Xcode.app build and confirm every
  Global Constraints copy string is present.
- [ ] **Step 2: Write the docs.**
- [ ] **Step 3: Run the full plans**, one at a time (never unit and UI at
  once): `UnitTests`, `UITests-Smoke`, `UITests-Full` on iPhone 17,
  `TVUnitTests`, `TVUITests` on Apple TV 4K (4th generation). Expected: all
  pass; record counts.
- [ ] **Step 4: Restore the Simulators to SavareseHillFlix as Ben and shut
  them down** (memory: restore on hand-back).
- [ ] **Step 5: Commit** `Document Night Mode and sync its strings`, then
  after sign-off push and open the PR to `develop` with `Closes #363` in its body (concise, "Generated with
  Claude Code", no session URL).
