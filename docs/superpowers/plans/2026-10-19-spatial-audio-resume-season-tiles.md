# Spatial Audio, Resume after a rewatch, season tiles: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Offer Resume after a partial rewatch, caption season tiles with their show, and let TrueHD Atmos and DTS:X play with their height channels as Spatial Audio, each behind its own Profile toggle and speaker layout, on iOS and Apple TV.

**Architecture:** Parts 1 and 2 are fixes in the shared `MediaItem` model (plus tvOS's and Downloads' own Resume gates). Part 3 turns on AetherEngine 7.42.0's two object-audio traits through a local wrapper package, stores two per-device settings, predicts the playing track's format before load to choose `objectAudioRendering`, and corrects with `reloadAtCurrentPosition(applying:)` when the playing track needs a different option. Feature code sees only the app's own `SpatialAudioRendering`; `AetherPlaybackEngine` maps it to the engine's types.

**Tech Stack:** Swift 6, SwiftUI, XcodeGen, Swift Package Manager (package traits), AetherEngine 7.42.0, XCTest/XCUITest.

**Spec:** `docs/superpowers/specs/2026-10-19-spatial-audio-resume-season-tiles-design.md`

> **Update, 2026-10-20:** executed, then bumped to AetherEngine 7.44.0,
> which decodes DTS:X with FFmpeg and drops LibDTSX. The steps below that
> pin 7.42.0 or add LibDTSX's notices, its `LicenseDocumentTests` entry or
> `DTSX.framework` were undone by that bump (see the spec's update note).

## Global Constraints

- iOS floor 18, tvOS floor 26. Spatial Audio settings are hidden on iOS below 26 and wherever the engine component isn't built in.
- AetherEngine pinned exactly (`version:`/`exact:`), never a range; 7.42.0.
- Atmos layouts: 5.1.2, 5.1.4, 7.1.2, 7.1.4, 9.1.6. DTS:X layouts: 7.1.4, 9.1.6. Default 7.1.4 for both, both platforms.
- Both toggles default **off**. Settings are per device, shared by all users (tvOS: the shared keychain, as `AudioOffsetStore`; iOS: `UserDefaults`).
- On iOS, the 7.1.4 option reads "7.1.4 (Recommended for AirPods)"; a footer line instead if the row can't fit it.
- Layout names ("7.1.4") are formatted data, never localized. Every other new string goes through the String Catalog (`String(localized:)` outside views), synced by an Xcode.app build in the same PR.
- Feature code never imports AetherEngine; a playback behaviour change goes into `PlaybackEngine`, `AetherPlaybackEngine` and `PreviewPlaybackEngine` together.
- Never select on accessibility labels in UI tests; new controls get `A11yID` identifiers. Decorative SF Symbols are `.accessibilityHidden(true)`.
- `DTSX.framework` stays a separate dynamic framework. The Top Shelf extension never links AetherEngine.
- No tag pushes, no device commands without asking Benjamin; no commit without his sign-off.

## Review Focus

1. **A remembered audio choice that isn't the predicted track** (viewer picked the DTS:X track last time, the default is TrueHD Atmos, both toggles on with different layouts): one corrective reload, landing on the remembered track at the resume position, not a loop. Pinned in Task 6.
2. **Atmos on, DTS:X off, viewer switches from the Atmos track to the DTS:X track mid-film:** DTS:X must play on today's path (rendering `.off`), not inherit the Atmos layout. Pinned in Task 6.
3. **A played movie whose position is 0** (finished, never rewatched) still says Play, and a Series marked played still says Play. Pinned in Task 1.
4. **A season with no `seriesName`** (a server that omits it) keeps a one-line caption with its own name, no empty title. Pinned in Task 2.
5. **Offline (downloaded) playback and server transcodes** load with rendering `.off` and never trigger a corrective reload, whatever the settings. Pinned in Task 6.

---

### Task 1: Resume after a rewatch

**Files:**
- Modify: `DionysusPlayer/Core/Models/MediaItem.swift` (`isPartWatched`, ~line 335)
- Modify: `DionysusTV/Browse/Detail/TVDetailActions.swift` (`hasResume`), `DionysusTV/Browse/Detail/TVDetailFormat.swift` (`playTitle`)
- Modify: `DionysusPlayer/Features/Downloads/Components/DownloadedPlayResumeButtonRow.swift`
- Test: `DionysusPlayerTests/Core/Models/MediaItemTests.swift` (or the existing model test file), `DionysusTVTests/` detail-format tests, a Downloads row test if one exists

**Interfaces:**
- Produces: `MediaItem.canResume: Bool`: true when `resumePositionSeconds > 0` for an item with its own position (anything but `.series`/`.season`), whatever `isPlayed`; for `.series`/`.season`, today's `isPartWatched` rule.

- [ ] **Step 1: Audit callers.** List every non-test use of `isPartWatched` (~17). Each that means "Play becomes Resume" (iOS `PlayResumeButtonRow` label/action/overlay) moves to `canResume`; each that means "in progress for a badge or rail" keeps `isPartWatched` unchanged. Note the split in the commit message.
- [ ] **Step 2: Write failing tests** `test_canResume_playedWithPosition_isTrue` (movie, `played: true`, ticks 600_000_000 → true), `test_canResume_playedWithoutPosition_isFalse` (ticks 0), `test_canResume_unplayedWithPosition_isTrue`, `test_canResume_series_followsPlayedPercentage` (series, `played: true`, `playedPercentage: 40` → false; unplayed 40 → true). tvOS: `test_playTitle_playedWithPosition_saysResume` → `"Resume"`, and `focusIDs` includes `TVDetailFocus.restart` for that item.
- [ ] **Step 3: Run, expect FAIL** (`canResume` undefined / "Play").
- [ ] **Step 4: Implement** `canResume`; point `PlayResumeButtonRow`, `TVDetailActions.hasResume`, `TVDetailFormat.playTitle` and `DownloadedPlayResumeButtonRow`'s gate at it (Downloads: its own item type; apply the same rule: `resumePositionTicks > 0`, played or not).
- [ ] **Step 5: UI journey.** Add a stub item to the harness's standard scenario with `Played: true` and a position; iOS `AssetDetailJourneyTests` and tvOS `DetailJourneyTests` assert the play button's identifier shows the resume form (existing resume assertions show which identifier/value to read).
- [ ] **Step 6: Run** iOS `UnitTests`, tvOS `TVUnitTests`, the two journeys. Expected: PASS.
- [ ] **Step 7: Commit** (after Benjamin's sign-off on the diff).

### Task 2: Season tiles name their show

**Files:**
- Modify: `DionysusPlayer/Core/Models/MediaItem.swift` (`railTitle` ~219, `railSubtitle` ~232)
- Test: the `MediaItem` model tests

**Interfaces:**
- Produces: for `.season`: `railTitle == seriesName ?? name`; `railSubtitle == name` when `seriesName != nil`, else nil. `accessibilityDescription` follows unchanged.

- [ ] **Step 1: Failing tests** `test_railTitle_season_isSeriesName` ("American Horror Story"), `test_railSubtitle_season_isSeasonName` ("Season 13"), `test_accessibilityDescription_season` == "American Horror Story, Season 13", `test_season_withoutSeriesName_isOneLine` (title "Season 13", subtitle nil).
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** the two `case .season` branches.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Screenshot** a season tile on the iOS and tvOS Simulators (a Home rail; on tvOS also a grid) and send to Benjamin before running the suites (his standing rule for visual changes).
- [ ] **Step 6: Commit** after sign-off.

### Task 3: AetherEngine 7.42.0 with the object-audio traits

**Prerequisite:** PR #360 (bump to 7.42.0) merged into `develop` and this branch updated; ask Benjamin to approve that merge if it hasn't happened.

**Files:**
- Create: `Packages/AetherEngineWithObjectAudio/Package.swift`, `Packages/AetherEngineWithObjectAudio/Sources/AetherEngineWithObjectAudio/Exports.swift`
- Modify: `project.yml` (packages and the `DionysusPlayer`, `DionysusTV` and test targets' dependencies), `.github/workflows/aetherengine-bump.yml`, root `CLAUDE.md` ("Pinning AetherEngine"), `THIRD-PARTY-NOTICES`
- Test: `DionysusPlayerTests/Core/Models/LicenseDocumentTests.swift`; a new `SpatialAudioSupportTests` (Task 4 file) asserting both components are built in

**Interfaces:**
- Produces: a local package product `AetherEngineWithObjectAudio` that `@_exported import AetherEngine`, depending on `https://github.com/superuser404notfound/AetherEngine` `exact: "7.42.0"` with `traits: ["TrueHDObjectAudio", "DTSXObjectAudio"]`. Existing `import AetherEngine` lines keep compiling.

- [ ] **Step 1: Write the package.** `swift-tools-version` that supports traits (6.1+); platforms iOS 18, tvOS 26; one library product. `project.yml`: replace the `AetherEngine` remote package with a local `path: Packages/AetherEngineWithObjectAudio` package; targets that depended on `AetherEngine` depend on the product. Keep the existing explanatory comment, moved to `Package.swift`.
- [ ] **Step 2: Bump workflow.** Make `aetherengine-bump.yml` read and rewrite the `exact:` version in `Packages/AetherEngineWithObjectAudio/Package.swift` instead of `project.yml` (its awk/sed lines ~66 and ~115, and `git add`). Dry-run the extraction line locally against the new file.
- [ ] **Step 3: Generate and build** `xcodegen generate`, then build `DionysusPlayer` (iPhone 17 Simulator) and `DionysusTV` (tvOS 27 Simulator, `-destination id=…`). Expected: BUILD SUCCEEDED; `Dionysus.app/Frameworks/DTSX.framework` exists in both products; the Top Shelf appex links no AetherEngine (`otool -L` on its binary).
- [ ] **Step 4: Release config.** Build both schemes `-configuration Release` for generic device without signing (`CODE_SIGNING_ALLOWED=NO`). Expected: succeeds with `DTSX.framework` embedded. No tag, no upload.
- [ ] **Step 5: Notices.** Read LibTrueHD's and LibDTSX's versions from AetherEngine 7.42.0's `Package.swift`/resolved graph and their `LICENSE`/`NOTICE`/`LICENSES/`. Add `# LibTrueHD` and `# LibDTSX` sections to `THIRD-PARTY-NOTICES` (source, version, licence text; truehdd's Apache-2.0 + LibTrueHD `NOTICE`; LibDTSX as LGPL-3.0-or-later with its `NOTICE`, pointing to the LGPL text already given). Update AetherEngine's (and FFmpeg's, if changed) version lines.
- [ ] **Step 6: Failing test, then pass.** Add "LibTrueHD" and "LibDTSX" to `LicenseDocumentTests`' expected library list; run (FAIL before Step 5's edit is in, PASS after).
- [ ] **Step 7: Docs.** Root `CLAUDE.md` "Pinning AetherEngine": the pin now lives in the wrapper's `Package.swift`, why (traits; XcodeGen drops `traits:`), and the bump workflow edits it there.
- [ ] **Step 8: Run** iOS `UnitTests` and tvOS `TVUnitTests`. Expected: PASS.
- [ ] **Step 9: Commit** after sign-off.

### Task 4: Spatial Audio settings and format rules

**Files:**
- Create: `DionysusPlayer/Core/Playback/SpatialAudio.swift` (model + pure rules), `DionysusPlayer/Core/Persistence/SpatialAudioStore.swift`, `DionysusPlayer/Core/Playback/SpatialAudioSupport.swift` (AetherEngine-backed availability)
- Modify: `project.yml` only if the tvOS target's `includes` needs the new `Core/` files listed (check how `AudioOffsetStore` is included)
- Test: `DionysusPlayerTests/Core/Playback/SpatialAudioTests.swift`, `DionysusPlayerTests/Core/Persistence/SpatialAudioStoreTests.swift`, `SpatialAudioSupportTests`

**Interfaces:**
- Produces:
  - `enum SpeakerLayout: String, CaseIterable, Codable { case l512 = "5.1.2", l514 = "5.1.4", l712 = "7.1.2", l714 = "7.1.4", l916 = "9.1.6" }`
  - `enum SpatialAudioFormat: CaseIterable { case dolbyAtmos, dtsX }` with `var layouts: [SpeakerLayout]` (Atmos: all five; DTS:X: `[.l714, .l916]`) and `static let defaultLayout = SpeakerLayout.l714`
  - `struct SpatialAudioSettings: Equatable { var atmosEnabled = false; var atmosLayout = SpeakerLayout.l714; var dtsXEnabled = false; var dtsXLayout = SpeakerLayout.l714; func layout(for: SpatialAudioFormat) -> SpeakerLayout? }` (nil when that format is off)
  - `enum SpatialAudioRendering: Equatable { case off; case layout(SpeakerLayout) }`
  - `enum SpatialAudioRules` (pure, no AetherEngine): `static func format(of stream: MediaStream) -> SpatialAudioFormat?` (audio, `codec` `truehd` + `audioSpatialFormat == "DolbyAtmos"` → `.dolbyAtmos`; `codec` `dts` + `"DTSX"` → `.dtsX`; E-AC-3 JOC and everything else → nil); `static func rendering(for stream: MediaStream?, settings: SpatialAudioSettings) -> SpatialAudioRendering`; `static func predictedAudioStream(in streams: [MediaStream], rememberedTrackID: Int?, settings: SpatialAudioSettings) -> MediaStream?`
  - `final class SpatialAudioStore` with `var settings: SpatialAudioSettings { get set }`, storage as `AudioOffsetStore` (reuse `AudioOffsetStorage`/`SharedKeychainAudioOffsetStorage`; keys `spatialAudio.atmos.enabled`, `spatialAudio.atmos.layout`, `spatialAudio.dtsx.enabled`, `spatialAudio.dtsx.layout`); an unknown or format-invalid stored layout reads as 7.1.4
  - `enum SpatialAudioSupport { static func isOffered(_ format: SpatialAudioFormat) -> Bool }`: OS 26+ (`#available(iOS 26, tvOS 26, *)`) and `AetherEngine.OptionalComponent.trueHDObjectAudio`/`.dtsxObjectAudio` `.isBuiltIn`

- [ ] **Step 1: Failing tests** for `format(of:)` (TrueHD+DolbyAtmos, DTS+DTSX, EAC3+DolbyAtmos → nil, TrueHD without label → nil); `rendering(for:)` (Atmos on 5.1.2 → `.layout(.l512)`; Atmos off → `.off`; DTS:X on 9.1.6 → `.layout(.l916)`; nil stream → `.off`); `predictedAudioStream` (remembered id wins when present among audio streams, matching `MediaStream.index`; else the default audio stream, or first audio; with Atmos on, a TrueHD Atmos stream of the default's language replaces the default; with DTS:X on, likewise a DTS:X stream; never one whose title contains "Commentary" case-insensitively; never another language); store defaults (both off, both 7.1.4), round-trip, and a stored DTS:X layout of "5.1.2" reading as 7.1.4; `SpatialAudioSupportTests.test_bothComponentsBuiltIn`.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** the types above.
- [ ] **Step 4: Run, expect PASS** on iOS `UnitTests` and tvOS `TVUnitTests`.
- [ ] **Step 5: Commit** after sign-off.

### Task 5: The engine protocol carries the rendering

**Files:**
- Modify: `DionysusPlayer/Core/Playback/PlaybackEngine.swift`, `AetherPlaybackEngine.swift` (`makeLoadOptions` ~496, `load` ~550, stats ~132), `PreviewPlaybackEngine.swift`, `PlaybackTypes.swift` (`PlaybackStats`)
- Test: existing `makeLoadOptions` tests (`AetherPlaybackEngineTests` or equivalent)

**Interfaces:**
- Consumes: `SpatialAudioRendering`, `SpeakerLayout` (Task 4).
- Produces:
  - `load(url:externalSubtitles:knownAtmosAudioTrackIndices:isRemoteHLS:audioOffset:spatialAudio:)`, with the existing convenience overloads passing `.off`
  - `func setSpatialAudio(_ rendering: SpatialAudioRendering) async throws`: rebuilds at the current position via `reloadAtCurrentPosition(applying:)` setting `objectAudioRendering`, keeping the selected audio track and play/pause state; no-op when equal to the current value
  - `var spatialAudio: SpatialAudioRendering { get }` (what the session is loaded with)
  - `makeLoadOptions(..., spatialAudio: SpatialAudioRendering)` mapping `.off` → `.off`, `.layout(l)` → `.apac(SpatialSpeakerLayout(rawValue: l.rawValue)!)`
  - `PlaybackStats.spatialAudio: String?` from `liveTelemetry?.objectAudio`: "7.1.4 · 13 objects, 4 overhead" when `objects > 0`, "7.1.4 · 4 height channels" otherwise (DTS:X); nil when no activity
  - `PreviewPlaybackEngine` records `loadedSpatialAudio` and `spatialAudioReloads: [SpatialAudioRendering]` for tests

- [ ] **Step 1: Check engine behaviour.** In the 7.42.0 source, confirm (a) `reloadAtCurrentPosition(applying:)` keeps the selected audio track (if not, set `audioSourceStreamIndexOverride` in the closure) and (b) what `selectAudioTrack` does under `.apac` for a track of the other format. Record both in `Core/Playback/CLAUDE.md`.
- [ ] **Step 2: Failing tests** `test_makeLoadOptions_spatialOff_isOff`, `test_makeLoadOptions_layout714_isApac714`, every `SpeakerLayout` maps to a `SpatialSpeakerLayout` (`CaseIterable` loop), stats formatting for an Atmos and a DTS:X `ObjectAudioActivity`.
- [ ] **Step 3: Run, expect FAIL.**
- [ ] **Step 4: Implement** in the protocol and both conformers.
- [ ] **Step 5: Run, expect PASS** (both unit plans).
- [ ] **Step 6: Commit** after sign-off.

### Task 6: The player predicts, corrects and switches

**Files:**
- Modify: `DionysusPlayer/Features/Player/PlayerViewModel.swift` (`start()` ~512–630, `startOffline` ~676, `applyStoredTrackSelection` ~1402, `selectAudioTrack` ~1443; init takes a `SpatialAudioStore`)
- Test: `DionysusPlayerTests/Features/Player/PlayerViewModelTests.swift` (with `PreviewPlaybackEngine` or the existing mock engine)

**Interfaces:**
- Consumes: `SpatialAudioRules`, `SpatialAudioStore` (Task 4); `load(... spatialAudio:)`, `setSpatialAudio`, `spatialAudio` (Task 5).

- [ ] **Step 1: Failing tests.**
  - `test_start_predictsAtmosTrack_loadsWithAtmosLayout` (default TrueHD Atmos, Atmos on 5.1.4 → loaded `.layout(.l514)`, no reloads)
  - `test_start_rememberedDTSX_loadsWithDTSXLayout` (remembered id is the DTS:X stream, DTS:X on 9.1.6 → `.layout(.l916)`, no reloads)
  - `test_start_mispredicted_reloadsOnce` (prediction says Atmos, engine reports the DTS:X track selected after `applyStoredTrackSelection`, settings differ → exactly one reload to the DTS:X value; Review Focus 1)
  - `test_selectAudioTrack_atmosToDTSXWithDTSXOff_reloadsOff` (Review Focus 2)
  - `test_selectAudioTrack_sameRenderingNeeded_noReload`
  - `test_offlineAndTranscode_loadOff_neverReload` (Review Focus 5)
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** In `start()`, read `SpatialAudioStore().settings`, predict with `predictedAudioStream(in: source.mediaStreams, rememberedTrackID: trackPreferenceStore.selection(...)?.audioTrack?.id, settings:)`, pass `rendering(for:)` to `load` (`.off` when `isRemoteHLS`). After `applyStoredTrackSelection()`, compute the needed rendering from the selected engine track's `MediaStream` (match `index` to track id, as `atmosAudioTrackIndices` does) and `await engine.setSpatialAudio(needed)` if it differs, before the resume seek. In `selectAudioTrack(id:)`, after selecting, do the same. `startOffline` passes `.off` and never corrects. A failed `setSpatialAudio` is logged and playback continues as loaded.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** after sign-off.

### Task 7: Playback Stats shows Spatial Audio

**Files:**
- Modify: `DionysusPlayer/Features/Player/PlaybackStatsReport.swift` (`audio(...)` ~111)
- Test: `PlaybackStatsReportTests`

- [ ] **Step 1: Failing test** `test_audioSection_spatialAudioRow_whenRendering` (row "Spatial Audio" with `stats.spatialAudio`), and no such row when nil.
- [ ] **Step 2: Run, expect FAIL.** **Step 3: Implement** (row after "Output Channels"; title via `String(localized:)`). **Step 4: Run, expect PASS.** Both platforms show it through the shared report; check tvOS `PlayerStatsJourneyTests` still passes.
- [ ] **Step 5: Commit** after sign-off.

### Task 8: iOS settings

**Files:**
- Modify: `DionysusPlayer/Features/Profile/ProfileView.swift` (Playback section, after Audio Offset ~453), `DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift` (`A11yID.Profile`)
- Test: `DionysusPlayerUITests/Journeys/ProfileJourneyTests.swift`, `AccessibilityAuditTests.swift`, `Screens/Screens.swift`

**Interfaces:**
- Consumes: `SpatialAudioStore`, `SpatialAudioFormat.layouts`, `SpatialAudioSupport.isOffered` (Task 4).
- Produces: `A11yID.Profile.spatialAtmosToggle`, `.spatialAtmosLayout`, `.spatialDTSXToggle`, `.spatialDTSXLayout`.

- [ ] **Step 1: Implement** per format, only when `isOffered`: `Toggle("Dolby Atmos as Spatial Audio")` / `Toggle("DTS:X as Spatial Audio")`; while on, `Picker("Speaker Layout")` over the format's `layouts`, 7.1.4's label "7.1.4 (Recommended for AirPods)" (footer line instead if the row truncates at the largest default text size on iPhone 17); the footer copy from the spec ("Keeps the height channels of TrueHD Atmos tracks for a receiver with height speakers or for Spatial Audio headphones. The audio is re-encoded, so it isn't lossless."; DTS:X likewise). State mirrors the store as the Audio Offset row does. Add a harness launch argument only if needed to force `isOffered` on the iOS 26 Simulator (it should already be true there).
- [ ] **Step 2: Screenshot** Profile → Playback with both toggles on and send to Benjamin; wait for his OK before tests.
- [ ] **Step 3: Journey** `testSpatialAudioToggleShowsLayoutPicker`: toggle hidden layout appears with 7.1.4 selected; DTS:X picker offers exactly two options; choice survives relaunch. Extend the Profile audit to cover the rows.
- [ ] **Step 4: Run** the journey and the audit. Expected: PASS.
- [ ] **Step 5: Commit** after sign-off.

### Task 9: Apple TV settings

**Files:**
- Modify: `DionysusTV/Shell/Profile/TVProfileView.swift` (Playback section after Audio Offset), `DionysusTV/Shell/Profile/TVSettingsPicker.swift` if it needs a generic option list, `A11yID.TV.Profile`
- Test: `DionysusTVUITests/ProfileJourneyTests.swift`, `DionysusTVUITests/AccessibilityAuditTests.swift`

- [ ] **Step 1: Implement** two on/off `TVSettingsRow`s (Select flips) and, while on, a "Speaker Layout" row opening a `TVSettingsPicker` page of that format's layouts (current ticked and focused), each row's footer as its hint (the spec's copy; no AirPods note on tvOS). Value as accessibility value.
- [ ] **Step 2: Screenshot** on the tvOS 27 Simulator and send to Benjamin; wait for his OK.
- [ ] **Step 3: Journey** `test_spatialAudio_toggleRevealsLayout_andPickerChooses`: flip Atmos on, layout row appears reading 7.1.4, choose 5.1.2, Menu returns with the value changed; DTS:X picker lists two. Compare accessibility values before/after, never to literal "On".
- [ ] **Step 4: Run** the journey on tvOS 27 and 26.5, and the Profile audit. Expected: PASS.
- [ ] **Step 5: Commit** after sign-off.

### Task 10: Docs, strings, full suites, device hand-off

**Files:**
- Modify: `DionysusPlayer/Core/Playback/CLAUDE.md`, `DionysusTV/CLAUDE.md` ("HDR and audio", Profile rows), `README.md` (feature list, if it names audio formats), `DionysusPlayer/Resources/Localizable.xcstrings`

- [ ] **Step 1: Docs.** Playback CLAUDE.md: the two settings, prediction + correction, fallbacks, what Task 5 Step 1 found. tvOS CLAUDE.md: TrueHD Atmos no longer always loses its heights; the new rows.
- [ ] **Step 2: String Catalog.** Sync via an Xcode.app build (memory: `automate-xcstrings-catalog-sync`); commit the diff.
- [ ] **Step 3: Full suites, one at a time:** tvOS `TVUnitTests`, tvOS `TVUITests` (warm-up first), iOS `UnitTests`, iOS `UITests-Smoke`. Expected: all PASS. Restore the Simulators to SavareseHillFlix as Ben.
- [ ] **Step 4: Device check, asking Benjamin before each deploy:** Living Room, a TrueHD Atmos and a DTS:X title, toggle off (DD+, as today) and on (AVR shows Atmos; heights audible; Stats row), plus a seek and a resume; iPhone with AirPods on the same titles.
- [ ] **Step 5: PR** into `develop` with the deferred items listed; merge only with Benjamin's approval once checks pass.
